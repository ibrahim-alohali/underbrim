//
//  AccessibilityPermission.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//

import SwiftUI
import Defaults

// macOS 27 renamed the "Accessibility" privacy pane to "Device Control and
// Data Access". Read the name from Apple's private UniversalAccess auth-warn
// prompt bundle so it matches what the user sees in System Settings, falling
// back to the localized catalog strings.
enum AccessibilityPermission {
    /// What uses Accessibility: the settings each use reads, and whether it's on.
    private static let uses: [(keys: [Defaults._AnyKey], isOn: @Sendable () -> Bool)] = [
        ([.osdReplacement, .osdBrightnessSource, .osdVolumeSource],
         { Defaults[.osdReplacement] && (Defaults[.osdBrightnessSource] == .builtin || Defaults[.osdVolumeSource] == .builtin) }),
        ([.showFocusChanges], { Defaults[.showFocusChanges] && FocusWatcher.isSupported }),
        ([.showCapsLock], { Defaults[.showCapsLock] }),
        ([.showPhoneActivities], { Defaults[.showPhoneActivities] }),
        (SystemNotificationManager.wantedKeys, { SystemNotificationManager.isWanted }),
    ]

    static var needed: Bool { uses.contains { $0.isOn() } }

    /// Settings Accessibility's need follows, to look again when one changes.
    static let keys: [Defaults._AnyKey] = uses.flatMap(\.keys)

    static var displayName: String {
        if let appleName = appleLocalizedAccessibilityName() {
            return appleName
        }
        if #available(macOS 27, *) {
            return String(localized: "Device Control and Data Access")
        } else {
            return String(localized: "Accessibility")
        }
    }

    static var systemImageName: String {
        if #available(macOS 27, *) {
            return "folder.badge.gearshape"
        } else {
            return "accessibility"
        }
    }

    private static let osLocalizationPath =
        "/System/Library/PrivateFrameworks/UniversalAccess.framework/Versions/A/Resources/universalAccessAuthWarn.app/Contents/Resources/Localizable.loctable"

    private static let osPermissionKey = "window.title.accessibility"

    private static let osLocalizedNameTables: [String: [String: String]]? = {
        guard let plist = NSDictionary(contentsOfFile: osLocalizationPath) else {
            return nil
        }
        var tables: [String: [String: String]] = [:]
        for (key, value) in plist {
            guard let locale = key as? String, let entries = value as? [String: Any] else {
                continue
            }
            tables[locale] = entries.compactMapValues { $0 as? String }
        }
        return tables
    }()

    private static func appleLocalizedAccessibilityName() -> String? {
        guard let tables = osLocalizedNameTables else {
            return nil
        }
        for locale in preferredLocaleCandidates {
            if let name = tables[locale]?[osPermissionKey] {
                return name
            }
        }
        return tables["en"]?[osPermissionKey]
    }

    private static var preferredLocaleCandidates: [String] {
        let preferred = Bundle.main.preferredLocalizations + Locale.preferredLanguages
        var candidates: [String] = []
        for preference in preferred {
            let identifier = preference.replacingOccurrences(of: "-", with: "_")
            candidates.append(identifier)
            if identifier.hasPrefix("zh_Hans") {
                candidates.append("zh_CN")
            } else if identifier.hasPrefix("zh_Hant") {
                candidates.append("zh_TW")
                candidates.append("zh_HK")
            }
            if let language = identifier.split(separator: "_", maxSplits: 1).first {
                candidates.append(String(language))
            }
        }
        return candidates
    }
}
