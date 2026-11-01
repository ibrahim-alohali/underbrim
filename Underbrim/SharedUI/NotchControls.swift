//
//  NotchControls.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The open notch's small buttons. No fills: they brighten on hover, so the
//  rows stay the only filled things inside the notch.
//

import SwiftUI

/// A symbol-only button (a symbol, or one of the app's own glyphs); `label` is its tooltip and VoiceOver name.
struct NotchSymbolButton<Glyph: View>: View {
    let label: String
    var box: CGFloat = 26
    /// A state's colour (the pin while it's on); otherwise white, brighter on hover.
    var tint: Color?
    /// Set in the header and on cards: the name shows by the button (HoverName) instead of as a tooltip.
    var nameEdge: HorizontalAlignment?
    /// The name above the button, for one at the bottom of a card.
    var nameAbove = false
    let action: () -> Void
    @ViewBuilder let glyph: Glyph
    @State private var hovering = false

    var body: some View {
        Button {
            NotificationCenter.default.post(name: .closeIslandPopovers, object: nil)
            action()
        } label: {
            glyph
                .frame(width: box, height: box)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint ?? .white.opacity(hovering ? 1 : 0.6))
        .onHover { hovering = $0 }
        .notchName(label, edge: nameEdge, above: nameAbove)
        .accessibilityLabel(label)
    }
}

extension NotchSymbolButton where Glyph == NotchSymbol {
    init(symbol: String, label: String, size: CGFloat = 13, box: CGFloat = 26, tint: Color? = nil,
         nameEdge: HorizontalAlignment? = nil, nameAbove: Bool = false, action: @escaping () -> Void) {
        self.init(label: label, box: box, tint: tint, nameEdge: nameEdge, nameAbove: nameAbove, action: action) {
            NotchSymbol(name: symbol, size: size)
        }
    }
}

/// An icon's name under it after a moment's hover, drawn in the island: macOS doesn't show the island's
/// tooltips while another app is active, so the header's icon-only buttons say what they are themselves.
struct HoverName: ViewModifier {
    let name: String
    /// The edge it lines up with, the one nearer the island's side, so a long name stays inside.
    var edge: HorizontalAlignment = .leading
    var above = false
    @State private var shown = false
    @State private var wait: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                wait?.cancel()
                guard inside else { return withAnimation(.easeOut(duration: 0.1)) { shown = false } }
                wait = Task {
                    try? await Task.sleep(for: .seconds(0.5))
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.15)) { shown = true }
                }
            }
            .onDisappear { wait?.cancel(); shown = false }
            .overlay(alignment: Alignment(horizontal: edge, vertical: .top)) {
                if shown {
                    Text(name)
                        .font(.notchCaption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 7)
                        .frame(height: 20)
                        .background(.black, in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.18)))
                        // Just under a 26-point button, or just over the button.
                        .offset(y: above ? -24 : 30)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .transition(.opacity)
                }
            }
    }
}

extension View {
    /// The island's own hover name lined up with `edge`, or else macOS's tooltip.
    @ViewBuilder func notchName(_ name: String, edge: HorizontalAlignment?, above: Bool = false) -> some View {
        if let edge { modifier(HoverName(name: name, edge: edge, above: above)) } else { help(name) }
    }
}

struct NotchSymbol: View {
    let name: String
    var size: CGFloat = 13

    var body: some View {
        Image(systemName: name)
            .font(.notchSymbol(size: size))
            // Symbol replace, not a cross-fade, which leaves a ghost behind while the button moves.
            .contentTransition(.symbolEffect(.replace))
    }
}

extension View {
    /// The island's look for a control that can't act now: 35% and disabled (plain buttons don't show it).
    func notchDisabled(_ disabled: Bool) -> some View {
        self.disabled(disabled).opacity(disabled ? 0.35 : 1)
    }
}

struct NotchTextButton: View {
    let title: String
    /// A longer explanation, for the tooltip and the VoiceOver hint.
    var help: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        // A 20 pt tall target, brighter than secondary text so it reads as a button.
        Button(action: action) {
            Text(title).frame(minHeight: 20).contentShape(Rectangle())
        }
            .buttonStyle(.plain)
            .font(.notchCaption)
            .foregroundStyle(.white.opacity(hovering ? 1 : 0.8))
            .onHover { hovering = $0 }
            .help(help ?? title)
            .accessibilityHint(help ?? "")
    }
}

/// The notch's main action, in the accent. Not `.borderedProminent`: AppKit greys that style out
/// in a window that isn't key, which the notch's rarely is.
struct NotchProminentStyle: ButtonStyle {
    /// 24 pt in the header, which is 24 pt tall on a display without a notch.
    var height: CGFloat = 28

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.onNotchAccent)
            .padding(.horizontal, height < 28 ? 12 : 18)
            .frame(height: height)
            .background(Color.notchAccent.opacity(configuration.isPressed ? 0.8 : 1), in: Capsule())
            .contentShape(Capsule())
    }
}
