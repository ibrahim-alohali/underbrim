//
//  HookInstallerTests.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Editing someone's agent config must keep everything that isn't ours, exactly as
//  it was, and be fully reversible.
//

import Foundation
import Testing
@testable import Underbrim

struct HookInstallerTests {
    private let relay = "/Users/me/Library/Application Support/Underbrim/bin/underbrim-relay"

    private func sandbox() throws -> (home: URL, backups: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("underbrim-hooks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        return (root, root.appendingPathComponent("backups"))
    }

    private func installer(_ agent: AgentProvider, home: URL) throws -> HookInstaller {
        try #require(HookInstaller(agent: agent, home: home.path, relayPath: relay))
    }

    @Test func keepsTheUsersHooksAndRemovesExactlyOurs() throws {
        let (home, backups) = try sandbox()
        let i = try installer(.codex, home: home)
        let original = """
        {
          "description": "mine",
          "hooks": {
            "PermissionRequest": [
              { "matcher": "Bash", "hooks": [ { "type": "command", "command": "~/bin/audit.sh", "timeout": 1.5 } ] }
            ]
          }
        }
        """
        try Data(original.utf8).write(to: i.configURL)
        try i.install(backupDirectory: backups)

        let root = try OrderedJSON.parse(Data(contentsOf: i.configURL))
        guard case .object(let members) = root else { Issue.record("not object"); return }
        #expect(members.map(\.key) == ["description", "hooks"])
        let groups = try #require(root["hooks"]?["PermissionRequest"]?.arrayValue)
        #expect(groups.count == 2)
        #expect(groups[0]["hooks"]?.arrayValue?.first?["timeout"] == .number("1.5"))  // number spelling kept
        #expect(i.isOwned(try #require(groups[1]["hooks"]?.arrayValue?.first)))

        // A private backup of the original.
        let saved = try FileManager.default.contentsOfDirectory(atPath: backups.path)
        #expect(saved.count == 1)
        #expect(try Data(contentsOf: backups.appendingPathComponent(saved[0])) == Data(original.utf8))
        let mode = try FileManager.default.attributesOfItem(atPath: backups.appendingPathComponent(saved[0]).path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)

        // Installing again changes nothing (and writes no new backup).
        let before = try Data(contentsOf: i.configURL)
        #expect(try i.install(backupDirectory: backups) == nil)
        #expect(try Data(contentsOf: i.configURL) == before)

        // Removing leaves exactly the user's content.
        try i.uninstall(backupDirectory: backups)
        #expect(i.status() == .notInstalled)
        #expect(try OrderedJSON.parse(Data(contentsOf: i.configURL)) == (try OrderedJSON.parse(Data(original.utf8))))
    }

    @Test func invalidFilesAreNeverTouched() throws {
        let (home, backups) = try sandbox()
        for agent in [AgentProvider.claude, .codex] {
            let i = try installer(agent, home: home)
            let broken = Data("{ \"hooks\": { ".utf8)
            try broken.write(to: i.configURL)
            #expect(i.status() == .unreadable(String(localized: "invalid JSON")))
            #expect(throws: HookInstaller.InstallError.self) {
                agent == .codex ? try i.install(backupDirectory: backups) : try i.uninstall(backupDirectory: backups)
            }
            #expect(try Data(contentsOf: i.configURL) == broken)
        }
    }
}
