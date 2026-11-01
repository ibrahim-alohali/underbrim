//
//  ShelfActionService.swift
//  Underbrim
//
//  Created by Alexander on 2025-10-07.
//

import AppKit
import CoreServices
import Foundation
import UniformTypeIdentifiers

/// What can be done with `ShelfItem`s and their files: opening, revealing, copying, renaming,
/// compressing and image work. The menus and dialogs ask; this does the work.
@MainActor
enum ShelfActionService {
    /// Files on the pasteboard from the last Copy, kept readable while they're there.
    private static var copiedURLs: [URL] = []

    static func open(_ item: ShelfItem) {
        switch item.kind {
        case .file(let bookmarkData):
            Bookmark(data: bookmarkData).withAccess { url in
                NSWorkspace.shared.open(url)
            }
        case .link(let url):
            NSWorkspace.shared.open(url)
        case .text(let string):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(string, forType: .string)
        }
    }

    /// The items' files and links, opened together with one app.
    static func open(_ items: [ShelfItem], with appURL: URL) async {
        let urls = items.compactMap { item -> URL? in
            if let fileURL = item.fileURL { return fileURL }
            if case .link(let url) = item.kind { return url }
            return nil
        }
        guard !urls.isEmpty else { return }
        do {
            try await open(urls, withApplicationAt: appURL)
        } catch {
            Log.shelf.error("❌ Failed to open with application: \(error.localizedDescription)")
        }
    }

    /// One file or link opened with an app chosen in a panel; with `defaultFor`, the app first becomes the
    /// default for every file of that type.
    static func open(_ url: URL, with appURL: URL, defaultFor type: UTType?) async {
        do {
            if let type, let bundleID = Bundle(url: appURL)?.bundleIdentifier {
                let status = LSSetDefaultRoleHandlerForContentType(type.identifier as CFString, LSRolesMask.all, bundleID as CFString)
                if status != noErr { Log.shelf.error("Failed to set default handler for \(type.identifier): \(status)") }
            }
            try await open([url], withApplicationAt: appURL)
        } catch {
            Log.shelf.error("❌ Failed to open with application: \(error.localizedDescription)")
        }
    }

    /// Opens `urls` with an app, holding access to the files among them meanwhile.
    nonisolated private static func open(_ urls: [URL], withApplicationAt appURL: URL) async throws {
        let fileURLs = urls.filter { $0.isFileURL }
        guard !fileURLs.isEmpty else {
            try await NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
            return
        }
        try await withFileAccess(to: fileURLs) { _ in
            _ = try await NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    static func reveal(_ item: ShelfItem) {
        guard case .file(let bookmarkData) = item.kind else { return }
        Bookmark(data: bookmarkData).withAccess { url in
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// The items' files selected in Finder, their bookmarks refreshed first.
    static func reveal(_ items: [ShelfItem]) async {
        let urls = items.compactMap { item -> URL? in
            if case .file = item.kind {
                // Use immediate update for user-initiated menu action
                return ShelfStateViewModel.shared.resolveAndUpdateBookmark(for: item)
            }
            return nil
        }
        if !urls.isEmpty {
            await withFileAccess(to: urls) { accessibleURLs in
                NSWorkspace.shared.activateFileViewerSelecting(accessibleURLs)
            }
        }
    }

    static func copyPaths(of items: [ShelfItem]) {
        let paths = items.compactMap { $0.fileURL?.path }
        if !paths.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
        }
    }

    /// The items on the pasteboard: files as files, text and links exactly as kept.
    static func copy(_ items: [ShelfItem]) {
        let pb = NSPasteboard.general

        // Stop accessing previously copied URLs
        for url in copiedURLs {
            url.stopAccessingSecurityScopedResource()
        }
        copiedURLs.removeAll()

        pb.clearContents()
        let fileURLs = items.compactMap { item -> URL? in
            if case .file = item.kind {
                return ShelfStateViewModel.shared.resolveAndUpdateBookmark(for: item)
            }
            return nil
        }
        // Underbrim: text and links exactly as kept (displayName trims text and
        // drops a link's scheme), alongside any files rather than instead of them.
        let strings = items.compactMap { item -> String? in
            switch item.kind {
            case .text(let string): string
            case .link(let url): url.absoluteString
            default: nil
            }
        }
        if !fileURLs.isEmpty {
            // Start security-scoped access for all URLs and keep them active
            copiedURLs = fileURLs.filter { $0.startAccessingSecurityScopedResource() }
            pb.writeObjects(fileURLs as [NSURL])
        }
        if !strings.isEmpty {
            if fileURLs.isEmpty {
                pb.setString(strings.joined(separator: "\n"), forType: .string)
            } else {
                pb.writeObjects(strings as [NSString])
            }
        }
    }

    /// Moves the item's file to `newURL` and points the item at it. The save panel already asked to
    /// replace a file there: it goes to the Trash, unless it's this file in other capitals on a
    /// case-insensitive disk (only a rename).
    static func rename(_ item: ShelfItem, at fileURL: URL, to newURL: URL) throws {
        let id: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        if let existing = (try? newURL.resourceValues(forKeys: id))?.fileResourceIdentifier,
           !existing.isEqual((try? fileURL.resourceValues(forKeys: id))?.fileResourceIdentifier) {
            try FileManager.default.trashItem(at: newURL, resultingItemURL: nil)
        }
        try FileManager.default.moveItem(at: fileURL, to: newURL)

        if let newBookmark = try? Bookmark(url: newURL) {
            ShelfStateViewModel.shared.updateBookmark(for: item, bookmark: newBookmark.data)
        }
    }

    /// The items' files zipped into a temporary file on the shelf; false when one couldn't be read.
    static func compress(_ items: [ShelfItem]) async -> Bool {
        let fileURLs = items.compactMap { $0.fileURL }
        guard !fileURLs.isEmpty else { return true }

        // Create ZIP in a temporary location while holding access to selected resources
        guard let zipTempURL = await withFileAccess(to: fileURLs, { urls in
            await TemporaryFileStorageService.shared.createZip(from: urls)
        }) else { return false }
        if !addTemporaryFile(zipTempURL) {
            // Fallback: reveal the temporary file in Finder
            NSWorkspace.shared.activateFileViewerSelecting([zipTempURL])
        }
        return true
    }

    static func removeBackground(from imageURL: URL) async throws {
        let resultURL = try await withFileAccess(to: [imageURL]) { urls in
            try await ImageProcessingService.shared.removeBackground(from: urls[0])
        }
        if let resultURL { addTemporaryFile(resultURL) }
    }

    static func createPDF(from imageURLs: [URL]) async throws {
        let resultURL = try await withFileAccess(to: imageURLs) { urls in
            try await ImageProcessingService.shared.createPDF(from: urls)
        }
        if let resultURL { addTemporaryFile(resultURL) }
    }

    static func convert(_ imageURL: URL, options: ImageConversionOptions) async throws {
        let resultURL = try await withFileAccess(to: [imageURL]) { urls in
            try await ImageProcessingService.shared.convertImage(from: urls[0], options: options)
        }
        if let resultURL { addTemporaryFile(resultURL) }
    }

    static func remove(_ item: ShelfItem) {
        item.cleanupStoredData()
        ShelfStateViewModel.shared.remove(item)
    }

    /// `work` with access to the files held, off the main actor: zipping and image work take a while.
    nonisolated private static func withFileAccess<T: Sendable>(
        to urls: [URL], _ work: @Sendable ([URL]) async throws -> T
    ) async rethrows -> T {
        try await urls.accessSecurityScopedResources(accessor: work)
    }

    /// A file made from shelf items, added to the shelf as a temporary item; false without a bookmark.
    @discardableResult
    private static func addTemporaryFile(_ url: URL) -> Bool {
        guard let bookmark = try? Bookmark(url: url) else { return false }
        ShelfStateViewModel.shared.add([ShelfItem(kind: .file(bookmark: bookmark.data), isTemporary: true)])
        return true
    }
}
