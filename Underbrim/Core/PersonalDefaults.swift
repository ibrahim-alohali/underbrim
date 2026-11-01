//
//  PersonalDefaults.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Settings added by Underbrim. Integrations that change other apps' settings default to off and
//  are turned on through their guided setup in Settings.
//

import Defaults
import Foundation

extension Defaults {
    /// Calls `action` whenever one of `keys` changes, however it changed. A settings view can't
    /// use `.onChange(of: Defaults[…])`: plain reads aren't tracked.
    @MainActor @discardableResult
    static func whenChanged(_ keys: [_AnyKey], perform action: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        Task { @MainActor in
            for await _ in updates(keys, initial: false) { action() }
        }
    }
}

extension Defaults.Keys {
    // MARK: Coding agents
    /// Off for new installs (the first-run tour offers it).
    static let showAgentActivity = Key<Bool>("personal_showAgentActivity", default: false)
    /// Scripted or background runs (`claude -p`, SDK apps).
    static let showBackgroundAgents = Key<Bool>("personal_showBackgroundAgents", default: false)
    /// What an agent waits on (an approval, a question, a plan) has the island on its own until
    /// it's answered or closed, without taking the keyboard. Off: the closed notch shows it.
    static let openIslandForAgentRequests = Key<Bool>("personal_openIslandForAgentRequests", default: true)
    static let dismissedAgentAsks = Key<[String]>("personal_dismissedAgentAsks", default: [])
    static let setAsideAgentAsks = Key<[String]>("personal_setAsideAgentAsks", default: [])
    /// Claude Desktop's session link: undocumented, but it's the one the Claude
    /// app builds for its own Spotlight results.
    static let useClaudeDesktopSessionLinks = Key<Bool>("personal_useClaudeDesktopSessionLinks", default: true)
    /// Session cards name the file or command at work, the tasks and the last prompt and reply.
    static let showSessionDetails = Key<Bool>("personal_showSessionDetails", default: true)
    static let hiddenAgentFolders = Key<[String]>("personal_hiddenAgentFolders", default: [])
    static let agentSounds = Key<Bool>("personal_agentSounds", default: true)
    /// Of the alert volume set in Sound settings.
    static let agentSoundVolume = Key<Double>("personal_agentSoundVolume", default: 1)
    static let agentSoundForAttention = Key<Bool>("personal_agentSoundForAttention", default: true)
    static let agentSoundForDone = Key<Bool>("personal_agentSoundForDone", default: true)
    static let agentSoundForFailed = Key<Bool>("personal_agentSoundForFailed", default: true)
    /// A request still waiting this many minutes later: the sound once more (0: never).
    static let agentReminderMinutes = Key<Int>("personal_agentReminderMinutes", default: 5)
    /// Out of screen shares and recordings while they run (screenshots keep the notch);
    /// `hideFromScreenRecording` hides it from every capture.
    static let hideWhileScreenShared = Key<Bool>("personal_hideWhileScreenShared", default: false)
    static let keepAwakeWhileAgentsWork = Key<Bool>("personal_keepAwakeWhileAgentsWork", default: true)

    // MARK: Sound page
    static let soundPageEnabled = Key<Bool>("personal_soundPageEnabled", default: true)
    /// Levels up to 200 %, with a limiter; off, up to 100 %.
    static let soundBoost = Key<Bool>("personal_soundBoost", default: true)
    static let soundKeepPaused = Key<Bool>("personal_soundKeepPaused", default: true)
    static let soundShowSystem = Key<Bool>("personal_soundShowSystem", default: true)
    /// Each app's level away from 100 % (1 is 100 %), by bundle ID.
    static let soundLevels = Key<[String: Double]>("personal_soundLevels", default: [:])
    static let soundMuted = Key<[String]>("personal_soundMuted", default: [])

    // MARK: Plan usage (Codex and the status line are opt-in)
    /// The closed notch says so once when a usage window reaches this percent (0: never).
    static let usageWarningPercent = Key<Int>("personal_usageWarningPercent", default: 90)
    static let usageWarned = Key<[String: Double]>("personal_usageWarned", default: [:])
    static let codexUsageEnabled = Key<Bool>("personal_codexUsageEnabled", default: false)
    static let claudeStatusLineFeed = Key<Bool>("personal_claudeStatusLineFeed", default: false)
    static let readClaudeDesktopUsage = Key<Bool>("personal_readClaudeDesktopUsage", default: true)

    // MARK: Clipboard history
    /// On for new installs; it records once the first-run tour ends.
    static let clipboardHistoryEnabled = Key<Bool>("personal_clipboardHistoryEnabled", default: true)
    static let clipboardPaused = Key<Bool>("personal_clipboardPaused", default: false)
    static let clipboardExcludedApps = Key<Set<String>>("personal_clipboardExcludedApps", default: ClipboardPolicy.defaultExcludedApps)
    static let clipboardMaxEntries = Key<Int>("personal_clipboardMaxEntries", default: 100)
    static let clipboardRetentionDays = Key<Int>("personal_clipboardRetentionDays", default: 7)

    // MARK: Screenshots (opt-in)
    static let screenshotShelfEnabled = Key<Bool>("personal_screenshotShelfEnabled", default: false)
    static let screenshotFolderBookmark = Key<Data?>("personal_screenshotFolderBookmark", default: nil)

    // MARK: Appearance
    static let accentStyle = Key<AccentStyle>("personal_accentStyle", default: .migrated(custom: Defaults[.useCustomAccentColor]))
    static let closeDelay = Key<TimeInterval>("personal_closeDelay", default: 0)
    static let settingsLastTab = Key<SettingsTab>("personal_settingsLastTab", default: .general)

    // MARK: Devices (opt-in: needs Bluetooth permission)
    static let showHeadphoneBattery = Key<Bool>("personal_showHeadphoneBattery", default: false)

    // MARK: Meetings
    static let meetingCountdown = Key<Bool>("personal_meetingCountdown", default: true)
    static let meetingLeadMinutes = Key<Int>("personal_meetingLeadMinutes", default: 10)

    // MARK: Downloads
    static let addFinishedDownloadsToShelf = Key<Bool>("personal_addFinishedDownloadsToShelf", default: true)
    static let browserDownloadProgress = Key<Bool>("personal_browserDownloadProgress", default: true)
    static let downloadsFolderBookmark = Key<Data?>("personal_downloadsFolderBookmark", default: nil)
    static let showDownloadActivity = Key<Bool>("personal_showDownloadActivity", default: true)

    // MARK: Home widgets (Calendar and Mirror keep upstream's showCalendar / showMirror)
    static let homeWidgetOrder = Key<[HomeWidget]>("personal_homeWidgetOrder", default: HomeWidget.allCases)
    static let homeWidgetSizes = Key<[String: WidgetSize]>("personal_homeWidgetSizes", default: [:])
    static let showNowPlayingWidget = Key<Bool>("personal_showNowPlayingWidget", default: true)
    static let showQuickLaunch = Key<Bool>("personal_showQuickLaunch", default: true)
    /// Quick Launch: the spots the user set (0–11: an app's bundle ID, or "" where emptied), row 1's
    /// suggestions, apps removed (never suggested again), and use counts that halve weekly as of
    /// `quickLaunchUsageAt` (nil until seeded from Spotlight).
    static let quickLaunchSpots = Key<[Int: String]>("personal_quickLaunchSpots", default: [:])
    static let quickLaunchSuggested = Key<[Int: String]>("personal_quickLaunchSuggested", default: [:])
    static let quickLaunchHidden = Key<[String]>("personal_quickLaunchHidden", default: [])
    static let quickLaunchUsage = Key<[String: Double]>("personal_quickLaunchUsage", default: [:])
    static let quickLaunchUsageAt = Key<Date?>("personal_quickLaunchUsageAt", default: nil)
    /// Pinned as the island, one row under the notch, until unpinned (kept across restarts). Kept in
    /// step with `pinnedWidget`, which took its place, so an earlier version still finds it.
    static let quickLaunchPinned = Key<Bool>("personal_quickLaunchPinned", default: false)
    static let pinnedWidget = Key<HomeWidget?>("personal_pinnedWidget", default: nil)
    static let compactWidget = Key<HomeWidget>("personal_compactWidget", default: .nowPlaying)
    static let quickLaunchBadges = Key<Bool>("personal_quickLaunchBadges", default: true)
    static let quickLaunchHotkeys = Key<Bool>("personal_quickLaunchHotkeys", default: true)
    /// The list builds before 1.0 kept, read once to move to the spots.
    static let quickLaunchKept = Key<[String]>("personal_quickLaunchKept", default: [])
    static let quickLaunchAutoFill = Key<Bool>("personal_quickLaunchAutoFill", default: true)
    static let tabOrder = Key<[NotchViews]>("personal_tabOrder", default: NotchViews.tabs)
    static let showTimerWidget = Key<Bool>("personal_showTimerWidget", default: false)
    static let showShortcutsWidget = Key<Bool>("personal_showShortcutsWidget", default: false)
    static let showScratchpadWidget = Key<Bool>("personal_showScratchpadWidget", default: false)
    static let showSystemWidget = Key<Bool>("personal_showSystemWidget", default: false)
    static let showRemindersWidget = Key<Bool>("personal_showRemindersWidget", default: false)
    static let showUnreadWidget = Key<Bool>("personal_showUnreadWidget", default: false)
    static let showCallsWidget = Key<Bool>("personal_showCallsWidget", default: false)
    static let showPhoneActivities = Key<Bool>("personal_showPhoneActivities", default: false)
    static let showDeliveryUpdates = Key<Bool>("personal_showDeliveryUpdates", default: false)
    static let deliveryApps = Key<[String]>("personal_deliveryApps", default: DeliveryTracker.defaultApps)
    static let showCallActivity = Key<Bool>("personal_showCallActivity", default: true)
    /// The HUD has asked once to take over from macOS's.
    static let hudNudgeShown = Key<Bool>("personal_hudNudgeShown", default: false)
    static let showUnlockAnimation = Key<Bool>("personal_showUnlockAnimation", default: true)
    static let showFocusChanges = Key<Bool>("personal_showFocusChanges", default: false)
    static let showCapsLock = Key<Bool>("personal_showCapsLock", default: false)
    /// Lunar's and BetterDisplay's own OSD, turned off by Underbrim while one is
    /// the HUD's source: put back only if Underbrim turned it off.
    static let lunarOSDHiddenByUnderbrim = Key<Bool>("personal_lunarOSDHiddenByUnderbrim", default: false)
    static let betterDisplayOSDOffByUnderbrim = Key<Bool>("personal_betterDisplayOSDOffByUnderbrim", default: false)

    // MARK: Prayer times
    /// On for new installs; the first-run tour asks where.
    static let prayerTimesEnabled = Key<Bool>("personal_prayerTimesEnabled", default: true)
    static let prayerPlace = Key<PrayerPlace?>("personal_prayerPlace", default: nil)
    /// A method's id; nil for the place's country's.
    static let prayerMethod = Key<String?>("personal_prayerMethod", default: nil)
    static let prayerAsrHanafi = Key<Bool>("personal_prayerAsrHanafi", default: false)
    static let prayerAdjustments = Key<PrayerAdjustmentSet>("personal_prayerAdjustments", default: .init())
    /// Days added to the Umm al-Qura date (±2), for where the month starts on a sighting.
    static let hijriAdjustment = Key<Int>("personal_hijriAdjustment", default: 0)
    static let prayerAtTime = Key<Bool>("personal_prayerAtTime", default: true)
    static let prayerSound = Key<Bool>("personal_prayerSound", default: false)
    static let showPrayerWidget = Key<Bool>("personal_showPrayerWidget", default: true)
}

/// A changed default reaches new installs only: an update keeps each existing
/// install as it was, settings it never touched included, so nothing turns on
/// or off by itself. One step per version that changed any; add steps, never
/// edit one.
enum DefaultsHistory {
    /// Each step: the keys it changed, at the value they had before.
    private static let steps: [[String: Any]] = [
        // New-install defaults of build 1.6.0 (before the public 1.0)
        [Defaults.Keys.prayerTimesEnabled.name: false,
         Defaults.Keys.showPrayerWidget.name: false,
         Defaults.Keys.clipboardHistoryEnabled.name: false,
         Defaults.Keys.osdReplacement.name: true,
         Defaults.Keys.showAgentActivity.name: true],
        // Build 123: displays without a notch get the floating island
        [Defaults.Keys.nonNotchStyle.name: NonNotchStyle.notch.rawValue],
        // Build 125: the real-time waveform
        [Defaults.Keys.realtimeAudioWaveform.name: false],
    ]
    private static let doneKey = "personal_defaultsStepsDone"

    /// At launch, before anything reads these settings. Reads what's stored
    /// itself: `object(forKey:)` also returns the defaults Defaults registers.
    static func apply() {
        let defaults = UserDefaults.standard
        let done = defaults.integer(forKey: doneKey)
        guard done < steps.count else { return }
        let stored = defaults.persistentDomain(forName: bundleIdentifier) ?? [:]
        // Finished (or skipped) the first-run tour before: an update.
        if stored[Defaults.Keys.firstLaunch.name] as? Bool == false {
            for step in steps[done...] {
                for (key, old) in step where stored[key] == nil { defaults.set(old, forKey: key) }
            }
        }
        defaults.set(steps.count, forKey: doneKey)
    }
}
