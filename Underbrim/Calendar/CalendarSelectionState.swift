//
//  CalendarSelectionState.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//

import SwiftUI
import Defaults

enum CalendarSelectionState: Codable, Defaults.Serializable {
    case all
    case selected(Set<String>)
}
