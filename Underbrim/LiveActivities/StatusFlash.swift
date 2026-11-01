//
//  StatusFlash.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  A moment's word on the closed notch, as the Dynamic Island shows a switch flipped: a symbol and
//  "On" or "Off" for two seconds (Focus, Caps Lock, unlocking). An interruption, not an activity.
//

import AppKit
import Defaults
import Observation
import SwiftUI

@MainActor
@Observable
final class StatusFlash {
    static let shared = StatusFlash()

    struct Flash: Identifiable, Equatable, Sendable {
        let id = UUID()
        let symbol: String
        /// Shown first and replaced by `symbol` (a padlock opening).
        var from: String?
        var label: String?
        var tint: Color
        var spoken: String
    }

    private(set) var current: Flash?
    /// When `current` began: a padlock opens once, at its time, however often its view is drawn.
    private(set) var shownAt = Date.distantPast
    @ObservationIgnored private var hide: Task<Void, Never>?
    /// Islands whose closed notch can show a flash now; Focus moves macOS's banner away only while one can.
    @ObservationIgnored private var showable: Set<ObjectIdentifier> = []
    var canShow: Bool { !showable.isEmpty }

    func setShowable(_ can: Bool, for island: AnyObject) {
        if can { showable.insert(ObjectIdentifier(island)) } else { showable.remove(ObjectIdentifier(island)) }
    }

    func show(_ flash: Flash, for duration: TimeInterval = 2) {
        current = flash
        shownAt = Date()
        AccessibilityNotification.Announcement(flash.spoken).post()
        hide?.cancel()
        hide = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.current = nil
        }
    }
}

struct FlashLiveActivity: View {
    @EnvironmentObject private var vm: NotchViewModel
    let flash: StatusFlash.Flash
    var since = Date.distantPast
    @State private var changed: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let change: TimeInterval = 0.35

    /// `from` until the change is due, then `symbol`: a view drawn again (a new
    /// branch at unlock, a window moving off the lock screen) never replays it.
    static func symbol(of flash: StatusFlash.Flash, since: Date, now: Date) -> String {
        guard let from = flash.from, now.timeIntervalSince(since) < change else { return flash.symbol }
        return from
    }

    private var itemSize: CGFloat { vm.closedItemSize }

    var body: some View {
        HStack {
            // Larger and bolder than an activity's symbol and label on purpose: a flash interrupts, as the
            // volume display does.
            Image(systemName: changed == since ? flash.symbol : Self.symbol(of: flash, since: since, now: Date()))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(flash.tint)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: itemSize, height: itemSize)
            Rectangle()
                .fill(.black)
                .frame(width: vm.closedMiddleWidth)
            Text(flash.label ?? "")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(flash.tint)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(width: itemSize + TimerLiveActivity.extraWidth, height: itemSize)
        }
        .frame(height: vm.effectiveClosedNotchHeight)
        .accessibilityHidden(true)  // announced when it appears
        .task(id: since) {
            let wait = Self.change - Date().timeIntervalSince(since)
            guard flash.from != nil, wait > 0 else { return }
            try? await Task.sleep(for: .seconds(wait))
            withAnimation(reduceMotion ? nil : .snappy) { changed = since }
        }
    }
}

/// Unlocking and Caps Lock turning on or off.
@MainActor
final class SystemTouches {
    static let shared = SystemTouches()

    private var capsMonitors: [Any] = []

    static let unlocked = StatusFlash.Flash(symbol: "lock.open.fill", from: "lock.fill", tint: .white,
                                            spoken: String(localized: "Unlocked"))
    static let locked = StatusFlash.Flash(symbol: "lock.fill", tint: .white, spoken: String(localized: "Locked"))

    func start() {
        Defaults.whenChanged([.showCapsLock]) { [weak self] in self?.apply() }
        NotificationCenter.default.addObserver(forName: .accessibilityAuthorizationChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply() }
        }
        apply()
    }

    private func apply() {
        // Key events from other apps reach a global monitor only with Accessibility.
        let caps = Defaults[.showCapsLock] && AXIsProcessTrusted()
        if caps, capsMonitors.isEmpty {
            // The Caps Lock key itself (57), in other apps and in Underbrim's own windows.
            let pressed: (NSEvent) -> Void = { event in
                guard event.keyCode == 57 else { return }
                let on = event.modifierFlags.contains(.capsLock)
                MainActor.assumeIsolated { StatusFlash.shared.show(Self.capsFlash(on: on), for: 1.5) }
            }
            capsMonitors = [NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: pressed),
                            NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { pressed($0); return $0 }].compactMap { $0 }
        } else if !caps {
            capsMonitors.forEach(NSEvent.removeMonitor)
            capsMonitors = []
        }
    }

    static func capsFlash(on: Bool) -> StatusFlash.Flash {
        .init(symbol: "capslock.fill", label: on ? String(localized: "On") : String(localized: "Off"),
              tint: on ? .white : .white.opacity(0.45),
              spoken: on ? String(localized: "Caps Lock on") : String(localized: "Caps Lock off"))
    }
}
