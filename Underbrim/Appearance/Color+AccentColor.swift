//
//  Color+AccentColor.swift
//  Underbrim
//
//  Created by Alexander on 2025-10-24.
//

import Defaults
import SwiftUI

/// Whose accent: Underbrim's own (the warm glow of its icon), macOS's, or a colour the user picks.
enum AccentStyle: String, CaseIterable, Defaults.Serializable {
    case underbrim, system, custom

    /// From the two-style setting: Custom stays Custom, everyone else gets Underbrim's own.
    static func migrated(custom: Bool) -> AccentStyle { custom ? .custom : .underbrim }
}

/// The accent, as chosen; observed, so every view that reads it repaints when it changes.
@MainActor
@Observable
final class AccentColor {
    static let shared = AccentColor()

    private(set) var color = Color.accentColor
    /// For accent text and symbols on Settings' pages, and its menus and buttons (`readableText`).
    private(set) var text = Color.accentColor
    /// For a fill under white text in Settings: Underbrim's deep amber (white reads only 2.4:1 on the
    /// usual fill); System and Custom deepened where white wouldn't read (`readableUnderWhite`).
    private(set) var underText = Color.accentColor
    /// For the black notch: the same, lifted where it would be too dark to read.
    private(set) var onBlack = Color.accentColor
    private(set) var onAccent = Color.white

    private init() {
        update()
        Defaults.whenChanged([.accentStyle, .customAccentColorData]) { [weak self] in self?.update() }
        // macOS's own accent, changed in System Settings while Underbrim runs.
        NotificationCenter.default.addObserver(forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
    }

    private func update() {
        let style = Defaults[.accentStyle]
        let custom = style == .custom ? Self.saved : nil
        color = style == .underbrim ? Color(nsColor: .underbrimSettings) : custom.map(Color.init(nsColor:)) ?? .accentColor
        let chosen = custom ?? .controlAccentColor
        text = Color(nsColor: style == .underbrim ? .underbrimText : Self.readableText(chosen))
        underText = Color(nsColor: style == .underbrim ? .underbrimDeep : Self.readableUnderWhite(chosen))
        let readable = Self.onBlack(style == .underbrim ? .underbrimGlow : custom ?? .controlAccentColor)
        onBlack = Color(nsColor: readable)
        onAccent = readable.relativeLuminance > 0.4 ? .black : .white
    }

    /// A colour as the always-dark notch shows it (Dark Mode), lifted where it would be too dark to read.
    static func onBlack(_ color: NSColor) -> NSColor {
        var accent = color
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            accent = accent.usingColorSpace(.sRGB) ?? accent
        }
        return accent.readableOnBlack
    }

    /// A chosen accent as text on Settings' page: lightened or deepened in tenths until it reads (4.5:1).
    static func readableText(_ color: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            var accent = color, page = NSColor(SettingsPalette.page)
            appearance.performAsCurrentDrawingAppearance {
                accent = accent.usingColorSpace(.sRGB) ?? accent
                page = page.usingColorSpace(.sRGB) ?? page
            }
            return accent.mixed(toward: appearance.isDark ? .white : .black, until: 4.5, against: page)
        }
    }

    static func readableUnderWhite(_ color: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            var accent = color
            appearance.performAsCurrentDrawingAppearance { accent = accent.usingColorSpace(.sRGB) ?? accent }
            return accent.mixed(toward: .black, until: 4.5, against: .white)
        }
    }

    /// The saved custom colour, whichever accent is in use (Custom starts on it).
    static var saved: NSColor? {
        guard let data = Defaults[.customAccentColorData] else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data)
    }
}

extension NSColor {
    /// Brimlight amber, the light under the icon's brim: the accent on the black notch (11.9:1, black text on it).
    static let underbrimGlow = NSColor(srgbRed: 1, green: 0xB4 / 255, blue: 0x43 / 255, alpha: 1)
    static let underbrimSettings = NSColor(srgbRed: 0xE8 / 255, green: 0x96 / 255, blue: 0x1C / 255, alpha: 1)
    /// A deep amber: text on Settings' light page (5.1:1) and under white text (5.6:1).
    static let underbrimDeep = NSColor(srgbRed: 0x9A / 255, green: 0x58 / 255, blue: 0, alpha: 1)
    static let underbrimText = NSColor(name: nil) { $0.isDark ? .underbrimGlow : .underbrimDeep }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

extension Color {
    @MainActor static var effectiveAccent: Color { AccentColor.shared.color }
    @MainActor static var accentText: Color { AccentColor.shared.text }
    @MainActor static var accentUnderText: Color { AccentColor.shared.underText }
    @MainActor static var notchAccent: Color { AccentColor.shared.onBlack }
    @MainActor static var onNotchAccent: Color { AccentColor.shared.onAccent }
}

extension NSColor {
    var readableOnBlack: NSColor { mixed(toward: .white, until: 4.5, against: .black) }

    /// Mixed toward `target` in tenths until it stands `ratio` apart from `other` (unchanged if it does).
    func mixed(toward target: NSColor, until ratio: CGFloat, against other: NSColor) -> NSColor {
        var mixed = self
        var step = 0
        while mixed.contrast(with: other) < ratio, step < 10 {
            step += 1
            mixed = blended(withFraction: CGFloat(step) / 10, of: target) ?? mixed
        }
        return mixed
    }

    func contrast(with other: NSColor) -> CGFloat {
        let (x, y) = (relativeLuminance, other.relativeLuminance)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    var relativeLuminance: CGFloat {
        guard let rgb = usingColorSpace(.sRGB) else { return 1 }
        func linear(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
    }
}
