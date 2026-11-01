//
//  ClipboardTests.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//

import CryptoKit
import Foundation
import Testing
@testable import Underbrim

struct ClipboardVaultTests {
    @Test func sealedFilesNeverContainPlaintextAndNeedTheKey() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("underbrim-vault-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let vault = ClipboardVault(directory: dir, key: SymmetricKey(size: .bits256))
        try vault.prepare()
        let secret = "correct horse battery staple"
        // Stored at millisecond precision, so use a whole-second date here.
        let entry = ClipboardEntry(id: UUID(), content: .text(secret), byteCount: secret.utf8.count,
                                   copiedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try vault.saveEntries([entry])
        try vault.saveBlob(Data("image bytes".utf8), for: entry.id)

        let raw = try Data(contentsOf: dir.appendingPathComponent("index.sealed"))
        #expect(raw.range(of: Data(secret.utf8)) == nil)
        #expect(try vault.loadEntries() == [entry])
        #expect(try vault.loadBlob(for: entry.id) == Data("image bytes".utf8))
        let mode = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("index.sealed").path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)

        let wrongKey = ClipboardVault(directory: dir, key: SymmetricKey(size: .bits256))
        #expect(throws: ClipboardVaultError.corrupt) { try wrongKey.loadEntries() }
    }

    /// An index that exists but can't be read isn't an empty history: the sweep after opening deletes every
    /// image an empty history doesn't name, and the next save would write over the index.
    @Test func anUnreadableIndexIsAnErrorNotAnEmptyHistory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("underbrim-vault-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let vault = ClipboardVault(directory: dir, key: SymmetricKey(size: .bits256))
        try vault.prepare()
        #expect(try vault.loadEntries().isEmpty)
        let entry = ClipboardEntry(id: UUID(), content: .text("kept"), byteCount: 4, copiedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try vault.saveEntries([entry])
        let index = dir.appendingPathComponent("index.sealed").path
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: index)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: index) }
        #expect(throws: (any Error).self) { try vault.loadEntries() }
    }

    /// The history is stored flat, as older versions wrote it: they read it after a downgrade, and it
    /// reads theirs. A text without its text isn't an entry.
    @Test func entriesKeepTheirStoredShape() throws {
        let stored = #"[{"id":"8C1A2B3C-0000-4000-8000-000000000003","kind":"image","byteCount":12,"imageSize":[640,480],"copiedAt":1700000000000,"pinned":true},"#
            + #"{"id":"8C1A2B3C-0000-4000-8000-000000000004","kind":"link","text":"https://example.com","byteCount":19,"sourceBundleID":"com.apple.Safari","copiedAt":1700000000000,"pinned":false}]"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let entries = try decoder.decode([ClipboardEntry].self, from: Data(stored.utf8))
        #expect(entries.map(\.content) == [.image(size: CGSize(width: 640, height: 480)), .link("https://example.com")])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let written = try JSONSerialization.jsonObject(with: encoder.encode(entries)) as? [[String: Any]]
        #expect(written?.map { Set($0.keys) } == [["id", "kind", "byteCount", "imageSize", "copiedAt", "pinned"],
                                                  ["id", "kind", "text", "byteCount", "sourceBundleID", "copiedAt", "pinned"]])
        let textless = #"[{"id":"8C1A2B3C-0000-4000-8000-000000000005","kind":"text","byteCount":3,"copiedAt":1700000000000,"pinned":false}]"#
        #expect(throws: (any Error).self) { try decoder.decode([ClipboardEntry].self, from: Data(textless.utf8)) }
    }
}
