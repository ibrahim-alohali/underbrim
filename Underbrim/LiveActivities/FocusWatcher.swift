//
//  FocusWatcher.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  A Focus turning on or off, on the notch: its symbol in its colour with "On", in grey with "Off".
//  macOS 27 has no API for it, so the banner MenuBarAgent draws ("focus-system-banner") is read
//  through Accessibility and moved off screen; the notch shows the change in its place.
//

import AppKit
import ApplicationServices
import Defaults
import SwiftUI

@MainActor
final class FocusWatcher {
    static let shared = FocusWatcher()

    private var observer: AXObserver?
    private var agent: pid_t = 0
    private var shown: (focus: FocusBanner, at: Date)?
    /// Whether a Focus is on, as the last banner said; nil until one was seen.
    private(set) var isOn: Bool?

    func start() {
        Defaults.whenChanged([.showFocusChanges]) { [weak self] in self?.apply() }
        NotificationCenter.default.addObserver(forName: .accessibilityAuthorizationChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply() }
        }
        // MenuBarAgent restarting gets a new observer.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == MenuBarActivityReader.agentBundleID else { return }
            MainActor.assumeIsolated {
                self?.detach()
                self?.apply()
            }
        }
        apply()
    }

    /// The banner it reads is macOS 27's (MenuBarAgent); before that there's nothing to read.
    nonisolated static var isSupported: Bool {
        if #available(macOS 27, *) { true } else { false }
    }

    private func apply() {
        if Self.isSupported, Defaults[.showFocusChanges], AXIsProcessTrusted() { attach() } else { detach() }
    }

    private func attach() {
        guard observer == nil,
              let pid = NSRunningApplication.runningApplications(withBundleIdentifier: MenuBarActivityReader.agentBundleID).first?.processIdentifier
        else { return }
        var created: AXObserver?
        let callback: AXObserverCallback = { _, element, _, refcon in
            guard let refcon else { return }
            let watcher = Unmanaged<FocusWatcher>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.windowCreated(element) }
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let created else { return }
        AXObserverAddNotification(created, AXUIElementCreateApplication(pid), kAXWindowCreatedNotification as CFString,
                                  Unmanaged.passUnretained(self).toOpaque())
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        observer = created
        agent = pid
    }

    private func detach() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
    }

    private func windowCreated(_ window: AXUIElement) {
        // The name may be the window's identifier or its title: either counts.
        guard Self.labels(of: window).contains(FocusBanner.identifier) else { return }
        // macOS's banner goes off screen at once (it reads the same there); not while the notch hides
        // for a full-screen app or no closed notch can show the flash, when macOS's is the only one.
        Log.general.info("Focus banner appeared")
        let home = window.point(kAXPositionAttribute)
        let hideAtFirst = !Self.notchHidden && StatusFlash.shared.canShow
        if hideAtFirst { window.setPoint(kAXPositionAttribute, Self.offScreen) }
        Task { [weak self] in
            let start = Date()
            var hide = hideAtFirst
            var last: FocusBanner?
            // Read until it goes: its parts fill in late, and a change made while it's up reuses the window.
            while window.exists, Date().timeIntervalSince(start) < 30 {
                guard let self else { return }
                if let focus = Self.read(window) {
                    if focus != last {
                        last = focus
                        self.flash(focus)
                    }
                    if hide, !StatusFlash.shared.canShow, let home {
                        // The island opened while it showed: macOS's banner comes back.
                        window.setPoint(kAXPositionAttribute, home)
                        hide = false
                    }
                    if hide { window.setPoint(kAXPositionAttribute, Self.offScreen) }  // in case it slid back in
                } else if hide, last == nil, Date().timeIntervalSince(start) > 0.6, let home {
                    // Unreadable: macOS's banner comes back rather than neither showing.
                    window.setPoint(kAXPositionAttribute, home)
                    hide = false
                }
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    private static let offScreen = CGPoint(x: -10_000, y: -10_000)

    private static var notchHidden: Bool {
        Defaults[.hideNotchOption] != .never
            && FullscreenMediaDetector.shared.fullscreenStatus[NotchViewCoordinator.shared.selectedScreenUUID] == true
    }

    private static func read(_ window: AXUIElement) -> FocusBanner? {
        var symbol: String?
        var texts: [String] = []
        collect(window, depth: 0, symbol: &symbol, texts: &texts)
        return FocusBanner.parse(symbol: symbol, texts: texts)
    }

    /// The change on the notch (once: two banners can say the same thing).
    private func flash(_ focus: FocusBanner) {
        isOn = focus.on
        guard shown.map({ $0.focus != focus || $0.at.timeIntervalSinceNow < -2 }) ?? true else { return }
        shown = (focus, Date())
        StatusFlash.shared.show(focus.flash)
        Log.general.info("Focus flash: \(focus.on ? "on" : "off", privacy: .public)")
    }

    /// The banner's picture (one of its labels is the symbol's name) and its text, in order.
    private static func collect(_ element: AXUIElement, depth: Int, symbol: inout String?, texts: inout [String]) {
        guard depth < 5 else { return }
        for child in (element[kAXChildrenAttribute] as? [AXUIElement]) ?? [] {
            switch child.string(kAXRoleAttribute) {
            case kAXImageRole: symbol = symbol ?? labels(of: child).first(where: FocusBanner.isSymbolName)
            case kAXStaticTextRole: labels(of: child).last.map { texts.append($0) }
            default: break
            }
            collect(child, depth: depth + 1, symbol: &symbol, texts: &texts)
        }
    }

    private static func labels(of element: AXUIElement) -> [String] {
        [kAXIdentifierAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute]
            .compactMap { element[$0] as? String }.filter { !$0.isEmpty }
    }
}

struct FocusBanner: Equatable {
    static let identifier = "focus-system-banner"

    /// The Focus's symbol as macOS names it ("rocket.fill"), when the banner says.
    let symbol: String?
    let name: String
    let state: String
    let on: Bool

    /// "On" and "Off" as the banner and Control Center word them, in every language. A table also
    /// holds non-language keys ("LocProvenance"), so each is read on its own.
    static let words: (on: Set<String>, off: Set<String>) = {
        var on: Set<String> = ["On"], off: Set<String> = ["Off"]
        for path in ["/System/Library/PrivateFrameworks/SystemBannerUI.framework/Resources/SystemBannerUI.loctable",
                     "/System/Library/CoreServices/ControlCenter.app/Contents/Resources/Focus.loctable"] {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let tables = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { continue }
            for table in tables.compactMapValues({ $0 as? [String: Any] }).values {
                (table["FOCUS_MODE_ON"] as? String).map { _ = on.insert($0) }
                (table["FOCUS_MODE_OFF"] as? String).map { _ = off.insert($0) }
            }
        }
        return (on, off)
    }()

    /// "rocket.fill", not "Rocket, Filled".
    static func isSymbolName(_ text: String) -> Bool {
        text.contains(".") && !text.contains(" ") && text.first?.isLowercase == true
    }

    static func parse(symbol: String?, texts: [String], words: (on: Set<String>, off: Set<String>) = words) -> FocusBanner? {
        guard let state = texts.last(where: { words.on.contains($0) || words.off.contains($0) }),
              let name = texts.first(where: { $0 != state && !$0.isEmpty }) else { return nil }
        return FocusBanner(symbol: symbol, name: name, state: state, on: words.on.contains(state))
    }

    /// macOS's own symbol when other apps may draw it; some built-in Focuses use private ones.
    var displaySymbol: String {
        if let symbol, NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil { return symbol }
        switch symbol {
        case "rocket.fill"?: return "gamecontroller.fill"
        case "person.lanyardcard.fill"?: return "briefcase.fill"
        default: return "moon.fill"
        }
    }

    /// The built-in Focuses' colours; one of your own gets blue.
    var tint: Color {
        switch symbol {
        case "moon.fill"?: .indigo
        case "bed.double.fill"?: .teal
        case "person.fill"?: .purple
        case "person.lanyardcard.fill"?: .cyan
        case "car.fill"?, "book.fill"?: .orange
        case "figure.run"?: .green
        case "apple.meditate"?, "figure.mind.and.body"?: .mint
        default: .blue
        }
    }

    /// The app's own short On and Off (macOS's "Desactivado" wouldn't fit); VoiceOver says macOS's.
    var flash: StatusFlash.Flash {
        .init(symbol: displaySymbol, label: on ? String(localized: "On") : String(localized: "Off"),
              tint: on ? tint : .white.opacity(0.45), spoken: String(localized: "\(name) Focus \(state)"))
    }
}
