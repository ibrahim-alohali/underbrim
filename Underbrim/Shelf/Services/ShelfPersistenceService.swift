//
//  ShelfPersistenceService.swift
//  Underbrim
//
//  Created by Alexander on 2025-09-24.
//

import Foundation

// Access model types
@_exported import struct Foundation.URL

final class ShelfPersistenceService {
    static let shared = ShelfPersistenceService()

    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Underbrim: beside the app's other data, in Application Support/Underbrim.
    init(directory dir: URL = Relay.supportDirectory.appendingPathComponent("Shelf", isDirectory: true)) {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("items.json")
        encoder.outputFormatting = [.prettyPrinted]
        decoder.dateDecodingStrategy = .iso8601
        encoder.dateEncodingStrategy = .iso8601
    }

    /// What the list on disk held.
    struct Loaded {
        var items: [ShelfItem]
        /// Every item was read, so stored files that no item names can go.
        var complete: Bool
    }

    /// Items this build couldn't read (from a newer version, say), written back unchanged with the rest.
    private var unreadItems: [Data] = []
    /// The list couldn't be read or set aside, so nothing is saved over it.
    private var readOnly = false

    /// A list that can't be read whole is never written over: items this build can't read are kept
    /// as they are, and a file it can't read at all is set aside beside it, for a later version or by hand.
    func load() -> Loaded {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return Loaded(items: [], complete: true) }
        guard let data = try? Data(contentsOf: fileURL),
              let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else {
            setAside()
            return Loaded(items: [], complete: false)
        }

        var validItems: [ShelfItem] = []
        for (index, jsonItem) in jsonArray.enumerated() {
            guard let itemData = try? JSONSerialization.data(withJSONObject: jsonItem) else { continue }
            do {
                validItems.append(try decoder.decode(ShelfItem.self, from: itemData))
            } catch {
                unreadItems.append(itemData)
                Log.shelf.error("Shelf item \(index) kept unread: \(error.localizedDescription)")
            }
        }
        return Loaded(items: validItems, complete: unreadItems.isEmpty && !setAsideExists)
    }

    /// While a list set aside is there, the stored files it may name are kept.
    private var setAsideExists: Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: fileURL.deletingLastPathComponent().path)) ?? []
        return names.contains { $0.hasPrefix("items (unreadable ") }
    }

    private func setAside() {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: ".")
        let aside = fileURL.deletingLastPathComponent().appendingPathComponent("items (unreadable \(stamp)).json")
        do {
            try FileManager.default.moveItem(at: fileURL, to: aside)
            Log.shelf.error("Shelf list unreadable, set aside as \(aside.lastPathComponent, privacy: .public)")
        } catch {
            readOnly = true
            Log.shelf.error("Shelf list unreadable and not set aside, so it isn't saved: \(error.localizedDescription)")
        }
    }

    /// The list as written: the items, then any this build couldn't read.
    private static func encoded(_ items: [ShelfItem], keeping unread: [Data], encoder: JSONEncoder) throws -> Data {
        let data = try encoder.encode(items)
        guard !unread.isEmpty, var array = try JSONSerialization.jsonObject(with: data) as? [Any] else { return data }
        array += unread.compactMap { try? JSONSerialization.jsonObject(with: $0) }
        return try JSONSerialization.data(withJSONObject: array, options: [.prettyPrinted])
    }

    func save(_ items: [ShelfItem]) {
        guard !readOnly else { return }
        do {
            try Self.encoded(items, keeping: unreadItems, encoder: encoder).write(to: fileURL, options: .atomic)
        } catch {
            Log.shelf.error("Failed to save shelf items: \(error.localizedDescription)")
        }
    }

    func saveAsync(_ items: [ShelfItem]) async {
        guard !readOnly else { return }
        await Task.detached(priority: .utility) { [fileURL, encoder, unreadItems] in
            do {
                try Self.encoded(items, keeping: unreadItems, encoder: encoder).write(to: fileURL, options: .atomic)
            } catch {
                Log.shelf.error("Failed to save shelf items: \(error.localizedDescription)")
            }
        }.value
    }
}
