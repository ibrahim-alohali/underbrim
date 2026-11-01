//
//  UnderbrimApp.swift
//  Underbrim
//
//  Created by Harsh Vardhan  Goswami  on 02/08/24.
//

import AVFoundation
import Defaults
import KeyboardShortcuts
import LaunchAtLogin
import SwiftUI

@main
struct UnderbrimApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Default(.menubarIcon) var showMenuBarIcon
    @Environment(\.openWindow) var openWindow
    @ObservedObject private var steppingAside = SteppingAside.shared

    var body: some Scene {
        MenuBarExtra("Underbrim", systemImage: "sparkle", isInserted: $showMenuBarIcon) {
            if steppingAside.everywhere {
                Button("Open Underbrim") {
                    DispatchQueue.main.async { appDelegate.openFromMenu() }
                }
                Divider()
            }
            Button("Settings") {
                DispatchQueue.main.async {
                    SettingsWindowController.shared.showWindow()
                }
            }
            .keyboardShortcut(KeyEquivalent(","), modifiers: .command)
            Button("Restart Underbrim") {
                ApplicationRelauncher.restart()
            }
            Button(String(localized: "Quit Underbrim"), role: .destructive) {
                NSApplication.shared.terminate(self)
            }
            .keyboardShortcut(KeyEquivalent("Q"), modifiers: .command)
        }
    }
}

/// App-lifecycle glue: shortcuts, onboarding, termination, observer wiring.
/// All notch-window / per-screen view-model / drag-detector lifecycle lives
/// in `NotchWindowManager` (see Notch/Window/NotchWindowManager.swift).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Made on first use, after the settings' history is applied: the camera reads its settings.
    private lazy var camera = CameraModel(persistsSelection: true)
    var coordinator: NotchViewCoordinator { .shared }
    lazy var windowManager = NotchWindowManager(camera: camera)
    private var screenLockedObserver: Any?
    private var screenUnlockedObserver: Any?
    var observers: [Any] = []

    override init() {
        // First, so nothing reads a setting an update would change.
        DefaultsHistory.apply()
        // A chosen language follows the Mac's region and calendar as they are now (from the next launch).
        if Defaults[.appLanguage] != .system { Defaults[.appLanguage].applyAppleLanguagesOverride() }
        super.init()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // A preview copy never stays as a login item (its tour may have ticked one).
        if Relay.isPreviewCopy { LaunchAtLogin.isEnabled = false }
        // Flush debounced shelf persistence to avoid losing recent changes.
        ShelfStateViewModel.shared.flushSync()
        ClipboardHistory.shared.flush()
        Scratchpad.shared.flush()

        NotificationCenter.default.removeObserver(self)
        if let observer = screenLockedObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            screenLockedObserver = nil
        }
        if let observer = screenUnlockedObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            screenUnlockedObserver = nil
        }
        MusicManager.shared.destroy()
        windowManager.cleanup()
        RelayListener.shared.stop()
        AgentSessionStore.shared.stopListening()
        BetterDisplayManager.shared.stopObserving()
        LunarManager.shared.stopListening()
        LunarManager.restoreOnQuit()
        XPCHelperClient.shared.stopMonitoringAccessibilityAuthorization()

        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    func onScreenLocked(_ notification: Notification) {
        windowManager.screenLocked()
    }

    func onScreenUnlocked(_ notification: Notification) {
        windowManager.screenUnlocked()
        if Defaults[.showUnlockAnimation] { StatusFlash.shared.show(SystemTouches.unlocked, for: 1.4) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Nor one left by a preview that was killed rather than quit.
        if Relay.isPreviewCopy { LaunchAtLogin.isEnabled = false }
        SettingsWindowController.shared.setCamera(camera)
        // Not inside the unit-test host: it shares this app's id, so it would take over the relay link
        // and socket, record the clipboard into the real history and start Codex.
        let hostingTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        startServices(hostingTests: hostingTests)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenConfigurationDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        // Display settings take effect however they're changed: from either Settings, or by the app.
        // A new preferred display, or switching displays turned on or off: the island moves, or hides (and closes).
        Defaults.whenChanged([Defaults.Keys.preferredScreenUUID, .automaticallySwitchDisplay]) { [weak self] in
            self?.windowManager.letPinnedGo()
            self?.windowManager.adjustWindowPosition(changeAlpha: true)
            self?.windowManager.setupDragDetectors()
        }
        Defaults.whenChanged([Defaults.Keys.notchHeight, .notchHeightMode, .nonNotchHeight, .nonNotchHeightMode,
                              .minimumHoverDuration, .nonNotchStyle]) { [weak self] in
            self?.windowManager.adjustWindowPosition()
            self?.windowManager.setupDragDetectors()
        }
        Defaults.whenChanged([Defaults.Keys.showOnAllDisplays]) { [weak self] in
            guard let self = self else { return }
            self.windowManager.cleanupWindows(shouldInvert: true)
            self.windowManager.adjustWindowPosition(changeAlpha: true)
            self.windowManager.setupDragDetectors()
        }
        Defaults.whenChanged([Defaults.Keys.expandedDragDetection]) { [weak self] in
            self?.windowManager.setupDragDetectors()
        }

        // Use closure-based observers for DistributedNotificationCenter and keep tokens for removal
        screenLockedObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(rawValue: "com.apple.screenIsLocked"),
            object: nil, queue: .main) { [weak self] notification in
                Task { @MainActor in
                    self?.onScreenLocked(notification)
                }
        }

        screenUnlockedObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(rawValue: "com.apple.screenIsUnlocked"),
            object: nil, queue: .main) { [weak self] notification in
                Task { @MainActor in
                    self?.onScreenUnlocked(notification)
                }
        }

        #if DEBUG
        listenForDebugCommands()
        #endif

        registerShortcuts()

        // Sync notch height with real value on app launch if mode is matchRealNotchSize
        syncNotchHeightIfNeeded()

        // Nor a notch window for the test host: it would draw a second notch over the running app's.
        if !hostingTests {
            windowManager.prepareInitialWindows()
        }

        // The notch greets a new install itself, once its window is up; not the unit-test host.
        if coordinator.firstLaunch && !hostingTests {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.coordinator.startFirstRun()
            }
        }

        // make sure OSD subsystems are in the right state now that initial
        // notch windows have been created/cleaned up
        HUDPresenter.shared.applyOSDSources()
    }

    @objc func screenConfigurationDidChange() {
        windowManager.screenConfigurationDidChange()
    }

}
