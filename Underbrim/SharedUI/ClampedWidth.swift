//
//  ClampedWidth.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//

import SwiftUI

/// Clamps its one view's width to `range`: wider is offered the upper bound (text shrinks), narrower gets room after.
struct ClampedWidth: Layout {
    let range: ClosedRange<CGFloat>

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let view = subviews.first else { return .zero }
        let width = min(max(view.sizeThatFits(.unspecified).width, range.lowerBound), range.upperBound)
        return CGSize(width: width, height: view.sizeThatFits(ProposedViewSize(width: width, height: proposal.height)).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
                              proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}
