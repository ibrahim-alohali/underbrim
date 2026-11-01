//
//  AgentFileWatcher.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Follows Claude Code and Codex sessions through files the agents keep anyway
//  (ClaudeSessionFiles, CodexRollout): one FSEvents stream, no polling, nothing changed
//  in either app. Changes become AgentEvents for AgentSession's reducer, timed by
//  the files themselves so a late arrival never moves a session back. One private queue.
//

import CoreServices
import Darwin
import Foundation

final class AgentFileWatcher: @unchecked Sendable {
    struct Update: Equatable, Sendable {
        let event: AgentEvent
        /// Claude reports this session's state itself, so silence never makes it quiet.
        let live: Bool
        var details: AgentDetails?
    }

    /// At launch, Codex threads untouched for longer are left out (as long
    /// as the store keeps an idle session).
    static let launchWindow: TimeInterval = 90 * 60
    /// The transcript's last lines can land just after the status says idle.
    static let turnEndGrace: TimeInterval = 0.25

    private let claudeSessions: URL
    let claudeProjects: URL
    private let codexSessions: URL
    let codexIndex: URL
    let queue = DispatchQueue(label: "\(bundleIdentifier).agent-files")
    private let deliver: @Sendable ([Update]) -> Void

    // Queue-confined.
    private var stream: FSEventStreamRef?
    var claude: [Int32: ClaudeSession] = [:]
    var codex: [String: CodexThread] = [:]
    var pending: [Update] = []
    var codexNames: [String: String] = [:]
    /// Codex names a thread a few seconds in, often after the turn's last line:
    /// the file is followed like a log, so the name doesn't wait for the next turn.
    var codexIndexSource: DispatchSourceFileSystemObject?

    /// The agent's process (for exit detection) and the app hosting it, put on
    /// every event so a session the store dropped comes back complete.
    struct AgentProcess {
        var stamp: ProcessStamp?
        var host: String?
    }

    struct ClaudeSession {
        /// The turn as the transcript tells it.
        enum Turn: Equatable {
            /// None read yet.
            case none
            case running
            case ended(Outcome, at: Date)
        }

        enum Outcome: Equatable {
            case done, interrupted
            case failed(reason: String?)

            var event: AgentEvent.Kind {
                switch self {
                case .done: .stop
                case .interrupted: .interrupt
                case .failed(let reason): .stopFailure(reason: reason)
                }
            }
        }

        let process: AgentProcess
        var record: ClaudeSessionRegistry.Record
        var transcript: URL?
        var tail = JSONLTail()
        /// Tool calls whose results aren't in yet, oldest first.
        var running: [(id: String?, name: String, target: String?)] = []
        var details = AgentDetails()
        var lastText: String?
        var turn = Turn.none
        /// The last line was the app's own words, not yet answered by Claude.
        var appWords = false
        var live: Bool { record.status != nil }
        /// A tool call whose result isn't in yet (the newest, when several run).
        var tool: String? { running.last?.name }
        /// What a busy status means now: the tool at work, or the Claude app's offer card waiting on the user.
        var busyEvent: AgentEvent.Kind {
            if details.offer != nil { return .notification(.agentNeedsInput) }
            return tool.map { .preToolUse(tool: $0) } ?? .userPromptSubmit
        }
    }

    struct CodexThread {
        let id: String
        var meta = CodexRollout.Meta()
        var process = AgentProcess()
        var tail = JSONLTail()
        var details = AgentDetails()
        var lastText: String?
        var seenAt = Date()
        /// Codex keeps the log open while it writes, and FSEvents reports a
        /// file's changes only once it's closed; kqueue reports every append.
        var source: DispatchSourceFileSystemObject?
    }

    init(deliver: @escaping @Sendable ([Update]) -> Void) {
        // FSEvents reports real paths (/private/var/…, a symlinked ~/.claude's
        // target), and only matches watched paths given that way.
        let home = AgentFiles.home
        claudeSessions = URL(fileURLWithPath: Self.realPath(AgentFiles.claudeSessions(home: home).path))
        claudeProjects = URL(fileURLWithPath: Self.realPath(AgentFiles.claudeProjects(home: home).path))
        codexSessions = URL(fileURLWithPath: Self.realPath(AgentFiles.codexSessions(home: home).path))
        codexIndex = URL(fileURLWithPath: Self.realPath(AgentFiles.codexIndex(home: home).path))
        self.deliver = deliver
    }

    /// `path` with symlinks resolved as far as it exists (not
    /// resolvingSymlinksInPath, which strips /private).
    static func realPath(_ path: String) -> String {
        if let real = realpath(path, nil) {
            defer { free(real) }
            return String(cString: real)
        }
        let parent = (path as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != path else { return path }
        return (realPath(parent) as NSString).appendingPathComponent((path as NSString).lastPathComponent)
    }

    deinit {
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
        codexIndexSource?.cancel()
    }

    /// Watches the three folders (even missing ones) and picks up running sessions.
    func start() {
        queue.async { [self] in
            guard stream == nil else { return }
            var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                               retain: nil, release: nil, copyDescription: nil)
            let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
                guard let info else { return }
                let watcher = Unmanaged<AgentFileWatcher>.fromOpaque(info).takeUnretainedValue()
                watcher.handle(paths: unsafeBitCast(paths, to: NSArray.self) as? [String] ?? [])
            }
            let roots = [claudeSessions, claudeProjects, codexSessions].map(\.path) as CFArray
            let flags = kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
            guard let stream = FSEventStreamCreate(nil, callback, &context, roots,
                                                   FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05,
                                                   FSEventStreamCreateFlags(flags))
            else { return }
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
            self.stream = stream
            // After the stream starts, so nothing written meanwhile is missed.
            scan()
        }
    }

    func stop() {
        queue.sync {
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            codex.values.forEach { $0.source?.cancel() }
            codex = [:]
            claude = [:]  // a pending finishTurn then finds nothing to read
            codexIndexSource?.cancel()
            codexIndexSource = nil
            codexNames = [:]
        }
    }

    // MARK: - Changes

    func scan() {
        let files = FileManager.default
        func children(_ url: URL) -> [URL] {
            ((try? files.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []).sorted { $0.path < $1.path }
        }
        var paths = children(claudeSessions).map(\.path)
        let cutoff = Date().addingTimeInterval(-Self.launchWindow)
        // The two newest day folders, across a month or year change too.
        let days = children(codexSessions).suffix(2).flatMap(children).suffix(2).flatMap(children).suffix(2)
        for file in days.flatMap(children) {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified > cutoff { paths.append(file.path) }
        }
        handle(paths: paths)
        lookForOpenCodexThreads()
        flush()
    }

    /// Codex threads its processes hold open, from any day: FSEvents reports a log only once
    /// closed, and the Codex app keeps a loaded thread's log open (even one from days ago).
    func findOpenCodexThreads() {
        queue.async { [self] in
            guard stream != nil else { return }
            lookForOpenCodexThreads()
            flush()
        }
    }

    private func lookForOpenCodexThreads() {
        for (pid, path) in ProcessLineage.openFiles(namePrefix: "codex", under: codexSessions.path + "/")
        where codex[path]?.source == nil && CodexRollout.threadID(fileName: (path as NSString).lastPathComponent) != nil {
            rolloutChanged(URL(fileURLWithPath: path), holder: pid)
        }
    }

    func handle(paths: [String]) {
        var statusFiles: [Int32: URL] = [:]
        for path in Set(paths) {
            let url = URL(fileURLWithPath: path)
            let folder = url.deletingLastPathComponent()
            if folder.path == claudeSessions.path, let pid = ClaudeSessionRegistry.pid(fileName: url.lastPathComponent) {
                statusFiles[pid] = url
            } else if url.pathExtension == "jsonl", folder.deletingLastPathComponent().path == claudeProjects.path {
                transcriptChanged(url)
            } else if path.hasPrefix(codexSessions.path + "/"), CodexRollout.threadID(fileName: url.lastPathComponent) != nil {
                rolloutChanged(url)
            }
        }
        // After the transcripts, so a status change sees the lines written just before it. Files still there
        // first: a session a new process carries on (a restart) is taken over before the old file's removal
        // could read as its end.
        let present = statusFiles.filter { FileManager.default.fileExists(atPath: $0.value.path) }
        for (pid, url) in present { statusFileChanged(pid: pid, url: url) }
        for (pid, url) in statusFiles where present[pid] == nil { statusFileChanged(pid: pid, url: url) }
        flush()
    }

    func flush() {
        guard !pending.isEmpty else { return }
        let outputs = pending
        pending = []
        deliver(outputs)
    }
}
