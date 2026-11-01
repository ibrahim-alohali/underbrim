//
//  ShortcutConstants.swift
//  Underbrim
//
//  Created by Richard Kunkli on 16/08/2024.
//

import KeyboardShortcuts
import SwiftUI

extension KeyboardShortcuts.Name {
    /// No shortcut for new installs: ⌘⇧H is Finder's Home, Teams' hang-up and
    /// Slack's huddle. An existing install keeps the one it stored.
    static let toggleSneakPeek = Self("toggleSneakPeek")
    static let toggleNotchOpen = Self("toggleNotchOpen", initial: .init(.i, modifiers: [.command, .shift]))
    /// ⌃⇧⌘N for new installs: straight into the Scratchpad. Three modifiers, as apps rarely
    /// take those (⌃⌥N is Rectangle's Reflow Todo). An existing install keeps the one it stored.
    static let openScratchpad = Self("openScratchpad", initial: .init(.n, modifiers: [.control, .shift, .command]))
    /// ⌃⌥1–9: Quick Launch's spots, from any app.
    static let quickLaunchSpots: [Self] = zip(1...9, [KeyboardShortcuts.Key.one, .two, .three, .four, .five, .six, .seven, .eight, .nine])
        .map { number, key in Self("quickLaunch\(number)", initial: .init(key, modifiers: [.control, .option])) }
}
