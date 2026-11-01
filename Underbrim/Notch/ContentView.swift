//
//  ContentView.swift
//  Underbrim
//
//  Created by Harsh Vardhan Goswami  on 02/08/24
//  Modified by Richard Kunkli on 24/08/2024.
//

import AVFoundation
import Combine
import Defaults
import KeyboardShortcuts
import SwiftUI
import SwiftUIIntrospect

@MainActor
struct ContentView: View {
    @EnvironmentObject var vm: NotchViewModel
    @ObservedObject var coordinator = NotchViewCoordinator.shared
    @ObservedObject var hud = HUDPresenter.shared
    @ObservedObject var musicManager = MusicManager.shared
    @ObservedObject var batteryModel = BatteryStatusViewModel.shared
    @ObservedObject var notificationManager = SystemNotificationManager.shared
    @State var activities = ActivitySelection()
    @State var swapping = false
    /// Counts swaps, so only the latest one's end clears `swapping`.
    @State var swaps = 0
    /// Bumped when the island leaves Home for pinned Quick Launch's row and back, so the one left
    /// comes back as a new view rather than the same one still leaving.
    @State var homeTurns = (home: 0, row: 0)
    /// A bubble drag passes over the island; it doesn't open until the pointer has left it once.
    @State var bubbleDragging = false
    /// The island has nearly closed: the bubble returns at its edge, not over its still-wide body.
    @State var bubbleReady = false
    @State var holdHoverUntilExit = false
    /// One that arrived while the notch was open on something else: given its full time once closed.
    @State var unseenNotification: String?
    @State var hoverTask: Task<Void, Never>?
    @State var isHovering: Bool = false
    @State var hudDragging = false
    /// The last key press the HUD's brim light glowed for, so it doesn't glow again after a hover or drag.
    @State var hudLit = Date.distantPast
    @State var openHUDExpanded = false
    @State var openHUDCollapse: Task<Void, Never>?
    @State var compactDotsShown = false
    @State var compactDots: Task<Void, Never>?
    /// An automatic close was skipped for a hold (a menu, say); when the hold ends, it's tried again.
    @State var closeSkipped = false
    @State private var anyDropDebounceTask: Task<Void, Never>?
    @State var pointerWatch = IslandPointerWatch()
    @State private var pinHold = PinHold()
    let pageSwipe = PageSwipe.shared
    /// Lives as long as the notch's window, so a Quick Look opened from the island outlives its close.
    @StateObject private var quickLook = QuickLookService()
    @State private var openContentLive = false
    /// The floating island's surface (FloatingIsland): set apart from the change that hides it, so its fade
    /// doesn't take over the outline's spring.
    @State private var floatingShown = true
    /// The fill under it, below the band: only while the surface is opaque, or the two would darken each other.
    @State private var floatingSolid = true
    @State private var clipboardBrowse = ClipboardBrowse()

    @State var haptics: Bool = false
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    @Namespace var albumArtNamespace

    @Default(.showNotHumanFace) var showNotHumanFace
    /// Read through vm.openView; here so turning it on or off redraws the pinned island.
    @Default(.showAgentActivity) private var showAgentActivity
    @Default(.showDownloadActivity) var showDownloadActivity
    // Observed so turning Quick Launch or compact mode off lets a pinned row go at once.
    @Default(.showQuickLaunch) private var showQuickLaunch
    @Default(.compactMode) private var compactMode
    /// Read through vm.compactWidget; here so a new choice redraws the compact island.
    @Default(.compactWidget) private var compactWidgetChoice
    /// Observed: the mirror turned off in Settings stops the camera at once.
    @Default(.showMirror) private var showMirror
    let askStore = AgentAsks.shared
    /// Also read through vm.shownAsk.
    @Default(.openIslandForAgentRequests) var showsAsks
    @State var openedForAsk = false
    /// The question's size on the island: the room the island keeps, empty, while it folds after the last one.
    @State var askSize: CGSize = .zero
    private let timer = TimerModel.shared
    private let callActivity = CallActivity.shared
    let statusFlash = StatusFlash.shared
    private let prayerStore = PrayerTimesStore.shared
    let menus = MenuTracking.shared
    private let quickLaunch = QuickLaunch.shared

    // Use standardized animations from StandardAnimations enum
    let animationSpring = StandardAnimations.interactive

    // MARK: - Corner Radius Scaling
    private var cornerRadiusScaleFactor: CGFloat? {
        guard Defaults[.cornerRadiusScaling] else { return nil }
        let effectiveHeight = displayClosedNotchHeight
        guard effectiveHeight > 0 else { return nil }
        return effectiveHeight / 38.0
    }

    /// The closed flare: the cutout's own on a notched display, so the idle notch vanishes behind it.
    private var closedTopRadius: CGFloat {
        if vm.hasNotch { return NotchMetrics.cutoutTopRadius(height: displayClosedNotchHeight) }
        if vm.floating != nil { return 0 }
        let baseClosedTop = cornerRadiusInsets.closed.top
        guard let scaleFactor = cornerRadiusScaleFactor else {
            return displayClosedNotchHeight > 0 ? baseClosedTop : 0
        }
        return max(0, baseClosedTop * scaleFactor)
    }

    private var closedBottomRadius: CGFloat {
        if showsHUD, let radius = NotchHUD.bottomRadius(expanded: hudExpanded, nudge: hud.hudNudge) { return radius }
        if vm.hasNotch { return NotchMetrics.cutoutBottomRadius(height: displayClosedNotchHeight) }
        // Floating: a capsule.
        if vm.floating != nil { return displayClosedNotchHeight / 2 }
        let baseClosedBottom = cornerRadiusInsets.closed.bottom
        if let scaleFactor = cornerRadiusScaleFactor {
            return max(0, baseClosedBottom * scaleFactor)
        }
        return displayClosedNotchHeight > 0 ? baseClosedBottom : 0
    }

    var currentNotchShape: IslandShape {
        vm.notchState == .open
            ? IslandShape(topRadius: NotchMetrics.openTopRadius, bottomRadius: islandAlone ? Self.pinnedRadius : NotchMetrics.openBottomRadius,
                          floating: vm.floating != nil)
            : IslandShape(topRadius: closedTopRadius, bottomRadius: closedBottomRadius, floating: vm.floating != nil)
    }

    /// Floating with nothing to show (or closed beside Apple's island): the shape is there for the pointer, not drawn.
    var floatingHidden: Bool {
        vm.floating != nil && vm.notchState == .closed && (closedNotchContent == .idle || steppingAside)
    }

    /// Closed on a display with Apple's own island: nothing over it, nothing to point at.
    var steppingAside: Bool { vm.notchState == .closed && vm.floating?.besideAppleIsland == true }

    static let catchWindow: TimeInterval = 0.2

    /// Coming straight back onto the still visible outline just after leaving the open island reopens it
    /// mid-close (only where hovering opens it). Escape, the shortcut, a drop or locking don't set
    /// `leftOpenAt`. The point is in the island frame's coordinates.
    private func closingOutlineContains(_ point: CGPoint) -> Bool {
        guard vm.notchState == .closed, Date.now.timeIntervalSince(pointerWatch.leftOpenAt) < Self.catchWindow,
              opensOnHover else { return false }
        let open = pointerWatch.openFrame, island = pointerWatch.islandFrame
        let shape = IslandShape(topRadius: NotchMetrics.openTopRadius, bottomRadius: pointerWatch.openBottomRadius,
                                floating: vm.floating != nil)
        return shape.path(in: CGRect(origin: .zero, size: open.size))
            .contains(CGPoint(x: point.x + island.minX - open.minX, y: point.y + island.minY - open.minY))
    }

    /// Pointing opens the closed island: Open on Hover is on, no HUD, peek or Now Playing notice, no dragged bubble.
    var opensOnHover: Bool {
        !shouldDisplayNowPlayingFallbackNotice && !showsPeek
            && !bubbleDragging && !holdHoverUntilExit && Defaults[.openNotchOnHover]
    }

    private var mirrorOnScreen: Bool {
        vm.notchState == .open && vm.openView == .home && vm.openNotification == nil && !coordinator.editingWidgets && showMirror
            && (vm.widgetAlone ?? (compactMode ? vm.compactWidget : nil)).map { $0 == .mirror } ?? true
    }

    var compactAlone: HomeWidget? {
        guard vm.notchState == .open, vm.widgetAlone == nil, vm.openNotification == nil, compactMode,
              !Self.compactPages.contains(vm.openView), vm.shownAsk == nil, !foldingAfterAsks else { return nil }
        return vm.compactWidget
    }

    /// The last question just went from an island that opened for it: until it folds back (closeAfterAsks,
    /// right after), it shows nothing at the question's size, rather than springing toward the page under the
    /// question, or toward an empty island smaller than the closed one, first.
    var foldingAfterAsks: Bool { openedForAsk && vm.notchState == .open && askStore.current == nil }

    /// The island is one thing on its own (a widget or a question): it hugs it, rounder and closer.
    private var islandAlone: Bool { shownAlone != nil || vm.shownAsk != nil || foldingAfterAsks }

    private var shownAlone: HomeWidget? { vm.pinnedAlone ?? compactAlone }

    private var pinnedRow: Bool { shownAlone == .quickLaunch }

    private var pinnedOSD: Bool { vm.pinnedAlone != nil && hud.showsOpenOSD(on: vm.screenUUID) }

    /// A call already going when the widget was pinned: shown in the band, as on the closed island.
    var pinnedCall: CallActivity.Call? { vm.pinnedAlone != nil ? callActivity.call : nil }

    private static let pinnedRadius: CGFloat = 18
    /// Below a pinned widget other than Quick Launch, whose row has room enough of its own.
    private static let aloneBottom: CGFloat = 8
    private static let pinnedInset: CGFloat = 8

    private let closedHorizontalPadding = cornerRadiusInsets.closed.bottom
    /// Closed, between the outline's sides and the content: less inside the floating capsule's round ends.
    private var closedSidePadding: CGFloat { vm.floating == nil ? closedHorizontalPadding : FloatingIsland.edge }

    var bandHeight: CGFloat { max(displayClosedNotchHeight, 26) }

    /// Atoll's 420 base less 20%, near their Dynamic Island's 340.
    let compactPanelWidth: CGFloat = 336

    /// Compact mode drops the tab bar along with the tabs it switches
    /// between — there's only the player to show, so a switcher would have
    /// nothing to switch to. Also what keeps the panel narrow, since the
    /// header spans the full notch width.
    private var showsHeader: Bool {
        vm.notchState == .open
            && vm.openNotification == nil
            && !Defaults[.compactMode]
            && vm.widgetAlone == nil
            && coordinator.currentView != .welcome
            && vm.shownAsk == nil
            && !foldingAfterAsks
    }

    /// The activity currently on top of the stack — what the chin has to be
    /// sized for.
    var selectedActivity: LiveActivityItem? {
        let items = ActivityFeed.items
        guard let top = activities.top(of: items.map(\.id)) else { return nil }
        return items.first { $0.id == top }
    }

    var liveTabs: [TabModel] {
        var tabs: [TabModel] = []
        for item in ActivityFeed.items {
            guard let view = item.page, !NotchViews.tabs.contains(view), !tabs.contains(where: { $0.view == view }) else { continue }
            if case .call(let call) = item {
                tabs.append(TabModel(label: AppInfo.name(bundleID: call.app) ?? call.app, icon: call.symbol, view: view))
            } else {
                tabs.append(TabModel(label: view.title, icon: view.symbol, view: view))
            }
        }
        // The page on show keeps its tab after its activity ends, or when it never had one (Prayer from its widget).
        let shown = coordinator.currentView
        if shown != .welcome, !NotchViews.tabs.contains(shown), !tabs.contains(where: { $0.view == shown }) {
            tabs.append(TabModel(label: shown.title, icon: shown.symbol, view: shown))
        }
        return tabs
    }

    // If the closed notch height is 0 (any display/setting), display a 10pt nearly-invisible notch
    // instead of fully hiding it. This preserves layout while avoiding visual artifacts.
    var isNotchHeightZero: Bool { vm.effectiveClosedNotchHeight == 0 }

    var displayClosedNotchHeight: CGFloat { isNotchHeightZero ? 10 : vm.effectiveClosedNotchHeight }

    var body: some View {
        @Bindable var dropInteraction = vm.dropInteraction

        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                let mainLayout = NotchLayout()
                    .frame(alignment: .top)
                    // Open: one margin all round, inside the flares; the HUD measures its ears from the island's edge.
                    .padding(
                        .horizontal,
                        vm.notchState == .open
                            ? NotchMetrics.openTopRadius + (islandAlone ? Self.pinnedInset : NotchMetrics.margin)
                            : showsHUD ? 0 : closedSidePadding
                    )
                    .padding(.bottom, vm.notchState != .open ? 0 : openHUDSlider ? NotchMetrics.margin : pinnedRow ? 0 : islandAlone ? Self.aloneBottom : NotchMetrics.margin)
                    .background {
                        NotchSurface(shape: currentNotchShape, isOpen: vm.notchState == .open, bandHeight: bandHeight)
                            .opacity(floatingShown ? 1 : 0)
                    }
                    .clipShape(currentNotchShape)
                    .overlayPreferenceValue(QuickLaunchFloatKey.self) { QuickLaunchFloatsView(floats: $0) }
                    // For the pointer watch; a plain property, so no re-render.
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                        pointerWatch.islandFrame = frame
                        if vm.notchState == .open {
                            pointerWatch.openFrame = frame
                            pointerWatch.openBottomRadius = currentNotchShape.bottomRadius
                        }
                    }
                          .overlay(alignment: .top) {
                              displayClosedNotchHeight.isZero && vm.notchState == .closed || vm.floating != nil ? nil
                        : Rectangle()
                            .fill(.black)
                            .frame(height: 1)
                            .padding(.horizontal, currentNotchShape.topRadius)
                    }
                    // Open only (closed, the outline must vanish behind the cutout), and below the menu-bar band,
                    // where it would haze the flares and darken and catch clicks on the menu bar.
                    .background {
                        currentNotchShape
                            .fill(.black)
                            .shadow(color: (vm.notchState == .open && Defaults[.enableShadow]) ? .black.opacity(0.7) : .clear,
                                    radius: 6)
                            .mask {
                                Rectangle().padding(EdgeInsets(top: bandHeight, leading: -20, bottom: -20, trailing: -20))
                            }
                            .opacity(floatingSolid ? 1 : 0)
                    }
                    // Removed conditional bottom padding when using custom 0 notch to keep layout stable
                    .opacity((isNotchHeightZero && vm.notchState == .closed) ? 0.01 : 1)

                mainLayout
                    .animation(vm.notchState == .open ? StandardAnimations.open : StandardAnimations.close, value: vm.notchState)
                    // Outermost on purpose: it fires only when the closed content changes, and with several keys
                    // changing the innermost animation wins, so the open/close springs keep precedence.
                    .animation(reduceMotion ? .easeOut(duration: 0.18) : .smooth(duration: 0.3), value: closedNotchContent)
                    // The outline, not its bounding box: past the flares is the menu bar, and pointing there leaves the notch.
                    .contentShape(currentNotchShape)
                    .onContinuousHover(perform: openHUDHover)
                    // Hover comes from the pointer watch alone, so two sources can't disagree.
                    .onHover { _ in pointerWatch.update() }
                    .background(alignment: .top) { floatingCatcher }
                    // Moves over the menu bar beside the notch never reach onHover; the watch reports them.
                    .background(WindowReader { window in
                        pointerWatch.window = window
                        pinHold.watch(window)
                    })
                    .onAppear {
                        pointerWatch.start(contains: { point in
                            let size = pointerWatch.islandFrame.size
                            if let floating = vm.floating {
                                if steppingAside { return false }
                                // The gap above counts, and closed, the whole menu bar's height: a flung pointer stops at the edge.
                                let below = vm.notchState == .closed ? max(0, floating.menuBar - floating.top - size.height) : 0
                                if point.x >= 0, point.x <= size.width, point.y >= -FloatingIsland.gap, point.y < size.height + below,
                                   vm.notchState == .closed || point.y < 0 { return true }
                            }
                            if currentNotchShape.path(in: CGRect(origin: .zero, size: size)).contains(point) { return true }
                            if closingOutlineContains(point) { return true }
                            // "Hide title bar": the clear chin below the closed notch, down to the menu bar's
                            // edge, never wider than the island (or below the menu bar when it's taller).
                            return vm.chinHeight > 0 && point.y >= size.height && point.y < vm.effectiveClosedNotchHeight + vm.chinHeight
                                && abs(point.x - size.width / 2) <= min(computedChinWidth, size.width) / 2
                        }, onChange: handleHover, onHoldDropped: holdEnded)
                        // Not while editing (a press drags there), on the lock screen, or closed.
                        pinHold.allowed = { [vm, coordinator] in
                            vm.notchState == .open && !coordinator.editingWidgets && !coordinator.screenLocked && !QuickLaunch.shared.editing
                        }
                    }
                    .onDisappear {
                        pointerWatch.stop()
                        pinHold.stop()
                    }
                    .onTapGesture {
                        if vm.notchState == .closed && !shouldDisplayNowPlayingFallbackNotice && !steppingAside {
                            doOpen()
                        }
                    }
                    // Nothing here may come and go with a setting: rebuilding the island runs the new onAppear
                    // before the old onDisappear, which stops the pointer watch for good.
                    .onReceive(NotificationCenter.default.publisher(for: .sharingDidFinish)) { _ in
                        scheduleCloseIfNotHovering(overNotch: vm)
                    }
                    // A new notification always takes the front of the stack,
                    // even if the user had swiped away to music.
                    .onChange(of: notificationManager.activeNotification?.id) { oldID, newID in
                        if newID != nil { bringForward(.notification) }
                        if oldID != nil, oldID == vm.notificationAtOpen {
                            // Its card stepped to the next one (+1, ×): it follows (on show already, see openNotification).
                            withAnimation(StandardAnimations.open) { vm.notificationAtOpen = newID }
                        } else if newID != nil, vm.notchState == .open, vm.widgetAlone != nil {
                            // Over a pinned widget: the island morphs to the card on its spring, as it does back.
                            withAnimation(StandardAnimations.open) { vm.notificationAtOpen = newID }
                        } else if newID != nil, vm.notchState == .open {
                            unseenNotification = newID
                            notificationManager.holdActive()
                        }
                    }
                    // Something that starts comes forward; one that ends goes back to its place.
                    .onChange(of: ActivityFeed.starts) { old, new in
                        for kind in ActivityFeed.startOrder where old[kind] != new[kind] {
                            if new[kind] != nil { bringForward(kind) } else { release(kind) }
                        }
                    }
                    .modifier(AgentAsksOpening(current: askStore.current?.page, locked: coordinator.screenLocked,
                                               open: openForAsk, close: closeAfterAsks))
                    .onChange(of: ActivityFeed.items.map(\.id), initial: true) { _, ids in
                        activities.update(ids: ids)
                    }
                    // Opened some other way (a drag, the keyboard), it isn't opened on a notification.
                    .onChange(of: vm.notchState) { _, state in
                        guard state == .closed else { return }
                        // Closed while still held (the keyboard, say): the pointer leaving won't resume it.
                        if notificationManager.isUserPresent, !isHovering { resumeNotificationDismiss() }
                        vm.notificationAtOpen = nil
                        closeSkipped = false
                        pointerWatch.releaseMenuHold()
                        menus.closeAll()
                    }
                    .onChange(of: vm.isPopoverActive) { _, _ in
                        scheduleCloseIfNotHovering(overNotch: vm)
                    }
                    .sensoryFeedback(.alignment, trigger: haptics)
                    .contextMenu {
                        // Its controls otherwise live in the Timer widget, which may be off Home (or compact mode on).
                        if timer.mode != .idle && !timer.isFinished {  // paused too: then nothing else on the closed notch can stop it
                            Button("Stop Timer") { timer.reset() }
                            Divider()
                        }
                        Toggle(String(localized: "Keep Open"), isOn: Binding(get: { vm.isPinned }, set: { pinned in
                            // Not a pin on an island that can't open (the lock screen).
                            if pinned, vm.notchState == .closed, !doOpen() { return }
                            vm.isPinned = pinned
                        }))
                        Button("Settings") {
                            DispatchQueue.main.async {
                                SettingsWindowController.shared.showWindow()
                            }
                        }
                        .keyboardShortcut(KeyEquivalent(","), modifiers: .command)
                        // Where people look for it: the menu bar icon can be hidden, and isn't Underbrim's mark.
                        Divider()
                        Button(String(localized: "Quit Underbrim")) { NSApp.terminate(nil) }
                            .keyboardShortcut(KeyEquivalent("q"), modifiers: .command)
                    }
                    // Outside the outline, so after its clip and gestures: from its trailing edge, growing outward.
                    .overlay(alignment: .topTrailing) {
                        ZStack(alignment: .leading) {
                            if let item = bubbleActivity {
                                ActivityBubble(item: item, size: displayClosedNotchHeight, open: { open(on: item) },
                                               swap: { swap(to: item) }, dragging: bubbleDragged)
                                    .fixedSize()
                                    .offset(x: 6)
                                    // One bubble per activity, so a swap replaces it.
                                    .id(item.id)
                                    .transition(reduceMotion ? .opacity : .scale(scale: 0.3, anchor: .leading).combined(with: .opacity))
                            }
                        }
                        .frame(width: 0, alignment: .leading)
                    }
                    .animation(.smooth(duration: 0.3), value: bubbleActivity?.id)
                    // When the closed content comes back (StandardAnimations.closedContent).
                    .task(id: vm.notchState) {
                        guard vm.notchState == .closed else { bubbleReady = false; return }
                        guard (try? await Task.sleep(for: .seconds(0.22 / Defaults[.animationSpeedMultiplier]))) != nil else { return }
                        withAnimation(.smooth(duration: 0.3)) { bubbleReady = true }
                    }
                    // The bubble went or changed mid-drag: the drag is over for the island too.
                    .onChange(of: bubbleActivity?.id) { _, _ in
                        if bubbleDragging { bubbleDragged(false) }
                    }
                    .overlay {
                        firstRunGlint
                        hudBrimLight
                    }
                    .modifier(RimLights(shape: currentNotchShape, open: vm.notchState == .open,
                                        bandHeight: bandHeight, pluggedIn: batteryModel.isPluggedIn, pluggedInAt: batteryModel.pluggedInAt,
                                        unpluggedAt: batteryModel.unpluggedAt, lowBatteryAt: batteryModel.lowBatteryAt,
                                        adhanAt: prayerStore.arrived?.at, padlock: showsLockedPadlock,
                                        hidden: vm.hideOnClosed || isNotchHeightZero || steppingAside))
                    // initial: a notch window that appears after the start still opens.
                    .onChange(of: coordinator.firstRunStart, initial: true) { _, start in
                        let window = pointerWatch.window as? NotchSkyLightWindow
                        guard start != nil, isTargetDisplay else {
                            // Also when it isn't key (Open Settings took it): left on, the next click in the
                            // island would make it key and hold it open as if typing.
                            if start == nil, let window, window.wantsKeyForTextInput {
                                let hadFocus = window.isKeyWindow
                                window.wantsKeyForTextInput = false
                                if hadFocus { NSApp.deactivate() }
                            }
                            return
                        }
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(reduceMotion ? 0.2 : RimLight.Glint.duration))
                            guard coordinator.touring else { return }
                            openContentLive = true
                            // Even if a click already opened it: on the welcome card.
                            withAnimation(StandardAnimations.open) {
                                vm.open()
                                coordinator.currentView = .welcome
                            }
                            window?.wantsKeyForTextInput = true
                        }
                    }
                if vm.chinHeight > 0 {
                    Rectangle()
                        .fill(Color.black.opacity(0.01))
                        .frame(width: computedChinWidth, height: vm.chinHeight)
                }
            }
        }
        // Floating: a little below the screen's edge (below the menu bar beside Apple's island).
        .padding(.top, vm.floating?.top ?? 0)
        .padding(.bottom, 8)
        .frame(maxWidth: windowSize.width, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea(.all)
        .compositingGroup()
        .background(dragDetector)
        .preferredColorScheme(.dark)
        .tint(.notchAccent)
        .environment(\.liveTabs, liveTabs)
        .environment(\.islandPointerWatch, pointerWatch)
        .environmentObject(vm)
        .environmentObject(quickLook)
        .quickLookPresenter(using: quickLook)
        .onChange(of: dropInteraction.anyDropZoneTargeting) { _, isTargeted in
            anyDropDebounceTask?.cancel()

            if isTargeted {
                if (Defaults[.shelfEnabled] || coordinator.viewForDrag == .home) && vm.notchState == .closed {
                    openContentLive = true  // a drop can't press anything
                    hoverTask?.cancel()
                    withAnimation(StandardAnimations.open) {
                        if vm.open() { coordinator.currentView = coordinator.viewForDrag }
                    }
                }
                return
            }

            anyDropDebounceTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }

                if dropInteraction.dropEvent {
                    dropInteraction.dropEvent = false
                    return
                }

                dropInteraction.dropEvent = false
                closeUnlessHeld()
            }
        }
        // The drag ended (dropped or cancelled): stay only if the pointer is on the notch.
        .onChange(of: dropInteraction.dragSession) { _, active in
            guard !active else { return openContentLive = true }
            pointerWatch.update()
            if pointerWatch.inside != true { closeUnlessHeld() }
        }
        .onChange(of: menus.isOpen) { _, open in if !open { holdEnded() } }
        .onChange(of: vm.heldOpen) { _, held in if !held { holdEnded() } }
        .onChange(of: quickLaunch.dragging) { _, dragging in if !dragging { holdEnded() } }
        // Let go as the pointer leaves, it goes at once (a press's timer was stopped while held).
        .onChange(of: hudHeld) { _, held in hud.holdSneakPeek(held, on: vm.screenUUID) }
        .onChange(of: openHUD) { _, showing in
            guard !showing else { return }
            openHUDCollapse?.cancel()
            openHUDCollapse = nil
            openHUDExpanded = false
        }
        // The island moved to another display: the hold goes with it, so the HUD it leaves hides on time.
        .onChange(of: vm.screenUUID) { old, new in
            hud.holdSneakPeek(false, on: old)
            if hudHeld { hud.holdSneakPeek(true, on: new) }
        }
        .onChange(of: vm.notchState == .closed && !vm.hideOnClosed && !steppingAside, initial: true) { _, can in statusFlash.setShowable(can, for: vm) }
        .onChange(of: vm.notchState == .open) { _, open in swipeBetweenPages(open) }
        // Out once it has shrunk back to the capsule; in at once as it grows.
        .onChange(of: floatingHidden, initial: true) { old, hidden in
            guard old != hidden else { return (floatingShown, floatingSolid) = (!hidden, !hidden) }
            withAnimation(hidden ? .easeIn(duration: 0.1).delay(0.22) : .easeOut(duration: 0.08)) { floatingShown = !hidden }
            withAnimation(.linear(duration: 0.01).delay(hidden ? 0.22 : 0.08)) { floatingSolid = !hidden }
        }
        .onDisappear {
            statusFlash.setShowable(false, for: vm)
            // Its display gone: a hold it took mustn't keep that screen's HUD from hiding later.
            hud.holdSneakPeek(false, on: vm.screenUUID)
        }
        .onChange(of: mirrorOnScreen) { _, shown in if !shown { vm.camera.stopSession(for: vm) } }
        // The mirror alone runs its camera only while the pointer is on the island (where it may run
        // at all: never asking for access on a hover), so its light isn't on the whole time it's pinned.
        .onChange(of: isHovering && shownAlone == .mirror) { _, pointing in
            if pointing {
                if vm.camera.authorizationStatus == .authorized { vm.camera.startSession(for: vm) }
            } else if shownAlone == .mirror {
                vm.camera.stopSession(for: vm)
            }
        }
        .onChange(of: vm.widgetAlone) { _, alone in
            if alone != nil { homeTurns.home += 1 } else { homeTurns.row += 1 }
            guard alone != nil else {
                // Unpinned elsewhere (another display's island, the keyboard): one the pointer isn't on closes.
                pointerWatch.update()
                if pointerWatch.inside != true, !hasKeyboard { closeUnlessHeld() }
                return
            }
            if let id = notificationManager.activeNotification?.id {
                withAnimation(StandardAnimations.open) { vm.notificationAtOpen = id }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
            if let window = note.object as? NSWindow, window === pointerWatch.window { holdEnded() }
        }
    }

    @ViewBuilder
    func NotchLayout() -> some View {
        @Bindable var dropInteraction = vm.dropInteraction

        VStack(alignment: .leading) {
            if vm.notchState == .closed {
            VStack(alignment: .leading) {
                    if steppingAside {
                        Rectangle().fill(.clear).frame(width: FloatingIsland.hoverWidth - 2 * closedSidePadding, height: displayClosedNotchHeight)
                    } else if showsLockedPadlock {
                        FlashLiveActivity(flash: SystemTouches.locked)
                    } else if shouldDisplayNowPlayingFallbackNotice,
                       let notice = musicManager.nowPlayingNotice {
                        NowPlayingFallbackNoticeView(notice: notice)
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                    } else if showsBatteryNotice {
                        HStack(spacing: 0) {
                            // 55–90 pt, where every English status falls: the row is centred as a whole, so the camera
                            // mustn't land over the percentage. A longer one shrinks, to 70% at most.
                            ClampedWidth(range: 55...90) {
                                Text(batteryModel.statusText)
                                    .font(.subheadline)
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                            }

                            Rectangle()
                                .fill(.black)
                                .frame(width: vm.floating == nil ? vm.closedNotchSize.width + 10 : FloatingIsland.middle)

                            HStack {
                                NotchBatteryView(
                                    batteryWidth: 30,
                                    isCharging: batteryModel.isCharging,
                                    isInLowPowerMode: batteryModel.isInLowPowerMode,
                                    isPluggedIn: batteryModel.isPluggedIn,
                                    levelBattery: batteryModel.levelBattery,
                                    maxAdapterWatts: batteryModel.maxAdapterWatts,
                                    isForNotification: true,
                                    fadesFromCharge: batteryModel.lastStatus == .plugged(false)
                                        && batteryModel.unpluggedAt.map { $0.timeIntervalSinceNow > -2 } ?? false
                                )
                            }
                            .frame(width: 76, alignment: .trailing)
                        }
                        .frame(height: displayClosedNotchHeight, alignment: .center)
                        } else if showsHUD {
                           NotchHUD(state: hud.binding(for: vm.screenUUID), expanded: hudExpanded) { dragging in
                               hudDragging = dragging
                               // No moves are seen during a drag: let go outside the island, it goes now.
                               if !dragging { pointerWatch.update() }
                           }
                              .transition(.asymmetric(insertion: .opacity, removal: .opacity.animation(.easeOut(duration: 0.1))))
                      } else if let flash = statusFlash.current, vm.notchState == .closed, !vm.hideOnClosed {
                          FlashLiveActivity(flash: flash, since: statusFlash.shownAt)
                              .transition(.opacity)
                      } else if !ActivityFeed.items.isEmpty && vm.notchState == .closed && !vm.hideOnClosed {
                          LiveActivityStack(items: ActivityFeed.items, selected: selectedActivity, swapping: swapping, pick: swap(to:)) { item in
                              switch item {
                              case .notification(let notification):
                                  NotificationLiveActivity(notification: notification)
                              case .agent(let summary):
                                  AgentLiveActivity(summary: summary)
                              case .meeting(let meeting):
                                  MeetingLiveActivity(meeting: meeting)
                              case .timer:
                                  TimerLiveActivity()
                              case .phone(let activity):
                                  PhoneActivityLiveActivity(activity: activity)
                              case .delivery(let order):
                                  DeliveryLiveActivity(order: order)
                              case .call(let call):
                                  CallLiveActivity(call: call)
                              case .prayer(let moment):
                                  PrayerLiveActivity(moment: moment)
                              case .download(let summary):
                                  DownloadLiveActivity(summary: summary)
                              case .headphones(let device):
                                  HeadphoneLiveActivity(device: device)
                              case .music:
                                  ClosedMusicActivity(height: displayClosedNotchHeight, notchWidth: vm.closedNotchSize.width,
                                                      scale: cornerRadiusScaleFactor, albumArtNamespace: albumArtNamespace,
                                                      floating: vm.floating != nil)
                                      .frame(alignment: .center)
                              }
                          }
                      } else if !hud.expandingView.show && vm.notchState == .closed && (!musicManager.isPlaying && musicManager.isPlayerIdle) && Defaults[.showNotHumanFace] && !vm.hideOnClosed {
                          NotchFaceAnimation()
                       }
                        // Floating and idle: the capsule where pointing opens it, not drawn.
                        else if vm.floating != nil {
                           Rectangle().fill(.clear).frame(width: FloatingIsland.hoverWidth - 2 * closedSidePadding, height: displayClosedNotchHeight)
                       }
                        // Without a notch: as tall as the height set for those displays (as upstream).
                        else if !vm.hasNotch {
                           Rectangle().fill(.clear).frame(width: vm.closedNotchSize.width - 20, height: displayClosedNotchHeight)
                       } else {
                           // Idle: exactly the camera cutout, so it disappears.
                           Rectangle().fill(.clear)
                               .frame(width: max(0, (vm.cutoutWidth ?? vm.closedNotchSize.width - 20 + 2 * closedHorizontalPadding)
                                                    - 2 * closedHorizontalPadding),
                                      height: displayClosedNotchHeight)
                       }

                        // Old sneak peek music
                        if !showsLockedPadlock, showsMusicPeekRow, vm.notchState == .closed, !vm.hideOnClosed {
                                   HStack(alignment: .center) {
                                       Image(systemName: "music.note")
                                       GeometryReader { geo in
                                           MarqueeText(musicManager.songTitle + " - " + musicManager.artistName, color: Defaults[.playerColorTinting] ? Color(nsColor: musicManager.avgColor).ensureMinimumBrightness(factor: 0.6) : .gray, delayDuration: 1.0, frameWidth: geo.size.width)
                                       }
                                   }
                                   .foregroundStyle(.gray)
                                   .padding(.bottom, 10)
                        }
                      }
                      // A flag, not a modifier that comes and goes, which would rebuild the closed content at every HUD.
                      .fixedSize(horizontal: peekFixesSize, vertical: peekFixesSize)
                      .zIndex(1)
                      .transition(StandardAnimations.closedContent)
            }
            if vm.notchState == .open {
                let pinnedBand = pinnedOSD || pinnedCall != nil
                OpenNotchLayout(cutoutGap: cutoutGap, bandHeight: bandHeight, spacing: NotchMetrics.bandSpacing,
                                current: openContentKey, showsHeader: showsHeader || pinnedBand, hugsContent: islandAlone) {
                    if showsHeader {
                        // Above the page, which a button's hover name (HoverName) hangs over.
                        NotchHeader.Leading().notchSlot(.leading).transition(StandardAnimations.aroundPlayer).zIndex(1)
                        NotchHeader.Trailing().notchSlot(.trailing).transition(StandardAnimations.aroundPlayer).zIndex(1)
                    } else if pinnedBand {
                        if let call = pinnedCall {
                            HStack(spacing: 6) {
                                Image(systemName: call.symbol)
                                    .font(.notchSymbol(size: 12))
                                    .frame(width: 20)
                                    .accessibilityLabel(call.spokenText)
                                Text(call.since, style: .timer)
                                    .font(.notchCaption.weight(.semibold).monospacedDigit())
                                    .lineLimit(1)
                            }
                            .foregroundStyle(call.tint)
                            .notchSlot(.leading)
                            .transition(.opacity)
                        }
                    }
                    if openHUD {
                        OpenHUDSymbol(state: hud.binding(for: vm.screenUUID))
                            .notchSlot(.besideCamera)
                            .transition(.opacity.animation(.easeOut(duration: 0.15)))
                    }
                    if openHUDSlider {
                        OpenHUDSlider(state: hud.binding(for: vm.screenUUID), screenUUID: vm.screenUUID) { dragging in
                            hudDragging = dragging
                            // Let go off the slider's row: it goes after a moment, as when the pointer leaves it.
                            if !dragging { openHUDHover(.ended) }
                        }
                        .notchSlot(.below)
                        .transition(reduceMotion ? .opacity.animation(.easeOut(duration: 0.12))
                            : .asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.15).delay(0.15)),
                                          removal: .opacity.animation(.easeOut(duration: 0.08))))
                    }
                    openTab
                        .followsPageSwipe()
                }
                .id(vm.openings)
                .environment(clipboardBrowse)
                .environment(pinHold)
                .transition(StandardAnimations.openContent)
                .onExitCommand { vm.escape() }
                .zIndex(1)
                // Controls arrive under the pointer as the notch opens, where a click meant to open it would press
                // them: live once it has settled (at once for a file drag).
                .allowsHitTesting(vm.notchState == .open && openContentLive)
                .task {
                    guard (try? await Task.sleep(for: .milliseconds(300))) != nil else { return }
                    openContentLive = true
                }
                .onDisappear { openContentLive = false }
            }
        }
    }

    /// Between the header's halves: the camera housing and its clearance; floating, there's no camera.
    var cutoutGap: CGFloat { (vm.floating == nil ? cutoutWidth : 0) + 2 * NotchMetrics.cutoutClearance }

    private var cutoutWidth: CGFloat { vm.cutoutWidth ?? vm.closedNotchSize.width }

    /// Pages compact mode still shows (its panel is otherwise just the player).
    static let compactPages: Set<NotchViews> = [.agents, .downloads, .meeting, .phoneActivities, .prayer, .welcome]
}

#Preview {
    let vm = NotchViewModel(camera: CameraModel())
    vm.open()
    return ContentView()
        .environmentObject(vm)
        .frame(width: vm.notchSize.width, height: vm.notchSize.height)
}
