//
//  AppearanceIsland.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The Settings islands on Appearance (the accent) and Advanced (the notch's animation).
//

import Defaults
import SwiftUI

struct AppearanceIsland: View {
    @Default(.accentStyle) private var accent
    @Default(.customAccentColorData) private var custom

    var body: some View {
        let _ = custom
        HStack(spacing: 3) {
            ForEach(AccentStyle.allCases, id: \.self) { style in
                Button { accent = style } label: {
                    Circle()
                        .fill(style.swatch)
                        .frame(width: 12, height: 12)
                        .padding(3.5)
                        .overlay { if style == accent { Circle().strokeBorder(Color.notchAccent, lineWidth: 1.5) } }
                        .padding(2)
                        .contentShape(Circle())
                }
                .buttonStyle(IslandButtonStyle(radius: 12))
                .help(islandHelp(String(localized: "Accent color"), style.title))
                .accessibilityLabel(String(localized: "Accent color"))
                .accessibilityValue(style.title)
                .accessibilityAddTraits(style == accent ? .isSelected : [])
            }
        }
    }
}

struct AnimationIsland: View {
    @Default(.enableOpeningAnimation) private var animates
    @Default(.animationSpeedMultiplier) private var speed
    @State private var open = false
    @State private var showing: Task<Void, Never>?

    var body: some View {
        let name = String(localized: "Notch animation")
        if animates {
            ZStack {
                IslandSwitch(name: name, isOn: $animates, whole: false) { outline }
                    .frame(maxHeight: .infinity, alignment: .top)
                AnimationSpeed()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.bottom, 10)
            }
            .onChange(of: speed) { show() }
            // Turned off or left mid-demo: the outline shows closed.
            .onDisappear { showing?.cancel(); open = false }
        } else {
            IslandSwitch(name: name, isOn: $animates) {
                ZStack {
                    outline.frame(maxHeight: .infinity, alignment: .top)
                    Text(name).islandText(dim: true)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(.bottom, 10)
                }
            }
        }
    }

    private var outline: some View {
        let shape = IslandShape(topRadius: 0, bottomRadius: open ? 11 : 6)
        return shape
            .fill(.white.opacity(animates ? 0.16 : 0.08))
            .overlay { shape.stroke(.white.opacity(animates ? 0.35 : 0.18), lineWidth: 1) }
            .frame(width: open ? 168 : 84, height: open ? 32 : 14)
            .frame(width: 168, height: 32, alignment: .top)
    }

    private func show() {
        showing?.cancel()
        showing = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            withAnimation(StandardAnimations.open) { open = true }
            try? await Task.sleep(for: .seconds(0.45 / speed + 0.5))
            guard !Task.isCancelled else { return }
            withAnimation(StandardAnimations.close) { open = false }
        }
    }
}

private struct AnimationSpeed: View {
    @Default(.animationSpeedMultiplier) private var speed
    @State private var hovering = false
    @State private var dragFrom: Double?
    @State private var carry: CGFloat = 0
    @Environment(\.layoutDirection) private var direction

    private var value: Text {
        Text("\(speed, format: .number.precision(.fractionLength(1)))x", comment: "Animation speed multiplier.")
    }

    var body: some View {
        HStack(spacing: 6) {
            Text("Animation speed").islandText()
            HStack(spacing: 3) {
                Image(systemName: "chevron.backward").opacity(hovering || dragFrom != nil ? 0.6 : 0)
                value
                    .islandText(lit: true)
                    .monospacedDigit()
                Image(systemName: "chevron.forward").opacity(hovering || dragFrom != nil ? 0.6 : 0)
            }
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.white)
        }
        .contentShape(Rectangle())
        .modifier(IslandHighlight(pressed: dragFrom != nil))
        .onHover { hovering = $0 }
        .holdsSettingsWindow()
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { drag in
                    let from = dragFrom ?? speed
                    dragFrom = from
                    let toward = direction == .rightToLeft ? -drag.translation.width : drag.translation.width
                    set(from + Double(Int(toward / 14)) / 10)
                }
                .onEnded { _ in dragFrom = nil }
        )
        .islandScrollSteps($carry) { set(speed + Double($0) / 10) }
        .focusable(interactions: .activate)
        .onMoveCommand { move in
            switch move {
            case .up, .right: set(speed + (direction == .rightToLeft && move == .right ? -0.1 : 0.1))
            case .down, .left: set(speed - (direction == .rightToLeft && move == .left ? -0.1 : 0.1))
            default: break
            }
        }
        .help(islandHelp(String(localized: "Animation speed"), String(localized: "Drag or scroll to change")))
        // A drag is nothing to VoiceOver: a slider stands in for it, as the page's.
        .accessibilityRepresentation {
            Slider(value: Binding(get: { speed }, set: { set($0) }), in: 0.1...2, step: 0.1)
        }
        .accessibilityLabel(String(localized: "Animation speed"))
        .accessibilityValue(value)
    }

    private func set(_ new: Double) {
        let new = min(max((new * 10).rounded() / 10, 0.1), 2)
        if new != speed { speed = new }
    }
}
