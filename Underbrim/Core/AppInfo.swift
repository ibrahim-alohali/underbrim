//
//  AppInfo.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Other apps, for every feature that names one or brings one forward: one rule for an app's
//  name, and one way to activate it.
//

import AppKit
import os

enum AppInfo {
    private static let names = OSAllocatedUnfairLock(initialState: [String: String]())

    /// An installed app's display name by bundle id, or nil. Cached once found (rows ask on every redraw);
    /// not found is asked again, so an app Launch Services learns of later shows up.
    static func name(bundleID: String) -> String? {
        if let cached = names.withLock({ $0[bundleID] }) { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let name = name(url: url)
        names.withLock { $0[bundleID] = name }
        return name
    }

    /// Forgets a cached name, for an app that changed.
    static func forgetName(bundleID: String) {
        names.withLock { $0[bundleID] = nil }
    }

    /// The app at `url`, as Finder names it (localized, without ".app"); many apps, Mail among them,
    /// set no CFBundleDisplayName.
    static func name(url: URL) -> String {
        let name = (try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName) ?? url.lastPathComponent
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    /// Brings the app forward as its Dock icon does, unhiding it and showing a window if
    /// all were closed. `activate()` alone is refused for an inactive caller (the notch
    /// always is) and never asks for a window.
    @MainActor
    static func activate(_ bundleID: String) {
        // NSWorkspace's list: `runningApplications(withBundleIdentifier:)` found nothing
        // for an open app in the first seconds after Underbrim started.
        let running = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleID && !$0.isTerminated }
        guard let url = running?.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return NSSound.beep()
        }
        if running?.isHidden == true { running?.unhide() }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, _ in
            guard app == nil else { return }
            DispatchQueue.main.async { running?.activate(options: .activateAllWindows) }
        }
    }
}
