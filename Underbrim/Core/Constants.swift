//
//  Constants.swift
//  Underbrim
//
//  Created by Richard Kunkli on 2024. 10. 17..
//

import SwiftUI
import Defaults

let bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "io.github.ibrahim-alohali.underbrim"

let spacing: CGFloat = 16

// Define notification names at file scope
extension Notification.Name {
    // MARK: - System
    static let accessibilityAuthorizationChanged = Notification.Name("accessibilityAuthorizationChanged")

    // MARK: - Sharing
    static let sharingDidFinish = Notification.Name("sharingDidFinish")

    // MARK: - Island
    /// Settings opening, or another of the island's buttons pressed: its popovers close, as they
    /// do on a click elsewhere (a press from VoiceOver or the keyboard isn't one).
    static let closeIslandPopovers = Notification.Name("closeIslandPopovers")
}

enum PreferenceCompatibility {
    /// Runs before Defaults.Key registers its fallback, so a saved false is
    /// distinguishable from a missing value. Keep the old key for older builds.
    static func migratedKeyName(
        _ name: String,
        from legacyName: String,
        in defaults: UserDefaults = .standard
    ) -> String {
        if defaults.object(forKey: name) == nil,
           let legacyValue = defaults.object(forKey: legacyName) as? Bool {
            defaults.set(legacyValue, forKey: name)
        }
        return name
    }
}

extension Defaults.Keys {
    // MARK: General
    /// True until the first-run tour is finished or skipped.
    static let firstLaunch = Key<Bool>("firstLaunch", default: true)
    static let appLanguage = Key<AppLanguage>("appLanguage", default: .system)
    static let menubarIcon = Key<Bool>("menubarIcon", default: true)
    static let showOnAllDisplays = Key<Bool>("showOnAllDisplays", default: false)
    static let automaticallySwitchDisplay = Key<Bool>("automaticallySwitchDisplay", default: true)
    static let preferredScreenUUID = Key<String?>("preferred_screen_uuid", default: nil)
    /// The preferred display by name, from before display UUIDs: moved to `preferredScreenUUID` at launch.
    static let preferredScreenName = Key<String?>("preferred_screen_name", default: nil)

    // MARK: Behavior
    /// Underbrim opens at once by default (0.3 s upstream).
    static let minimumHoverDuration = Key<TimeInterval>("minimumHoverDuration", default: 0)
    static let enableOpeningAnimation = Key<Bool>("enableOpeningAnimation", default: true)
    static let animationSpeedMultiplier = Key<Double>("animationSpeedMultiplier", default: 1.0)
    static let enableHaptics = Key<Bool>("enableHaptics", default: true)
    static let openNotchOnHover = Key<Bool>("openNotchOnHover", default: true)
    static let notchHeightMode = Key<WindowHeightMode>(
        "notchHeightMode",
        default: WindowHeightMode.matchRealNotchSize
    )
    static let nonNotchHeightMode = Key<WindowHeightMode>(
        "nonNotchHeightMode",
        default: WindowHeightMode.matchMenuBar
    )
    static let nonNotchHeight = Key<CGFloat>("nonNotchHeight", default: 32)
    static let notchHeight = Key<CGFloat>("notchHeight", default: 32)
    // Underbrim: on by default, so the notch reopens where it was left.
    static let openLastTabByDefault = Key<Bool>("openLastTabByDefault", default: true)
    static let showOnLockScreen = Key<Bool>("showOnLockScreen", default: false)
    static let hideFromScreenRecording = Key<Bool>("hideFromScreenRecording", default: false)

    // MARK: Appearance
    static let alwaysShowTabs = Key<Bool>("alwaysShowTabs", default: true)
    static let showMirror = Key<Bool>("showMirror", default: false)
    static let isMirrored = Key<Bool>("isMirrored", default: true)
    static let mirrorShape = Key<MirrorShapeEnum>("mirrorShape", default: MirrorShapeEnum.rectangle)
    static let mirrorCameraID = Key<String?>("mirrorCameraID", default: nil)
    static let settingsIconInNotch = Key<Bool>("settingsIconInNotch", default: true)
    static let lightingEffect = Key<Bool>("lightingEffect", default: false)  // personal: pure black
    static let enableShadow = Key<Bool>("enableShadow", default: true)
    static let cornerRadiusScaling = Key<Bool>("cornerRadiusScaling", default: true)

    static let showNotHumanFace = Key<Bool>("showNotHumanFace", default: false)
    static let showCalendar = Key<Bool>("showCalendar", default: false)
    static let sliderColor = Key<SliderColorEnum>(
        "sliderUseAlbumArtColor",
        default: SliderColorEnum.white
    )
    static let playerColorTinting = Key<Bool>("playerColorTinting", default: false)  // personal: colour for status only

    // MARK: Media playback
    static let musicLiveActivityEnabled = Key<Bool>("musicLiveActivityEnabled", default: true)
    static let coloredSpectrogram = Key<Bool>("coloredSpectrogram", default: true)
    /// On for new installs; the first-run tour asks for its permission.
    static let realtimeAudioWaveform = Key<Bool>("realtimeAudioWaveform", default: true)
    static let enableSneakPeek = Key<Bool>("enableSneakPeek", default: false)
    static let sneakPeekStyles = Key<SneakPeekStyle>("sneakPeekStyles", default: .inline)  // personal: closed content on the sides
    static let waitInterval = Key<Double>("waitInterval", default: 3)
    static let showRemainingTime = Key<Bool>("showRemainingTime", default: false)
    static let musicControlSlots = Key<[MusicControlButton]>(
        "musicControlSlots",
        default: MusicControlButton.defaultLayout
    )
    static let musicControlSlotLimit = Key<Int>(
        "musicControlSlotLimit",
        default: MusicControlButton.defaultLayout.count
    )

    // MARK: Battery
    static let showPowerStatusNotifications = Key<Bool>("showPowerStatusNotifications", default: true)
    static let showBatteryIndicator = Key<Bool>("showBatteryIndicator", default: true)
    static let showBatteryPercentage = Key<Bool>("showBatteryPercentage", default: true)
    static let showPowerStatusIcons = Key<Bool>("showPowerStatusIcons", default: true)
    static let showChargingWattage = Key<Bool>("showChargingWattage", default: true)

    // MARK: OSD
    /// Off for new installs: it needs Accessibility, which the first-run tour asks for when it's ticked.
    static let osdReplacement = Key<Bool>(PreferenceCompatibility.migratedKeyName("osdReplacement", from: "hudReplacement"), default: false)

    // MARK: Layout
    /// Swaps the opened notch for a smaller, player-only layout: no tab
    /// bar, calendar or mirror. Off by default so existing users keep the
    /// layout they already have.
    static let compactMode = Key<Bool>("compactMode", default: false)

    // MARK: Notifications
    /// Off by default: mirroring banners needs Accessibility access.
    static let notificationLiveActivity = Key<Bool>("notificationLiveActivity", default: false)
    static let notificationsFromAllApps = Key<Bool>("notificationsFromAllApps", default: false)
    static let notificationAllowedApps = Key<Set<String>>(
        "notificationAllowedApps",
        default: []
    )
    static let systemEventIndicatorUseAccent = Key<Bool>("systemEventIndicatorUseAccent", default: false)
    static let showOpenNotchOSD = Key<Bool>(PreferenceCompatibility.migratedKeyName("showOpenNotchOSD", from: "showOpenNotchHUD"), default: true)
    // Option key modifier behaviour for media keys
    static let optionKeyAction = Key<OptionKeyAction>("optionKeyAction", default: OptionKeyAction.openSettings)
    // Brightness/volume/keyboard source selection
    static let osdBrightnessSource = Key<OSDControlSource>("osdBrightnessSource", default: .builtin)
    static let osdVolumeSource = Key<OSDControlSource>("osdVolumeSource", default: .builtin)

    // MARK: Shelf
    static let shelfEnabled = Key<Bool>(PreferenceCompatibility.migratedKeyName("shelfEnabled", from: "boringShelf"), default: true)
    static let openShelfByDefault = Key<Bool>("openShelfByDefault", default: true)
    static let quickShareProvider = Key<String>("quickShareProvider", default: QuickShareProvider.airDropId)
    // Underbrim: dragging out copies; the Shelf references the original, which stays put.
    static let copyOnDrag = Key<Bool>("copyOnDrag", default: true)
    static let autoRemoveShelfItems = Key<Bool>("autoRemoveShelfItems", default: false)
    static let expandedDragDetection = Key<Bool>("expandedDragDetection", default: true)
    static let reverseShelfOrdering = Key<Bool>("reverseShelfOrdering", default: false)

    // MARK: Calendar
    static let calendarSelectionState = Key<CalendarSelectionState>("calendarSelectionState", default: .all)
    static let joinMeetingOnEventTap = Key<Bool>("joinMeetingOnEventTap", default: true)

    // MARK: Fullscreen Media Detection
    static let hideNotchOption = Key<HideNotchOption>("hideNotchOption", default: .nowPlayingOnly)

    // MARK: Media Controller
    static let mediaController = Key<MediaControllerType>("mediaController", default: defaultMediaController)
    static let didChooseMediaController = Key<Bool>("didChooseMediaController", default: false)
    static let didMigrateMediaControllerChoice = Key<Bool>("didMigrateMediaControllerChoice", default: false)
    static let lastSupportedNowPlayingBundleIdentifier = Key<String?>(
        "lastSupportedNowPlayingBundleIdentifier",
        default: nil
    )

    // MARK: Advanced Settings
    static let useCustomAccentColor = Key<Bool>("useCustomAccentColor", default: false)
    static let customAccentColorData = Key<Data?>("customAccentColorData", default: nil)
    // Show or hide the title bar
    static let hideTitleBar = Key<Bool>("hideTitleBar", default: true)
    static let hideNonNotchedFromMissionControl = Key<Bool>("hideNonNotchedFromMissionControl", default: true)

    // Keep the default stable. Runtime availability is handled by MusicManager.
    static var defaultMediaController: MediaControllerType {
        .nowPlaying
    }

    static let didClearLegacyURLCacheV1 = Key<Bool>("didClearLegacyURLCache_v1", default: false)
}
