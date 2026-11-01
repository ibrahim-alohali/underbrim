//
//  AgentLiveActivity.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The closed notch's coding-agent activity. Motion only accompanies real activity
//  and stops under Reduce Motion.
//

import SwiftUI

/// Right-hand glyph of the closed pill.
struct AgentStateGlyph: View {
    let kind: AgentClosedSummary.Kind
    let since: Date
    let others: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Counts the bounces: one as a session comes to need you or finishes.
    @State private var bounces = 0

    var body: some View {
        ZStack(alignment: .topTrailing) {
            symbol
                .font(.notchSymbol(size: 13))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if others > 0 {
                Text("\(others + 1)")
                    .font(.system(size: 8, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.black)
                    .padding(.horizontal, 3)
                    .background(.white.opacity(0.85), in: Capsule())
                    .offset(x: 4, y: -2)
            }
        }
        .accessibilityHidden(true)
        // Once, when it happens: after the new symbol is in (a symbol effect plays on a change it
        // sees), and not again when the island closes over a state that's been there a while.
        .task(id: kind) {
            guard !reduceMotion, kind == .attention || kind == .question || kind == .finished,
                  Date.now.timeIntervalSince(since) < 1 else { return }
            bounces += 1
        }
    }

    @ViewBuilder private var symbol: some View {
        switch kind {
        case .working:
            ActivityDots(animated: !reduceMotion)
                .frame(width: 16, height: 6)
        case .attention:
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(.orange)
                .symbolEffect(.bounce, value: bounces)
        case .question:
            Image(systemName: "questionmark.bubble.fill")
                .foregroundStyle(.orange)
                .symbolEffect(.bounce, value: bounces)
        case .finished:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .symbolEffect(.bounce, value: bounces)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
        case .stopped:
            Image(systemName: "stop.circle")
                .foregroundStyle(.secondary)
        }
    }
}

struct AgentLiveActivity: View {
    @EnvironmentObject private var vm: NotchViewModel
    let summary: AgentClosedSummary

    private var itemSize: CGFloat { vm.closedItemSize }
    private static let creatureSpacing: CGFloat = 3
    /// Both sides as wide as the creatures need, so the island stays centred on the notch.
    private var wing: CGFloat {
        guard !summary.creatures.isEmpty, itemSize > 0 else { return itemSize }
        let widths = summary.creatures.map { item in
            let box = item.kind.creature.box
            return box.width * itemSize / box.height
        }
        return max(itemSize, widths.reduce(0, +) + CGFloat(widths.count - 1) * Self.creatureSpacing)
    }

    var body: some View {
        HStack {
            Group {
                if summary.creatures.isEmpty {
                    AppIconView(bundleID: summary.hostBundleID ?? summary.provider.defaultHostBundleID, size: itemSize)
                } else {
                    HStack(spacing: Self.creatureSpacing) {
                        ForEach(summary.creatures) { item in
                            AgentCreatureView(kind: item.kind, state: item.state, since: item.since, height: itemSize)
                        }
                    }
                }
            }
            .frame(width: wing, alignment: .leading)
            if vm.floating != nil {
                // The floating capsule has no camera in the middle: the state in words there.
                Text(summary.words)
                    .font(.notchCaption.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: FloatingIsland.titleWidth, alignment: .leading)
            } else {
                Rectangle()
                    .fill(.black)
                    .frame(width: vm.closedMiddleWidth)
            }
            AgentStateGlyph(kind: summary.kind, since: summary.since, others: summary.othersActive)
                .frame(width: itemSize, height: itemSize)
                .frame(width: wing, alignment: .trailing)
        }
        .frame(height: vm.effectiveClosedNotchHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary.accessibilityText)
        .accessibilityValue(summary.othersActive > 0 ? Text("Other active sessions: \(summary.othersActive)") : Text(verbatim: ""))
        .accessibilityAddTraits(.updatesFrequently)
    }
}
