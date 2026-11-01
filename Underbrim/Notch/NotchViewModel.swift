//
//  NotchViewModel.swift
//  Underbrim
//
//  Created by Harsh Vardhan  Goswami  on 04/08/24.
//

import Combine
import Defaults
import SwiftUI

final class NotchViewModel: NSObject, ObservableObject {
    @ObservedObject var coordinator = NotchViewCoordinator.shared
    @ObservedObject var detector = FullscreenMediaDetector.shared

    let dropInteraction = DropInteractionState()

    @Published private(set) var notchState: NotchState = .closed
    /// Counts openings. Each has its own content, coming in once the outline has made room, also
    /// when it catches the island mid-close (the closing content would otherwise turn straight back).
    private(set) var openings = 0

    var cancellables: Set<AnyCancellable> = []

    @Published var hideOnClosed: Bool = true

    @Published var edgeAutoOpenActive: Bool = false
    /// Keeps the open notch alive while a popover is showing.
    @Published var isPopoverActive: Bool = false
    /// Pinned: it closes only on purpose, and any close unpins. Not kept across launches.
    @Published var isPinned = false
    /// The widget pinned as the island (WidgetPin), in effect: not while the editor or tour shows, the
    /// widget is off or an app is full screen here; locked, only one that shows nothing private.
    var widgetAlone: HomeWidget? {
        guard let widget = WidgetPin.shared.widget, Defaults[widget.enabledKey], !coordinator.editingWidgets,
              coordinator.currentView != .welcome, !detector.anyFullscreen.contains(screenUUID ?? "") else { return nil }
        if coordinator.screenLocked, !(widget.showsWhileLocked && Defaults[.showOnLockScreen]) { return nil }
        return widget
    }
    /// Compact mode's widget (HomeWidget.compactChosen); locked, Now Playing unless it shows nothing private.
    var compactWidget: HomeWidget {
        let chosen = HomeWidget.compactChosen
        return coordinator.screenLocked && !chosen.showsWhileLocked ? .nowPlaying : chosen
    }
    /// Pinned at all (Keep Open or a widget, in effect or not): full screen, locking and display changes let go.
    var pinnedOpen: Bool { isPinned || WidgetPin.shared.widget != nil }
    /// The notification the island opened on; one arriving while open waits on the closed notch.
    @Published var notificationAtOpen: String?

    @Published var screenUUID: String?

    @Published var notchSize: CGSize = getClosedNotchSize()
    @Published var closedNotchSize: CGSize = getClosedNotchSize()
    /// On a display without a notch (or beside Apple's island): where the floating island sits. Nil where
    /// it grows from the notch, or the notch-shaped tab is chosen.
    @Published private(set) var floating: FloatingIsland?

    let camera: CameraModel

    deinit {
        destroy()
    }

    func destroy() {
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
    }

    init(screenUUID: String? = nil, camera: CameraModel) {
        self.camera = camera
        self.screenUUID = screenUUID

        super.init()

        notchSize = getClosedNotchSize(screenUUID: screenUUID)
        closedNotchSize = notchSize
        floating = FloatingIsland.on(screen)

        setupDetectorObserver()
    }

    private func setupDetectorObserver() {
        // Publisher for the user’s fullscreen detection setting
        let enabledPublisher = Defaults
            .publisher(.hideNotchOption)
            .map(\.newValue)
            .map { $0 != .never }
            .removeDuplicates()

        // Publisher for the current screen UUID (non-nil, distinct)
        let screenPublisher = $screenUUID
            .compactMap { $0 }
            .removeDuplicates()

        // Publisher for fullscreen status dictionary
        let fullscreenStatusPublisher = detector.$fullscreenStatus
            .removeDuplicates()

        Publishers.CombineLatest3(screenPublisher, fullscreenStatusPublisher, enabledPublisher)
            .map { screenUUID, fullscreenStatus, enabled in
                let isFullscreen = fullscreenStatus[screenUUID] ?? false
                return enabled && isFullscreen
            }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] shouldHide in
                withAnimation(.smooth) {
                    self?.hideOnClosed = shouldHide
                }
            }
            .store(in: &cancellables)

        // An app going full screen on this display lets a held island go (closing ends editing too).
        // Only an open one: what holds it is shared, and closing a closed island still resets things.
        Publishers.CombineLatest(screenPublisher, detector.$anyFullscreen)
            .map { screenUUID, screens in screens.contains(screenUUID) }
            .removeDuplicates()
            .filter { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.notchState == .open, self.pinnedOpen || QuickLaunch.shared.editing else { return }
                self.close()
            }
            .store(in: &cancellables)

        // A pinned widget closed by full screen, locking or a display change comes back after, and after a restart.
        Publishers.CombineLatest4($notchState, Defaults.publisher(keys: .pinnedWidget, .compactMode),
                                  detector.$anyFullscreen, coordinator.$screenLocked)
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] state, _, fullscreen, _ in
                guard let self, state == .closed, self.widgetAlone != nil,
                      !fullscreen.contains(self.screenUUID ?? "") else { return }
                withAnimation(StandardAnimations.open) { _ = self.open() }
            }
            .store(in: &cancellables)
    }

    // Computed property for effective notch height
    var effectiveClosedNotchHeight: CGFloat {
        let currentScreen = screenUUID.flatMap { NSScreen.screen(withUUID: $0) }
        let noNotchAndFullscreen = hideOnClosed && (currentScreen?.safeAreaInsets.top ?? 0 <= 0 || currentScreen == nil)
        return noNotchAndFullscreen ? 0 : closedNotchSize.height
    }

    private var screen: NSScreen? { screenUUID.flatMap { NSScreen.screen(withUUID: $0) } ?? NSScreen.main }

    /// Its display or the style changed: the floating island follows, open or closed.
    func measureDisplay() {
        let measured = FloatingIsland.on(screen)
        if measured != floating { floating = measured }
    }

    /// An activity's symbol or artwork in the closed island: the bar less its margins, or the capsule's.
    var closedItemSize: CGFloat {
        if let floating { return max(0, floating.capsuleHeight - 6) }
        return max(0, effectiveClosedNotchHeight - 12)
    }

    /// Between an activity's two sides: the camera's width on the notch; a short gap in the capsule.
    var closedMiddleWidth: CGFloat {
        floating == nil ? closedNotchSize.width - cornerRadiusInsets.closed.top : FloatingIsland.middle
    }

    var cutoutWidth: CGFloat? {
        notchCutoutWidth(for: screen)
    }

    /// Whether the current screen has a notch (safe area top inset > 0)
    var hasNotch: Bool {
        let currentScreen = screenUUID.flatMap { NSScreen.screen(withUUID: $0) } ?? NSScreen.main
        return (currentScreen?.safeAreaInsets.top ?? 0) > 0
    }

    var chinHeight: CGFloat {
        if !Defaults[.hideTitleBar] {
            return 0
        }

        guard let currentScreen = screenUUID.flatMap({ NSScreen.screen(withUUID: $0) }) else {
            return 0
        }

        // The floating island's hover area is the menu bar's full height already.
        if notchState == .open || floating != nil { return 0 }

        let menuBarHeight = currentScreen.frame.maxY - currentScreen.visibleFrame.maxY
        let currentHeight = effectiveClosedNotchHeight

        if currentHeight == 0 { return 0 }

        return max(0, menuBarHeight - currentHeight)
    }

    func toggleCameraPreview() {
        switch camera.state {
        case .running, .interrupted:
            camera.stopSession()
        case .stopped, .unavailable, .failed:
            if camera.cameraAvailable {
                camera.startSession(for: self)
            }

        case .permissionDenied:
            DispatchQueue.main.async {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)

                let alert = NSAlert()
                alert.messageText = NSLocalizedString("Camera Access Required", comment: "Camera permission alert title")
                alert.informativeText = NSLocalizedString("Please allow camera access in System Settings.", comment: "Camera permission alert message")
                alert.addButton(withTitle: NSLocalizedString("Open Settings", comment: "Button title that opens app or system settings"))
                alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel button title"))

                if alert.runModal() == .alertFirstButtonReturn {
                    SystemSettings.open(.camera)
                }

                NSApp.setActivationPolicy(.accessory)
                NSApp.deactivate()
            }

        case .permissionRequired:
            camera.requestAccess()

        case .requestingPermission, .starting:
            break
        }
    }

    func isMouseHovering(position: NSPoint = NSEvent.mouseLocation) -> Bool {
        let screenFrame = getScreenFrame(screenUUID)
        if let frame = screenFrame {
            let baseY = frame.maxY - notchSize.height
            let baseX = frame.midX - notchSize.width / 2

            return position.y >= baseY && position.x >= baseX && position.x <= baseX + notchSize.width
        }

        return false
    }

    @discardableResult
    func open() -> Bool {
        guard !coordinator.firstLaunch || coordinator.touring, notchState != .open else { return false }
        // On the lock screen the notch shows a padlock and nothing more.
        guard !coordinator.screenLocked || Defaults[.showOnLockScreen] else { return false }

        self.notchSize = openNotchSize
        openings += 1
        self.notchState = .open

        // Force music information update when notch is opened
        MusicManager.shared.forceUpdate()

        return true
    }

    func close() {
        // Do not close while a share picker or sharing service is active
        if SharingStateManager.shared.preventNotchClose {
            return
        }
        // Closed mid-tour any way at all (Escape, the shortcut, a drag): it was skipped.
        if coordinator.touring { coordinator.finishFirstRun() }
        // The camera is on-demand: the notch closing always ends capture.
        // Intent clears too, so no recovery path can reopen it while closed.
        // (Only this island's: another display's may be showing its mirror.)
        camera.stopSession(for: self)
        measureDisplay()
        self.notchSize = getClosedNotchSize(screenUUID: self.screenUUID)
        self.closedNotchSize = self.notchSize
        self.notchState = .closed
        self.isPopoverActive = false
        self.isPinned = false
        if HUDPresenter.shared.shouldShowSneakPeek(on: self.screenUUID) {
            HUDPresenter.shared.toggleSneakPeek(status: false, type: .music, targetScreenUUID: self.screenUUID)
        }
        self.edgeAutoOpenActive = false

        // "Remember last tab" wins over the shelf default; an activity's page comes back from the island
        // (see viewOnOpen), not from here.
        if coordinator.openLastTabByDefault {
            coordinator.currentView = coordinator.reopenView
        } else if Defaults[.shelfEnabled] && !ShelfStateViewModel.shared.isEmpty && Defaults[.openShelfByDefault] {
            coordinator.currentView = .shelf
        } else {
            coordinator.currentView = .home
        }
    }

    /// Closed on purpose (the shortcuts, or Done on a Scratchpad-shortcut note): a pinned widget goes too.
    func closeDeliberately() {
        if widgetAlone != nil { WidgetPin.shared.set(nil) }
        close()
    }

    /// Escape: ends editing (widgets, then Quick Launch), then unpins a pinned widget showing; over a call
    /// or a request on the pinned island brings the widget back; then closes (over a notification, the widget comes back).
    func escape() {
        if coordinator.editingWidgets {
            coordinator.setEditingWidgets(false)
        } else if QuickLaunch.shared.editing {
            withAnimation(.snappy(duration: 0.3)) { QuickLaunch.shared.editing = false }
        } else if let ask = shownAsk {
            withAnimation(StandardAnimations.open) { AgentAsks.shared.dismiss(ask) }
        } else if pinnedAlone != nil {
            WidgetPin.shared.set(nil)
        } else if pinnedTakeover {
            withAnimation(StandardAnimations.open) { WidgetPin.shared.chosen = .now }
        } else {
            close()
        }
    }
}
