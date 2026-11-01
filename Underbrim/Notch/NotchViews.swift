//
//  NotchViews.swift
//  Underbrim
//
//  Created by Harsh Vardhan  Goswami  on 04/08/24.
//

import Foundation
import Defaults

enum NotchState {
    case closed
    case open
}

enum NotchViews: String, Defaults.Serializable {
    case home
    case shelf
    case clipboard
    case agents
    case sound
    /// Not tabs: shown when the notch opens from these activities.
    case downloads
    case meeting
    case phoneActivities
    /// Today's prayer times (from the Prayer widget or the closed notch).
    case prayer
    case welcome

    static let tabs: [NotchViews] = [.home, .shelf, .clipboard, .agents, .sound]
}

enum WindowHeightMode: String, Defaults.Serializable {
    case matchMenuBar = "Match menubar height"
    case matchRealNotchSize = "Match real notch height"
    case custom = "Custom height"
}
