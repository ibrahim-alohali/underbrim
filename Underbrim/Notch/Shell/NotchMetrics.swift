//
//  NotchMetrics.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The notch's proportions and type. Closed, the outline is the camera cutout's (185 × 32 pt with
//  ~4 pt shoulders and ~8 pt corners on a 14" MacBook Pro, NotchBay's measurements; Apple publishes
//  none), so the radii scale with the cutout's height.
//

import SwiftUI

enum NotchMetrics {
    static let margin: CGFloat = 12
    static let openBottomRadius: CGFloat = 24
    /// Rows, artwork and drop areas: concentric with the open outline.
    static let innerRadius: CGFloat = openBottomRadius - margin
    static let openTopRadius: CGFloat = 10
    static let cutoutClearance: CGFloat = 8
    /// Between the header band and the tab; the band's own room around the header makes up the margin.
    static let bandSpacing: CGFloat = 4
    /// Every tab is one low row this tall (the artwork's height): the notch grows sideways, not down.
    static let tabHeight: CGFloat = 88
    /// Shelf, Clipboard and Agents fill this width; Home sizes to its widgets.
    static let openContentWidth: CGFloat = 716
    /// A file drag this far down opens the notch: the open Shelf plus ~120 pt, ahead of a quick drag.
    static let dragNearDepth: CGFloat = 260

    static let cardSpacing: CGFloat = 8

    static func cutoutTopRadius(height: CGFloat) -> CGFloat { height / 8 }
    static func cutoutBottomRadius(height: CGFloat) -> CGFloat { height / 4 }
}

extension Font {
    /// The open notch's text styles: titles, supporting text, labels and figures (`.monospacedDigit()` for changing numbers).
    static let notchTitle = Font.system(size: 13, weight: .semibold)
    static let notchBody = Font.system(size: 12)
    static let notchCaption = Font.system(size: 11)
    static func notchSymbol(size: CGFloat = 13) -> Font { .system(size: size, weight: .medium) }
}

extension ShapeStyle where Self == Color {
    static var notchRowFill: Color { .white.opacity(0.07) }
    static var notchRowHoverFill: Color { .white.opacity(0.11) }
}
