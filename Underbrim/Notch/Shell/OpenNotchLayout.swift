//
//  OpenNotchLayout.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The open notch: the header's halves in the menu-bar band either side of the camera housing, at
//  the wider one's width so the housing stays centred, and the current tab below, which may widen
//  it without moving the halves (the tabs never move under the pointer). Only the current tab counts.
//

import SwiftUI

struct OpenNotchLayout: Layout {
    var cutoutGap: CGFloat
    var bandHeight: CGFloat
    var spacing: CGFloat
    /// The content that sizes the layout, matched against `notchSlot(.content(_:))`.
    var current: String
    /// Whether the header counts; passed in so halves still fading out don't hold the width.
    var showsHeader = true
    /// Whether the content's own width counts beside the header's: pinned Quick
    /// Launch, whose row can be wider than a call or the volume in the band.
    var hugsContent = false

    enum Slot: Equatable, Sendable {
        case leading, trailing
        /// Volume or brightness: beside the housing, where the closed HUD shows its symbol, in
        /// the room a narrower half leaves there (the halves move apart only when neither has it).
        case besideCamera
        /// Under the tab, across the notch: the slider the HUD opens into.
        case below
        case content(String)
    }

    struct SlotKey: LayoutValueKey {
        static let defaultValue: Slot? = nil
    }

    static let belowSpacing: CGFloat = 8
    static let besideGap: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = width(for: subviews)
        let content = content(in: subviews)
        let contentHeight = content.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height } ?? 0
        return CGSize(width: width, height: top(of: content) + contentHeight + belowHeight(in: subviews, width: width))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let contentProposal = ProposedViewSize(width: bounds.width, height: nil)
        let band = band(of: subviews)
        let reach = cutoutGap / 2 + band.half
        let current = content(in: subviews)
        let contentBottom = top(of: current) + (current.map { $0.sizeThatFits(contentProposal).height } ?? 0)
        for subview in subviews {
            switch subview[SlotKey.self] {
            case .leading:
                subview.place(at: CGPoint(x: bounds.midX - reach, y: bounds.minY + bandHeight / 2), anchor: .leading,
                              proposal: .unspecified)
            case .trailing:
                subview.place(at: CGPoint(x: bounds.midX + reach, y: bounds.minY + bandHeight / 2), anchor: .trailing,
                              proposal: .unspecified)
            case .besideCamera:
                let edge = cutoutGap / 2 + Self.besideGap
                subview.place(at: CGPoint(x: band.besideLeading ? bounds.midX - edge : bounds.midX + edge, y: bounds.minY + bandHeight / 2),
                              anchor: band.besideLeading ? .trailing : .leading, proposal: .unspecified)
            case .below:
                subview.place(at: CGPoint(x: bounds.minX, y: bounds.minY + contentBottom + Self.belowSpacing),
                              anchor: .topLeading, proposal: contentProposal)
            case .content, nil:
                subview.place(at: CGPoint(x: bounds.minX, y: bounds.minY + top(of: subview)), anchor: .topLeading,
                              proposal: contentProposal)
            }
        }
    }

    private func top(of content: LayoutSubview?) -> CGFloat {
        content?[CoversBandKey.self] == true ? 0 : bandHeight + spacing
    }

    private func belowHeight(in subviews: Subviews, width: CGFloat) -> CGFloat {
        guard let below = subviews.first(where: { $0[SlotKey.self] == .below }) else { return 0 }
        return Self.belowSpacing + below.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
    }

    /// Each half's width beside the housing, and the side that shows beside the camera: the one leaving
    /// room, else both halves moved out by what's missing (so the housing stays centred).
    private func band(of subviews: Subviews) -> (half: CGFloat, besideLeading: Bool) {
        func width(_ slot: Slot) -> CGFloat {
            subviews.filter { $0[SlotKey.self] == slot }.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        }
        func need(_ slot: Slot) -> CGFloat {
            subviews.contains { $0[SlotKey.self] == slot } ? width(slot) + Self.besideGap : 0
        }
        let leading = width(.leading), trailing = width(.trailing)
        let half = max(leading, trailing)
        let beside = need(.besideCamera)
        guard beside > 0 else { return (half, true) }
        if half - leading >= beside { return (half, true) }
        if half - trailing >= beside { return (half, false) }
        return (max(half, leading + beside), true)
    }

    /// With a header, both halves at the wider one's width unless the tab asks for more; without one
    /// (a notification, compact mode), the content's own width. Never narrower than the housing.
    private func width(for subviews: Subviews) -> CGFloat {
        let content = content(in: subviews)
        let minimum = max(cutoutGap, content?[MinimumWidthKey.self] ?? 0)
        let band = 2 * band(of: subviews).half + cutoutGap
        guard showsHeader else { return max(minimum, content?.sizeThatFits(.unspecified).width ?? 0, band) }
        let own = hugsContent ? content?.sizeThatFits(.unspecified).width ?? 0 : 0
        return max(band, minimum, own)
    }

    private func content(in subviews: Subviews) -> LayoutSubview? {
        subviews.first { $0[SlotKey.self] == .content(current) }
            ?? subviews.last { if case .content = $0[SlotKey.self] { true } else { false } }
    }

    struct MinimumWidthKey: LayoutValueKey {
        static let defaultValue: CGFloat = 0
    }

    struct CoversBandKey: LayoutValueKey {
        static let defaultValue = false
    }
}

extension View {
    func notchSlot(_ slot: OpenNotchLayout.Slot) -> some View {
        layoutValue(key: OpenNotchLayout.SlotKey.self, value: slot)
    }

    func notchMinimumWidth(_ width: CGFloat) -> some View {
        layoutValue(key: OpenNotchLayout.MinimumWidthKey.self, value: width)
    }

    /// Content that starts at the top, in the band beside the housing: a widget alone.
    func notchCoversBand() -> some View {
        layoutValue(key: OpenNotchLayout.CoversBandKey.self, value: true)
    }
}
