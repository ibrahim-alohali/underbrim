//
//  ShortcutsSettingsView.swift
//  Underbrim
//
//  Created by Richard Kunkli on 07/08/2024.
//

import KeyboardShortcuts
import SwiftUI

/// General › Shortcuts (Toggle Sneak Peek's is in Advanced › Media).
struct ShortcutsSettingsSection: View {
    /// ⌘ with one key (⌘W, ⌘C, ⌘,) is each app's own command: as one of these shortcuts, which
    /// work in every app, it would take that command from all of them. The Shortcuts island checks too.
    static func validate(_ shortcut: KeyboardShortcuts.Shortcut) -> KeyboardShortcuts.ValidationResult {
        shortcut.modifiers == .command
            ? .disallow(reason: String(localized: "Apps use ⌘ with one key for their own commands. Add ⌃, ⌥ or ⇧."))
            : .allow
    }

    var body: some View {
        Section {
            ShortcutRecorderRow(title: "Toggle Notch Open", mark: "Toggle Notch Open", name: .toggleNotchOpen)
            ShortcutRecorderRow(title: "Open Scratchpad", mark: "Open Scratchpad", name: .openScratchpad)
        } header: {
            Text("Keyboard Shortcuts")
        }
    }
}

/// A shortcut's recorder, and under it the other running apps that use the same shortcut (only one of them gets it).
struct ShortcutRecorderRow: View {
    let title: LocalizedStringKey
    let mark: String
    let name: KeyboardShortcuts.Name
    @State private var clashes: [String] = []
    @State private var revision = 0

    var body: some View {
        KeyboardShortcuts.Recorder(title, name: name)
            .shortcutValidation(ShortcutsSettingsSection.validate)
            .settingsItem(mark)
            // Looked up on show, on a shortcut change and when Settings is back in front (other apps may have changed).
            .task(id: revision) { await findClashes() }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("KeyboardShortcuts_shortcutByNameDidChange"))) { _ in
                revision += 1
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                revision += 1
            }
        if !clashes.isEmpty {
            Label {
                Text("Also used by \(clashes.formatted(.list(type: .and))). Only one app gets a shortcut, so pick another for one of them.")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private func findClashes() async {
        var found: [String] = []
        if let shortcut = KeyboardShortcuts.getShortcut(for: name) {
            found = await ShortcutClash.apps(using: shortcut)
        }
        if found != clashes { clashes = found }
    }
}
