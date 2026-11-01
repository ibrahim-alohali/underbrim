//
//  OSDPreferences.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//

import SwiftUI
import Defaults

// Action to perform when Option (⌥) is held while pressing media keys
enum OptionKeyAction: String, CaseIterable, Identifiable, Defaults.Serializable {
    case openSettings
    case showOSD
    case none

    var id: String { self.rawValue }

    init?(rawValue: String) {
        switch rawValue {
        case "openSettings", "Open System Settings": self = .openSettings
        case "showOSD", "Show HUD": self = .showOSD
        case "none", "No Action": self = .none
        default: return nil
        }
    }

    var localizedString: String {
        switch self {
        case .openSettings:
            return String(localized: "Open System Settings", comment: "Option (⌥) key behavior: Open System Settings")
        case .showOSD:
            return String(localized: "Show OSD", comment: "Option (⌥) key behavior: Show OSD")
        case .none:
            return String(localized: "No action", comment: "Option (⌥) key behavior: No action")
        }
    }
}

// Source/provider for OSD control (user-facing: "Source")
enum OSDControlSource: String, CaseIterable, Identifiable, Defaults.Serializable {
    case builtin
    case betterDisplay = "BetterDisplay"
    case lunar = "Lunar"

    var id: String { self.rawValue }

    var localizedString: String {
        switch self {
        case .builtin:
            return String(localized: "Built-in", comment: "OSD Sources: Built-in")
        case .betterDisplay:
            return "BetterDisplay"
        case .lunar:
            return "Lunar"
        }
    }
}
