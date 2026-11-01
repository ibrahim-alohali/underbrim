//
//  ShortcutClash.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Which running app has the same global shortcut (only one app gets a shortcut two register).
//  macOS doesn't say who holds one, so this reads the running apps' preferences for the two common
//  forms: {keyCode, modifierFlags} (Rectangle) and KeyboardShortcuts' {"carbonKeyCode",
//  "carbonModifiers"}. Read only, off the main thread.
//

import AppKit
import Carbon.HIToolbox
import KeyboardShortcuts

enum ShortcutClash {
    static func apps(using shortcut: KeyboardShortcuts.Shortcut) async -> [String] {
        let apps = NSWorkspace.shared.runningApplications.compactMap { app -> (id: String, name: String)? in
            guard let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier, !id.hasPrefix("com.apple."),
                  app.activationPolicy != .prohibited else { return nil }
            return (id, app.localizedName ?? id)
        }
        let wanted = Keys(code: shortcut.carbonKeyCode, modifiers: shortcut.carbonModifiers & Keys.modifierMask)
        return await Task.detached(priority: .utility) {
            apps.filter { app in
                guard let preferences = CFPreferencesCopyMultiple(nil, app.id as CFString, kCFPreferencesCurrentUser,
                                                                  kCFPreferencesAnyHost) as? [String: Any] else { return false }
                return contains(wanted, in: preferences, depth: 0)
            }
            .map(\.name)
        }.value
    }

    struct Keys: Equatable {
        let code: Int
        let modifiers: Int

        /// ⌘ ⇧ ⌥ ⌃ in Carbon's form.
        static let modifierMask = cmdKey | shiftKey | optionKey | controlKey
    }

    static func contains(_ wanted: Keys, in value: Any, depth: Int) -> Bool {
        guard depth < 5 else { return false }
        switch value {
        case let dictionary as [String: Any]:
            if keys(in: dictionary) == wanted { return true }
            return dictionary.values.contains { contains(wanted, in: $0, depth: depth + 1) }
        case let array as [Any]:
            return array.contains { contains(wanted, in: $0, depth: depth + 1) }
        case let string as String:
            // KeyboardShortcuts keeps each shortcut as a small JSON object in a string.
            guard string.hasPrefix("{"), string.contains("carbonKeyCode"), let data = string.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return keys(in: object) == wanted
        default:
            return false
        }
    }

    static func keys(in dictionary: [String: Any]) -> Keys? {
        if let code = dictionary["carbonKeyCode"] as? Int, let modifiers = dictionary["carbonModifiers"] as? Int {
            return Keys(code: code, modifiers: modifiers & Keys.modifierMask)
        }
        guard let code = dictionary["keyCode"] as? Int, let flags = dictionary["modifierFlags"] as? Int else { return nil }
        let cocoa = NSEvent.ModifierFlags(rawValue: UInt(truncatingIfNeeded: flags))
        var carbon = 0
        if cocoa.contains(.command) { carbon |= cmdKey }
        if cocoa.contains(.shift) { carbon |= shiftKey }
        if cocoa.contains(.option) { carbon |= optionKey }
        if cocoa.contains(.control) { carbon |= controlKey }
        return Keys(code: code, modifiers: carbon)
    }
}
