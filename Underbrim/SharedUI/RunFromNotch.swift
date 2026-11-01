//
//  RunFromNotch.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Dialogs and panels opened from the notch, which is never the active app: Underbrim comes to the
//  front for them, and the app that had focus gets it back.
//

import AppKit

/// Runs a modal dialog shown from the notch: this app comes to the front for it, then the app that had focus gets it back.
@MainActor
func runFromNotch<T>(_ dialog: () -> T) -> T {
    let previous = NSWorkspace.shared.frontmostApplication
    NSApp.activate()
    defer { previous?.activate() }
    return dialog()
}

/// The same for a panel that runs on its own: the app that had focus gets it back on Cancel, while after OK
/// focus stays with whatever the answer opened.
@MainActor
func runFromNotch(_ panel: NSSavePanel) async -> NSApplication.ModalResponse {
    let previous = NSWorkspace.shared.frontmostApplication
    NSApp.activate()
    let response = await panel.begin()
    if response != .OK { previous?.activate() }
    return response
}
