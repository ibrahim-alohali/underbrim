//
//  ClipboardHistory.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Clipboard history. macOS has no pasteboard-changed notification, so while recording (and
//  unlocked) a 1 s timer compares `changeCount`, which exposes no content; only a change reads.
//

import AppKit
import Defaults
import ImageIO
import Observation
import os

@MainActor
@Observable
final class ClipboardHistory {
    static let shared = ClipboardHistory()

    enum State: Equatable {
        case off
        /// Reading the key (on a Mac without a Secure Enclave, macOS may be asking about it); nothing
        /// shown or recorded yet.
        case opening
        case recording
        case paused
        case locked
        case keyUnavailable
        /// The history's files couldn't be read or saved: recording stops, and nothing is deleted.
        case storageFailed
        case accessDenied
        case storageFull
    }

    /// Why the history stopped, until it's turned off and on, or deleted.
    private enum Failure: Error {
        /// The key couldn't be read, or doesn't open the history.
        case key
        case storage
    }

    private(set) var entries: [ClipboardEntry] = []
    private(set) var state: State = .off
    private(set) var macOSWillAsk = false
    /// History an earlier key opens, set aside because macOS would have asked about that key.
    private(set) var earlierKept = false
    private(set) var bringingBack = false
    private(set) var bringBackFailed = false

    @ObservationIgnored private var vault: ClipboardVault?
    /// Reading the key can wait on a Keychain password dialog (on a Mac without a Secure Enclave,
    /// when another build stored it), so the vault opens off the main thread.
    @ObservationIgnored private var opening: Task<Void, Never>?
    /// Waits on macOS's question about the earlier key; deleting everything meanwhile cancels it.
    @ObservationIgnored private var bringing: Task<Void, Never>?
    /// Not tried again until history is turned off and on, or deleted.
    @ObservationIgnored private var failure: Failure?
    @ObservationIgnored private var timer: Timer?
    /// While access is denied: the next look at the setting (macOS doesn't say when it's allowed).
    @ObservationIgnored private var accessCheck: Task<Void, Never>?
    @ObservationIgnored private var lastChangeCount = NSPasteboard.general.changeCount
    @ObservationIgnored private var screenLocked = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// Images seen in the panel (about 0.2 MB each): a hundred at most, and none for items gone.
    @ObservationIgnored private let thumbnails: NSCache<NSUUID, NSImage> = {
        let cache = NSCache<NSUUID, NSImage>()
        cache.countLimit = 100
        return cache
    }()
    @ObservationIgnored private let ioQueue = DispatchQueue(label: "\(bundleIdentifier).clipboard-io", qos: .utility)
    @ObservationIgnored private let log = Logger(subsystem: bundleIdentifier, category: "clipboard")
    @ObservationIgnored private let directory = ClipboardVault.defaultDirectory()
    @ObservationIgnored private let keyStore = ClipboardKeyStore.app

    var limits: ClipboardPolicy.Limits {
        ClipboardPolicy.Limits(maxUnpinned: Defaults[.clipboardMaxEntries],
                               maxAge: TimeInterval(Defaults[.clipboardRetentionDays]) * 24 * 3600)
    }

    var totalBytes: Int { entries.reduce(0) { $0 + $1.byteCount } }
    var previewsHidden: Bool { screenLocked }
    var browsable: Bool { !previewsHidden && ![.off, .opening, .keyUnavailable, .storageFailed, .accessDenied].contains(state) }

    // MARK: Lifecycle

    func start() {
        if observers.isEmpty {
            let distributed = DistributedNotificationCenter.default()
            observers.append(distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.screenLocked = true; self?.refreshState() }
            })
            observers.append(distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.screenLocked = false; self?.refreshState(); self?.pruneExpired() }
            })
            // Copy here, switch, paste there: a copy noticed on the switch belongs to the app being left.
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                let app = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
                MainActor.assumeIsolated {
                    guard let self, self.timer != nil else { return }  // only while recording
                    self.poll(leaving: app)
                }
            })
            Defaults.whenChanged([.clipboardHistoryEnabled, .clipboardPaused]) { [weak self] in self?.refreshState() }
        }
        refreshState()
    }

    /// Called at launch, when settings change and when the first-run tour ends (a new install
    /// records from then, as the tour says).
    func refreshState() {
        guard Defaults[.clipboardHistoryEnabled], !NotchViewCoordinator.shared.firstLaunch else {
            stopTimer()
            // Turning it back on asks again, even if a read is still pending.
            opening?.cancel()
            opening = nil
            failure = nil
            state = .off
            return
        }
        if let failure {
            stopTimer()
            state = failure == .key ? .keyUnavailable : .storageFailed
            return
        }
        if vault == nil {
            stopTimer()
            state = .opening
            openVault()
            return
        }
        if #available(macOS 15.4, *) {
            let behavior = NSPasteboard.general.accessBehavior
            macOSWillAsk = behavior == .ask
            if behavior == .alwaysDeny {
                stopTimer()
                state = .accessDenied
                accessCheck?.cancel()
                accessCheck = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(5))
                    guard let self, !Task.isCancelled else { return }
                    self.refreshState()
                }
                return
            }
        }
        let pinnedBytes = entries.filter(\.pinned).reduce(0) { $0 + $1.byteCount }
        let next: State = screenLocked ? .locked
            : Defaults[.clipboardPaused] ? .paused
            : pinnedBytes > limits.budgetBytes ? .storageFull
            : .recording
        state = next
        if next == .recording { startTimer() } else { stopTimer() }
    }

    private func openVault() {
        guard opening == nil else { return }
        let (directory, keyStore) = (self.directory, self.keyStore)
        opening = Task {
            let opened = await Task.detached(priority: .utility) {
                let vault: ClipboardVault
                do {
                    let key = try keyStore.loadOrCreate { try ClipboardVault.setAside(directory) }
                    vault = ClipboardVault(directory: directory, key: key)
                } catch {
                    throw Failure.key
                }
                let earlier = ClipboardVault.earlierDirectory(in: directory)
                do {
                    try vault.prepare()
                    return (vault, try vault.loadEntries(), FileManager.default.fileExists(atPath: earlier.path))
                } catch ClipboardVaultError.corrupt {
                    // Sealed with another key (a new one was made since): only starting over opens it.
                    throw Failure.key
                } catch {
                    throw Failure.storage
                }
            }.result
            guard !Task.isCancelled else { return }
            opening = nil
            switch opened {
            case .success(let (vault, entries, earlierKept)):
                self.entries = entries
                self.vault = vault
                self.earlierKept = earlierKept
                applyPruning()
                ioQueue.async { [entries] in vault.removeOrphanBlobs(keeping: Set(entries.map(\.id))) }
            case .failure(let error):
                failure = error as? Failure ?? .storage
                log.error("clipboard vault unavailable: \(String(describing: error), privacy: .public)")
            }
            refreshState()
        }
    }

    private func startTimer() {
        guard timer == nil else { return }
        lastChangeCount = NSPasteboard.general.changeCount  // never import what was there before
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: Capture

    private func poll(leaving app: String? = nil) {
        // Never record once paused or off, even before the settings observer stops the timer.
        guard Defaults[.clipboardHistoryEnabled], !Defaults[.clipboardPaused], !screenLocked else { return refreshState() }
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        capture(from: pasteboard, leaving: app)
    }

    /// Universal Clipboard's mark on a copy made on another device; kept as the entry's source.
    nonisolated static let anotherDevice = "com.apple.is-remote-clipboard"
    nonisolated static let screenshotApp = "com.apple.screenshot.launcher"
    nonisolated static let plainImageTypes: Set<String> = ["public.png", "public.tiff", "public.jpeg", "public.heic", "public.heif",
                                                           "com.compuserve.gif", "Apple PNG pasteboard type",
                                                           "NeXT TIFF v4.0 pasteboard type", "com.apple.pict"]

    private func capture(from pasteboard: NSPasteboard, leaving: String?) {
        let now = Date()
        let changeCount = pasteboard.changeCount
        let types = pasteboard.types?.map(\.rawValue) ?? []
        // The pasteboard doesn't say who wrote it: marks first, then the app in front.
        let marked = types.contains(Self.anotherDevice) ? Self.anotherDevice
            : pasteboard.string(forType: .init("org.nspasteboard.source"))
        var sourceID = marked ?? leaving ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if let reason = ClipboardPolicy.skipReason(types: types, sourceBundleID: sourceID,
                                                    excludedApps: Defaults[.clipboardExcludedApps]) {
            log.debug("skipped copy: \(String(describing: reason), privacy: .public)")
            return
        }
        if types.contains(NSPasteboard.PasteboardType.fileURL.rawValue) { return }

        let png = pasteboard.data(forType: .png)
        let image = png ?? pasteboard.data(forType: .tiff)
        let text = image == nil ? pasteboard.string(forType: .string) : nil
        // Changed while we read (a password manager may just have written): the types may not match.
        guard pasteboard.changeCount == changeCount else { return }

        if let image, marked == nil {
            if Self.isScreenshot(image) {
                sourceID = Self.screenshotApp
            } else if Set(types).isSubset(of: Self.plainImageTypes) {
                // A picture and nothing else (a ⌘⌃⇧4 screenshot, most of all) doesn't say who copied it.
                sourceID = nil
            }
        }
        if let image {
            addImage(image, isPNG: png != nil, source: sourceID, now: now)
        } else if let text, !text.isEmpty {
            if let reason = ClipboardPolicy.skipReason(forText: text) {
                log.debug("skipped text: \(String(describing: reason), privacy: .public)")
                return
            }
            addText(text, source: sourceID, now: now)
        }
    }

    private func addText(_ text: String, source: String?, now: Date) {
        if let index = entries.firstIndex(where: { $0.text == text }) {
            entries[index].copiedAt = now
            entries[index].sourceBundleID = source ?? entries[index].sourceBundleID
        } else {
            let content: ClipboardEntry.Content = ClipboardPolicy.link(in: text) != nil ? .link(text) : .text(text)
            entries.insert(ClipboardEntry(id: UUID(), content: content, byteCount: text.utf8.count,
                                          sourceBundleID: source, copiedAt: now), at: 0)
        }
        commit()
    }

    private func addImage(_ data: Data, isPNG: Bool, source: String?, now: Date) {
        guard data.count <= ClipboardPolicy.maxImageBytes, let vault else { return }
        let id = UUID()
        ioQueue.async { [weak self] in
            guard let image = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  Double(width) * Double(height) <= ClipboardPolicy.maxImagePixels else { return }
            let stored = isPNG ? data : (NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) ?? data)
            let size = CGSize(width: width, height: height)
            do {
                try vault.saveBlob(stored, for: id)
            } catch {
                Task { @MainActor in self?.saveFailed(error) }
                return
            }
            Task { @MainActor in
                guard let self else { return }
                self.entries.insert(ClipboardEntry(id: id, content: .image(size: size), byteCount: stored.count,
                                                   sourceBundleID: source, copiedAt: now), at: 0)
                self.commit()
            }
        }
    }

    // MARK: Actions

    /// Puts `entry` back on the pasteboard, marked so it isn't captured again: text at once, so
    /// Return then ⌘V pastes it; an image once read off the main thread, unless something newer
    /// was copied meanwhile (then `done` isn't called).
    func copy(_ entry: ClipboardEntry, done: @escaping @MainActor @Sendable (Bool) -> Void) {
        switch entry.content {
        case .text(let text), .link(let text):
            put(entry) { $0.setString(text, forType: .string) }
            done(true)
        case .image:
            guard let vault else { return done(false) }
            let changeCount = NSPasteboard.general.changeCount
            ioQueue.async { [weak self] in
                let data = try? vault.loadBlob(for: entry.id)
                Task { @MainActor in
                    guard let data, let self else { return done(false) }
                    guard NSPasteboard.general.changeCount == changeCount else { return }
                    self.put(entry) { $0.setData(data, forType: .png) }
                    done(true)
                }
            }
        }
    }

    private func put(_ entry: ClipboardEntry, _ fill: (NSPasteboard) -> Void) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        fill(pasteboard)
        pasteboard.setData(Data(), forType: .init(ClipboardPolicy.ownMarkerType))
        lastChangeCount = pasteboard.changeCount
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index].copiedAt = Date()
            commit()
        }
    }

    func togglePin(_ entry: ClipboardEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index].pinned.toggle()
        commit()
    }

    func delete(_ entry: ClipboardEntry) {
        entries.removeAll { $0.id == entry.id }
        if entry.kind == .image, let vault { ioQueue.async { vault.deleteBlob(for: entry.id) } }
        thumbnails.removeObject(forKey: entry.id as NSUUID)
        commit()
    }

    func clearUnpinned() {
        let removed = entries.filter { !$0.pinned }
        entries.removeAll { !$0.pinned }
        if let vault { ioQueue.async { removed.filter { $0.kind == .image }.forEach { vault.deleteBlob(for: $0.id) } } }
        commit()
    }

    func confirmClear() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Clear clipboard history?")
        alert.informativeText = String(localized: "Pinned items stay. This can't be undone.")
        alert.addButton(withTitle: String(localized: "Clear Unpinned Items")).hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "Cancel"))
        if runFromNotch({ alert.runModal() }) == .alertFirstButtonReturn { clearUnpinned() }
    }

    func eraseAll() {
        opening?.cancel()
        opening = nil
        bringing?.cancel()
        bringing = nil
        bringingBack = false
        entries = []
        thumbnails.removeAllObjects()
        // Also when the history is locked and was never opened.
        Relay.removeOwnItem(at: directory)
        keyStore.delete()
        vault = nil
        failure = nil
        earlierKept = false
        bringBackFailed = false
        refreshState()
    }

    /// Adds what the history set aside kept to this one. macOS is asked for the earlier key (the only
    /// time this version asks) unless the current key opens it. Anything that can't be copied keeps it
    /// all set aside; it's deleted once the merged history is saved.
    func bringBackEarlier() {
        guard let vault, earlierKept, bringing == nil else { return }
        bringingBack = true
        bringBackFailed = false
        let (keyStore, ioQueue, earlierDirectory) = (self.keyStore, self.ioQueue, ClipboardVault.earlierDirectory(in: directory))
        bringing = Task {
            let opened = await Task.detached(priority: .userInitiated) {
                // Set aside before a key was stored that's now this history's own (a crash in between).
                let sameKey = ClipboardVault(directory: earlierDirectory, key: vault.key)
                if let entries = try? sameKey.loadEntries() { return (sameKey, entries) }
                let earlier = ClipboardVault(directory: earlierDirectory, key: try keyStore.loadEarlier())
                return (earlier, try earlier.loadEntries())
            }.result
            // Images are copied in turn with the history's other file work.
            let copied: Result<[ClipboardEntry], Error> = await withCheckedContinuation { done in
                ioQueue.async {
                    done.resume(returning: Result {
                        let (earlier, entries) = try opened.get()
                        return try entries.filter { entry in
                            guard entry.kind == .image else { return true }
                            guard earlier.hasBlob(for: entry.id) else { return false }  // gone before
                            try vault.saveBlob(earlier.loadBlob(for: entry.id), for: entry.id)
                            return true
                        }
                    })
                }
            }
            guard !Task.isCancelled else { return }
            guard case .success(let earlier) = copied else {
                if case .failure(let error) = copied {
                    log.error("earlier clipboard history not brought back: \(String(describing: error), privacy: .public)")
                }
                bringing = nil
                bringingBack = false
                bringBackFailed = true
                return
            }
            let known = Set(entries.map(\.id))
            for entry in earlier where !known.contains(entry.id) {
                // Copied before and since, as copying it again would: one entry, pinned if either was.
                if let text = entry.text, let index = entries.firstIndex(where: { $0.text == text }) {
                    entries[index].pinned = entries[index].pinned || entry.pinned
                } else {
                    entries.append(entry)
                }
            }
            applyPruning()
            refreshState()
            let snapshot = entries
            ioQueue.async {
                let saved: Bool
                do {
                    try vault.saveEntries(snapshot)
                    Relay.removeOwnItem(at: earlierDirectory)
                    keyStore.forgetEarlier()
                    saved = true
                } catch {
                    Task { @MainActor in self.saveFailed(error) }
                    saved = false
                }
                Task { @MainActor in
                    self.bringing = nil
                    self.bringingBack = false
                    if saved { self.earlierKept = false }
                }
            }
        }
    }

    func deleteEarlier() {
        let (keyStore, earlierDirectory) = (self.keyStore, ClipboardVault.earlierDirectory(in: directory))
        earlierKept = false
        bringBackFailed = false
        ioQueue.async {
            Relay.removeOwnItem(at: earlierDirectory)
            keyStore.forgetEarlier()
        }
    }

    // MARK: Pruning & persistence

    func applyLimits() {
        commit()
    }

    /// Also when nothing new is copied (the tab opening, the Mac unlocking).
    func pruneExpired() {
        let before = entries.count
        applyPruning()
        if entries.count != before { commit() }
    }

    func flush() {
        saveTask?.cancel()
        guard let vault else { return }
        let snapshot = entries
        ioQueue.sync { try? vault.saveEntries(snapshot) }
    }

    private func applyPruning() {
        let result = ClipboardPolicy.prune(entries, now: Date(), limits: limits)
        entries = result.kept.sorted { ($0.pinned ? 1 : 0, $0.copiedAt) > ($1.pinned ? 1 : 0, $1.copiedAt) }
        result.removed.forEach { thumbnails.removeObject(forKey: $0.id as NSUUID) }
        if let vault {
            let gone = result.removed.filter { $0.kind == .image }
            if !gone.isEmpty { ioQueue.async { gone.forEach { vault.deleteBlob(for: $0.id) } } }
        }
    }

    private func commit() {
        applyPruning()
        refreshState()
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self, !Task.isCancelled, let vault = self.vault else { return }
            let snapshot = self.entries
            self.ioQueue.async {
                do { try vault.saveEntries(snapshot) } catch { Task { @MainActor in self.saveFailed(error) } }
            }
        }
    }

    /// Recording stops and says so, rather than going on with nothing kept.
    private func saveFailed(_ error: Error) {
        log.error("clipboard history not saved: \(String(describing: error), privacy: .public)")
        failure = .storage
        refreshState()
    }

    func filtered(_ query: String) -> [ClipboardEntry] {
        entries.filter { ClipboardPolicy.matches($0, query: query, appName: $0.sourceBundleID.flatMap(Self.appName)) }
    }

    nonisolated static func appName(_ bundleID: String) -> String? {
        bundleID == anotherDevice ? String(localized: "another device") : AppInfo.name(bundleID: bundleID)
    }

    /// macOS stamps its screenshots with this EXIF comment, on the clipboard as in files.
    nonisolated static func isScreenshot(_ image: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(image as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        else { return false }
        return exif[kCGImagePropertyExifUserComment] as? String == "Screenshot"
    }

    func thumbnail(for entry: ClipboardEntry) async -> NSImage? {
        if let cached = thumbnails.object(forKey: entry.id as NSUUID) { return cached }
        guard entry.kind == .image, let vault else { return nil }
        let image: NSImage? = await withCheckedContinuation { continuation in
            ioQueue.async {
                guard let data = try? vault.loadBlob(for: entry.id),
                      let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                          kCGImageSourceCreateThumbnailFromImageAlways: true,
                          kCGImageSourceThumbnailMaxPixelSize: 240,
                          kCGImageSourceCreateThumbnailWithTransform: true,
                      ] as CFDictionary) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: NSImage(cgImage: cg, size: .zero))
            }
        }
        if let image { thumbnails.setObject(image, forKey: entry.id as NSUUID) }
        return image
    }

    func itemProvider(for entry: ClipboardEntry) -> NSItemProvider {
        switch entry.content {
        case .text(let text):
            return NSItemProvider(object: text as NSString)
        case .link(let text):
            if let url = ClipboardPolicy.link(in: text) { return NSItemProvider(object: url as NSURL) }
            return NSItemProvider(object: text as NSString)
        case .image:
            let provider = NSItemProvider()
            let vault = self.vault
            provider.registerDataRepresentation(forTypeIdentifier: "public.png", visibility: .all) { completion in
                completion(try? vault?.loadBlob(for: entry.id), nil)
                return nil
            }
            return provider
        }
    }
}
