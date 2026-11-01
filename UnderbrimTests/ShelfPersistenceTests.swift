//
//  ShelfPersistenceTests.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//

import Foundation
import Testing
@testable import Underbrim

@MainActor
struct ShelfPersistenceTests {
    /// A list from a newer version holds an item this build can't read. It must come back unchanged
    /// with the next save, and the stored files it may name must not be swept.
    @Test func itemsThisBuildCantReadAreKept() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("underbrim-shelf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let list = #"[{"id":"8C1A2B3C-0000-4000-8000-000000000001","kind":{"type":"text","value":"kept"},"isTemporary":false},"#
            + #"{"id":"8C1A2B3C-0000-4000-8000-000000000002","kind":{"type":"folder","value":"from a newer version"},"isTemporary":true}]"#
        try Data(list.utf8).write(to: dir.appendingPathComponent("items.json"))

        let service = ShelfPersistenceService(directory: dir)
        let loaded = service.load()
        #expect(loaded.items.count == 1)
        #expect(!loaded.complete)
        service.save(loaded.items)
        let saved = try String(contentsOf: dir.appendingPathComponent("items.json"), encoding: .utf8)
        #expect(saved.contains("from a newer version"))
    }
}
