//
//  ScreenshotWatcher.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Adds new screenshots to the Shelf, watching one folder with a dispatch source (no polling). A
//  file qualifies when macOS marks it as a screen capture, it appeared after watching started, and
//  its size has settled. The Shelf keeps a bookmark; nothing is moved or copied.
//

import AppKit
import Darwin
import Defaults
import Observation

@MainActor
@Observable
final class ScreenshotWatcher {
    static let shared = ScreenshotWatcher()

    enum State: Equatable {
        case off
        case watching
        case folderUnavailable(String)
    }

    private(set) var state: State = .off

    @ObservationIgnored private var source: DispatchSourceFileSystemObject?
    @ObservationIgnored private var watched: URL?
    @ObservationIgnored private var unlockObserver: NSObjectProtocol?
    @ObservationIgnored private var startedAt = Date()
    @ObservationIgnored private var handled: Set<String> = []
    @ObservationIgnored private var pending: Set<String> = []
    @ObservationIgnored private let queue = DispatchQueue(label: "\(bundleIdentifier).screenshots", qos: .utility)

    /// Where macOS saves screenshots (Screenshot app → Options → Save to).
    nonisolated static func systemScreenshotFolder() -> URL {
        if let location = CFPreferencesCopyAppValue("location" as CFString, "com.apple.screencapture" as CFString) as? String,
           !location.isEmpty {
            return URL(fileURLWithPath: (location as NSString).expandingTildeInPath, isDirectory: true)
        }
        return URL(fileURLWithPath: Relay.homeDirectory).appendingPathComponent("Desktop", isDirectory: true)
    }

    var folder: URL {
        Defaults[.screenshotFolderBookmark].flatMap { Bookmark(data: $0).resolvedURL } ?? Self.systemScreenshotFolder()
    }

    func start() {
        Defaults.whenChanged([.screenshotShelfEnabled]) { [weak self] in self?.refresh() }
        // The Screenshot app's Save to can change while we watch: look again on unlock.
        unlockObserver = DistributedNotificationCenter.default().addObserver(
            forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.followFolder() }
        }
        refresh()
    }

    func followFolder() {
        if Defaults[.screenshotShelfEnabled], watched != folder.standardizedFileURL { refresh() }
    }

    func refresh() {
        stop()
        guard Defaults[.screenshotShelfEnabled] else { state = .off; return }
        let url = folder
        _ = url.startAccessingSecurityScopedResource()
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            state = .folderUnavailable(url.path)
            return
        }
        startedAt = Date()
        handled = Set(((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []))
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: queue)
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.scan(url) }
        }
        source.setCancelHandler {
            close(fd)
            url.stopAccessingSecurityScopedResource()
        }
        self.source = source
        watched = url.standardizedFileURL
        source.resume()
        state = .watching
    }

    func stop() {
        source?.cancel()
        source = nil
        watched = nil
    }

    func chooseFolder() {
        guard let bookmark = chooseFolderBookmark(prompt: String(localized: "Watch This Folder"),
                                                  message: String(localized: "Choose the folder your screenshots are saved to."),
                                                  startingAt: folder)
        else { return }
        Defaults[.screenshotFolderBookmark] = bookmark
        refresh()
    }

    private func scan(_ directory: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where !handled.contains(name) && !pending.contains(name) && !name.hasPrefix(".") {
            let url = directory.appendingPathComponent(name)
            pending.insert(name)
            queue.async { [weak self, startedAt] in
                let qualifies = Self.isNewScreenshot(url, since: startedAt) && Self.waitUntilSettled(url)
                Task { @MainActor in self?.finish(name: name, url: url, add: qualifies) }
            }
        }
    }

    private func finish(name: String, url: URL, add: Bool) {
        pending.remove(name)
        handled.insert(name)
        if add { ShelfStateViewModel.shared.addFile(url) }
    }

    nonisolated static func isNewScreenshot(_ url: URL, since: Date) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .creationDateKey]),
              values.isRegularFile == true, let created = values.creationDate, created >= since.addingTimeInterval(-1)
        else { return false }
        return getxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) > 0
    }

    /// Waits until the file stops growing, so half-written files aren't added; gives up after ~5 s.
    nonisolated static func waitUntilSettled(_ url: URL) -> Bool {
        var last: Int?
        for _ in 0..<12 {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            if let size, size > 0, size == last { return true }
            last = size
            Thread.sleep(forTimeInterval: 0.4)
        }
        return false
    }
}
