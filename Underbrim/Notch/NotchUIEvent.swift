//
//  NotchUIEvent.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Created as part of the architecture remediation.
//

import SwiftUI
import Combine

/// UI-presentation events emitted by hardware/OS-facing managers.
///
/// Inverts the old "manager calls the presenter" direction: `HUDPresenter`
/// also *configures* those same managers (applyOSDSources), so direct calls
/// created a dependency cycle. Managers now publish events; the presenter is
/// the single subscriber and decides what to present.
/// Presentation policy (e.g. `Defaults[.osdReplacement]`) lives on the
/// presenter side, and managers stay testable without the UI stack.
enum NotchUIEvent {
    case sneakPeek(
        type: SneakContentType,
        value: CGFloat,
        icon: String = "",
        accent: Color? = nil,
        targetScreenUUID: String? = nil,
        duration: TimeInterval = 1.5
    )
    case expandingView(type: SneakContentType)
    /// The volume changed outside Underbrim while its keys aren't taken over:
    /// the HUD may offer to take them over (once; the presenter decides).
    case hudNudge(volume: CGFloat)
}

/// The event pipe. `HUDPresenter` is the subscriber.
enum NotchUIEventBus {
    static let events = PassthroughSubject<NotchUIEvent, Never>()
}
