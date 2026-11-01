//
//  DownloadsStore.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Browser downloads shown in the notch. Chrome reports measured bytes through the bundled
//  extension; Safari has no progress API, so its items are indeterminate. Nothing estimates speed or time.
//

import Defaults
import Foundation
import Observation

@MainActor
@Observable
final class DownloadsStore {
    static let shared = DownloadsStore()

    struct Item: Identifiable, Equatable {
        /// `.browser` when the publishing browser couldn't be told apart.
        enum Source: String { case chrome, safari, browser }
        /// `.stopped`: the transfer ended without proof it finished.
        enum State: Equatable { case active, paused, completed, cancelled, failed, dangerous, stopped }
        enum Origin: Equatable {
            /// Reported by the Chrome extension, by Chrome's download id.
            case chromeExtension(id: Int)
            /// Progress a browser published for the file (DownloadProgressWatcher), by its subscription.
            case published(token: String)
        }

        let origin: Origin
        let source: Source
        var name: String
        var received: Int64?
        var total: Int64?
        var state: State
        var updatedAt: Date
        var fileURL: URL?

        var fraction: Double? {
            guard let received, let total, total > 0 else { return nil }
            return min(1, Double(received) / Double(total))
        }

        var id: String {
            switch origin {
            case .chromeExtension(let id): "chrome:\(id)"
            case .published(let token): "progress:\(token)"
            }
        }

        var isActive: Bool { state == .active || state == .paused || state == .dangerous }

        /// The extension re-sends what it reports every second, so its silence means something.
        var fromExtension: Bool {
            if case .chromeExtension = origin { true } else { false }
        }

        var browserBundleID: String {
            switch source {
            case .chrome: "com.google.Chrome"
            case .safari: "com.apple.Safari"
            case .browser: "com.apple.finder"
            }
        }
    }

    private(set) var items: [Item] = []
    private(set) var chromeExtensionSeen: Date?

    static let finishedLinger: TimeInterval = 8
    /// The extension re-sends active downloads every second; this long without a report, Chrome stopped.
    static let chromeSilence: TimeInterval = 15
    @ObservationIgnored private var cleanup: Task<Void, Never>?

    var featured: Item? {
        items.first(where: \.isActive) ?? items.first
    }

    func chromeExtensionConnected() {
        chromeExtensionSeen = .now
    }

    func applyChrome(_ download: ChromeDownload) {
        chromeExtensionSeen = .now
        let origin = Item.Origin.chromeExtension(id: download.id)
        let state: Item.State = switch download.state {
        case .inProgress: .active
        case .paused: .paused
        case .complete: .completed
        case .cancelled: .cancelled
        case .failed: .failed
        case .dangerous: .dangerous
        }
        var item = items.first { $0.origin == origin }
            ?? Item(origin: origin, source: .chrome, name: download.name ?? String(localized: "Download"), state: state, updatedAt: .now)
        if let name = download.name { item.name = name }
        if let received = download.received { item.received = received }
        item.total = download.total
        if let path = download.path { item.fileURL = URL(fileURLWithPath: path) }
        let finishedNow = item.state != .completed && state == .completed
        item.state = state
        item.updatedAt = .now
        // Chrome may have published the same file's progress first: the extension knows more.
        if let name = download.name {
            items.removeAll { other in
                guard case .published = other.origin else { return false }
                return other.source != .safari && other.name == name && Date().timeIntervalSince(other.updatedAt) < Self.chromeSilence
            }
        }
        upsert(item)
        if finishedNow, Defaults[.addFinishedDownloadsToShelf], let url = item.fileURL { ShelfStateViewModel.shared.addFile(url) }
    }

    /// Progress a browser published for a file (see DownloadProgressWatcher). Chrome items the
    /// extension already reports are skipped: it knows more (pause, danger, errors).
    func applyPublished(token: String, source: Item.Source, fileURL: URL?, received: Int64?, total: Int64?, state: Item.State) {
        let name = fileURL?.lastPathComponent ?? String(localized: "Download")
        if source != .safari, items.contains(where: {
            $0.fromExtension && $0.name == name && Date().timeIntervalSince($0.updatedAt) < Self.chromeSilence
        }) { return }
        let origin = Item.Origin.published(token: token)
        var item = items.first { $0.origin == origin } ?? Item(origin: origin, source: source, name: name, state: state, updatedAt: .now)
        let finishedNow = item.state != .completed && state == .completed
        item.name = name
        item.received = received ?? item.received
        item.total = total ?? item.total
        item.fileURL = fileURL
        item.state = state
        item.updatedAt = .now
        upsert(item)
        if finishedNow, Defaults[.addFinishedDownloadsToShelf], let url = item.fileURL { ShelfStateViewModel.shared.addFile(url) }
    }

    /// Updates keep their place, so concurrent downloads don't swap on every tick; new items go first.
    private func upsert(_ item: Item) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else {
            items.insert(item, at: 0)
            if items.count > 20 { items.removeLast(items.count - 20) }
        }
        refreshSummary()
        scheduleCleanup()
    }

    /// What the closed notch shows, without progress, so progress ticks re-render only the small download view.
    private(set) var closedSummary: DownloadClosedSummary?

    private func refreshSummary() {
        let summary = featured.map { DownloadClosedSummary(id: $0.id, browserBundleID: $0.browserBundleID, state: $0.state) }
        if summary != closedSummary { closedSummary = summary }
    }

    static func accessibilityText(for item: Item) -> String {
        let state: String = switch item.state {
        case .active: item.fraction.map { String(localized: "\(Int($0 * 100)) percent") } ?? String(localized: "downloading")
        case .paused: String(localized: "paused")
        case .completed: String(localized: "finished")
        case .cancelled: String(localized: "cancelled")
        case .failed: String(localized: "failed")
        case .dangerous: String(localized: "flagged by the browser")
        case .stopped: String(localized: "stopped")
        }
        return String(localized: "Download \(item.name), \(state)")
    }

    /// Finished items leave after a short linger; active ones stay, except a Chrome one the extension
    /// stopped reporting: it's marked stopped, then lingers like the rest.
    private func scheduleCleanup() {
        cleanup?.cancel()
        let due = items.compactMap { item -> Date? in
            if !item.isActive { return item.updatedAt.addingTimeInterval(Self.finishedLinger) }
            return item.fromExtension ? item.updatedAt.addingTimeInterval(Self.chromeSilence) : nil
        }
        guard let next = due.min() else { return }
        let delay = max(0.1, next.timeIntervalSinceNow)
        cleanup = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            let now = Date()
            for (index, item) in self.items.enumerated() where item.isActive && item.fromExtension
                && now.timeIntervalSince(item.updatedAt) >= Self.chromeSilence {
                self.items[index].state = .stopped
                self.items[index].updatedAt = now
            }
            self.items.removeAll { !$0.isActive && now.timeIntervalSince($0.updatedAt) >= Self.finishedLinger }
            self.refreshSummary()
            self.scheduleCleanup()
        }
    }
}
