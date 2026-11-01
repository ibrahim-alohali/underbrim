//
//  NotchViewModel+Shown.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  What the open island shows and what holds it open, worked out from the app's state in one
//  place: the view draws it, and the window manager and Escape act on the same answer. The view
//  observes the settings and stores read here, so a change redraws it.
//

import Defaults
import Foundation

extension NotchViewModel {
    /// The notification the island opened on, while it's still the one showing, or the one that just took
    /// its place (ContentView then moves `notificationAtOpen` on): stepping to the next is one change, not
    /// a moment of the page underneath. Not on the lock screen, where the island shows only Home.
    var openNotification: SystemNotification? {
        guard !coordinator.screenLocked, let notificationAtOpen else { return nil }
        let manager = SystemNotificationManager.shared
        return manager.activeNotification.flatMap { active in
            active.id == notificationAtOpen || manager.replacedID == notificationAtOpen ? active : nil
        }
    }

    /// The open notch's page: the tab picked, or with a widget pinned Home, unless an agent waiting on the
    /// user or a call started after the pin needs the island (one already going shows beside the camera).
    var openView: NotchViews {
        guard widgetAlone != nil else { return coordinator.shownView }
        let chosen = WidgetPin.shared.chosen
        // The newest request counts: one made after the pin takes over even while an older one waits.
        if Defaults[.showAgentActivity] || !AgentRequestStore.shared.requests.isEmpty,
           let request = AgentSessionStore.shared.closedSummary?.lastRequest, request > chosen { return .agents }
        // A call, not just any app using the microphone (dictation, a recorder).
        if let call = CallActivity.shared.call, call.isCall, call.since > chosen { return .phoneActivities }
        return .home
    }

    /// The question an agent waits on, when it has the open island (AgentAsks).
    var shownAsk: AgentAsks.Ask? {
        guard Defaults[.openIslandForAgentRequests], notchState == .open, openNotification == nil, !coordinator.screenLocked,
              !coordinator.firstLaunch, !coordinator.touring, !coordinator.editingWidgets else { return nil }
        return AgentAsks.shared.current
    }

    /// The pinned widget is what the island shows: no call, agent, notification or question has it.
    var pinnedAlone: HomeWidget? {
        guard notchState == .open, let widget = widgetAlone, openView == .home, openNotification == nil,
              shownAsk == nil else { return nil }
        return widget
    }

    /// A call or a request has the pinned island instead of its widget.
    var pinnedTakeover: Bool {
        notchState == .open && widgetAlone != nil && (openView == .phoneActivities || openView == .agents)
    }

    /// Held open on purpose (Keep Open, a pinned widget, a question, Quick Launch being edited): it lets
    /// go only on a deliberate close, or for full screen, locking or a display change.
    var heldOpen: Bool { isPinned || widgetAlone != nil || QuickLaunch.shared.editing || shownAsk != nil }

    /// Why the open island mustn't close on its own now, or nil; deliberate closes don't ask.
    /// `keyboard`: this island has the keyboard.
    func holdReason(keyboard: Bool) -> String? {
        holdPausingNotifications(keyboard: keyboard)
            ?? (widgetAlone != nil ? "pinned widget" : QuickLaunch.shared.editing ? "Quick Launch editing"
                : shownAsk != nil ? "a question" : nil)
    }

    /// What holds the island besides a pinned widget, Quick Launch being edited or a question, under
    /// which a notification still ages out once the pointer leaves.
    func holdPausingNotifications(keyboard: Bool) -> String? {
        if isPinned { return "the pin" }
        if MenuTracking.shared.isOpen { return "a menu" }
        if keyboard { return "the keyboard" }
        if isPopoverActive { return "a popover" }
        if dropInteraction.dragSession || QuickLaunch.shared.dragging { return "a drag" }
        if SharingStateManager.shared.preventNotchClose { return "a share" }
        return nil
    }
}
