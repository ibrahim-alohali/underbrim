//
//  NotchGeometry.swift
//  Underbrim
//
//  Created by Harsh Vardhan  Goswami  on 05/08/24.
//

import Defaults
import Foundation
import SwiftUI

let shadowPadding: CGFloat = 20
/// Upstream's open notch size, which the view model still reports while open;
/// Underbrim's open notch sizes to its content (see OpenNotchLayout).
let openNotchSize: CGSize = .init(width: 640, height: 190)
/// Headroom for the open notch; the rest of the window is transparent and
/// clicks pass through it. The tallest island is the welcome tour's feature
/// picks: 392 pt in English on macOS 27, 433 pt in German.
let maxOpenNotchHeight: CGFloat = 440
/// Wide enough for the widest open notch (Home with many widgets, 1,200 pt).
let windowSize: CGSize = .init(width: 1240, height: maxOpenNotchHeight + shadowPadding)
/// The width of the band at the top, centred on the notch, where a dragged file opens it.
let dragOpenWidth: CGFloat = 940
let cornerRadiusInsets: (opened: (top: CGFloat, bottom: CGFloat), closed: (top: CGFloat, bottom: CGFloat)) = (opened: (top: 19, bottom: 24), closed: (top: 6, bottom: 14))

// Horizontal gap between closed-state live-activity content (album art / waveform)
// and the physical notch edge. Without this margin the hardware bezel clips the
// adjacent content since the spacer rect used to be narrower than the physical notch.
let liveActivityEdgeMargin: CGFloat = 8

/// The camera cutout's exact width (between the menu bar's two halves), or
/// nil on a display without one. getClosedNotchSize pads it by 4 for the
/// closed activities' layout; the idle notch uses this.
@MainActor func notchCutoutWidth(for screen: NSScreen?) -> CGFloat? {
    guard let screen, screen.safeAreaInsets.top > 0,
          let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { return nil }
    return screen.frame.width - left.width - right.width
}

@MainActor func getScreenFrame(_ screenUUID: String? = nil) -> CGRect? {
    var selectedScreen = NSScreen.main

    if let uuid = screenUUID {
        selectedScreen = NSScreen.screen(withUUID: uuid)
    }

    if let screen = selectedScreen {
        return screen.frame
    }

    return nil
}

@MainActor func getRealNotchHeight() -> CGFloat {
    for screen in NSScreen.screens {
        let safeAreaTop = screen.safeAreaInsets.top
        if safeAreaTop > 0 {
            return safeAreaTop
        }
    }

    return 38
}

@MainActor private func defaultMenuBarHeight(hasNotch: Bool) -> CGFloat {
    if #available(macOS 26.0, *) {
        return hasNotch ? 38 : 29
    }

    return hasNotch ? 43 : 23
}

@MainActor private func resolvedMenuBarHeight(for screen: NSScreen?) -> CGFloat {
    if let screen {
        let measuredHeight = max(0, screen.frame.maxY - screen.visibleFrame.maxY - 1)
        if measuredHeight > 0 {
            return measuredHeight
        }

        return defaultMenuBarHeight(hasNotch: screen.safeAreaInsets.top > 0)
    }

    return defaultMenuBarHeight(hasNotch: false)
}

@MainActor func getMenuBarHeight(for screen: NSScreen?) -> CGFloat {
    resolvedMenuBarHeight(for: screen ?? NSScreen.main ?? NSScreen.screens.first)
}

@MainActor func getMenuBarHeight(hasNotch: Bool) -> CGFloat {
    if let matchingScreen = NSScreen.screens.first(where: { ($0.safeAreaInsets.top > 0) == hasNotch }) {
        return resolvedMenuBarHeight(for: matchingScreen)
    }

    return defaultMenuBarHeight(hasNotch: hasNotch)
}

@MainActor func syncNotchHeightIfNeeded() {
    // "Match real notch height" isn't a valid choice for a non-notch display
    // — there's no real notch to match — so it's not offered in that
    // Picker. A value here can only be leftover from an older build that
    // allowed it; fall back to the sensible default rather than leaving a
    // persisted value with no matching Picker tag.
    if Defaults[.nonNotchHeightMode] == .matchRealNotchSize {
        Defaults[.nonNotchHeightMode] = .matchMenuBar
    }

    switch Defaults[.notchHeightMode] {
    case .matchRealNotchSize:
        let realHeight = getRealNotchHeight()
        if Defaults[.notchHeight] != realHeight {
            Defaults[.notchHeight] = realHeight
        }

    case .matchMenuBar:
        let menuHeight = getMenuBarHeight(hasNotch: true)
        if Defaults[.notchHeight] != menuHeight {
            Defaults[.notchHeight] = menuHeight
        }

    case .custom:
        break
    }

    switch Defaults[.nonNotchHeightMode] {
    case .matchMenuBar:
        let menuHeight = getMenuBarHeight(hasNotch: false)
        if Defaults[.nonNotchHeight] != menuHeight {
            Defaults[.nonNotchHeight] = menuHeight
        }

    case .matchRealNotchSize, .custom:
        break
    }
}

@MainActor func getClosedNotchSize(screenUUID: String? = nil) -> CGSize {
    // Default notch size, to avoid using optionals
    var notchHeight: CGFloat = Defaults[.nonNotchHeight]
    var notchWidth: CGFloat = 185

    var selectedScreen = NSScreen.main

    if let uuid = screenUUID {
        selectedScreen = NSScreen.screen(withUUID: uuid)
    }

    // Floating (a display without a notch): the closed capsule, as wide as where pointing opens it.
    if let island = FloatingIsland.on(selectedScreen) {
        return .init(width: FloatingIsland.hoverWidth, height: island.capsuleHeight)
    }

    // Check if the screen is available
    if let screen = selectedScreen {
        // Calculate and set the exact width of the notch
        if let topLeftNotchpadding: CGFloat = screen.auxiliaryTopLeftArea?.width,
           let topRightNotchpadding: CGFloat = screen.auxiliaryTopRightArea?.width {
            notchWidth = screen.frame.width - topLeftNotchpadding - topRightNotchpadding + 4
        }
        notchHeight = screen.safeAreaInsets.top > 0 ? Defaults[.notchHeight] : Defaults[.nonNotchHeight]
    }

    return .init(width: notchWidth, height: notchHeight)
}
