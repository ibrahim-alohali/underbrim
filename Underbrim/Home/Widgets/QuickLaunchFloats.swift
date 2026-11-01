//
//  QuickLaunchFloats.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  What floats over the island from Quick Launch: an app's name, the app being dragged, and the
//  puff when one is removed.
//

import SwiftUI

struct QuickLaunchFloats {
    let anchor: Anchor<CGRect>
    let float: QuickLaunchFloat
}

enum QuickLaunchFloat {
    case name(String, at: CGPoint, belowIsland: Bool)
    case ghost(String, center: CGPoint, size: CGFloat, removing: Bool)
    case poof(String, center: CGPoint, size: CGFloat)
}

struct QuickLaunchFloatKey: PreferenceKey {
    static var defaultValue: QuickLaunchFloats? { nil }

    static func reduce(value: inout QuickLaunchFloats?, nextValue: () -> QuickLaunchFloats?) {
        value = value ?? nextValue()
    }
}

struct QuickLaunchFloatsView: View {
    let floats: QuickLaunchFloats?

    var body: some View {
        GeometryReader { proxy in
            if let floats {
                let frame = proxy[floats.anchor]
                switch floats.float {
                case let .name(text, point, belowIsland):
                    // The same label from icon to icon, as in the Dock: only its first showing comes in.
                    QuickLaunchName(text: text)
                        .position(x: frame.minX + point.x, y: belowIsland ? proxy.size.height + 13 : frame.minY + point.y + 7.5)
                case let .ghost(app, center, size, removing):
                    QuickLaunchGhost(app: app, size: size, removing: removing)
                        .position(x: frame.minX + center.x, y: frame.minY + center.y)
                case let .poof(app, center, size):
                    QuickLaunchPoof(app: app, size: size)
                        .position(x: frame.minX + center.x, y: frame.minY + center.y)
                }
            }
        }
        .environment(\.layoutDirection, .leftToRight)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct QuickLaunchName: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .frame(height: 15)
            .background(Color(white: 0.17), in: Capsule())
            .scaleEffect(shown || reduceMotion ? 1 : 0.94, anchor: .top)
            .opacity(shown ? 1 : 0)
            .onAppear { withAnimation(.easeOut(duration: 0.15)) { shown = true } }
    }
}

struct QuickLaunchGhost: View {
    static let lift: CGFloat = 1.12

    let app: String
    let size: CGFloat
    let removing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        AppIconView(bundleID: app, size: size)
            .shadow(color: .black.opacity(0.5), radius: 11, y: 10)
            .scaleEffect(reduceMotion ? 1 : Self.lift)
            .opacity(removing ? 0.65 : 1)
            .overlay(alignment: .bottom) {
                Text(String(localized: "Remove"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .frame(height: 16)
                    .background(.red, in: Capsule())
                    .fixedSize()
                    .offset(y: 23)
                    .opacity(removing ? 1 : 0)
            }
            .animation(.easeOut(duration: 0.12), value: removing)
    }
}

private struct QuickLaunchPoof: View {
    let app: String
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var gone = false

    var body: some View {
        AppIconView(bundleID: app, size: size)
            .scaleEffect(reduceMotion ? 1 : gone ? 1.35 : QuickLaunchGhost.lift)
            .opacity(gone ? 0 : 0.65)
            .onAppear { withAnimation(.easeOut(duration: 0.18)) { gone = true } }
    }
}
