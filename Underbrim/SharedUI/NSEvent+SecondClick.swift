//
//  NSEvent+SecondClick.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//

import AppKit

extension NSEvent {
    /// The click being handled is the second of a double-click. A button that moves or changes
    /// under the pointer ignores it, or a double-click acts twice (a step skipped, a widget added
    /// and taken off again). Only a recent mouse event counts, so a keyboard or VoiceOver press
    /// after an old double-click still works.
    @MainActor static var isSecondClick: Bool {
        guard let event = NSApp.currentEvent, [.leftMouseDown, .leftMouseUp].contains(event.type),
              ProcessInfo.processInfo.systemUptime - event.timestamp < doubleClickInterval
        else { return false }
        return event.clickCount > 1
    }
}
