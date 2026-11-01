//
//  RelayServer.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Owner-only Unix socket receiving `RelayEvent` lines from `underbrim-relay`, all
//  on one private queue, each checked and turned into a RelayMessage as it's read. A
//  request keeps its connection open for the answer; the helper closing it (answered
//  elsewhere, or gone) withdraws the request.
//

import Darwin
import Foundation

final class RelayServer: @unchecked Sendable {
    enum StartError: Error, Equatable {
        case directory(String)
        case pathOccupied
        case alreadyRunning
        case socket(Int32)
    }

    private static let allowedProviders: Set<String> = Set(AgentProvider.allCases.map(\.rawValue)).union(["chrome"])
    private static let maxConnections = 32
    /// Requests held at once (each holds a connection), leaving the rest for status events.
    private static let maxHeldRequests = 24

    private let path = Relay.socketPath
    private let directory = Relay.supportDirectory
    private let queue = DispatchQueue(label: "\(bundleIdentifier).relay-server")
    private let onMessage: @Sendable (RelayMessage) -> Void
    private let onRequestEnded: @Sendable (String) -> Void

    // Queue-confined state.
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [Int32: (source: DispatchSourceRead, lines: LineSplitter)] = [:]
    /// Connections holding a request (fd → request id), and the reverse.
    private var held: [Int32: String] = [:]
    private var heldConnection: [String: Int32] = [:]
    private var tokens: Double = 200
    private var lastRefill = DispatchTime.now()

    /// `onMessage` gets a request once its connection is held for the answer.
    init(
        onMessage: @escaping @Sendable (RelayMessage) -> Void,
        onRequestEnded: @escaping @Sendable (String) -> Void
    ) {
        self.onMessage = onMessage
        self.onRequestEnded = onRequestEnded
    }

    deinit { stopOnQueue() }

    func start() throws(StartError) {
        let failure: StartError? = queue.sync {
            do throws(StartError) {
                try startOnQueue()
                return nil
            } catch {
                return error
            }
        }
        if let failure { throw failure }
    }

    func stop() {
        queue.sync { stopOnQueue() }
    }

    /// Answers the request `id` (nil: hands it back to the agent's prompt) and closes its connection.
    func reply(_ answer: RelayAnswer?, to id: String) {
        queue.async { [self] in
            guard let fd = heldConnection.removeValue(forKey: id) else { return }
            held[fd] = nil
            if let answer, var line = try? JSONEncoder().encode(answer), line.count < Relay.maxLineBytes {
                line.append(0x0A)
                // A few hundred bytes to a helper that's waiting for them; never stall the queue.
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
                var timeout = timeval(tv_sec: 0, tv_usec: 250_000)
                setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                _ = RelayClient.write(fd, line)
            }
            drop(fd)
        }
    }

    // MARK: - Setup

    private func startOnQueue() throws(StartError) {
        guard listenFD < 0 else { return }
        try prepareDirectory()
        try clearStaleSocket()

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StartError.socket(errno) }
        guard let bound = Relay.withSocketAddress(path, { bind(fd, $0, $1) }) else {
            close(fd)
            throw StartError.directory("socket path too long")
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, SOMAXCONN) == 0 else {
            let code = errno
            close(fd)
            unlink(path)
            throw StartError.socket(code)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listenFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        // Closing in the cancel handler keeps the fd number from being reused
        // while the source may still be delivering an event.
        source.setCancelHandler { close(fd) }
        acceptSource = source
        source.resume()
    }

    /// The containing folder must be ours and private (0700).
    private func prepareDirectory() throws(StartError) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            throw StartError.directory(error.localizedDescription)
        }
        var st = stat()
        guard lstat(directory.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == getuid() else {
            throw StartError.directory("not an owned directory")
        }
        if st.st_mode & 0o077 != 0, chmod(directory.path, 0o700) != 0 {
            throw StartError.directory("cannot make private")
        }
    }

    /// Removes a leftover socket from a previous run — but never a regular
    /// file, a symlink, or a socket another live instance is serving.
    private func clearStaleSocket() throws(StartError) {
        var st = stat()
        guard lstat(path, &st) == 0 else { return }
        guard (st.st_mode & S_IFMT) == S_IFSOCK, st.st_uid == getuid() else { throw StartError.pathOccupied }
        let probe = RelayClient.connect(path: path)
        if probe >= 0 {
            close(probe)
            throw StartError.alreadyRunning
        }
        unlink(path)
    }

    private func stopOnQueue() {
        acceptSource?.cancel()
        acceptSource = nil
        for conn in connections.values { conn.source.cancel() }
        connections.removeAll()
        for id in held.values { onRequestEnded(id) }
        held.removeAll()
        heldConnection.removeAll()
        if listenFD >= 0 {
            listenFD = -1
            unlink(path)
        }
    }

    // MARK: - Connections

    private func acceptPending() {
        while true {
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else { return }
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == getuid(),
                  connections.count < Self.maxConnections else {
                close(fd)
                continue
            }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.readAvailable(fd) }
            source.setCancelHandler { close(fd) }
            connections[fd] = (source, LineSplitter(maxLine: Relay.maxLineBytes))
            source.resume()
        }
    }

    private func drop(_ fd: Int32) {
        connections.removeValue(forKey: fd)?.source.cancel()
        if let id = held.removeValue(forKey: fd) {
            heldConnection[id] = nil
            onRequestEnded(id)
        }
    }

    /// Lines are handled chunk by chunk, so a sender that never ends a line
    /// is dropped at the limit instead of filling memory.
    private func readAvailable(_ fd: Int32) {
        var chunk = [UInt8](repeating: 0, count: 4096)
        while connections[fd] != nil {
            let n = read(fd, &chunk, chunk.count)
            if n > 0 {
                guard let lines = connections[fd]?.lines.append(Data(chunk[0..<n])) else { return }
                for line in lines where connections[fd] != nil { handle(line: line, from: fd) }
                if connections[fd]?.lines.overflowed == true { drop(fd); return }
                continue
            }
            if n == 0 || (errno != EAGAIN && errno != EINTR) {
                if let last = connections[fd]?.lines.finish() { handle(line: last, from: fd) }
                drop(fd)
            }
            return
        }
    }

    private func handle(line: Data, from fd: Int32) {
        // A connection holding a request has said all it may.
        guard held[fd] == nil, !line.isEmpty else { return }
        guard line.count <= Relay.maxLineBytes, takeToken(), let message = Self.decode(line) else {
            if Self.isRequest(line) { drop(fd) }
            return
        }
        guard case .request(let arrival) = message else { return onMessage(message) }
        let id = arrival.request.id
        guard held.count < Self.maxHeldRequests, heldConnection[id] == nil else { return drop(fd) }
        held[fd] = id
        heldConnection[id] = fd
        onMessage(message)
    }

    /// A request refused is the end of its connection: the hook waiting on it (one from another version,
    /// say) gives up at once and leaves the agent to ask, instead of holding a connection till its timeout.
    /// Other lines are only skipped: Chrome's host sends all of its own on one connection.
    private static func isRequest(_ line: Data) -> Bool {
        struct Kind: Decodable { let kind: String }
        return (try? JSONDecoder().decode(Kind.self, from: line))?.kind == "Request"
    }

    /// Token bucket: sustained 100 lines/s, bursts of 200. A runaway hook
    /// loop can't flood the main thread.
    private func takeToken() -> Bool {
        let now = DispatchTime.now()
        let elapsed = Double(now.uptimeNanoseconds - lastRefill.uptimeNanoseconds) / 1e9
        lastRefill = now
        tokens = min(200, tokens + elapsed * 100)
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }

    /// Strict decode + re-validation: the socket is owner-only, but the app
    /// still treats every line as untrusted input. An unknown kind goes no further.
    static func decode(_ line: Data) -> RelayMessage? {
        guard var event = try? JSONDecoder().decode(RelayEvent.self, from: line),
              event.v == RelayEvent.currentVersion,
              allowedProviders.contains(event.provider),
              Relay.identifier(event.kind, maxLength: 48) != nil,
              event.ts.isFinite, event.ts > 0,
              event.session.map({ Relay.identifier($0) != nil }) ?? true,
              event.cwd.map({ Relay.path($0) != nil }) ?? true,
              event.tool.map({ Relay.identifier($0, maxLength: 96) != nil }) ?? true,
              event.detail.map({ Relay.identifier($0, maxLength: 48) != nil }) ?? true,
              event.name.map({ Relay.fileName($0) == $0 }) ?? true,
              event.host.map({ Relay.identifier($0) != nil }) ?? true,
              event.title.map({ Relay.label($0, maxLength: 200) == $0 }) ?? true,
              event.entry.map({ RelaySanitizer.entrypoints.contains($0) }) ?? true,
              event.hostSession.map({ Relay.desktopSessionID($0) == $0 }) ?? true,
              (event.pid ?? 2) > 1,
              (event.received ?? 0) >= 0, (event.total ?? 0) >= -1,
              (event.windows ?? []).count <= 4,
              (event.windows ?? []).allSatisfy({ Relay.identifier($0.id, maxLength: 32) != nil && (0...100).contains($0.used) }),
              (event.kind == "Request") == (event.request != nil),
              event.request.map(isValid) ?? true
        else { return nil }
        // Sessions order events by time: one stamped ahead of the clock would make the next ones look stale.
        event.ts = min(event.ts, Date().timeIntervalSince1970)
        return RelayMessage(event)
    }

    /// The sizes the helper keeps to; the payload's shape (one to four questions, a plan with
    /// something to show) is already checked by its type.
    static func isValid(_ request: RelayRequest) -> Bool {
        guard Relay.identifier(request.id, maxLength: 64) != nil,
              request.tool.map({ Relay.identifier($0, maxLength: 96) != nil }) ?? true,
              request.mode.map({ Relay.identifier($0, maxLength: 32) != nil }) ?? true
        else { return false }
        switch request.payload {
        case .permission(let action, let suggestions):
            return suggestions.count <= 8 && suggestions.allSatisfy({ (0..<8).contains($0.index) })
                && (action.diff ?? []).count <= RelayRequestBuilder.maxDiffLines
        case .question(let questions):
            let places = questions.all.map(\.sourceIndex)
            return Set(places).count == places.count && places.allSatisfy({ (0..<4).contains($0) })
                && questions.all.allSatisfy { question in
                    let options = question.options.map(\.sourceIndex)
                    return options.count <= 6 && Set(options).count == options.count && options.allSatisfy({ (0..<6).contains($0) })
                }
        case .plan(let plan):
            return plan.file.map({ Relay.path($0) != nil }) ?? true
        }
    }
}
