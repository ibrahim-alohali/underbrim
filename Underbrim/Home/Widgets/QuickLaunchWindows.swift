//
//  QuickLaunchWindows.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Apps' windows through Accessibility, for Quick Launch: whether they're all minimized, and
//  minimizing them or bringing them back.
//

@preconcurrency import ApplicationServices
import os

enum QuickLaunchWindows {
    enum Arrangement: Sendable { case minimized, forward, unseen }

    static func arrange(pid: pid_t, inFront: Bool) -> Arrangement {
        let windows = standardWindows(pid)
        // None: coming forward opens one; unless one shows that Accessibility can't see.
        guard !windows.isEmpty else { return CallActivity.hasWindowOnScreen(pid) ? .unseen : .forward }
        if windows.allSatisfy(isMinimized) {
            windows.forEach { $0.set(kAXMinimizedAttribute, false) }
            return .forward
        }
        guard inFront else { return .forward }
        windows.forEach { $0.set(kAXMinimizedAttribute, true) }
        return .minimized
    }

    static func allMinimized(_ apps: [(String, pid_t)]) -> Set<String> {
        Set(apps.compactMap { id, pid in
            let windows = standardWindows(pid)
            return !windows.isEmpty && windows.allSatisfy(isMinimized) ? id : nil
        })
    }

    /// Some apps (WhatsApp) leave minimized windows out of the list; seen before, they still answer,
    /// so they count while they're there and minimized.
    static func standardWindows(_ pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        // A hung app mustn't hold Quick Launch up: each element waits half a second at most.
        AXUIElementSetMessagingTimeout(app, 0.5)
        let all = app[kAXWindowsAttribute] as? [AXUIElement] ?? []
        all.forEach { AXUIElementSetMessagingTimeout($0, 0.5) }
        let listed = all.filter { $0.string(kAXSubroleAttribute) == kAXStandardWindowSubrole }
        let earlier = seenWindows.withLockUnchecked { $0[pid] ?? [] }
        let windows = listed + earlier.filter { old in !listed.contains { CFEqual($0, old) } && old.exists && isMinimized(old) }
        seenWindows.withLockUnchecked { $0[pid] = windows.isEmpty ? nil : windows }
        return windows
    }

    private static let seenWindows = OSAllocatedUnfairLock(uncheckedState: [pid_t: [AXUIElement]]())

    static func isMinimized(_ window: AXUIElement) -> Bool { window[kAXMinimizedAttribute] as? Bool == true }
}
