//
//  ProcessLineage.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Finds, from inside a hook, the agent process (to notice its exit) and the
//  app hosting it (to activate it without a deep link).
//

import Darwin
import Foundation

enum ProcessLineage {
    struct Info: Equatable {
        let pid: pid_t
        let ppid: pid_t
        /// Start time (µs since 1970); with the pid, survives pid reuse.
        let start: UInt64
        let path: String
    }

    private static let launchers: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "env", "nohup", "timeout"]

    static func info(_ pid: pid_t) -> Info? {
        var bsd = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size else { return nil }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        let path = length > 0 ? String(cString: buffer) : ""
        return Info(pid: pid, ppid: pid_t(bsd.pbi_ppid), start: bsd.pbi_start_tvsec * 1_000_000 + bsd.pbi_start_tvusec, path: path)
    }

    /// Ancestors from `pid` up to (not including) launchd.
    static func ancestors(of pid: pid_t) -> [Info] {
        var chain: [Info] = []
        var current = pid
        while current > 1, chain.count < 64, let item = info(current) {
            chain.append(item)
            current = item.ppid
        }
        return chain
    }

    /// The first ancestor that isn't a shell or launcher is the agent; the
    /// outermost one inside an `.app` bundle is the host app.
    static func agentAndHost(chain: [Info]) -> (agent: Info?, hostBundleID: String?) {
        let agent = chain.first { !launchers.contains(($0.path as NSString).lastPathComponent) }
        let host = chain.reversed().lazy.compactMap { bundlePath(in: $0.path) }.first
        return (agent, host.flatMap { Bundle(path: $0)?.bundleIdentifier })
    }

    /// "/Applications/Foo.app/Contents/MacOS/foo" → "/Applications/Foo.app"
    static func bundlePath(in executablePath: String) -> String? {
        guard let range = executablePath.range(of: ".app/Contents/") else { return nil }
        return String(executablePath[..<range.lowerBound]) + ".app"
    }
}
