//
//  ContentView+OpenContent.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The open island's page: a notification, a question, a widget alone or a tab, and the swipes
//  between them.
//

import Defaults
import SwiftUI

extension ContentView {
    /// Two fingers sideways change the page; in compact mode, the widget, with dots beside the camera.
    /// On a question, up sets the questions aside and closes the island, and sideways sets them aside for
    /// the page under them; they wait one swipe back from the first page.
    func swipeBetweenPages(_ open: Bool) {
        guard open, let window = pointerWatch.window else { return pageSwipe.stop(window: pointerWatch.window) }
        pageSwipe.start(window: window, pages: swipePages,
                        current: { vm.shownAsk.map { SwipePage.ask($0.id) } ?? compactAlone.map(SwipePage.widget) ?? .view(coordinator.currentView) },
                        onIsland: { pointerWatch.islandFrame.contains($0) },
                        lift: { asksLift }) { page in
            switch page {
            case .view(let view):
                if vm.shownAsk != nil { setAsksAsideForPage() }
                coordinator.selectTab(view)
            case .widget(let widget):
                if vm.shownAsk != nil { setAsksAsideForPage() }
                Defaults[.compactWidget] = widget
                showCompactDots()
            case .ask(let id):
                askStore.show(id)
            }
        }
    }

    private func swipePages() -> [SwipePage] {
        if vm.shownAsk != nil {
            let under = pageUnderAsks
            return [under] + askStore.all.map { SwipePage.ask($0.id) } + [under]
        }
        guard vm.openNotification == nil, !coordinator.screenLocked else { return [] }
        let back = showsAsks ? askStore.setAside.prefix(1).map { SwipePage.ask($0.id) } : []
        if vm.widgetAlone != nil { return back.isEmpty ? [] : back + [.view(coordinator.currentView)] }
        if Defaults[.compactMode] { return compactAlone == nil ? [] : back + HomeWidget.compactChoices.map(SwipePage.widget) }
        return back + (NotchViews.orderedTabs(Defaults[.tabOrder]).filter(\.isOn) + liveTabs.map(\.view)).map(SwipePage.view)
    }

    /// The page a question covers, which a sideways swipe goes on to.
    private var pageUnderAsks: SwipePage {
        if Defaults[.compactMode], vm.widgetAlone == nil, !Self.compactPages.contains(coordinator.currentView) {
            return .widget(vm.compactWidget)
        }
        return .view(coordinator.currentView)
    }

    /// What two fingers up do: on a question, set it aside. It says whether the island stayed open.
    private var asksLift: (() -> Bool)? {
        guard vm.shownAsk != nil else { return nil }
        return {
            setAsksAsideAndClose()
            return vm.notchState == .open
        }
    }

    /// Two fingers up on a question: every question waits for later, and the island folds back into the notch,
    /// unless something else holds it open (Keep Open, a pinned widget), which it then shows.
    private func setAsksAsideAndClose() {
        askStore.setAsideAll()
        openedForAsk = false
        if !vm.heldOpen { vm.close() }
    }

    /// Two fingers sideways on a question: the questions wait for later and the page under them stays.
    private func setAsksAsideForPage() {
        openedForAsk = false
        askStore.setAsideAll()
    }

    private func showCompactDots() {
        compactDots?.cancel()
        compactDotsShown = true
        compactDots = Task {
            guard (try? await Task.sleep(for: .seconds(1))) != nil else { return }
            compactDotsShown = false
        }
    }

    private var compactDotPages: AloneBand.Pages? {
        guard let widget = compactAlone else { return nil }
        let choices = HomeWidget.compactChoices
        guard choices.count > 1 else { return nil }
        return choices.firstIndex(of: widget).map { AloneBand.Pages(index: $0, count: choices.count) }
    }

    var openContentKey: String {
        if let notification = vm.openNotification { return "notification \(notification.id)" }
        if vm.shownAsk != nil || foldingAfterAsks { return "ask" }
        if let widget = vm.widgetAlone, vm.openView == .home { return "alone \(widget)" }
        if Defaults[.compactMode], !Self.compactPages.contains(vm.openView) { return "alone \(vm.compactWidget)" }
        return "\(vm.openView)"
    }

    /// A widget alone, pinned or compact: the same view, so pinning compact mode's widget only adds the pin.
    private func alone(_ widget: HomeWidget, change: AnyTransition) -> some View {
        HomeWidgetAlone(widget: widget, albumArtNamespace: albumArtNamespace,
                        band: AloneBand(gap: cutoutGap, height: bandHeight, spans: vm.floating != nil,
                                        taken: openHUD || pinnedCall != nil, pages: compactDotPages, showsPages: compactDotsShown))
            .id("alone \(widget) \(homeTurns.row)")
            .transition(change)
            .notchCoversBand()
            .notchSlot(.content(openContentKey))
    }

    @ViewBuilder var openTab: some View {
        let change = pageSwipe.entering == 0 ? StandardAnimations.pageChange : StandardAnimations.pageSwipe(entering: pageSwipe.entering)
        if let notification = vm.openNotification {
            NotificationExpandedView(notification: notification,
                                     holdsWhileShown: !(vm.widgetAlone != nil && pointerWatch.inside != true))
                .id(notification.id)
                .transition(change)
                .notchSlot(.content(openContentKey))
        } else if let ask = vm.shownAsk {
            let asks = askStore.all
            AgentAskIsland(ask: ask,
                           position: asks.count > 1 ? AloneBand.Pages(index: asks.firstIndex { $0.id == ask.id } ?? 0, count: asks.count) : nil,
                           band: AloneBand(gap: cutoutGap, height: bandHeight, spans: vm.floating != nil),
                           setAside: setAsksAsideAndClose)
                .id(ask.page)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { askSize = $0 }
                .transition(change)
                .notchCoversBand()
                .notchSlot(.content(openContentKey))
        } else if foldingAfterAsks {
            Color.clear
                .frame(width: max(askSize.width, 1), height: max(askSize.height, 1))
                .notchCoversBand()
                .notchSlot(.content(openContentKey))
        } else if let widget = vm.widgetAlone, vm.openView == .home {
            alone(widget, change: change)
        } else if Defaults[.compactMode], Self.compactPages.contains(vm.openView) {
            Group {
                switch vm.openView {
                case .downloads: DownloadsExpandedView()
                case .meeting: MeetingExpandedView(showsOthers: false)
                case .phoneActivities: PhoneActivitiesExpandedView()
                case .prayer: PrayerExpandedView()
                case .welcome: FirstRunTour()
                default: AgentsTabView(compact: true)
                }
            }
            // The tour and the prayer page keep their own width: squeezed to the panel they'd be cut off.
            .frame(width: vm.openView == .welcome || vm.openView == .prayer ? nil : compactPanelWidth)
            .transition(change)
            .notchSlot(.content(openContentKey))
        } else if Defaults[.compactMode], vm.widgetAlone == nil {
            // One widget on its own, as when pinned: no tabs or shelf in compact mode; two fingers sideways change it.
            alone(vm.compactWidget, change: change)
        } else {
            switch vm.openView {
            case .home:
                NotchHomeView(albumArtNamespace: albumArtNamespace)
                    .id(homeTurns.home)
                    .transition(change)
                    .notchMinimumWidth(homeWidth)
                    .notchSlot(.content("\(NotchViews.home)"))
            case .shelf:
                ShelfView(dropInteraction: vm.dropInteraction)
                .transition(change)
                .notchMinimumWidth(NotchMetrics.openContentWidth)
                .notchSlot(.content("\(NotchViews.shelf)"))
            case .clipboard:
                ClipboardPanel()
                    .transition(change)
                    .notchMinimumWidth(NotchMetrics.openContentWidth)
                    .notchSlot(.content("\(NotchViews.clipboard)"))
            case .agents:
                AgentsTabView(compact: false)
                    .transition(change)
                    .notchMinimumWidth(NotchMetrics.openContentWidth)
                    .notchSlot(.content("\(NotchViews.agents)"))
            case .sound:
                SoundPage()
                    .transition(change)
                    .notchMinimumWidth(NotchMetrics.openContentWidth)
                    .notchSlot(.content("\(NotchViews.sound)"))
            case .downloads:
                DownloadsExpandedView()
                    .transition(change)
                    .notchMinimumWidth(NotchMetrics.openContentWidth)
                    .notchSlot(.content("\(NotchViews.downloads)"))
            case .meeting:
                MeetingExpandedView()
                    .transition(change)
                    .notchMinimumWidth(NotchMetrics.openContentWidth)
                    .notchSlot(.content("\(NotchViews.meeting)"))
            case .phoneActivities:
                PhoneActivitiesExpandedView()
                    .transition(change)
                    .notchMinimumWidth(PhoneActivitiesExpandedView.callOnly ? 480 : NotchMetrics.openContentWidth)
                    .notchSlot(.content("\(NotchViews.phoneActivities)"))
            case .prayer:
                PrayerExpandedView()
                    .transition(change)
                    .notchMinimumWidth(NotchMetrics.openContentWidth)
                    .notchSlot(.content("\(NotchViews.prayer)"))
            case .welcome:
                FirstRunTour()
                    .transition(change)
                    .notchMinimumWidth(FirstRunTour.width)
                    .notchSlot(.content("\(NotchViews.welcome)"))
            }
        }
    }

    private var homeWidth: CGFloat {
        let limit = NotchHomeView.maxContentWidth(screen: vm.screenUUID)
        if coordinator.editingWidgets { return min(limit, WidgetEditor.contentWidth) }
        return NotchHomeView.minimumWidth(NotchHomeView.shown(cameraRunning: vm.camera.cameraAvailable && vm.camera.isSessionRunning,
                                                              locked: coordinator.screenLocked),
                                          limit: limit)
    }
}
