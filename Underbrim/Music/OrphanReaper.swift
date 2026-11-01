//
//  OrphanReaper.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The Now Playing adapter never notices its parent going away, so a killed or crashed run leaves
//  its adapters (≈6 MB each) and the launch check's stand-in player running. At launch, end orphaned
//  ones of *this* bundle, nobody else's.
//

import Darwin
import Foundation

enum OrphanReaper {
    static func reapAdapters() {
        guard let scriptPath = Bundle.main.path(forResource: "mediaremote-adapter", ofType: "pl"), !scriptPath.isEmpty else { return }
        let testClientPath = Bundle.main.path(forResource: "MediaRemoteAdapterTestClient", ofType: nil)
        DispatchQueue.global(qos: .utility).async {
            for pid in orphans(runningScript: scriptPath, testClient: testClientPath, psOutput: listProcesses()) {
                kill(pid, SIGTERM)
            }
        }
    }

    /// `ps -axo pid=,ppid=,uid=,command=` lines → orphaned pids of ours: adapters
    /// running this bundle's script, and its test client (run without arguments).
    static func orphans(runningScript scriptPath: String, testClient: String?, psOutput: String) -> [pid_t] {
        let uid = getuid()
        return psOutput.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard fields.count == 4, let pid = pid_t(fields[0]), fields[1] == "1", uid_t(fields[2]) == uid else { return nil }
            let command = fields[3]
            return command.contains(" \(scriptPath) ") || testClient.map { command == $0 } == true ? pid : nil
        }
    }

    private static func listProcesses() -> String {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "pid=,ppid=,uid=,command="]
        ps.environment = Process.cleanEnvironment()
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
