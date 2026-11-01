//
//  ShelfStateViewModel.swift
//  Underbrim
//
//  Created by Alexander on 2025-10-09.

import Foundation
import AppKit

@MainActor
final class ShelfStateViewModel: ObservableObject {
    static let shared = ShelfStateViewModel()

    @Published private(set) var items: [ShelfItem] = [] {
        didSet { schedulePersistence() }
    }

    var isEmpty: Bool { items.isEmpty }

    // Debounced persistence
    private var persistenceTask: Task<Void, Never>?
    private let persistenceDelay: Duration = .seconds(1)

    private init() {
        let loaded = ShelfPersistenceService.shared.load()
        items = loaded.items
        // Only a list read whole says which stored files are no longer used.
        guard loaded.complete else { return }
        let stored = items.filter(\.isTemporary)
        Task.detached(priority: .utility) {
            TemporaryFileStorageService.shared.removeUnused(keeping: stored.compactMap(\.fileURL))
        }
    }

    private func schedulePersistence() {
        persistenceTask?.cancel()
        persistenceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: self?.persistenceDelay ?? .seconds(1))
            guard let self = self, !Task.isCancelled else { return }
            await ShelfPersistenceService.shared.saveAsync(self.items)
        }
    }

    func add(_ newItems: [ShelfItem]) {
        guard !newItems.isEmpty else { return }
        var merged = items
        // Deduplicate by identityKey while preserving order (existing first)
        var seen: Set<String> = Set(merged.map { $0.identityKey })
        for it in newItems {
            let key = it.identityKey
            if !seen.contains(key) {
                merged.append(it)
                seen.insert(key)
            }
        }
        items = merged
    }

    /// Off the list only: a temporary item's file goes with ShelfActionService.remove.
    func remove(_ item: ShelfItem) {
        items.removeAll { $0.id == item.id }
    }

    func updateBookmark(for item: ShelfItem, bookmark: Data) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        if case .file = items[idx].kind {
            items[idx] = ShelfItem(id: items[idx].id, kind: .file(bookmark: bookmark), isTemporary: items[idx].isTemporary)
        }
    }

    func load(_ providers: [NSItemProvider]) {
        guard !providers.isEmpty else { return }
        Task { [weak self] in
            let dropped = await ShelfDropService.items(from: providers)
            await MainActor.run {
                self?.add(dropped)
            }
        }
    }

    func cleanupInvalidItems() {
        Task { [weak self] in
            guard let self else { return }
            // Underbrim: removes only what failed, from the list as it is then, so items added meanwhile stay.
            var gone: Set<ShelfItem.ID> = []
            for item in self.items {
                guard case .file(let data) = item.kind else { continue }
                if await !Bookmark(data: data).validate() {
                    item.cleanupStoredData()
                    gone.insert(item.id)
                }
            }
            guard !gone.isEmpty else { return }
            await MainActor.run { self.items.removeAll { gone.contains($0.id) } }
        }
    }

    /// Resolves the file URL for an item and updates the bookmark if stale.
    /// Use this for user-initiated actions where bookmark refresh is desired.
    func resolveAndUpdateBookmark(for item: ShelfItem) -> URL? {
        guard case .file(let bookmarkData) = item.kind else { return nil }
        let bookmark = Bookmark(data: bookmarkData)
        let result = bookmark.resolve()
        if let refreshed = result.refreshedData, refreshed != bookmarkData {
            NSLog("Bookmark for \(item) stale; refreshing")
            updateBookmark(for: item, bookmark: refreshed)
        }
        return result.url
    }

    @MainActor
    func flushSync() {
        // Cancel any scheduled persistence task (we'll save synchronously now)
        persistenceTask?.cancel()
        persistenceTask = nil

        // Perform a synchronous, atomic save to disk
        ShelfPersistenceService.shared.save(self.items)
    }
}
