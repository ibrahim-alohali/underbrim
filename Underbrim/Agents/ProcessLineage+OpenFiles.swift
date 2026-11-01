//
//  ProcessLineage+OpenFiles.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Which process holds a file open, for the Codex logs no other file ties to a process.
//

import Darwin
import Foundation

extension ProcessLineage {
    static func holder(of path: String, namePrefix: String) -> pid_t? {
        pids(namePrefix: namePrefix).first { openPaths(of: $0).contains(path) }
    }

    /// The files under `folder` (a real path ending in "/") that processes named `namePrefix…` have open.
    static func openFiles(namePrefix: String, under folder: String) -> [(pid: pid_t, path: String)] {
        pids(namePrefix: namePrefix).flatMap { pid in openPaths(of: pid).filter { $0.hasPrefix(folder) }.map { (pid, $0) } }
    }

    private static func pids(namePrefix: String) -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: Int(max(0, proc_listallpids(nil, 0))) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return pids.prefix(Int(max(0, count))).filter { pid in
            var name = [CChar](repeating: 0, count: 64)
            return pid > 0 && proc_name(pid, &name, UInt32(name.count)) > 0 && String(cString: name).hasPrefix(namePrefix)
        }
    }

    private static func openPaths(of pid: pid_t) -> [String] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / MemoryLayout<proc_fdinfo>.stride)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * MemoryLayout<proc_fdinfo>.stride))
        return fds.prefix(Int(max(0, filled)) / MemoryLayout<proc_fdinfo>.stride).compactMap { fd in
            guard fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) else { return nil }
            var vnode = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &vnode, size) == size else { return nil }
            return withUnsafeBytes(of: vnode.pvip.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        }
    }
}
