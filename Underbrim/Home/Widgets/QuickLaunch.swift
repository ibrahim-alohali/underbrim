//
//  QuickLaunch.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Quick Launch: twelve spots in two rows. Untouched spots in row 1 suggest the
//  most used apps (app switches, halving weekly, seeded from Spotlight); counts stay on this Mac.
//

import AppKit
@preconcurrency import ApplicationServices
import Defaults
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class QuickLaunch {
    static let shared = QuickLaunch()
    nonisolated static let halfLife: TimeInterval = 7 * 86400
    nonisolated static let rowLength = 6
    nonisolated static let spotCount = 2 * rowLength

    /// The spots the user set: an app's bundle ID, or "" where they emptied it.
    private(set) var spots: [Int: String]
    private(set) var suggested: [Int: String]
    private(set) var running: Set<String> = []
    private(set) var hidden: Set<String> = []
    private(set) var minimized: Set<String> = []
    /// The user's app in front. Underbrim doesn't count: its Settings, or the
    /// notch with the keyboard, don't change what a click on an app does.
    private(set) var front: String?
    private(set) var launching: Set<String> = []
    private(set) var badges: [String: String] = [:]
    /// A click brought the app forward (a pop) or sent it away (a dip); each bump plays once.
    private(set) var pops: [String: Int] = [:]
    private(set) var dips: [String: Int] = [:]
    var pinned: Bool { WidgetPin.shared.widget == .quickLaunch }
    var editing = false
    /// An app is being dragged: the island stays open meanwhile.
    var dragging = false
    var focus: Int?
    /// Quick Launch showing in an island (Home or pinned): the keyboard's keys are its.
    @ObservationIgnored var onScreen = 0
    @ObservationIgnored var gridOnScreen = 0
    /// Pinned or unpinned so far (see QuickLaunchWidget's `flies`).
    @ObservationIgnored private(set) var pinChanges = 0

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var query: NSMetadataQuery?
    @ObservationIgnored private var queryObserver: NSObjectProtocol?
    @ObservationIgnored private var watched: [String] = []
    @ObservationIgnored private var suggestedAt = Date.distantPast

    private init() {
        spots = Defaults[.quickLaunchSpots]
        suggested = Defaults[.quickLaunchSuggested]
        HomeWidgetKeys.register(.quickLaunch) { [weak self] key, modifiers in self?.key(key, modifiers: modifiers) ?? false }
    }

    /// Its keys while it's showing: arrows move, Return clicks the pick, 1–9 click spots; false if not its.
    private func key(_ key: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard onScreen > 0, !editing, modifiers.intersection([.command, .control, .option]).isEmpty else { return false }
        switch key {
        case 123: moveFocus(across: -1)
        case 124: moveFocus(across: 1)
        case 125: moveFocus(down: 1)
        case 126: moveFocus(down: -1)
        case 36, 76:
            guard focus != nil else { return false }
            clickFocus()
        default:
            // By key, not character: the same keys in every keyboard layout (Arabic's digits too), and the keypad's.
            guard let digit = Self.digitKeys.firstIndex(of: key) ?? Self.keypadDigitKeys.firstIndex(of: key) else { return false }
            clickSpot(digit + 1)
        }
        return true
    }

    private static let digitKeys: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
    private static let keypadDigitKeys: [UInt16] = [83, 84, 85, 86, 87, 88, 89, 91, 92]

    static var columns: Int { HomeWidget.quickLaunch.size.quickLaunchColumns }

    func start() {
        migrate()
        Defaults.whenChanged([.showQuickLaunch]) { [weak self] in self?.applySetting() }
        applySetting()
    }

    private func applySetting() {
        let center = NSWorkspace.shared.notificationCenter
        guard Defaults[.showQuickLaunch] else {
            observers.forEach(center.removeObserver)
            observers = []
            return
        }
        guard observers.isEmpty else { return }
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { if let app { QuickLaunch.shared.activated(app) } }
        })
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { QuickLaunch.shared.refreshRunning() }
            })
        }
        if let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier != Bundle.main.bundleIdentifier {
            front = app.bundleIdentifier
        }
        refreshRunning()
        if Defaults[.quickLaunchUsageAt] == nil { seedFromSpotlight() }
    }

    private func refreshRunning() {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        let now = Set(apps.compactMap(\.bundleIdentifier)), hiddenNow = Set(apps.filter(\.isHidden).compactMap(\.bundleIdentifier))
        if now != running { running = now }
        if hiddenNow != hidden { hidden = hiddenNow }
    }

    private func activated(_ app: NSRunningApplication) {
        guard app.activationPolicy == .regular, let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier else { return }
        front = id
        if launching.remove(id) != nil { pops[id, default: 0] += 1 }
        record(app)
        refreshRunning()
        Task { await refreshStates(for: watched) }
    }

    private func record(_ app: NSRunningApplication) {
        guard let id = app.bundleIdentifier, let path = app.bundleURL?.path, Self.isEligible(path: path, bundleID: id) else { return }
        let now = Date()
        Defaults[.quickLaunchUsage] = Self.counted(id, in: Defaults[.quickLaunchUsage], since: Defaults[.quickLaunchUsageAt], now: now)
        Defaults[.quickLaunchUsageAt] = now
    }

    private func seedFromSpotlight() {
        guard query == nil else { return }
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryLocalComputerScope]
        query.predicate = NSPredicate(format: "kMDItemContentTypeTree == 'com.apple.application-bundle' AND kMDItemLastUsedDate >= %@",
                                      Date(timeIntervalSinceNow: -30 * 86400) as NSDate)
        queryObserver = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main) { _ in
            MainActor.assumeIsolated { QuickLaunch.shared.finishSeeding() }
        }
        self.query = query
        query.start()
    }

    private func finishSeeding() {
        guard let query else { return }
        query.stop()
        self.query = nil
        if let queryObserver { NotificationCenter.default.removeObserver(queryObserver) }
        queryObserver = nil
        let now = Date()
        var seeds: [String: Double] = [:]
        for case let item as NSMetadataItem in query.results {
            guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  let id = item.value(forAttribute: "kMDItemCFBundleIdentifier") as? String,
                  let used = item.value(forAttribute: "kMDItemLastUsedDate") as? Date,
                  let count = (item.value(forAttribute: "kMDItemUseCount") as? NSNumber)?.doubleValue,
                  Self.isEligible(path: path, bundleID: id), !Self.runsInBackground(Bundle(path: path)?.infoDictionary)
            else { continue }
            seeds[id] = max(seeds[id] ?? 0, count * pow(0.5, max(0, now.timeIntervalSince(used)) / Self.halfLife))
        }
        // Switches counted meanwhile stay; the seed fills in around them.
        let counted = Self.decayed(Defaults[.quickLaunchUsage], by: now.timeIntervalSince(Defaults[.quickLaunchUsageAt] ?? now))
        Defaults[.quickLaunchUsage] = seeds.merging(counted, uniquingKeysWith: +)
        Defaults[.quickLaunchUsageAt] = now
        refreshSuggestions(reorder: false)
    }

    nonisolated static func decayed(_ scores: [String: Double], by elapsed: TimeInterval) -> [String: Double] {
        guard elapsed > 0 else { return scores }
        let factor = pow(0.5, elapsed / halfLife)
        return scores.compactMapValues { $0 * factor >= 0.05 ? $0 * factor : nil }
    }

    nonisolated static func counted(_ id: String, in scores: [String: Double], since: Date?, now: Date) -> [String: Double] {
        var scores = decayed(scores, by: now.timeIntervalSince(since ?? now))
        scores[id, default: 0] += 1
        return scores
    }

    /// An app the user opens: in an Applications folder, not inside another app, not Finder or Underbrim.
    nonisolated static func isEligible(path: String, bundleID: String) -> Bool {
        guard path.hasSuffix(".app"), bundleID != "com.apple.finder", bundleID != Bundle.main.bundleIdentifier else { return false }
        // Safari runs from the system's app cryptex.
        let folders = ["/Applications/", "/System/Applications/", Relay.homeDirectory + "/Applications/",
                       "/System/Volumes/Preboot/Cryptexes/App/System/Applications/"]
        guard let folder = folders.first(where: path.hasPrefix) else { return false }
        return !path.dropFirst(folder.count).dropLast(4).contains(".app/")
    }

    nonisolated static func runsInBackground(_ info: [String: Any]?) -> Bool {
        ["LSUIElement", "LSBackgroundOnly"].contains { key in
            info?[key] as? Bool == true || (info?[key] as? String).map { $0 == "1" || $0.lowercased() == "yes" } == true
        }
    }

    // MARK: The spots

    nonisolated static func order(columns: Int) -> [Int] {
        (0..<2).flatMap { row in (0..<columns).map { row * rowLength + $0 } }
    }

    func shown(columns: Int = QuickLaunch.columns) -> [Int: String] {
        let placed = Set(spots.values)
        var shown: [Int: String] = [:], seen = Set<String>()
        for spot in Self.order(columns: columns) {
            let id = spots[spot] ?? (spot < Self.rowLength ? suggested[spot].flatMap { placed.contains($0) ? nil : $0 } : nil)
            if let id, !id.isEmpty, AppInfo.name(bundleID: id) != nil, seen.insert(id).inserted { shown[spot] = id }
        }
        return shown
    }

    nonisolated static func pinnedOrder(_ shown: [Int: String], columns: Int) -> [Int] {
        order(columns: columns).filter { shown[$0] != nil }
    }

    /// `reorder` (as Quick Launch appears) lets suggestions follow rank; otherwise
    /// only gaps fill, so nothing moves under the pointer.
    func refreshSuggestions(reorder: Bool = true) {
        if reorder { suggestedAt = .now }
        let placed = Set(spots.values), never = Set(Defaults[.quickLaunchHidden])
        let ranked = Defaults[.quickLaunchUsage].sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
            .filter { !placed.contains($0) && !never.contains($0) && AppInfo.name(bundleID: $0) != nil }
        let next = Self.sticky(previous: suggested, open: (0..<Self.columns).filter { spots[$0] == nil }, ranked: ranked, reorder: reorder)
        guard next != suggested else { return }
        suggested = next
        Defaults[.quickLaunchSuggested] = next
    }

    /// Pinned Quick Launch stays on screen: its suggestions change when the
    /// pointer leaves it, at most every ten minutes.
    func refreshSuggestionsIfStale() {
        if Date.now.timeIntervalSince(suggestedAt) > 600 { refreshSuggestions() }
    }

    nonisolated static func sticky(previous: [Int: String], open: [Int], ranked: [String], reorder: Bool) -> [Int: String] {
        let keepable = reorder ? Array(ranked.prefix(open.count)) : ranked
        var next: [Int: String] = [:]
        for spot in open {
            if let id = previous[spot], keepable.contains(id), !next.values.contains(id) { next[spot] = id }
        }
        var rest = ranked.filter { !next.values.contains($0) }.makeIterator()
        for spot in open where next[spot] == nil {
            guard let id = rest.next() else { break }
            next[spot] = id
        }
        return next
    }

    func place(_ id: String, at spot: Int) {
        Defaults[.quickLaunchHidden].removeAll { $0 == id }
        spots = Self.placing(id, at: spot, in: spots)
        saved()
    }

    nonisolated static func placing(_ id: String, at spot: Int, in spots: [Int: String]) -> [Int: String] {
        var spots = spots.mapValues { $0 == id ? "" : $0 }
        spots[spot] = id
        return spots
    }

    func move(from: Int, to: Int) {
        spots = Self.moving(from: from, to: to, shown: shown(), in: spots)
        saved()
    }

    nonisolated static func moving(from: Int, to: Int, shown: [Int: String], in spots: [Int: String]) -> [Int: String] {
        guard from != to, let id = shown[from] else { return spots }
        var spots = spots
        spots[to] = id
        spots[from] = shown[to] ?? ""
        return spots
    }

    func remove(at spot: Int) {
        guard let id = shown()[spot] else { return }
        spots[spot] = ""
        if !Defaults[.quickLaunchHidden].contains(id) { Defaults[.quickLaunchHidden].append(id) }
        saved()
    }

    func keep(at spot: Int) {
        if spots[spot] == nil, let id = suggested[spot] { place(id, at: spot) }
    }

    func suggest(at spot: Int) {
        spots[spot] = nil
        saved()
    }

    private func saved() {
        Defaults[.quickLaunchSpots] = spots
        refreshSuggestions(reorder: false)
    }

    /// Imports, once, the list builds before 1.0 kept. The old keys stay, so an
    /// older build still has them.
    private func migrate() {
        guard UserDefaults.standard.object(forKey: Defaults.Keys.quickLaunchSpots.name) == nil else { return }
        spots = Self.migrated(kept: Defaults[.quickLaunchKept], fill: Defaults[.quickLaunchAutoFill], columns: Self.columns)
        Defaults[.quickLaunchSpots] = spots
    }

    nonisolated static func migrated(kept: [String], fill: Bool, columns: Int) -> [Int: String] {
        let showing = order(columns: columns)
        var spots: [Int: String] = [:]
        for (spot, id) in zip(showing + (0..<spotCount).filter { !showing.contains($0) }, kept) { spots[spot] = id }
        if !fill { for spot in 0..<columns where spots[spot] == nil { spots[spot] = "" } }
        return spots
    }

    // MARK: Adding

    func openApps(besides showing: Set<String>) -> [String] {
        Set(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap(\.bundleIdentifier))
            .filter { $0 != Bundle.main.bundleIdentifier && !showing.contains($0) }
            .sorted { (AppInfo.name(bundleID: $0) ?? $0).localizedStandardCompare(AppInfo.name(bundleID: $1) ?? $1) == .orderedAscending }
    }

    func pickApp(for spot: Int) {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = String(localized: "Add")
        guard runFromNotch({ panel.runModal() }) == .OK, let id = panel.url.flatMap({ Bundle(url: $0)?.bundleIdentifier }) else { return }
        withAnimation(.snappy(duration: 0.3)) { place(id, at: spot) }
    }

    /// Dropped from Finder: apps fill `spot` and the next empty spots (the app there moves
    /// to an empty one); documents dropped on an app open with it. False when nothing would happen.
    func drop(_ providers: [NSItemProvider], at spot: Int?) -> Bool {
        let showing = shown()
        let carriesApps = providers.contains { $0.registeredTypeIdentifiers.contains { UTType($0)?.conforms(to: .application) == true } }
        guard carriesApps || spot.flatMap({ showing[$0] }) != nil else { return false }
        Task {
            var urls: [URL] = []
            for provider in providers { if let url = await provider.extractFileURL() { urls.append(url) } }
            let documents = urls.filter { $0.pathExtension != "app" }
            if !documents.isEmpty, let target = spot.flatMap({ showing[$0] }),
               let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: target) {
                NSWorkspace.shared.open(documents, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
                pops[target, default: 0] += 1
            }
            let apps = urls.filter { $0.pathExtension == "app" }.compactMap { Bundle(url: $0)?.bundleIdentifier }
            let visible = Self.order(columns: Self.columns), free = visible.filter { showing[$0] == nil }
            guard !apps.isEmpty, let first = spot ?? free.first else { return }
            let displaced = spots[first].flatMap { $0.isEmpty || apps.contains($0) ? nil : $0 }
            withAnimation(.snappy(duration: 0.3)) {
                for (id, place) in zip(apps, [first] + free.filter { $0 != first }) { self.place(id, at: place) }
                let empty = (visible + (0..<Self.spotCount).filter { !visible.contains($0) })
                    .first { (spots[$0] ?? "").isEmpty && shown()[$0] == nil }
                if let displaced, let empty { self.place(displaced, at: empty) }
            }
        }
        return true
    }

    // MARK: Clicking

    /// Not open: opens. Open behind: comes forward with its minimized windows.
    /// In front: minimizes (hides without Accessibility). No window: opens one.
    func click(_ id: String) {
        guard !launching.contains(id) else { return }
        guard let app = Self.runningApp(id) else {
            // Uninstalled since its tile showed: a beep, not ten seconds of "opening".
            guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil else {
                AppInfo.forgetName(bundleID: id)
                return NSSound.beep()
            }
            launching.insert(id)
            AppInfo.activate(id)
            Task {
                try? await Task.sleep(for: .seconds(10))
                launching.remove(id)
            }
            return
        }
        if app.isHidden { return bringForward(id) }
        let inFront = front == id, pid = app.processIdentifier
        guard AXIsProcessTrusted() else { return hideOrBringForward(id, inFront: inFront) }
        Task {
            switch await Task.detached(operation: { QuickLaunchWindows.arrange(pid: pid, inFront: inFront) }).value {
            case .minimized: dips[id, default: 0] += 1
            case .forward: bringForward(id)
            case .unseen: hideOrBringForward(id, inFront: inFront)
            }
            try? await Task.sleep(for: .milliseconds(500))  // past the windows' animation
            await refreshStates(for: [id])
        }
    }

    private func hideOrBringForward(_ id: String, inFront: Bool) {
        if inFront, let app = Self.runningApp(id), CallActivity.hasWindowOnScreen(app.processIdentifier) {
            app.hide()
            dips[id, default: 0] += 1
        } else {
            bringForward(id)
        }
    }

    private func bringForward(_ id: String) {
        AppInfo.activate(id)
        pops[id, default: 0] += 1
    }

    /// ⌃⌥1–9, or 1–9 with the island's keyboard. The pinned row counts the apps drawn;
    /// Home's grid counts spots, whenever it's on screen.
    func clickSpot(_ n: Int) {
        let order = pinned && gridOnScreen == 0 ? Self.pinnedOrder(shown(), columns: Self.columns) : Self.order(columns: Self.columns)
        guard order.indices.contains(n - 1), let id = shown()[order[n - 1]] else { return NSSound.beep() }
        click(id)
    }

    /// Left and right (`across`) in reading order, mirrored in right-to-left; up and down between the rows.
    func moveFocus(across: Int = 0, down: Int = 0) {
        let apps = shown()
        let order = Self.pinnedOrder(apps, columns: Self.columns)
        guard let current = focus, let index = order.firstIndex(of: current) else { focus = order.first; return }
        if across != 0 {
            let step = NSApp.userInterfaceLayoutDirection == .rightToLeft ? -across : across
            focus = order[min(max(index + step, 0), order.count - 1)]
        } else if down != 0, (down > 0) == (current < Self.rowLength) {
            let other = current + down * Self.rowLength
            if apps[other] != nil { focus = other }
        }
    }

    func clickFocus() {
        if let focus, let id = shown()[focus] { click(id) }
    }

    func setPinned(_ on: Bool) {
        if on { WidgetPin.shared.set(.quickLaunch) } else if pinned { WidgetPin.shared.set(nil) }
    }

    func pinChanged() {
        editing = false
        pinChanges += 1
    }

    // MARK: States

    /// From NSWorkspace's list: `NSRunningApplication.runningApplications(withBundleIdentifier:)`
    /// found nothing for an open app in the first seconds after Underbrim started.
    static func runningApp(_ id: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == id && !$0.isTerminated }
    }

    func watch(_ apps: [String]) async {
        watched = apps
        while !Task.isCancelled {
            await refreshStates(for: apps)
            try? await Task.sleep(for: .seconds(2))
        }
        if watched == apps { watched = [] }
    }

    func refreshStates(for apps: [String]) async {
        let open = apps.compactMap { id in Self.runningApp(id).map { (id, $0.processIdentifier) } }
        var badges = self.badges.filter { !apps.contains($0.key) }
        if Defaults[.quickLaunchBadges] {
            for (id, pid) in open { badges[id] = AppBadges.badge(pid: pid) }
        }
        if badges != self.badges { self.badges = badges }
        guard AXIsProcessTrusted() else {
            if !minimized.isEmpty { minimized = [] }
            return
        }
        let found = await Task.detached { QuickLaunchWindows.allMinimized(open) }.value
        let next = minimized.subtracting(apps).union(found)
        if next != minimized { minimized = next }
    }
}
