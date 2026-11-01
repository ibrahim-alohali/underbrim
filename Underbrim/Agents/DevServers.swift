//
//  DevServers.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Ports a session's commands serve (a dev server on localhost:3000), for its card: TCP
//  listeners among the agent's children or processes working in its folder (not apps).
//  Read from libproc off the main thread, every few seconds, only while the Agents page
//  shows. Stop sends SIGTERM to that process if it still serves the port.
//

import Darwin
import Foundation

struct DevServer: Identifiable, Equatable, Sendable {
    let port: Int
    let pid: pid_t
    let program: String
    var id: Int { port }

    var url: URL? { URL(string: "http://localhost:\(port)") }
}

@MainActor @Observable
final class DevServerStore {
    static let shared = DevServerStore()

    /// By session id, lowest port first.
    private(set) var servers: [String: [DevServer]] = [:]

    @ObservationIgnored private var viewers = 0
    @ObservationIgnored private var task: Task<Void, Never>?

    /// The Agents page came on screen (or left): scans run only meanwhile.
    func watch(_ on: Bool) {
        viewers = max(0, viewers + (on ? 1 : -1))
        if viewers > 0, task == nil {
            task = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.scan()
                    try? await Task.sleep(for: .seconds(3))
                }
            }
        } else if viewers == 0 {
            task?.cancel()
            task = nil
        }
    }

    func stop(_ server: DevServer) {
        // The scan may be a few seconds old: the process could have ended and its number gone to another.
        if DevServerScan.listeningPorts(of: server.pid).contains(server.port) { kill(server.pid, SIGTERM) }
        Task {
            try? await Task.sleep(for: .seconds(0.5))
            await scan()
        }
    }

    private func scan() async {
        let sessions = AgentSessionStore.shared.visibleSessions
            .filter { !$0.hasEnded && ($0.agentPID != nil || $0.cwd != nil) }
            .map { DevServerScan.Session(id: $0.id, agent: $0.agentPID, folder: $0.cwd) }
        let found = sessions.isEmpty ? [:] : await Task.detached(priority: .utility) { DevServerScan.run(sessions) }.value
        if found != servers { servers = found }
    }
}

enum DevServerScan {
    struct Session: Sendable {
        let id: String
        let agent: pid_t?
        let folder: String?
    }

    private struct Process {
        let pid: pid_t
        let parent: pid_t
        let name: String
    }

    static func run(_ sessions: [Session]) -> [String: [DevServer]] {
        let processes = ownProcesses()
        var children: [pid_t: [pid_t]] = [:]
        for process in processes.values { children[process.parent, default: []].append(process.pid) }
        var result: [String: [DevServer]] = [:]
        // A folder's processes, looked up once for all sessions. Not the home folder: everything
        // started from a terminal's first prompt works there.
        let folders = Set(sessions.compactMap { $0.folder.flatMap(realPath) }.filter { $0.count > 1 && $0 != realPath(NSHomeDirectory()) })
        var inFolder: [String: Set<pid_t>] = [:]
        if !folders.isEmpty {
            for pid in processes.keys where !isApp(pid) {
                guard let cwd = workingDirectory(of: pid) else { continue }
                for folder in folders where cwd == folder || cwd.hasPrefix(folder + "/") { inFolder[folder, default: []].insert(pid) }
            }
        }
        var listening: [pid_t: [Int]] = [:]
        for session in sessions {
            var candidates = session.folder.flatMap(realPath).flatMap { inFolder[$0] } ?? []
            if let agent = session.agent { candidates.formUnion(descendants(of: agent, children: children)) }
            // The agent itself (and its app) aren't the session's servers.
            if let agent = session.agent { candidates.remove(agent) }
            var byPort: [Int: DevServer] = [:]
            for pid in candidates.sorted() {
                let ports = listening[pid] ?? listeningPorts(of: pid)
                listening[pid] = ports
                for port in ports where byPort[port] == nil {
                    byPort[port] = DevServer(port: port, pid: pid, program: processes[pid]?.name ?? "")
                }
            }
            if !byPort.isEmpty { result[session.id] = byPort.values.sorted { $0.port < $1.port } }
        }
        return result
    }

    private static func ownProcesses() -> [pid_t: Process] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [:] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let found = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        let user = getuid()
        var processes: [pid_t: Process] = [:]
        for pid in pids.prefix(Int(max(0, found))) where pid > 0 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == user else { continue }
            let name = withUnsafeBytes(of: info.pbi_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let comm = withUnsafeBytes(of: info.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            processes[pid] = Process(pid: pid, parent: pid_t(info.pbi_ppid), name: name.isEmpty ? comm : name)
        }
        return processes
    }

    /// As the process table names folders: links resolved ("/tmp" is "/private/tmp").
    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func descendants(of root: pid_t, children: [pid_t: [pid_t]]) -> Set<pid_t> {
        var found: Set<pid_t> = []
        var queue = children[root] ?? []
        while let pid = queue.popLast(), found.count < 4096 {
            guard found.insert(pid).inserted else { continue }
            queue += children[pid] ?? []
        }
        return found
    }

    private static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return path.isEmpty ? nil : path
    }

    /// An installed app's own process (in its MacOS or Frameworks folder), not a tool an app
    /// carries elsewhere, such as the python3 in Xcode's Developer folder.
    private static func isApp(_ pid: pid_t) -> Bool {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
        let path = String(cString: buffer)
        guard RelayLink.isInstalledLocation(path), let bundle = path.range(of: ".app/Contents/") else { return false }
        let inside = path[bundle.upperBound...]
        return inside.hasPrefix("MacOS/") || inside.hasPrefix("Frameworks/")
    }

    static func listeningPorts(of pid: pid_t) -> [Int] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / MemoryLayout<proc_fdinfo>.stride + 8)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * MemoryLayout<proc_fdinfo>.stride))
        guard filled > 0 else { return [] }
        var ports: [Int] = []
        for fd in fds.prefix(Int(filled) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var socket = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &socket, size) == size,
                  socket.psi.soi_kind == SOCKINFO_TCP,
                  socket.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: socket.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport)))
            if port > 0, !ports.contains(port) { ports.append(port) }
        }
        return ports
    }
}
