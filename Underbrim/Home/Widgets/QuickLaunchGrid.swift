//
//  QuickLaunchGrid.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Where Quick Launch's spots sit in Home's grid or the pinned row.
//

import SwiftUI

/// Home's grid or the pinned row, worked out left to right and mirrored for right-to-left.
struct QuickLaunchLayout {
    let style: QuickLaunchWidget.Style
    let columns: Int
    let row: [Int]
    let rows: Int
    let rightToLeft: Bool

    init(style: QuickLaunchWidget.Style, columns: Int, shown: [Int: String], editing: Bool, rightToLeft: Bool) {
        self.style = style
        self.columns = columns
        self.rightToLeft = rightToLeft
        row = QuickLaunch.pinnedOrder(shown, columns: columns)
        rows = style != .pinned && (editing || shown.keys.contains { $0 >= QuickLaunch.rowLength }) ? 2 : 1
    }

    var icon: CGFloat { style == .pinned ? QuickLaunchWidget.pinnedIcon : QuickLaunchWidget.icon }
    var cell: CGFloat { icon + QuickLaunchWidget.spacing }
    var gridWidth: CGFloat {
        style == .pinned ? CGFloat(row.count) * cell : QuickLaunchWidget.width(columns: columns)
    }
    var width: CGFloat { gridWidth + (style == .home ? QuickLaunchWidget.corner : 0) }
    var height: CGFloat { style == .pinned ? QuickLaunchWidget.pinnedHeight : NotchMetrics.tabHeight }
    var top: CGFloat { style == .pinned ? 2 : (height - (CGFloat(rows) * cell - QuickLaunchWidget.spacing)) / 2 }

    private func x(_ leading: CGFloat, width size: CGFloat) -> CGFloat { rightToLeft ? width - leading - size : leading }

    func origin(_ spot: Int) -> CGPoint {
        if style == .pinned {
            let k = row.firstIndex(of: spot) ?? 0
            let leading = CGFloat(k) * cell + QuickLaunchWidget.spacing / 2
            return CGPoint(x: x(leading, width: icon), y: top)
        }
        return CGPoint(x: x(CGFloat(spot % QuickLaunch.rowLength) * cell, width: icon), y: top + CGFloat(spot / QuickLaunch.rowLength) * cell)
    }

    func center(_ spot: Int) -> CGPoint {
        let origin = origin(spot)
        return CGPoint(x: origin.x + icon / 2, y: origin.y + icon / 2)
    }

    func minusCenter(_ spot: Int) -> CGPoint {
        let origin = origin(spot)
        return CGPoint(x: rightToLeft ? origin.x + icon - 2 : origin.x + 2, y: origin.y + 2)
    }

    var spots: [Int] {
        style == .pinned ? row : QuickLaunch.order(columns: columns).filter { $0 < QuickLaunch.rowLength || rows == 2 }
    }

    func spot(at point: CGPoint) -> Int? {
        spots.first { spot in
            CGRect(origin: origin(spot), size: CGSize(width: icon, height: icon))
                .insetBy(dx: -QuickLaunchWidget.spacing / 2, dy: -QuickLaunchWidget.spacing / 2).contains(point)
        }
    }

    var area: CGRect {
        style == .pinned
            ? CGRect(x: x(0, width: gridWidth), y: 0, width: gridWidth, height: height)
            : CGRect(x: x(0, width: gridWidth), y: top, width: gridWidth, height: CGFloat(rows) * cell - QuickLaunchWidget.spacing)
    }

    var editCenter: CGPoint { CGPoint(x: x(gridWidth, width: QuickLaunchWidget.corner) + QuickLaunchWidget.corner / 2, y: height / 2) }
}
