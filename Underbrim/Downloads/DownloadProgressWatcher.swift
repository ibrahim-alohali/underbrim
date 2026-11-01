//
//  DownloadProgressWatcher.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Browsers publish progress for files they download into the Downloads folder (macOS file-progress
//  publishing; Safari has no downloads extension API but does this). Byte counts are shown exactly
//  as published.
//

import AppKit
import Defaults
import Observation

@MainActor
@Observable
final class DownloadProgressWatcher {
    static let shared = DownloadProgressWatcher()

    @ObservationIgnored private var subscriber: Any?
    @ObservationIgnored private var observations: [String: NSKeyValueObservation] = [:]
    @ObservationIgnored private var lastPush: [String: Date] = [:]

    static var defaultFolder: URL {
        URL(fileURLWithPath: Relay.homeDirectory).appendingPathComponent("Downloads", isDirectory: true)
    }

    var folder: URL {
        Defaults[.downloadsFolderBookmark].flatMap { Bookmark(data: $0).resolvedURL } ?? Self.defaultFolder
    }

    func start() {
        Defaults.whenChanged([.browserDownloadProgress]) { [weak self] in self?.refresh() }
        refresh()
    }

    func refresh() {
        stop()
        guard Defaults[.browserDownloadProgress] else { return }
        let url = folder
        _ = url.startAccessingSecurityScopedResource()
        // Called on arbitrary threads; hop to the (singleton) watcher on main.
        subscriber = Progress.addSubscriber(forFileURL: url) { progress in
            let token = UUID().uuidString
            Task { @MainActor in DownloadProgressWatcher.shared.track(progress, token: token) }
            return {
                Task { @MainActor in DownloadProgressWatcher.shared.finished(progress, token: token) }
            }
        }
    }

    func stop() {
        if let subscriber { Progress.removeSubscriber(subscriber) }
        subscriber = nil
        observations.values.forEach { $0.invalidate() }
        observations.removeAll()
    }

    func chooseFolder() {
        guard let bookmark = chooseFolderBookmark(prompt: String(localized: "Use This Folder"),
                                                  message: String(localized: "Choose the folder your browsers download to."),
                                                  startingAt: folder)
        else { return }
        Defaults[.downloadsFolderBookmark] = bookmark
        refresh()
    }

    // MARK: Progress → store

    /// A subscriber's copy fills `fileURL` only once `userInfo` has been read: on macOS 27 reading
    /// `fileURL` first gives nil.
    nonisolated static func fileURL(of progress: Progress) -> URL? {
        progress.userInfo[.fileURLKey] as? URL
    }

    /// "file.zip.download" (Safari) / "file.zip.crdownload" (Chrome) → source + final name.
    nonisolated static func classify(_ url: URL?) -> (source: DownloadsStore.Item.Source, finalURL: URL?) {
        guard let url else { return (.browser, nil) }
        switch url.pathExtension.lowercased() {
        case "download": return (.safari, url.deletingPathExtension())
        case "crdownload": return (.chrome, url.deletingPathExtension())
        default: return (.browser, url)
        }
    }

    /// Finder copies, AirDrop and unzips publish progress in the folder too; only downloads count.
    nonisolated static func isDownload(_ progress: Progress) -> Bool {
        let operation = progress.userInfo[.fileOperationKindKey] as? Progress.FileOperationKind
        return operation == nil || operation == .downloading
    }

    private func track(_ progress: Progress, token: String) {
        guard Self.isDownload(progress) else { return }
        push(progress, token: token, final: false)
        observations[token] = progress.observe(\.completedUnitCount, options: [.new]) { [weak self] progress, _ in
            Task { @MainActor in self?.push(progress, token: token, final: false) }
        }
    }

    private func finished(_ progress: Progress, token: String) {
        // Not a guard on `observations`: stop() empties it before these run.
        guard Self.isDownload(progress) else { return }
        observations.removeValue(forKey: token)?.invalidate()
        lastPush.removeValue(forKey: token)
        push(progress, token: token, final: true)
    }

    /// At most ~4 updates a second per download, plus the final one.
    private func push(_ progress: Progress, token: String, final: Bool) {
        if !final {
            let now = Date()
            if let last = lastPush[token], now.timeIntervalSince(last) < 0.25 { return }
            lastPush[token] = now
        }
        let fileURL = Self.fileURL(of: progress)
        let (source, finalURL) = Self.classify(fileURL)
        let total = progress.totalUnitCount > 0 ? progress.totalUnitCount : nil
        let completed = progress.completedUnitCount >= 0 ? progress.completedUnitCount : nil
        let state: DownloadsStore.Item.State
        if final {
            if progress.isCancelled {
                state = .cancelled
            } else if let finalURL, FileManager.default.fileExists(atPath: finalURL.path),
                      !FileManager.default.fileExists(atPath: fileURL?.path ?? "") || source == .browser {
                state = .completed
            } else if let total, let completed, completed >= total {
                state = .completed
            } else {
                state = .stopped
            }
        } else {
            state = progress.isPaused ? .paused : .active
        }
        DownloadsStore.shared.applyPublished(token: token, source: source, fileURL: finalURL,
                                             received: completed, total: total, state: state)
    }
}
