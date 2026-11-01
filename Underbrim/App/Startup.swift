//
//  Startup.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The services that run from launch start here, after the settings' history is applied
//  (AppDelegate's init), so a new one has one place to go. The app delegate itself sets up the
//  windows, the display and lock observers and the shortcuts.
//

import Defaults
import Foundation

extension AppDelegate {
    func startServices(hostingTests: Bool) {
        HUDPresenter.shared.start()
        SoundMixer.shared.startIfEnabled()
        ScreenWatch.shared.start()
        // Found ahead of the first share.
        _ = QuickShareService.shared

        // Accessibility granted or taken away: the keys and the notification reader follow.
        observers.append(NotificationCenter.default.addObserver(
            forName: Notification.Name.accessibilityAuthorizationChanged,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                let authorized = await XPCHelperClient.shared.isAccessibilityAuthorized()
                if authorized {
                    if Defaults[.osdReplacement] {
                        await MediaKeyInterceptor.shared.start(promptIfNeeded: false)
                    }
                    await SystemNotificationManager.shared.sync()
                } else {
                    MediaKeyInterceptor.shared.stop()
                    SystemNotificationManager.shared.stop()
                }
            }
        })
        XPCHelperClient.shared.startMonitoringAccessibilityAuthorization()
        // The notification reader follows its own settings from here on.
        Task { await SystemNotificationManager.shared.sync() }

        // The test host's adapters are orphaned too, each time a run ends.
        OrphanReaper.reapAdapters()
        guard !hostingTests else { return }
        RelayListener.shared.start()
        AgentSessionStore.shared.startListening()
        AgentUsageStore.shared.start()
        ClipboardHistory.shared.start()
        ScreenshotWatcher.shared.start()
        DownloadProgressWatcher.shared.start()
        MeetingStore.shared.start()
        PhoneActivityStore.shared.start()
        DeliveryTracker.shared.start()
        CallActivity.shared.start()
        SystemTouches.shared.start()
        FocusWatcher.shared.start()
        HeadphoneBatteryStore.shared.start()
        QuickLaunch.shared.start()
        PrayerTimesStore.shared.start()
    }
}
