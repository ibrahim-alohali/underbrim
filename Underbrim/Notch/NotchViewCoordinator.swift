//
//  NotchViewCoordinator.swift
//  Underbrim
//
//  Created by Alexander on 2024-11-20.
//

import AppKit
import Combine
import Defaults
import SwiftUI

@MainActor
final class NotchViewCoordinator: ObservableObject {
    static let shared = NotchViewCoordinator()

    @Published var currentView: NotchViews = .home
    /// The tab last picked, which the notch reopens to with "Remember last tab"; activity and drag views don't count.
    private(set) var lastTab: NotchViews = .home
    private var picked: (view: NotchViews, at: Date) = (.home, .distantPast)

    func selectTab(_ view: NotchViews) {
        currentView = view
        picked = (view, Date())
        if NotchViews.tabs.contains(view) { lastTab = view }
    }
    @Published var screenLocked = false
    /// The page the open island shows: Home on the lock screen (files and sessions are no one's business
    /// there) unless the tour was showing. Page-dependent code reads this; `currentView` keeps the page for after.
    var shownView: NotchViews { screenLocked && currentView != .welcome ? .home : currentView }
    @Published var editingWidgets = false

    func setEditingWidgets(_ on: Bool) {
        withAnimation(StandardAnimations.open) { editingWidgets = on }
    }

    var firstLaunch: Bool {
        get { Defaults[.firstLaunch] }
        set {
            objectWillChange.send()
            Defaults[.firstLaunch] = newValue
        }
    }
    /// The first-run tour: when its rim light started (the notch opens on the welcome card after it).
    @Published var firstRunStart: Date?
    var touring: Bool { firstRunStart != nil }

    func startFirstRun() {
        firstRunStart = Date()
    }

    func finishFirstRun() {
        firstRunStart = nil
        // The tour offered the notch's volume and brightness: no second offer later.
        Defaults[.hudNudgeShown] = true
        firstLaunch = false
        currentView = .home
        ClipboardHistory.shared.refreshState()
    }
    var musicLiveActivityEnabled: Bool {
        get { Defaults[.musicLiveActivityEnabled] }
        set {
            objectWillChange.send()
            Defaults[.musicLiveActivityEnabled] = newValue
        }
    }

    var alwaysShowTabs: Bool {
        get { Defaults[.alwaysShowTabs] }
        set {
            objectWillChange.send()
            Defaults[.alwaysShowTabs] = newValue
            // "Remember last tab" is left as it was: turning this back on mustn't find it off.
            if !newValue, ShelfStateViewModel.shared.isEmpty || !Defaults[.openShelfByDefault] {
                currentView = .home
            }
        }
    }

    var openLastTabByDefault: Bool {
        get { Defaults[.openLastTabByDefault] }
        set {
            objectWillChange.send()
            Defaults[.openLastTabByDefault] = newValue
            if newValue {
                alwaysShowTabs = true
            }
        }
    }

    /// Reopens on the last tab unless its feature is now off; compact mode has no tab bar, so the player.
    var reopenView: NotchViews {
        if Defaults[.compactMode] || !lastTab.isOn { return .home }
        // An empty shelf with its tab hidden would have no way back to Home.
        if lastTab == .shelf, !alwaysShowTabs, ShelfStateViewModel.shared.isEmpty { return .home }
        return lastTab
    }

    var viewForDrag: NotchViews {
        let urls = NSPasteboard(name: .drag).readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return Defaults[.showQuickLaunch] && !urls.isEmpty && urls.allSatisfy { $0.pathExtension == "app" } ? .home : .shelf
    }

    /// Where the notch opens from the island: the activity's page, unless a tab was picked since that
    /// activity took the island; then that tab, a `live` activity's while it lasts, a regular one where
    /// the notch would open anyway. The bubble opens its own page and doesn't count as a pick.
    func viewOnOpen(main: (view: NotchViews, since: Date)?, live: [NotchViews]) -> NotchViews {
        let pickedSince = main.map { picked.at > $0.since } ?? true
        if pickedSince, live.contains(picked.view) { return picked.view }
        if let main, !(pickedSince && NotchViews.tabs.contains(picked.view)) { return main.view }
        return openLastTabByDefault ? reopenView : currentView
    }

    var preferredScreenUUID: String? {
        get { Defaults[.preferredScreenUUID] }
        set {
            objectWillChange.send()
            Defaults[.preferredScreenUUID] = newValue
            if let uuid = newValue {
                selectedScreenUUID = uuid
            }
        }
    }

    @Published var selectedScreenUUID: String = NSScreen.main?.displayUUID ?? ""

    private var shelfCancellable: AnyCancellable?

    private init() {
        // Perform migration from name-based to UUID-based storage
        if preferredScreenUUID == nil, let legacyName = Defaults[.preferredScreenName] {
            // Try to find screen by name and migrate to UUID
            if let screen = NSScreen.screens.first(where: { $0.localizedName == legacyName }),
               let uuid = screen.displayUUID {
                preferredScreenUUID = uuid
                NSLog("✅ Migrated display preference from name '\(legacyName)' to UUID '\(uuid)'")
            } else {
                // Fallback to main screen if legacy screen not found
                preferredScreenUUID = NSScreen.main?.displayUUID
                NSLog("⚠️ Could not find display named '\(legacyName)', falling back to main screen")
            }
            // Clear legacy value after migration
            Defaults[.preferredScreenName] = nil
        } else if preferredScreenUUID == nil {
            // No legacy value, use main screen
            preferredScreenUUID = NSScreen.main?.displayUUID
        }

        selectedScreenUUID = preferredScreenUUID ?? NSScreen.main?.displayUUID ?? ""
        // Home's widgets changed: Home and the island's width, which read them unobserved, lay out again.
        Defaults.whenChanged(HomeWidget.layoutKeys) {
            [weak self] in withAnimation(StandardAnimations.open) { self?.objectWillChange.send() }
        }
        shelfCancellable = Defaults.publisher(.shelfEnabled)
            .sink { [weak self] change in
                Task { @MainActor in
                    guard let self = self else { return }
                    if !change.newValue && self.currentView == .shelf {
                        self.currentView = .home
                    }
                }
            }
    }

}
