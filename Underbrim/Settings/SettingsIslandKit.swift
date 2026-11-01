//
//  SettingsIslandKit.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The parts the Settings islands are made of: text, rows, switches, menus, scrolling over them,
//  and keeping the window still under a drag.
//

import AppKit
import SwiftUI

// MARK: - Pieces

extension View {
    func islandText(lit: Bool = false, dim: Bool = false) -> some View {
        font(.system(size: 12, weight: .semibold))
            .foregroundStyle(lit ? Color.notchAccent : .white.opacity(dim ? 0.6 : 1))
            .lineLimit(1)
    }
}

struct IslandGlyph: View {
    let symbol: String
    var lit = false
    var dim = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(lit ? Color.notchAccent : .white.opacity(dim ? 0.45 : 0.88))
            .accessibilityHidden(true)
    }
}

struct IslandRow: View {
    let symbol: String
    var lit = false
    let title: String
    var value: String?
    var valueLit = true
    var dim = false

    var body: some View {
        HStack(spacing: 7) {
            IslandGlyph(symbol: symbol, lit: lit, dim: dim)
            Text(title).islandText(dim: dim)
            Spacer(minLength: 8)
            if let value {
                Text(value).islandText(lit: valueLit, dim: !valueLit).monospacedDigit()
            }
        }
        // Dim, it only names the feature that's off.
        .islandShown(dim ? nil : title, dim ? nil : value)
    }
}

/// What an island shows, in words, for the switch around it: the switch's name is what VoiceOver
/// reads as its label, so this goes with its value.
private struct IslandShownKey: PreferenceKey {
    static let defaultValue: [String] = []
    static func reduce(value: inout [String], nextValue: () -> [String]) { value += nextValue() }
}

extension View {
    /// The words shown here, for VoiceOver on the island's switch (`IslandRow` gives its own).
    func islandShown(_ words: String?...) -> some View {
        preference(key: IslandShownKey.self, value: words.compactMap { $0 })
    }
}

// MARK: - Controls

func islandHelp(_ lines: String?...) -> String { lines.compactMap { $0 }.joined(separator: "\n") }

private let turnOff = String(localized: "Click to turn off")
private let turnOn = String(localized: "Click to turn on")

/// The soft highlight under the pointer, drawn around the part so its content doesn't move. `pad`
/// reaches past the part (negative) or stays inside it (positive, for a part as tall as the island).
struct IslandHighlight: ViewModifier {
    var pressed = false
    var pad = EdgeInsets(top: -4, leading: -4, bottom: -4, trailing: -4)
    var radius: CGFloat = 7
    /// Lights under the pointer too (not for a part whose button already does).
    var hovers = true
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.white.opacity(!enabled ? 0 : pressed ? 0.22 : hovering && hovers ? 0.13 : 0))
                    .padding(pad)
                    .animation(.easeOut(duration: 0.12), value: hovering)
            }
            .onHover { hovering = $0 }
    }
}

struct IslandButtonStyle: ButtonStyle {
    /// As tall as the island: the highlight stays inside it, reaching into the side margins.
    var whole = false
    var radius: CGFloat = 7
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(IslandHighlight(
            pressed: configuration.isPressed || active,
            pad: whole ? EdgeInsets(top: 5, leading: -8, bottom: 5, trailing: -8) : EdgeInsets(top: -4, leading: -4, bottom: -4, trailing: -4),
            radius: radius))
    }
}

struct IslandSwitch<Label: View>: View {
    let name: String
    @Binding var isOn: Bool
    var whole = true
    var note: String?
    var help: String?
    @ViewBuilder let label: Label
    @State private var shown: [String] = []

    var body: some View {
        Button { isOn.toggle() } label: {
            label
                .frame(maxWidth: whole ? .infinity : nil, maxHeight: whole ? .infinity : nil)
                .contentShape(Rectangle())
        }
        .buttonStyle(IslandButtonStyle(whole: whole))
        .help(help ?? islandHelp(name, isOn ? turnOff : turnOn, note))
        .onPreferenceChange(IslandShownKey.self) { shown = $0 }
        .accessibilityLabel(name)
        .accessibilityValue(spokenValue)
        .accessibilityAddTraits(.isToggle)
    }

    /// On or off, then what it shows; not the switch's own name again, nor a page's, which the window says.
    private var spokenValue: String {
        let pages = Set(SettingsTab.allCases.map(\.title))
        let words = shown.filter { $0 != name && !pages.contains($0) }
        return ([isOn ? String(localized: "On") : String(localized: "Off")] + words).joined(separator: ", ")
    }
}

/// A menu opened under the part clicked (`frame`, in its window's SwiftUI coordinates), as a pop-up button's.
@MainActor
final class IslandMenu: NSObject {
    private let menu = NSMenu()
    private var actions: [() -> Void] = []

    override init() {
        super.init()
        menu.autoenablesItems = false
    }

    func add(_ title: String, checked: Bool = false, enabled: Bool = true, help: String? = nil, _ action: @escaping () -> Void) {
        let item = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: "")
        item.target = self
        item.tag = actions.count
        item.state = checked ? .on : .off
        item.isEnabled = enabled
        item.toolTip = help
        actions.append(action)
        menu.addItem(item)
    }

    func separator() { menu.addItem(.separator()) }

    @objc private func run(_ item: NSMenuItem) { actions[item.tag]() }

    func show(under frame: CGRect, rightToLeft: Bool) {
        // Settings' own window: a press can come while another is key (VoiceOver's, say).
        guard let view = SettingsWindowController.shared.window?.contentView else { return }
        menu.userInterfaceLayoutDirection = rightToLeft ? .rightToLeft : .leftToRight
        let x = rightToLeft ? frame.maxX : frame.minX
        let y = view.isFlipped ? frame.maxY + 6 : view.bounds.height - frame.maxY - 6
        _ = menu.popUp(positioning: nil, at: NSPoint(x: x, y: y), in: view)  // returns once it's closed
    }
}

extension View {
    /// The view's frame in the Settings window, for a menu shown under it (`show(under:rightToLeft:)`).
    func settingsIslandFrame(_ frame: Binding<CGRect>) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame.wrappedValue = $0 }
    }
}

/// Keeps the window still while the pointer is over a drag: in the title bar's band macOS moves the
/// window as the button goes down, before the drag reaches the island. Counted, since the pointer can
/// enter one part before leaving the one beside it.
@MainActor
private enum WindowHold {
    private static var holders = 0
    private static var held = false

    static func hold(_ on: Bool) {
        guard let window = SettingsWindowController.shared.window else { return }
        holders += on ? 1 : -1
        if on, holders == 1, window.isMovable {
            window.isMovable = false
            held = true
        } else if holders == 0, held {
            window.isMovable = true
            held = false
        }
    }
}

private struct HoldsWindow: ViewModifier {
    @State private var holding = false

    func body(content: Content) -> some View {
        content
            .onHover { hold($0) }
            .onDisappear { hold(false) }
    }

    private func hold(_ on: Bool) {
        guard on != holding else { return }
        holding = on
        WindowHold.hold(on)
    }
}

extension View {
    func holdsSettingsWindow() -> some View { modifier(HoldsWindow()) }
}

/// Scrolls over the view, taken from the page under it. `amount` is positive for up or right, as on
/// the notch's sliders; `precise` for trackpad points, else wheel notches. Momentum doesn't count.
private struct IslandScroll: ViewModifier {
    let scrolled: (_ amount: CGFloat, _ precise: Bool) -> Void
    @State private var watch = ScrollWatch()

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                watch.scrolled = scrolled
                inside ? watch.start() : watch.stop()
            }
            .onDisappear { watch.stop() }
    }

    @MainActor final class ScrollWatch {
        var scrolled: (CGFloat, Bool) -> Void = { _, _ in }
        private var monitor: Any?

        func start() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                let taken = MainActor.assumeIsolated { () -> Bool in
                    // Only Settings' (a window opening over the island leaves the pointer "in" it).
                    guard let self, event.window === SettingsWindowController.shared.window else { return false }
                    guard event.momentumPhase.isEmpty else { return true }
                    let natural: CGFloat = event.isDirectionInvertedFromDevice ? -1 : 1
                    let up = event.scrollingDeltaY * natural, toward = -event.scrollingDeltaX * natural
                    let amount = abs(up) >= abs(toward) ? up : toward
                    if amount != 0 { self.scrolled(amount, event.hasPreciseScrollingDeltas) }
                    return true
                }
                return taken ? nil : event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

extension View {
    func islandScroll(_ scrolled: @escaping (_ amount: CGFloat, _ precise: Bool) -> Void) -> some View {
        modifier(IslandScroll(scrolled: scrolled))
    }

    func islandScrollSteps(_ carry: Binding<CGFloat>, _ step: @escaping (Int) -> Void) -> some View {
        islandScroll { amount, precise in
            guard precise else { return step(amount > 0 ? 1 : -1) }
            carry.wrappedValue += amount
            let steps = Int(carry.wrappedValue / 14)
            guard steps != 0 else { return }
            carry.wrappedValue -= CGFloat(steps) * 14
            step(steps)
        }
    }
}
