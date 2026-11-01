//
//  QuickLaunchTile.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  A Quick Launch spot: an app's tile, an empty well, and what's dropped on them.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension View {
    /// Pinning, the row's apps fly from Home's (the `source`); `active` off,
    /// an app has no partner, so unpinning is a plain fade.
    @ViewBuilder func quickLaunchMatched(_ id: String, in namespace: Namespace.ID?, source: Bool, active: Bool) -> some View {
        if let namespace {
            matchedGeometryEffect(id: active ? "quickLaunch \(id)" : "quickLaunch resting \(id)", in: namespace, isSource: source)
        } else {
            self
        }
    }
}

struct QuickLaunchAppTile: View {
    enum Indicator: Equatable { case none, open, front, away }

    let app: String
    let size: CGFloat
    let pinned: Bool
    let indicator: Indicator
    let badge: String?
    let faded: Bool
    let hovered: Bool
    let pressed: Bool
    let launching: Bool
    let pops: Int
    let dips: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hopping = false

    private struct Dip {
        var scale = 1.0
        var y = 0.0
    }

    var body: some View {
        icon
            .frame(width: size, height: size)
            .overlay(alignment: .bottom) { dot }
    }

    private var icon: some View {
        AppIconView(bundleID: app, size: size)
            .opacity(faded ? 0.45 : 1)
            .brightness(pressed ? -0.25 : hovered && reduceMotion ? 0.08 : 0)
            .scaleEffect(reduceMotion ? 1 : pressed ? 0.92 : hovered ? 1.08 : 1)
            .animation(.snappy(duration: 0.15), value: hovered)
            .animation(.snappy(duration: 0.12), value: pressed)
            .keyframeAnimator(initialValue: 1.0, trigger: reduceMotion ? 0 : pops) { view, scale in
                view.scaleEffect(scale)
            } keyframes: { _ in
                KeyframeTrack {
                    CubicKeyframe(1.13, duration: 0.12)
                    SpringKeyframe(1, duration: 0.14)
                }
            }
            .keyframeAnimator(initialValue: Dip(), trigger: reduceMotion ? 0 : dips) { view, dip in
                view.scaleEffect(dip.scale).offset(y: dip.y)
            } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    CubicKeyframe(0.9, duration: 0.13)
                    CubicKeyframe(1, duration: 0.15)
                }
                KeyframeTrack(\.y) {
                    CubicKeyframe(3, duration: 0.13)
                    CubicKeyframe(0, duration: 0.15)
                }
            }
            .offset(y: hopping && !reduceMotion ? -6 : 0)
            .opacity(hopping && reduceMotion ? 0.45 : 1)
            .overlay(alignment: .topTrailing) {
                if let badge {
                    Text(badge)
                        .font(.system(size: pinned ? 9 : 10, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, pinned ? 3 : 4)
                        .frame(minWidth: pinned ? 13 : 16, minHeight: pinned ? 13 : 16)
                        .background(.red, in: Capsule())
                        // Pinned, kept clear of the camera housing above the row. SwiftUI
                        // mirrors the offset in right-to-left already.
                        .offset(x: pinned ? 4 : 5, y: pinned ? 0 : -4)
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.2), value: badge)
            .onChange(of: launching, initial: true) { _, on in
                if on {
                    withAnimation(.easeInOut(duration: reduceMotion ? 0.45 : 0.26).repeatForever(autoreverses: true)) { hopping = true }
                } else {
                    withAnimation(.snappy(duration: 0.2)) { hopping = false }
                }
            }
    }

    private var dot: some View {
        let front = indicator == .front, away = indicator == .away
        return Capsule()
            .fill(front ? Color.notchAccent : away ? Color.clear : Color.white.opacity(0.85))
            .overlay(Capsule().strokeBorder(.white.opacity(away ? 0.75 : 0), lineWidth: 1))
            .frame(width: front ? 12 : 4, height: 4)
            .opacity(indicator == .none || hovered ? 0 : 1)
            .offset(y: (pinned ? 1 : 3) + 4)
            .animation(.snappy(duration: 0.22), value: indicator)
            .animation(.snappy(duration: 0.16), value: hovered)
            .accessibilityHidden(true)
    }
}

struct QuickLaunchWell: View {
    let size: CGFloat
    @State private var hovering = false

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
            .fill(.white.opacity(hovering ? 0.15 : 0.08))
            .overlay {
                Image(systemName: "plus")
                    .font(.system(size: size * 0.4, weight: .light))
                    .foregroundStyle(.white.opacity(hovering ? 1 : 0.7))
            }
            .frame(width: size, height: size)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

struct QuickLaunchDrop: DropDelegate {
    let spotAt: (CGPoint) -> Int?
    @Binding var spot: Int?
    let perform: ([NSItemProvider], Int?) -> Bool

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let under = spotAt(info.location)
        if under != spot { spot = under }
        return DropProposal(operation: .copy)
    }

    func dropExited(info _: DropInfo) { spot = nil }

    func performDrop(info: DropInfo) -> Bool {
        let under = spotAt(info.location)
        spot = nil
        return perform(info.itemProviders(for: [.fileURL]), under)
    }
}
