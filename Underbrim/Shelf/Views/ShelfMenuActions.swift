//
//  ShelfMenuActions.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  What the Shelf's item menu does when an item in it is chosen, for the items
//  selected when it opened.
//

import AppKit

@MainActor
final class ShelfMenuActionTarget: NSObject {
    /// The item the menu opened on.
    let item: ShelfItem
    /// The selected items when the menu opened (the item among them).
    let items: [ShelfItem]
    weak var view: NSView?
    let onShare: (NSView?) -> Void
    let onQuickLook: ([URL]) -> Void

    init(item: ShelfItem, items: [ShelfItem], view: NSView,
         onShare: @escaping (NSView?) -> Void, onQuickLook: @escaping ([URL]) -> Void) {
        self.item = item
        self.items = items
        self.view = view
        self.onShare = onShare
        self.onQuickLook = onQuickLook
    }

    private var imageURLs: [URL] {
        items.compactMap { $0.fileURL }.filter { ImageProcessingService.shared.isImageFile($0) }
    }

    @objc func handle(_ sender: NSMenuItem) {
        if let marker = sender.representedObject as? String, marker == "__OTHER__" {
            ShelfDialogs.openWith(item)
            return
        }

        // Dispatch on the action tag, never the (localized) title.
        let actionRaw = sender.representedObject as? String
        let action = actionRaw.flatMap { ContextMenuAction(rawValue: $0) }

        if let appURL = sender.representedObject as? URL {
            let items = items
            Task { await ShelfActionService.open(items, with: appURL) }
            return
        }

        switch action {
        case .quickLook?:
            // Handle all selected items for Quick Look, not just the clicked item
            let urls: [URL] = items.compactMap { item in
                if let fileURL = item.fileURL {
                    return fileURL
                }
                if case .link(let url) = item.kind {
                    return url
                }
                return nil
            }
            if !urls.isEmpty {
                onQuickLook(urls)
            }

        case .open?:
            for it in items { ShelfActionService.open(it) }

        case .share?:
            onShare(view)

        case .rename?:
            if items.count == 1, let single = items.first { ShelfDialogs.rename(single) }

        case .showInFinder?:
            let items = items
            Task { await ShelfActionService.reveal(items) }

        case .copyPath?:
            ShelfActionService.copyPaths(of: items)

        case .copy?:
            ShelfActionService.copy(items)

        case .remove?:
            for it in items { ShelfActionService.remove(it) }

        case .removeBackground?:
            guard let imageURL = imageURLs.first else { break }
            Task {
                do {
                    try await ShelfActionService.removeBackground(from: imageURL)
                } catch {
                    Log.shelf.error("❌ Failed to remove background: \(error.localizedDescription)")
                    ShelfDialogs.showError(title: String(localized: "Background Removal Failed"), message: error.localizedDescription)
                }
            }

        case .convertImage?:
            // Once the menu has closed (VoiceOver's press runs this while it's still drawn), from the run loop:
            // a main-queue block would hold the main queue while the dialog is open.
            perform(#selector(convertImage), with: nil, afterDelay: 0)

        case .createPDF?:
            let imageURLs = imageURLs
            guard !imageURLs.isEmpty else { break }
            Task {
                do {
                    try await ShelfActionService.createPDF(from: imageURLs)
                } catch {
                    Log.shelf.error("❌ Failed to create PDF: \(error.localizedDescription)")
                    ShelfDialogs.showError(title: String(localized: "PDF Creation Failed"), message: error.localizedDescription)
                }
            }

        case .compress?:
            let items = items
            Task {
                if await !ShelfActionService.compress(items) {
                    ShelfDialogs.showError(title: String(localized: "Couldn't Compress"), message: String(localized: "One of the items couldn't be read."))
                }
            }

        case .none:
            break
        }
    }

    @objc private func convertImage() {
        guard let imageURL = imageURLs.first, let options = ShelfDialogs.convertOptions() else { return }
        Task {
            do {
                try await ShelfActionService.convert(imageURL, options: options)
            } catch {
                Log.shelf.error("❌ Failed to convert image: \(error.localizedDescription)")
                ShelfDialogs.showError(title: String(localized: "Image Conversion Failed"), message: error.localizedDescription)
            }
        }
    }
}
