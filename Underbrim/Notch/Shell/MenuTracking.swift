//
//  MenuTracking.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The menus this app is showing. AppKit runs a menu in its own tracking loop and reaching an item
//  takes the pointer off the island, so the island stays open while one shows.
//

import AppKit
import Observation

@MainActor
@Observable
final class MenuTracking {
    static let shared = MenuTracking()

    private(set) var isOpen = false
    /// Weak: a menu AppKit has let go of no longer counts, even if its end was never reported.
    @ObservationIgnored private let menus = NSHashTable<NSMenu>.weakObjects()

    private init() {
        let center = NotificationCenter.default
        center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] note in
            guard let menu = note.object as? NSMenu else { return }
            MainActor.assumeIsolated { self?.menus.add(menu); self?.changed() }
        }
        center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] note in
            guard let menu = note.object as? NSMenu else { return }
            MainActor.assumeIsolated { self?.menus.remove(menu); self?.changed() }
        }
    }

    private func changed() {
        let open = !menus.allObjects.isEmpty
        if isOpen != open { isOpen = open }
    }

    /// Forgets menus never reported closed once nothing is tracking, so a lost notification can't hold the island.
    func dropStale() {
        guard isOpen, RunLoop.current.currentMode != .eventTracking else { return }
        Log.window.notice("Menu hold dropped: no menu is tracking")
        menus.removeAllObjects()
        changed()
    }

    /// The island closed on purpose (Escape, the shortcut, locking): its menus go with it.
    func closeAll() {
        menus.allObjects.forEach { $0.cancelTracking() }
    }
}
