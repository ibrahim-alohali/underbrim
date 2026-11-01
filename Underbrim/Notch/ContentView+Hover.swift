//
//  ContentView+Hover.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Opening and closing the island: hover, clicks, the bubble, notifications coming forward, and
//  what holds it open.
//

import Defaults
import SwiftUI

extension ContentView {
    @discardableResult
    func doOpen() -> Bool {
        // A click (or drop) beats the hover timer; it never opens twice.
        hoverTask?.cancel()
        var didOpen = false
        withAnimation(StandardAnimations.open) {
            didOpen = vm.open()
            if didOpen {
                // On the lock screen the island shows Home: the notification isn't opened on.
                if case .notification(let notification) = selectedActivity, !coordinator.screenLocked {
                    vm.notificationAtOpen = notification.id
                } else {
                    vm.notificationAtOpen = nil
                }
                let main = selectedActivity.flatMap { item in item.page.map { ($0, activities.since[item.id] ?? Date()) } }
                coordinator.currentView = coordinator.viewOnOpen(main: main, live: liveTabs.map(\.view))
            }
        }
        return didOpen
    }

    /// Opens on the bubble's activity's page, once: it doesn't change where the island opens.
    func open(on item: LiveActivityItem) {
        hoverTask?.cancel()
        withAnimation(StandardAnimations.open) {
            guard vm.open() else { return }
            if case .notification(let notification) = item { vm.notificationAtOpen = notification.id }
            coordinator.currentView = item.page ?? .home
        }
    }

    func swap(to item: LiveActivityItem) {
        swapping = true
        swaps += 1
        let swap = swaps
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.4)) {
            activities.pick(item.id, among: ActivityFeed.items.map(\.id))
        } completion: {
            if swaps == swap { swapping = false }
        }
        if Defaults[.enableHaptics] { haptics.toggle() }
    }

    /// Ages the notification out again: briefly if seen, its full time if it arrived while open elsewhere.
    func resumeNotificationDismiss() {
        // On the lock screen its card wasn't shown, so it keeps its full time.
        let unseen = coordinator.screenLocked || notificationManager.activeNotification.map { $0.id == unseenNotification } ?? false
        notificationManager.resumeDismiss(after: unseen ? notificationManager.displayDuration : 2)
        unseenNotification = nil
    }

    func bubbleDragged(_ dragging: Bool) {
        bubbleDragging = dragging
        guard !dragging else { return }
        // Let go over the island: no opening under the pointer until it leaves.
        holdHoverUntilExit = true
        pointerWatch.update()
        if pointerWatch.inside != true { holdHoverUntilExit = false }
    }

    func bringForward(_ kind: LiveActivityItem.Kind) {
        if let item = ActivityFeed.items.first(where: { $0.kind == kind }) { activities.bringForward(item.id) }
    }

    /// Back to its place, if it's still there (an agent at work after it needed the user, a timer counting down).
    func release(_ kind: LiveActivityItem.Kind) {
        ActivityFeed.items.filter { $0.kind == kind }.forEach { activities.release($0.id) }
        activities.update(ids: ActivityFeed.items.map(\.id))
    }

    // MARK: - Hover Management

    /// Closes the open notch after the hover grace period unless a popover
    /// still owns the pointer.
    func scheduleCloseIfNotHovering(overNotch notchViewModel: NotchViewModel) {
        guard notchViewModel.notchState == .open,
              !isHovering,
              !notchViewModel.isPopoverActive else { return }
        hoverTask?.cancel()
        hoverTask = Task {
            try? await Task.sleep(for: .seconds(Defaults[.closeDelay]))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if !self.isHovering { self.closeUnlessHeld() }
            }
        }
    }

    /// This island has the keyboard (typing in it, or opened with the shortcut).
    var hasKeyboard: Bool {
        guard let window = pointerWatch.window as? NotchSkyLightWindow else { return false }
        return window.wantsKeyForTextInput && window.isKeyWindow
    }

    /// A hold ended with the pointer away: the island closes as if the pointer had just left.
    /// One the pointer never touched (opened and used from the keyboard) stays open.
    func holdEnded() {
        pointerWatch.update()
        guard Self.closesAfterHold(pointerInside: pointerWatch.inside, hovering: isHovering, closeSkipped: closeSkipped) else { return }
        isHovering = false
        scheduleCloseIfNotHovering(overNotch: vm)
    }

    nonisolated static func closesAfterHold(pointerInside: Bool?, hovering: Bool, closeSkipped: Bool) -> Bool {
        pointerInside != true && (hovering || closeSkipped)
    }

    /// A question arrived: the island opens by itself and holds it until answered or closed (AgentAsks),
    /// on the pointer's display, not over the lock screen or the first run, without taking the keyboard.
    func openForAsk() {
        guard showsAsks, askStore.current != nil, vm.notchState == .closed,
              !coordinator.screenLocked, !coordinator.firstLaunch, !coordinator.touring else { return }
        if Defaults[.showOnAllDisplays] {
            let pointer = NSEvent.mouseLocation
            guard NSScreen.screens.first(where: { $0.frame.contains(pointer) })?.displayUUID == vm.screenUUID else { return }
        }
        hoverTask?.cancel()
        withAnimation(StandardAnimations.open) {
            guard vm.open() else { return }
            openedForAsk = true
        }
    }

    /// The last question is done: an island that opened by itself folds straight back with it, also under
    /// the pointer that just answered it, which then doesn't open it again until it has left. Staying open
    /// would show the page under the question for a moment, a second move for one event; a question that
    /// comes next opens it again. The keyboard, taken with the shortcut to answer, doesn't hold it: closing
    /// gives it back to the app the user was in.
    func closeAfterAsks() {
        guard openedForAsk else { return }
        openedForAsk = false
        pointerWatch.update()
        if pointerWatch.inside == true { holdHoverUntilExit = true }
        closeUnlessHeld(byKeyboard: false)
    }

    func closeUnlessHeld(byKeyboard: Bool = true) {
        guard vm.notchState == .open else { return }
        menus.dropStale()
        if let reason = vm.holdReason(keyboard: byKeyboard && hasKeyboard) ?? (pointerWatch.heldAfterMenu ? "a menu choice" : nil) {
            closeSkipped = true
            Log.window.notice("Close skipped: held by \(reason, privacy: .public)")
            return
        }
        vm.close()
    }

    func handleHover(_ hovering: Bool) {
        if coordinator.firstLaunch || coordinator.touring { return }
        if !hovering { holdHoverUntilExit = false }
        hoverTask?.cancel()

        if hovering {
            closeSkipped = false
            withAnimation(animationSpring) {
                isHovering = true
            }

            // Freeze the dismiss countdown the moment the pointer arrives,
            // not when the notch finishes opening. Opening waits out
            // minimumHoverDuration plus an animation, and a notification
            // near the end of its life would expire during that — so it
            // vanished exactly as the notch opened around it.
            if notificationManager.activeNotification != nil {
                notificationManager.holdActive()
            }

            if vm.notchState == .closed && Defaults[.enableHaptics] {
                haptics.toggle()
            }

            guard vm.notchState == .closed, opensOnHover else { return }

            hoverTask = Task {
                try? await Task.sleep(for: .seconds(Defaults[.minimumHoverDuration]))
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    guard self.vm.notchState == .closed,
                          self.isHovering,
                          !self.shouldDisplayNowPlayingFallbackNotice,
                          !self.showsPeek else { return }

                    self.doOpen()
                }
            }
        } else {
            hoverTask = Task {
                try? await Task.sleep(for: .seconds(Defaults[.closeDelay]))
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    withAnimation(animationSpring) {
                        // The HUD goes in the same change, not first back to one bar tall, unless its slider is dragged.
                        if !self.hudDragging { self.hud.holdSneakPeek(false, on: self.vm.screenUUID) }
                        self.isHovering = false
                    }

                    // Pointer left: a notification ages out again, unless held, then once the island closes.
                    if self.vm.holdPausingNotifications(keyboard: self.hasKeyboard) == nil { self.resumeNotificationDismiss() }

                    if self.vm.notchState == .open { self.pointerWatch.leftOpenAt = .now }
                    self.closeUnlessHeld()
                }
            }
        }
    }
}
