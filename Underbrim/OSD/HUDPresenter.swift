//
//  HUDPresenter.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The volume and brightness display (the HUD, one per screen) and the closed island's brief
//  notices (a new song, the charger, a download), kept apart from the notch's navigation so a key
//  press redraws only the views that show them. It also sets up where the levels come from, and
//  is the one subscriber to the managers' presentation events (NotchUIEventBus).
//

import AppKit
import Combine
import Defaults
import SwiftUI

enum SneakContentType {
    case brightness
    case volume
    case backlight
    case music
    case mic
    case battery
    case download

    var isOSD: Bool { [.volume, .brightness, .backlight, .mic].contains(self) }

    /// What VoiceOver calls the HUD's bar for it.
    var levelName: String {
        switch self {
        case .volume: String(localized: "Volume")
        case .brightness: String(localized: "Brightness")
        case .backlight: String(localized: "Keyboard Brightness")
        default: String(localized: "Value", comment: "Label for OSD value slider")
        }
    }
}

struct SneakPeekState {
    var show: Bool = false
    var type: SneakContentType = .music
    var value: CGFloat = 0
    var icon: String = ""
    var accent: Color?
    var targetScreenUUID: String?
    /// When it was last shown or updated: each key press, even one that leaves the level as it is.
    var updated = Date.distantPast
}

struct ExpandedItem {
    var show: Bool = false
    var type: SneakContentType = .battery
    var value: CGFloat = 0
}

@MainActor
final class HUDPresenter: ObservableObject {
    static let shared = HUDPresenter()

    /// The HUD asks to take over from macOS's, or says Accessibility is missing (see NotchHUD).
    @Published var hudNudge = false
    /// "Not Now" to Accessibility: not asked again until the next launch.
    var hudNudgeDeclined = false

    private var osdEnableTask: Task<Void, Never>?
    private var osdReplacementCancellable: AnyCancellable?
    private var osdSourceCancellables: [AnyCancellable] = []
    private var uiEventCancellable: AnyCancellable?

    private init() {}

    /// From launch: the managers' events, the keys taken over if that's on, and the levels' sources,
    /// set up again whenever their settings change or the helper restarts.
    func start() {
        // A restarted helper keeps nothing the HUD's sources set up in it: they're set up again.
        XPCHelperClient.shared.onHelperRestart = { [weak self] in self?.applyOSDSources() }

        // Managers publish presentation events through the bus instead of
        // calling in directly; this is the single presenter (and keeps all
        // show/hide policy in one place).
        uiEventCancellable = NotchUIEventBus.events
            .sink { [weak self] event in
                Task { @MainActor in
                    guard let self else { return }
                    switch event {
                    case .sneakPeek(let type, let value, let icon, let accent, let uuid, let duration):
                        self.toggleSneakPeek(
                            status: true, type: type, duration: duration, value: value,
                            icon: icon, accent: accent, targetScreenUUID: uuid)
                    case .expandingView(let type):
                        self.toggleExpandingView(status: true, type: type)
                    case .hudNudge(let volume):
                        // Asked once; if the keys are taken over but Accessibility is missing, until Not Now.
                        guard !self.hudNudge, Defaults[.osdReplacement]
                            ? !AXIsProcessTrusted() && !self.hudNudgeDeclined : !Defaults[.hudNudgeShown]
                        else { return }
                        self.hudNudge = true
                        self.toggleSneakPeek(status: true, type: .volume, duration: 6, value: volume)
                    }
                }
            }

        // Observe changes to osdReplacement
        osdReplacementCancellable = Defaults.publisher(.osdReplacement)
            .sink { [weak self] change in
                Task { @MainActor in
                    guard let self = self else { return }

                    self.osdEnableTask?.cancel()
                    self.osdEnableTask = nil

                    if change.newValue {
                        self.osdEnableTask = Task { @MainActor in
                            await MediaKeyInterceptor.shared.start(promptIfNeeded: false)
                        }
                    } else {
                        MediaKeyInterceptor.shared.stop()
                    }

                    self.applyOSDSources()
                }
            }
        // Observe changes to any of the OSD source selections
        osdSourceCancellables = [
            Defaults.publisher(.osdBrightnessSource).sink { [weak self] _ in Task { @MainActor in self?.applyOSDSources() } },
            Defaults.publisher(.osdVolumeSource).sink { [weak self] _ in Task { @MainActor in self?.applyOSDSources() } }
        ]

        Task { @MainActor in
            if Defaults[.osdReplacement] {
                await MediaKeyInterceptor.shared.start(promptIfNeeded: false)
            }
            self.applyOSDSources()
        }
    }

    // MARK: - Per-Screen Sneak Peek Management

    // Dictionary to hold sneak peek state for each screen UUID
    @Published var sneakPeekStates: [String: SneakPeekState] = [:]

    // Dictionary to hold hide tasks for each screen UUID
    private var sneakPeekTasks: [String: Task<Void, Never>] = [:]
    /// Screens whose HUD the pointer is on, or a drag in its slider: it stays until let go.
    private var heldSneakPeeks: Set<String> = []

    func toggleSneakPeek(
        status: Bool, type: SneakContentType, duration: TimeInterval = 1.5, value: CGFloat = 0,
        icon: String = "", accent: Color? = nil, targetScreenUUID: String? = nil
    ) {
        if type != .music, !Defaults[.osdReplacement], !hudNudge {
            return
        }

        Task { @MainActor in
            // Helper to update state for a specific UUID
            @MainActor
            func updateState(for uuid: String) {
                // If we don't have a state for this screen yet, initialize it
                let before = self.sneakPeekStates[uuid] ?? SneakPeekState(targetScreenUUID: uuid)
                var state = before
                state.show = status
                // Hiding keeps what it showed: the views fading out still draw it, and nothing reads it while hidden.
                if status {
                    state.type = type
                    state.value = value
                    state.icon = icon
                    state.accent = accent
                    state.updated = Date()
                }
                state.targetScreenUUID = uuid // Ensure UUID is set
                // Showing, hiding or another kind animate; a new level follows the key at once.
                if before.show != status || before.type != state.type {
                    withAnimation(.smooth(duration: 0.25)) { self.sneakPeekStates[uuid] = state }
                } else {
                    self.sneakPeekStates[uuid] = state
                }

                if status {
                    if !self.heldSneakPeeks.contains(uuid) { self.scheduleSneakPeekHide(for: uuid, duration: duration) }
                } else {
                    self.sneakPeekTasks[uuid]?.cancel()
                    self.sneakPeekTasks[uuid] = nil
                }
            }

            if let targetUUID = targetScreenUUID {
                // Update specific screen
                updateState(for: targetUUID)
            } else {
                // Update ALL connected screens + the main screen as fallback
                // We use known screen UUIDs from NSScreen
                let screens = NSScreen.screens.compactMap { $0.displayUUID }
                if screens.isEmpty {
                    // Fallback if no screens detected (unlikely in UI app but safe)
                     if let mainUUID = NSScreen.main?.displayUUID {
                         updateState(for: mainUUID)
                     }
                } else {
                    for uuid in screens {
                        updateState(for: uuid)
                    }
                }
            }
        }
    }

     func applyOSDSources() {
        if NotchSpaceManager.shared.notchSpace.windows.isEmpty {
            BetterDisplayManager.shared.stopObserving()
            LunarManager.shared.stopListening()
            LunarManager.shared.configureLunarOSD(hide: false)
            MediaKeyInterceptor.shared.stop()
            return
        }

        // Read and watched whether or not the keys are taken over, so an outside change can offer to take
        // them over, and the first key press steps from the volume read here rather than from 0.
        if Defaults[.osdVolumeSource] == .builtin { _ = VolumeManager.shared }

        // Beside Apple's island the HUD has nowhere to show: macOS keeps the keys.
        guard Defaults[.osdReplacement], !SteppingAside.shared.everywhere else {
            BetterDisplayManager.shared.stopObserving()
            LunarManager.shared.stopListening()
            LunarManager.shared.configureLunarOSD(hide: false)
            MediaKeyInterceptor.shared.stop()
            return
        }

        let brightness = Defaults[.osdBrightnessSource]
        let volume = Defaults[.osdVolumeSource]

        Task { @MainActor in
            await MediaKeyInterceptor.shared.start(promptIfNeeded: false)
        }
        // BetterDisplay is used when either brightness or volume is set to it
        if brightness == .betterDisplay || volume == .betterDisplay {
            BetterDisplayManager.shared.startObserving()
        } else {
            BetterDisplayManager.shared.stopObserving()
        }

        // Lunar only supports brightness; disable Lunar's OSD when we replace it, restore when we don't
        if brightness == .lunar {
            LunarManager.shared.configureLunarOSD(hide: true)
            LunarManager.shared.startListening()
        } else {
            LunarManager.shared.stopListening()
            LunarManager.shared.configureLunarOSD(hide: false)
        }
    }

    func showsOpenOSD(on screenUUID: String?) -> Bool {
        sneakPeekState(for: screenUUID).type.isOSD && shouldShowSneakPeek(on: screenUUID) && Defaults[.showOpenNotchOSD]
    }

    func shouldShowSneakPeek(on screenUUID: String?) -> Bool {
        guard let uuid = screenUUID else { return false }
        return sneakPeekStates[uuid]?.show == true
    }

    var isAnySneakPeekShowing: Bool {
        return sneakPeekStates.values.contains { $0.show }
    }

    // Helper to get state safely for binding/reading
    func sneakPeekState(for screenUUID: String?) -> SneakPeekState {
        guard let uuid = screenUUID else { return SneakPeekState() }
        return sneakPeekStates[uuid] ?? SneakPeekState(targetScreenUUID: uuid)
    }

    // Helper to get binding for SwiftUI views
    func binding(for screenUUID: String?) -> Binding<SneakPeekState> {
        Binding(
            get: { [weak self] in
                guard let self = self, let uuid = screenUUID else { return SneakPeekState() }
                return self.sneakPeekStates[uuid] ?? SneakPeekState(targetScreenUUID: uuid)
            },
            set: { [weak self] newValue in
                guard let self = self, let uuid = screenUUID else { return }
                self.sneakPeekStates[uuid] = newValue
            }
        )
    }

    /// Keeps this screen's HUD up while the pointer is on it, or lets it go at once.
    func holdSneakPeek(_ hold: Bool, on screenUUID: String?) {
        guard let uuid = screenUUID else { return }
        if hold {
            heldSneakPeeks.insert(uuid)
            sneakPeekTasks[uuid]?.cancel()
            sneakPeekTasks[uuid] = nil
        } else if heldSneakPeeks.remove(uuid) != nil, sneakPeekStates[uuid]?.show == true {
            hideSneakPeek(on: uuid)
        }
    }

    private func scheduleSneakPeekHide(for screenUUID: String, duration: TimeInterval) {
        sneakPeekTasks[screenUUID]?.cancel()

        sneakPeekTasks[screenUUID] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard let self = self, !Task.isCancelled else { return }
            self.hideSneakPeek(on: screenUUID)
        }
    }

    private func hideSneakPeek(on screenUUID: String) {
        sneakPeekTasks[screenUUID] = nil
        withAnimation {
            // We only want to hide it, not reset everything instantly which might cause glitches
            self.hudNudge = false
            // Its kind stays: the symbol and slider fading out keep drawing it (nothing reads it while hidden).
            if var state = self.sneakPeekStates[screenUUID] {
                 state.show = false
                 self.sneakPeekStates[screenUUID] = state
            }
        }
    }

    func toggleExpandingView(
        status: Bool,
        type: SneakContentType,
        value: CGFloat = 0
    ) {
        Task { @MainActor in
            withAnimation(.smooth) {
                self.expandingView.show = status
                self.expandingView.type = type
                self.expandingView.value = value
            }
        }
    }

    private var expandingViewTask: Task<Void, Never>?

    @Published var expandingView: ExpandedItem = .init() {
        didSet {
            if expandingView.show {
                expandingViewTask?.cancel()
                let duration: TimeInterval = (expandingView.type == .download ? 2 : 3)
                let currentType = expandingView.type
                expandingViewTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(duration))
                    guard let self = self, !Task.isCancelled else { return }
                    self.toggleExpandingView(status: false, type: currentType)
                }
            } else {
                expandingViewTask?.cancel()
            }
        }
    }
}
