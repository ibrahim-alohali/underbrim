//
//  ScreenWatch.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Whether something is capturing the screen (a call's share, a recording, mirroring): SkyLight's
//  screen-watcher flag. macOS doesn't announce it, so it's read twice a second, only while the notch
//  hides during shares.
//

import AppKit
import Defaults

@MainActor
final class ScreenWatch {
    static let shared = ScreenWatch()
    static let changed = Notification.Name("ScreenWatchChanged")

    /// While the notch hides during shares: whether the screen is being captured.
    private(set) var captured = false
    private var timer: Timer?

    /// Whether the screen is being captured, read now; nil when macOS doesn't say.
    static func isCaptured() -> Bool? { present?() }

    func start() {
        Defaults.whenChanged([.hideFromScreenRecording, .hideWhileScreenShared]) { [weak self] in self?.apply() }
        apply()
    }

    private func apply() {
        let needed = Defaults[.hideWhileScreenShared] && !Defaults[.hideFromScreenRecording] && Self.present != nil
        if needed, timer == nil {
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.check() }
            }
            timer.tolerance = 0.1
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            check()
        } else if !needed, let timer {
            timer.invalidate()
            self.timer = nil
            set(false)
        }
    }

    private func check() { set(Self.present?() == true) }

    private func set(_ value: Bool) {
        guard value != captured else { return }
        captured = value
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    private static let present: (@convention(c) () -> Bool)? = {
        guard let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW),
              let symbol = dlsym(skyLight, "SLSIsScreenWatcherPresent") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) () -> Bool).self)
    }()
}
