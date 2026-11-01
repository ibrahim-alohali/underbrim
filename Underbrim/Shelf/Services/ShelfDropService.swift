//
//  ShelfDropService.swift
//  Underbrim
//
//  Created by Alexander on 2025-09-26.
//

import AppKit
import Foundation
import UniformTypeIdentifiers

struct ShelfDropService {
    static func items(from providers: [NSItemProvider]) async -> [ShelfItem] {
        // Process providers concurrently for better performance with large drops
        await withTaskGroup(of: (Int, ShelfItem?).self) { group in
            for (index, provider) in providers.enumerated() {
                group.addTask {
                    (index, await processProvider(provider))
                }
            }

            var results: [(Int, ShelfItem)] = []
            results.reserveCapacity(providers.count)

            for await (index, item) in group {
                if let item = item {
                    results.append((index, item))
                }
            }

            // Underbrim: in the order they were dragged (Create PDF pages follow it), not as they finished.
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private static func processProvider(_ provider: NSItemProvider) async -> ShelfItem? {
        var fileURL = await provider.extractFileURL()
        if fileURL == nil { fileURL = await originalFile(provider) }
        // Underbrim: one with nothing behind it (text like a file URL) goes on to the text below, not vanishing.
        if let fileURL, let bookmark = createBookmark(for: fileURL) {
            return await ShelfItem(kind: .file(bookmark: bookmark), isTemporary: false)
        }

        if let url = await provider.extractURL() {
            if !url.isFileURL { return await ShelfItem(kind: .link(url: url), isTemporary: false) }
            if let bookmark = createBookmark(for: url) { return await ShelfItem(kind: .file(bookmark: bookmark), isTemporary: false) }
        }

        if let text = await provider.extractText() {
            return await ShelfItem(kind: .text(string: text), isTemporary: false)
        }

        if let data = await provider.loadData() {
            // Underbrim: data with no name is named for its type.
            let name = provider.suggestedName ?? provider.registeredTypeIdentifiers.lazy
                .compactMap { UTType($0)?.preferredFilenameExtension }.first
                .map { String(localized: "Dropped Item") + "." + $0 }
            if let tempDataURL = await TemporaryFileStorageService.shared.createTempFile(for: .data(data, suggestedName: name)),
               let bookmark = createBookmark(for: tempDataURL) {
                return await ShelfItem(kind: .file(bookmark: bookmark), isTemporary: true)
            }
            return nil
        }

        if let fileURL = await provider.extractItem() {
            if let bookmark = createBookmark(for: fileURL) {
                return await ShelfItem(kind: .file(bookmark: bookmark), isTemporary: false)
            }
        }

        return nil
    }

    /// Underbrim: Finder offers a file in place under its own type, without public.file-url: the user's
    /// file, bookmarked where it is. Promised files, data and text aren't in place: they're read once below.
    private static func originalFile(_ provider: NSItemProvider) async -> URL? {
        guard let type = provider.registeredTypeIdentifiers(fileOptions: .openInPlace).first else { return nil }
        return await withCheckedContinuation { done in
            _ = provider.loadInPlaceFileRepresentation(forTypeIdentifier: type) { url, inPlace, _ in
                done.resume(returning: inPlace ? url : nil)
            }
        }
    }

    private static func createBookmark(for url: URL) -> Data? {
        return (try? Bookmark(url: url))?.data
    }
}
