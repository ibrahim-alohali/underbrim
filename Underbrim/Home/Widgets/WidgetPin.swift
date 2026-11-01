//
//  WidgetPin.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  One Home widget pinned as the island on its own, until it's unpinned; kept across restarts. Each
//  island decides whether the pin is in effect there (NotchViewModel.widgetAlone).
//

import Defaults
import SwiftUI

@MainActor @Observable
final class WidgetPin {
    static let shared = WidgetPin()

    /// The pinned widget. Held here, not only in Defaults (whose SwiftUI updates arrive a moment
    /// later, outside the animation), so pinning and unpinning morph the island.
    private(set) var widget: HomeWidget? {
        didSet {
            guard widget != oldValue else { return }
            Defaults[.pinnedWidget] = widget
            Defaults[.quickLaunchPinned] = widget == .quickLaunch
        }
    }
    /// When the widget was last chosen (pinned, or brought back with Escape): only a call or a
    /// request that comes after takes the pinned island over.
    var chosen = Date.distantPast

    @ObservationIgnored private var watch: Task<Void, Never>?

    private init() {
        // Pinned Quick Launch from before any widget could be pinned.
        widget = Defaults[.pinnedWidget] ?? (Defaults[.quickLaunchPinned] ? .quickLaunch : nil)
        watch = Task { [weak self] in
            for await _ in Defaults.updates(HomeWidget.layoutKeys, initial: false) {
                guard let self, let widget = self.widget, !Defaults[widget.enabledKey] else { continue }
                self.set(nil)
            }
        }
    }

    func set(_ widget: HomeWidget?) {
        if widget == .quickLaunch || self.widget == .quickLaunch { QuickLaunch.shared.pinChanged() }
        withAnimation(StandardAnimations.open) {
            if widget != nil { chosen = .now }
            self.widget = widget
        }
    }

    func toggle(_ widget: HomeWidget) { set(self.widget == widget ? nil : widget) }
}
