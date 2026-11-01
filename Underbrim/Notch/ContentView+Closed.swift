//
//  ContentView+Closed.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The closed island: what it shows, how wide it is, the bubble beside it, and the drop target
//  around it.
//

import Defaults
import SwiftUI

extension ContentView {
    enum ClosedNotchContent: Equatable {
        case nowPlayingFallback
        case batteryStatus
        case osd(SneakContentType, expanded: Bool)
        case flash
        case activities([LiveActivityItem])
        case face
        case idle
    }

    var closedNotchContent: ClosedNotchContent {
        if steppingAside { return .idle }
        if showsLockedPadlock { return .flash }
        if nowPlayingFallbackNoticeActive { return .nowPlayingFallback }
        if hud.expandingView.show,
           hud.expandingView.type == .battery,
           Defaults[.showPowerStatusNotifications] {
            return .batteryStatus
        }
        if hud.shouldShowSneakPeek(on: vm.screenUUID) {
            return .osd(hud.sneakPeekState(for: vm.screenUUID).type, expanded: hudExpanded)
        }
        // A switch just flipped (Focus, Caps Lock, unlocking): over the activities, like the volume pill.
        if statusFlash.current != nil, !vm.hideOnClosed { return .flash }
        if !ActivityFeed.items.isEmpty, !vm.hideOnClosed {
            return .activities(ActivityFeed.items)
        }
        if !hud.expandingView.show,
           !musicManager.isPlaying,
           musicManager.isPlayerIdle,
           Defaults[.showNotHumanFace],
           !vm.hideOnClosed {
            return .face
        }
        return .idle
    }

    /// The second activity, in a bubble beside the island: the one swapped out or the next most important
    /// (ActivitySelection.bubble), but a playing song beats a working agent so it shows somewhere during a call.
    var bubbleActivity: LiveActivityItem? {
        guard vm.notchState == .closed, bubbleReady, !isNotchHeightZero, case .activities(let items) = closedNotchContent else { return nil }
        let ids = items.map(\.id)
        guard var id = activities.bubble(of: ids) else { return nil }
        if musicManager.isPlaying, ids.contains(LiveActivityItem.music.id), activities.top(of: ids) != LiveActivityItem.music.id,
           id != activities.picked, id != activities.swappedOut,
           case .agent(let summary)? = items.first(where: { $0.id == id }), summary.kind == .working {
            id = LiveActivityItem.music.id
        }
        return items.first { $0.id == id }
    }

    var showsLockedPadlock: Bool { coordinator.screenLocked && !Defaults[.showOnLockScreen] }

    @ViewBuilder var firstRunGlint: some View {
        if let start = coordinator.firstRunStart, vm.notchState == .closed, isTargetDisplay, !reduceMotion, !steppingAside {
            RimLight(kind: .glint, shape: currentNotchShape, start: start)
        }
    }

    /// Floating: the gap above the island and, closed, the menu bar's foot below it count as the island, for
    /// the pointer and for clicks (drawn at 1%, like the title bar's chin, so the window gets them).
    @ViewBuilder var floatingCatcher: some View {
        if let floating = vm.floating, !steppingAside {
            let below = vm.notchState == .closed ? max(0, floating.menuBar - floating.top - displayClosedNotchHeight) : 0
            Color.black.opacity(0.01)
                .padding(.top, -FloatingIsland.gap)
                .padding(.bottom, -below)
                .onTapGesture {
                    if vm.notchState == .closed && !shouldDisplayNowPlayingFallbackNotice { doOpen() }
                }
        }
    }

    var computedChinWidth: CGFloat {
        var chinWidth: CGFloat = vm.closedNotchSize.width

        if showsLockedPadlock {
            chinWidth += (2 * vm.closedItemSize + 20 + 2 * TimerLiveActivity.extraWidth)
        } else if showsHUD {
            chinWidth += 2 * NotchHUD.earWidth
        } else if shouldDisplayNowPlayingFallbackNotice {
            chinWidth = NowPlayingFallbackNoticeView.width
        } else if showsBatteryNotice {
            chinWidth = 640
        } else if vm.notchState == .closed, !vm.hideOnClosed, statusFlash.current != nil {
            chinWidth += (2 * vm.closedItemSize + 20 + 2 * TimerLiveActivity.extraWidth)
        } else if vm.notchState == .closed, !vm.hideOnClosed, let activity = selectedActivity {
            // Sized for whichever activity is actually on top, not for
            // whichever happens to exist — otherwise swiping to music while a
            // notification is still in the stack leaves the chin at the
            // notification's width.
            if activity.kind == .music {
                chinWidth += (2 * max(0, displayClosedNotchHeight - 12) + 20 + 2 * liveActivityEdgeMargin + 2)
                // The inline song-change peek widens the pill itself, so the
                // chin has to grow with it — otherwise the hover region is
                // narrower than what's on screen.
                if ClosedMusicActivity.peeksInline {
                    chinWidth += 2 * ClosedMusicActivity.labelWidth
                }
            } else {
                chinWidth += (2 * vm.closedItemSize + 20 + 2 * activity.kind.extraWidth)
            }
        } else if !hud.expandingView.show && vm.notchState == .closed
            && (!musicManager.isPlaying && musicManager.isPlayerIdle) && Defaults[.showNotHumanFace]
            && !vm.hideOnClosed {
            chinWidth += (2 * max(0, displayClosedNotchHeight - 12) + 20)
        }

        return chinWidth
    }

    var shouldDisplayNowPlayingFallbackNotice: Bool {
        vm.notchState == .closed && nowPlayingFallbackNoticeActive
    }

    private var nowPlayingFallbackNoticeActive: Bool {
        guard musicManager.nowPlayingNotice != nil else { return false }

        let currentScreen = vm.screenUUID.flatMap { NSScreen.screen(withUUID: $0) }
        let isConnected = vm.screenUUID == nil || currentScreen != nil

        return isConnected
            && isTargetDisplay
            && !isNotchHeightZero
    }

    var isTargetDisplay: Bool {
        let selectedScreen = NSScreen.screen(withUUID: coordinator.selectedScreenUUID)
        let targetScreenUUID = selectedScreen?.displayUUID ?? NSScreen.main?.displayUUID
        return vm.screenUUID == nil || vm.screenUUID == targetScreenUUID
    }

    @ViewBuilder
    func NotchFaceAnimation() -> some View {
        HStack {
            Rectangle()
                .fill(.black)
                .frame(width: vm.floating == nil ? vm.closedNotchSize.width + 20 : FloatingIsland.middle)
            let faceScale = min(1.0, displayClosedNotchHeight / 30.0)
            AnimatedFace(height: 24.0 * faceScale, width: 30.0 * faceScale)
        }.frame(
            height: displayClosedNotchHeight,
            alignment: .center
        )
    }

    @ViewBuilder
    var dragDetector: some View {
        @Bindable var dropInteraction = vm.dropInteraction

        if Defaults[.shelfEnabled] && vm.notchState == .closed && !shouldDisplayNowPlayingFallbackNotice {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], isTargeted: $dropInteraction.dragDetectorTargeting) { providers in
            dropInteraction.dropEvent = true
            ShelfStateViewModel.shared.load(providers)
            return true
        }
        } else {
            EmptyView()
        }
    }
}
