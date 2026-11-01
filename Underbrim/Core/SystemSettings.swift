//
//  SystemSettings.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Links into System Settings › Privacy & Security, one per permission Underbrim asks for.
//

import AppKit

enum SystemSettings {
    /// A pane of Privacy & Security, by the anchor System Settings opens it with.
    enum Privacy: String {
        case accessibility = "Privacy_Accessibility"
        case audioCapture = "Privacy_AudioCapture"
        case automation = "Privacy_Automation"
        case bluetooth = "Privacy_Bluetooth"
        case calendars = "Privacy_Calendars"
        case camera = "Privacy_Camera"
        case location = "Privacy_LocationServices"
        case reminders = "Privacy_Reminders"
    }

    static func privacy(_ pane: Privacy) -> URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)")!
    }

    static func open(_ pane: Privacy) {
        NSWorkspace.shared.open(privacy(pane))
    }
}
