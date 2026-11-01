//
//  FloatingIsland.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The island on a display without a notch: a capsule floating just below the top edge, inside the
//  menu bar, drawn only while something shows; idle, pointing at the top centre still opens it. A
//  notched display grows the island from its camera cutout instead, and "Notch" keeps upstream's tab.
//  On a Mac with Apple's own Dynamic Island, Underbrim steps aside: nothing closed over Apple's
//  island, and the open island floats below the menu bar.
//

import AppKit
import Defaults

/// How the island sits on a display without a notch.
enum NonNotchStyle: String, CaseIterable, Identifiable, Defaults.Serializable {
    case island, notch

    var id: String { rawValue }
}

extension Defaults.Keys {
    /// Island for new installs; an existing install keeps Notch (DefaultsHistory).
    static let nonNotchStyle = Key<NonNotchStyle>("personal_nonNotchStyle", default: .island)
    /// A display without a notch has been seen: Settings offers the style from then on.
    static let seenDisplayWithoutNotch = Key<Bool>("personal_seenDisplayWithoutNotch", default: false)
}

/// Where the floating island sits on one display, and how big its closed capsule is.
struct FloatingIsland: Equatable {
    /// From the screen's top edge to the island, and from the closed capsule to the menu bar's foot.
    static let gap: CGFloat = 3
    /// Idle, pointing here opens it: as wide as the tab it replaces, the menu bar's full height.
    static let hoverWidth: CGFloat = 185
    /// Between an activity's two sides in the closed capsule, where the camera would be.
    static let middle: CGFloat = 44
    /// A title in the closed capsule's middle (a song, an agent's state): with a side each, as wide as the idle hover area.
    static let titleWidth: CGFloat = 124
    /// Between the capsule's round ends and what's beside them.
    static let edge: CGFloat = 5

    /// The menu bar's height on this display.
    let menuBar: CGFloat
    /// Apple's own island is on this display: below the menu bar, never closed over it.
    var besideAppleIsland = false

    var capsuleHeight: CGFloat { max(16, menuBar - 2 * Self.gap) }
    /// From the screen's top edge to the island's.
    var top: CGFloat { besideAppleIsland ? menuBar + Self.gap : Self.gap }

    /// The display's floating island; nil where the island grows from a notch, or the tab is chosen.
    @MainActor static func on(_ screen: NSScreen?) -> FloatingIsland? {
        guard let screen else { return nil }
        if AppleIsland.isOn(screen) { return FloatingIsland(menuBar: menuBarHeight(of: screen), besideAppleIsland: true) }
        guard screen.safeAreaInsets.top <= 0, Defaults[.nonNotchStyle] == .island else { return nil }
        return FloatingIsland(menuBar: menuBarHeight(of: screen))
    }

    private struct Measured {
        let frame: CGRect
        let visible: CGRect
        let height: CGFloat
    }

    @MainActor private static var measured: [CGDirectDisplayID: Measured] = [:]

    /// What macOS reports (the visible frame); where it reports none, the menu bar it draws there (the
    /// window server's own window); else macOS 26's height for displays without a notch. Kept until
    /// the display's frame or visible frame changes.
    @MainActor static func menuBarHeight(of screen: NSScreen) -> CGFloat {
        guard let id = screen.cgDisplayID else { return 30 }
        if let known = measured[id], known.frame == screen.frame, known.visible == screen.visibleFrame { return known.height }
        let reported = screen.frame.maxY - screen.visibleFrame.maxY
        let height = reported > 0 ? reported : drawnMenuBarHeight(on: id) ?? 30
        measured[id] = Measured(frame: screen.frame, visible: screen.visibleFrame, height: height)
        return height
    }

    /// The menu bar window at the display's top edge, full width (no permission needed for its frame).
    private static func drawnMenuBarHeight(on display: CGDirectDisplayID) -> CGFloat? {
        let bounds = CGDisplayBounds(display)
        let level = Int(CGWindowLevelForKey(.mainMenuWindow))
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return nil }
        return windows.lazy.compactMap { info -> CGFloat? in
            guard info[kCGWindowLayer as String] as? Int == level,
                  let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: dictionary),
                  abs(frame.minY - bounds.minY) < 1, abs(frame.minX - bounds.minX) < 1, abs(frame.width - bounds.width) < 1,
                  frame.height > 10, frame.height < 80 else { return nil }
            return frame.height
        }.first
    }
}

/// Underbrim is beside Apple's island on every display it shows on: nothing at the top of the screen
/// opens it, so the menu bar icon offers to, and the HUD leaves the volume and brightness keys to macOS.
@MainActor final class SteppingAside: ObservableObject {
    static let shared = SteppingAside()
    @Published private(set) var everywhere = false

    func update(_ islands: [NotchViewModel]) {
        let now = !islands.isEmpty && islands.allSatisfy { $0.floating?.besideAppleIsland == true }
        if now != everywhere { everywhere = now }
    }
}

/// Apple's Dynamic Island on a MacBook Pro with a PROLED XDR display: known by its model identifier,
/// or by a system window at the top centre of the built-in display, narrower than a third of it.
/// Nobody here has that Mac, so this is unverified there.
enum AppleIsland {
    /// Apple hasn't listed this MacBook Pro's model identifiers yet; until then the window check decides.
    private static let models: Set<String> = []

    private static let model: String = {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &bytes, &size, nil, 0)
        return String(cString: bytes)
    }()

    /// By display, until the displays change (`forget`): not looked for at every close, so it can't
    /// change while the island is in use.
    @MainActor private static var known: [CGDirectDisplayID: Bool] = [:]

    @MainActor static func isOn(_ screen: NSScreen) -> Bool {
        guard let id = screen.cgDisplayID, CGDisplayIsBuiltin(id) != 0 else { return false }
        #if DEBUG
        // To check stepping aside on a Mac without Apple's island.
        if ProcessInfo.processInfo.environment["UNDERBRIM_SIMULATE_APPLE_ISLAND"] == "1" { return true }
        #endif
        if let on = known[id] { return on }
        let on = models.contains(model) || islandWindow(on: id)
        known[id] = on
        return on
    }

    @MainActor static func forget() { known = [:] }

    private static func islandWindow(on display: CGDirectDisplayID) -> Bool {
        let bounds = CGDisplayBounds(display)
        let me = ProcessInfo.processInfo.processIdentifier
        let level = Int(CGWindowLevelForKey(.mainMenuWindow))
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return false }
        return windows.contains { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let layer = info[kCGWindowLayer as String] as? Int, layer >= level,
                  let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: dictionary),
                  abs(frame.minY - bounds.minY) < 1, abs(frame.midX - bounds.midX) < 4,
                  frame.width > 60, frame.width < bounds.width / 3, frame.height < 80 else { return false }
            // Apple's own, not another app's notch.
            return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier.map { $0.hasPrefix("com.apple.") } ?? true
        }
    }
}
