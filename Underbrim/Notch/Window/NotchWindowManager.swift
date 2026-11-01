//
//  NotchWindowManager.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Extracted from AppDelegate: all notch-window, per-screen view-model and
//  drag-detector lifecycle in one place. AppDelegate keeps app-lifecycle
//  glue (shortcuts, onboarding, termination) and forwards to this manager.
//

import Combine
import Defaults
import SwiftUI

@MainActor
final class NotchWindowManager {
    /// All per-screen state in one value — replaces the parallel
    /// windows/viewModels/dragDetectors dictionaries that previously had
    /// to be mutated in lockstep (a missed mutation leaked observers).
    struct ScreenContext {
        let viewModel: NotchViewModel
        var window: NSWindow?
        var dragDetector: DragDetector?
    }

    private(set) var contexts: [String: ScreenContext] = [:] // UUID -> ScreenContext
    private(set) var primaryWindow: NSWindow?
    let primaryViewModel: NotchViewModel
    private var primaryDragDetector: DragDetector?

    private var windowScreenDidChangeObserver: Any?
    private var previousScreens: [NSScreen]?
    /// The notch opened from the keyboard shortcut, which owns key focus until it closes.
    private var keyboardSession: KeyboardSession?

    private struct KeyboardSession {
        let window: NotchSkyLightWindow
        /// Underbrim's own window that had the keyboard before (Settings): it gets it back.
        weak var previousKey: NSWindow?
        var resignObserver: NSObjectProtocol?
        var closeObserver: AnyCancellable?
        var escapeMonitor: Any?
    }

    init(camera: CameraModel) {
        primaryViewModel = NotchViewModel(camera: camera)
    }

    // MARK: - Lookups

    /// The island on the display under the pointer (with "Show on all displays"), else the main one.
    func viewModelUnderPointer() -> NotchViewModel {
        guard Defaults[.showOnAllDisplays] else { return primaryViewModel }
        return NSScreen.screenWithMouse?.displayUUID.flatMap { contexts[$0]?.viewModel } ?? primaryViewModel
    }

    // MARK: - Screen lock / unlock

    /// The notch stays on the lock screen: all of it, or just a closed padlock that opens on unlock.
    private var staysOnLockScreen: Bool { Defaults[.showOnLockScreen] || Defaults[.showUnlockAnimation] }

    private var keptWindowsWhileLocked = false

    func screenLocked() {
        NotchViewCoordinator.shared.screenLocked = true
        // The widget editor would let anyone at the locked Mac change Home.
        NotchViewCoordinator.shared.editingWidgets = false
        let notches = [primaryViewModel] + contexts.values.map(\.viewModel)
        // Locking lets a held island go (Keep Open, a pinned widget, which comes back on unlocking),
        // even where the notch stays on the lock screen: not a pinned widget that stays there.
        notches.forEach { if !Defaults[.showOnLockScreen] || $0.pinnedOpen && ($0.isPinned || $0.widgetAlone == nil) { $0.close() } }
        // An island the lock screen keeps open shows no camera to whoever is at the Mac.
        notches.forEach { $0.camera.stopSession(for: $0) }
        // A notch a share sheet holds open would show its contents: it leaves with its windows.
        keptWindowsWhileLocked = staysOnLockScreen
            && (Defaults[.showOnLockScreen] || notches.allSatisfy { $0.notchState == .closed })
        if keptWindowsWhileLocked {
            enableSkyLightOnAllWindows()
        } else {
            cleanupWindows()
        }
    }

    func screenUnlocked() {
        NotchViewCoordinator.shared.screenLocked = false
        if keptWindowsWhileLocked {
            disableSkyLightOnAllWindows()
        } else {
            adjustWindowPosition(changeAlpha: true)
            setupDragDetectors()
        }
    }

    private func enableSkyLightOnAllWindows() {
        if Defaults[.showOnAllDisplays] {
            contexts.values.forEach { context in
                (context.window as? NotchSkyLightWindow)?.enableSkyLight()
            }
        } else {
            (primaryWindow as? NotchSkyLightWindow)?.enableSkyLight()
        }
    }

    private func disableSkyLightOnAllWindows() {
        // Delay disabling SkyLight to avoid flicker during unlock transition
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            await MainActor.run {
                if Defaults[.showOnAllDisplays] {
                    contexts.values.forEach { context in
                        (context.window as? NotchSkyLightWindow)?.disableSkyLight()
                    }
                } else {
                    (primaryWindow as? NotchSkyLightWindow)?.disableSkyLight()
                }
            }
        }
    }

    // MARK: - Window lifecycle

    /// A held island (Keep Open, pinned Quick Launch) lets go when its window is rebuilt or moves to another display.
    func letPinnedGo() {
        ([primaryViewModel] + contexts.values.map(\.viewModel)).filter(\.pinnedOpen).forEach { $0.close() }
    }

    /// Every open island closes before its window goes, or its mirror's camera would keep running.
    private func closeOpenIslands() {
        ([primaryViewModel] + contexts.values.map(\.viewModel)).filter { $0.notchState == .open }.forEach { $0.close() }
    }

    func cleanupWindows(shouldInvert: Bool = false) {
        closeOpenIslands()
        // A drag torn down with its window ends here: the detector's "ended" looks up a window that's gone.
        ([primaryViewModel] + contexts.values.map(\.viewModel)).forEach { $0.dropInteraction.dragSession = false }
        let shouldCleanupMulti = shouldInvert ? !Defaults[.showOnAllDisplays] : Defaults[.showOnAllDisplays]

        if shouldCleanupMulti {
            for (uuid, context) in contexts {
                context.window?.close()
                if let window = context.window {
                    NotchSpaceManager.shared.notchSpace.windows.remove(window)
                }
                context.dragDetector?.stopMonitoring()
                contexts.removeValue(forKey: uuid)
            }
        } else {
            primaryDragDetector?.stopMonitoring()
            primaryDragDetector = nil
            if let window = primaryWindow {
                window.close()
                NotchSpaceManager.shared.notchSpace.windows.remove(window)
            }
            if let obs = windowScreenDidChangeObserver {
                NotificationCenter.default.removeObserver(obs)
                windowScreenDidChangeObserver = nil
            }
            primaryWindow = nil
        }

        // ensure OSD integration reflects the current window state
        HUDPresenter.shared.applyOSDSources()
    }

    private func createNotchWindow(for screen: NSScreen, with viewModel: NotchViewModel) -> NSWindow {
        let rect = NSRect(x: 0, y: 0, width: windowSize.width, height: windowSize.height)
        let styleMask: NSWindow.StyleMask = [.borderless, .nonactivatingPanel, .utilityWindow, .hudWindow]

        let window = NotchSkyLightWindow(contentRect: rect, styleMask: styleMask, backing: .buffered, defer: false)

        // Enable SkyLight only when screen is locked
        if NotchViewCoordinator.shared.screenLocked {
            window.enableSkyLight()
        } else {
            window.disableSkyLight()
        }

        window.contentView = NSHostingView(
            rootView: ContentView()
                .environmentObject(viewModel)
        )

        window.orderFrontRegardless()
        NotchSpaceManager.shared.notchSpace.windows.insert(window)

        // Observe when the window's screen changes so we can update drag detectors.
        // Remove any previous observer first — recreating windows used to
        // overwrite the token and leak the earlier observer each cycle.
        if let obs = windowScreenDidChangeObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        windowScreenDidChangeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: window,
            queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.setupDragDetectors()
                }
        }
        return window
    }

    private func positionWindow(_ window: NSWindow, on screen: NSScreen, changeAlpha: Bool = false) {
        if changeAlpha {
            window.alphaValue = 0
        }

        // Beside Apple's island the open island hangs below the menu bar: room for the tallest one there too.
        let height = windowSize.height + (FloatingIsland.on(screen).map { $0.besideAppleIsland ? $0.top : 0 } ?? 0)
        if window.frame.height != height { window.setContentSize(NSSize(width: windowSize.width, height: height)) }
        let screenFrame = screen.frame
        window.setFrameOrigin(
            NSPoint(
                x: screenFrame.origin.x + (screenFrame.width / 2) - window.frame.width / 2,
                y: screenFrame.origin.y + screenFrame.height - window.frame.height
            ))
        window.alphaValue = 1
    }

    func adjustWindowPosition(changeAlpha: Bool = false) {
        let coordinator = NotchViewCoordinator.shared
        if Defaults[.showOnAllDisplays] {
            let currentScreenUUIDs = Set(NSScreen.screens.compactMap { $0.displayUUID })

            // Remove windows for screens that no longer exist
            for uuid in contexts.keys where !currentScreenUUIDs.contains(uuid) {
                if let window = contexts[uuid]?.window {
                    window.close()
                    NotchSpaceManager.shared.notchSpace.windows.remove(window)
                }
                contexts[uuid]?.dragDetector?.stopMonitoring()
                contexts.removeValue(forKey: uuid)
            }

            // Create or update windows for all screens
            for screen in NSScreen.screens {
                guard let uuid = screen.displayUUID else { continue }

                if contexts[uuid] == nil {
                    contexts[uuid] = ScreenContext(
                        viewModel: NotchViewModel(screenUUID: uuid, camera: primaryViewModel.camera),
                        window: nil,
                        dragDetector: nil
                    )
                }

                if contexts[uuid]?.window == nil {
                    let viewModel = contexts[uuid]!.viewModel
                    let window = createNotchWindow(for: screen, with: viewModel)
                    contexts[uuid]?.window = window
                }

                if let window = contexts[uuid]?.window {
                    let viewModel = contexts[uuid]!.viewModel
                    viewModel.measureDisplay()
                    positionWindow(window, on: screen, changeAlpha: changeAlpha)

                    if viewModel.notchState == .closed {
                        viewModel.close()
                    }
                }
            }
        } else {
            let selectedScreen: NSScreen

            if let preferredScreen = NSScreen.screen(withUUID: coordinator.preferredScreenUUID ?? "") {
                coordinator.selectedScreenUUID = coordinator.preferredScreenUUID ?? ""
                selectedScreen = preferredScreen
            } else if Defaults[.automaticallySwitchDisplay], let mainScreen = NSScreen.main,
                      let mainUUID = mainScreen.displayUUID {
                coordinator.selectedScreenUUID = mainUUID
                selectedScreen = mainScreen
            } else {
                // No display for the island: hidden, it mustn't stay open.
                primaryViewModel.close()
                if let window = primaryWindow {
                    window.alphaValue = 0
                }
                return
            }

            primaryViewModel.screenUUID = selectedScreen.displayUUID
            primaryViewModel.measureDisplay()
            primaryViewModel.notchSize = getClosedNotchSize(screenUUID: selectedScreen.displayUUID)

            if primaryWindow == nil {
                primaryWindow = createNotchWindow(for: selectedScreen, with: primaryViewModel)
            }

            if let window = primaryWindow {
                positionWindow(window, on: selectedScreen, changeAlpha: changeAlpha)

                if primaryViewModel.notchState == .closed {
                    primaryViewModel.close()
                }
            }
        }

        if !Defaults[.seenDisplayWithoutNotch], NSScreen.screens.contains(where: { $0.safeAreaInsets.top <= 0 }) {
            Defaults[.seenDisplayWithoutNotch] = true
        }
        SteppingAside.shared.update(Defaults[.showOnAllDisplays] ? contexts.values.map(\.viewModel) : [primaryViewModel])

        // windows might have been added/removed during the earlier logic –
        // update the OSD subsystems accordingly.
        HUDPresenter.shared.applyOSDSources()
    }

    func screenConfigurationDidChange() {
        let currentScreens = NSScreen.screens

        let screensChanged =
            currentScreens.count != previousScreens?.count
            || Set(currentScreens.compactMap { $0.displayUUID })
                != Set(previousScreens?.compactMap { $0.displayUUID } ?? [])
            || Set(currentScreens.map { $0.frame }) != Set(previousScreens?.map { $0.frame } ?? [])

        previousScreens = currentScreens

        if screensChanged {
            AppleIsland.forget()
            DispatchQueue.main.async { [weak self] in
                // Sync notch height with real value if mode is matchRealNotchSize
                syncNotchHeightIfNeeded()

                self?.cleanupWindows()
                self?.adjustWindowPosition()
                self?.setupDragDetectors()
            }
        }
    }

    func noteInitialScreens() {
        previousScreens = NSScreen.screens
    }

    // MARK: - Drag detection

    func cleanupDragDetectors() {
        primaryDragDetector?.stopMonitoring()
        primaryDragDetector = nil
        for uuid in contexts.keys {
            contexts[uuid]?.dragDetector?.stopMonitoring()
            contexts[uuid]?.dragDetector = nil
        }
    }

    func setupDragDetectors() {
        cleanupDragDetectors()

        guard Defaults[.expandedDragDetection] else { return }

        if Defaults[.showOnAllDisplays] {
            for screen in NSScreen.screens {
                setupDragDetectorForScreen(screen)
            }
        } else {
            let preferredScreen: NSScreen? = primaryWindow?.screen
                ?? NSScreen.screen(withUUID: NotchViewCoordinator.shared.selectedScreenUUID)
                ?? NSScreen.main

            if let screen = preferredScreen {
                setupDragDetectorForScreen(screen)
            }
        }
    }

    private func setupDragDetectorForScreen(_ screen: NSScreen) {
        guard let uuid = screen.displayUUID else { return }
        // Per-display detectors belong to windows created by adjustWindowPosition.
        guard !Defaults[.showOnAllDisplays] || contexts[uuid]?.window != nil else { return }

        let screenFrame = screen.frame
        let notchHeight = NotchMetrics.dragNearDepth
        let notchWidth = dragOpenWidth

        let notchRegion = CGRect(
            x: screenFrame.midX - notchWidth / 2,
            y: screenFrame.maxY - notchHeight,
            width: notchWidth,
            height: notchHeight
        )

        let detector = DragDetector(notchRegion: notchRegion)

        detector.onDragEntersNotchRegion = { [weak self] in
            Task { @MainActor in
                self?.handleDragEntersNotchRegion(onScreen: screen)
            }
        }
        detector.onDragEnded = { [weak self] in
            Task { @MainActor in
                self?.viewModel(for: screen)?.dropInteraction.dragSession = false
            }
        }

        if Defaults[.showOnAllDisplays] {
            contexts[uuid]?.dragDetector = detector
        } else {
            primaryDragDetector = detector
        }
        detector.startMonitoring()
    }

    private func handleDragEntersNotchRegion(onScreen screen: NSScreen) {
        // Beside Apple's island, a drag at the top is Apple's (AirDrop).
        guard Defaults[.shelfEnabled] || NotchViewCoordinator.shared.viewForDrag == .home,
              let viewModel = viewModel(for: screen), viewModel.floating?.besideAppleIsland != true else { return }
        // Opens on the Shelf (Home for apps) for the whole drag. A pinned widget stays (a file dropped
        // on a Quick Launch app opens in it), and Home is still what unpinning shows.
        viewModel.dropInteraction.dragSession = true
        viewModel.open()
        if viewModel.widgetAlone == nil {
            // Already open (Keep Open): the island changes page on its spring, as for a tab.
            withAnimation(StandardAnimations.open) {
                NotchViewCoordinator.shared.currentView = NotchViewCoordinator.shared.viewForDrag
            }
        }
    }

    private func viewModel(for screen: NSScreen) -> NotchViewModel? {
        guard let uuid = screen.displayUUID else { return nil }
        if Defaults[.showOnAllDisplays] { return contexts[uuid]?.viewModel }
        return primaryWindow?.screen == screen ? primaryViewModel : nil
    }

    // MARK: - Initial setup

    /// Creates the windows for the current configuration (previously inlined
    /// in applicationDidFinishLaunching).
    func prepareInitialWindows() {
        if !Defaults[.showOnAllDisplays] {
            let viewModel = primaryViewModel
            if let screen = NSScreen.main ?? NSScreen.screens.first {
                primaryWindow = createNotchWindow(for: screen, with: viewModel)
            }
            adjustWindowPosition(changeAlpha: true)
        } else {
            adjustWindowPosition(changeAlpha: true)
        }

        setupDragDetectors()
        noteInitialScreens()
    }

    // MARK: - Keyboard access

    func window(for viewModel: NotchViewModel) -> NSWindow? {
        if viewModel === primaryViewModel { return primaryWindow }
        return contexts.values.first { $0.viewModel === viewModel }?.window
    }

    /// Opens the notch from the keyboard shortcut with key focus, so its controls are reachable and
    /// Escape closes it; it closes when focus moves elsewhere. Hover-opening never takes focus.
    func openWithKeyboard(_ viewModel: NotchViewModel) {
        guard viewModel.open() else { return }
        let coordinator = NotchViewCoordinator.shared
        if !NotchViews.tabs.contains(coordinator.currentView) { coordinator.currentView = coordinator.reopenView }
        takeKeyboard(viewModel)
    }

    /// Whether the island has the keyboard from its shortcut.
    func hasKeyboard(_ viewModel: NotchViewModel) -> Bool {
        keyboardSession.map { $0.window === window(for: viewModel) } ?? false
    }

    /// The open island takes the keyboard, as when the shortcut opens it.
    func takeKeyboard(_ viewModel: NotchViewModel) {
        guard let window = window(for: viewModel) as? NotchSkyLightWindow else { return }
        endKeyboardSession(restoreFocus: false)
        var session = KeyboardSession(window: window, previousKey: NSApp.isActive && !(NSApp.keyWindow is NotchSkyLightWindow) ? NSApp.keyWindow : nil)
        window.wantsKeyForTextInput = true
        // Escape closes (or first leaves editing, or unpins Quick Launch). onExitCommand needs a focused
        // view, which nothing gets with keyboard navigation off. A text field gets its keys first, then
        // a question's options, then Home's widgets theirs.
        session.escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak window, weak viewModel] event in
            guard let window, event.window === window, !(window.firstResponder is NSText) else { return event }
            let key = event.keyCode, modifiers = event.modifierFlags
            let handled = MainActor.assumeIsolated {
                guard key != 53 else {
                    viewModel?.escape()
                    return true
                }
                return QuestionKeys.handle(key, modifiers: modifiers) || HomeWidgetKeys.handle(key, modifiers: modifiers)
            }
            return handled ? nil : event
        }
        // Focus moved elsewhere (a click in another app): close, leaving focus where the user put it.
        session.resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self, weak viewModel] _ in
            MainActor.assumeIsolated {
                self?.endKeyboardSession(restoreFocus: false)
                // Held (Keep Open, pinned Quick Launch), it stays open; focus still stays where the user put it.
                if viewModel?.heldOpen != true { viewModel?.close() }
            }
        }
        // Closed any other way (Escape, the shortcut, locking): give the keyboard back to the app the
        // user was in, so typing never lands in the closed notch.
        session.closeObserver = viewModel.$notchState
            .dropFirst()
            .filter { $0 == .closed }
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.endKeyboardSession(restoreFocus: true) }
            }
        keyboardSession = session
    }

    func endKeyboardSession(restoreFocus: Bool = true) {
        guard let session = keyboardSession else { return }
        keyboardSession = nil
        if let observer = session.resignObserver { NotificationCenter.default.removeObserver(observer) }
        if let monitor = session.escapeMonitor { NSEvent.removeMonitor(monitor) }
        session.closeObserver?.cancel()
        let hadFocus = session.window.isKeyWindow
        session.window.wantsKeyForTextInput = false
        // Taking key made this app active; deactivating hands the keyboard back (activating that app does
        // nothing: macOS still counts it as frontmost). Underbrim's own window gets it back instead.
        if restoreFocus, hadFocus {
            if let previous = session.previousKey, previous.isVisible, previous.canBecomeKey { previous.makeKeyAndOrderFront(nil) } else { NSApp.deactivate() }
        }
    }

    func cleanup() {
        cleanupDragDetectors()
        cleanupWindows()
    }
}
