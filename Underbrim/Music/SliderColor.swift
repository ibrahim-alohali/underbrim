//
//  SliderColor.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//

import Foundation
import Defaults

enum SliderColorEnum: String, CaseIterable, Defaults.Serializable {
    case white
    case albumArt
    case accent

    init?(rawValue: String) {
        switch rawValue {
        case "white", "White": self = .white
        case "albumArt", "Match album art": self = .albumArt
        case "accent", "Accent color": self = .accent
        default: return nil
        }
    }

    var localizedString: String {
        switch self {
        case .white:
            return String(localized: "White", comment: "Slider color option: white")
        case .albumArt:
            return String(localized: "Match album art", comment: "Slider color option: match album art")
        case .accent:
            return String(localized: "Accent color", comment: "Slider color option: accent color")
        }
    }
}
