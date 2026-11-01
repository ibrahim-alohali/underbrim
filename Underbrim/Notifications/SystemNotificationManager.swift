//
//  SystemNotificationManager.swift
//  Underbrim
//
import AppKit
import Combine
import Defaults

struct SystemNotification: Identifiable, Equatable {
    let id: String
    let appName: String?
    let bundleID: String?
    let title: String?
    let subtitle: String?
    let body: String?
    let receivedAt: Date
}

@MainActor
final class SystemNotificationManager: ObservableObject {
    static let shared = SystemNotificationManager()

    @Published private(set) var activeNotification: SystemNotification?
    @Published private(set) var queuedNotifications: [SystemNotification] = []
    /// The notification the active one took the place of in one step (+1, × with more waiting, a new banner
    /// over one nobody is looking at), so a card showing the old one shows the new one in the same update.
    /// It changes only along with `activeNotification`.
    private(set) var replacedID: String?

    private let queueLimit = 5
    let displayDuration: TimeInterval = 8
    private var dismissTask: Task<Void, Never>?
    private var relaunchObservation: NSKeyValueObservation?
    /// Held by the pointer on the notch (holdActive) until resumeDismiss.
    private(set) var isUserPresent = false

    private init() {
        // Underbrim: when Notification Center relaunches, the notification reader watches the new one.
        // It's a background app, so NSWorkspace posts no launch notification for it, and it answers
        // Accessibility only once launched: a few tries, a second apart.
        relaunchObservation = NSWorkspace.shared.observe(\.runningApplications, options: [.new]) { _, change in
            guard change.newValue?.contains(where: { $0.bundleIdentifier == "com.apple.notificationcenterui" }) == true else { return }
            Task { @MainActor in
                for _ in 0..<5 {
                    try? await Task.sleep(for: .seconds(1))
                    guard Self.isWanted else { return }
                    if await SystemNotificationManager.shared.start() { return }
                }
            }
        }
        Defaults.whenChanged(Self.wantedKeys) { [weak self] in Task { await self?.sync() } }
        Defaults.whenChanged([.notificationsFromAllApps, .notificationAllowedApps, .deliveryApps]) { [weak self] in
            self?.updateFilter()
        }
    }

    /// The reader runs for notifications in the notch and for deliveries.
    nonisolated static var isWanted: Bool { Defaults[.notificationLiveActivity] || Defaults[.showDeliveryUpdates] }
    nonisolated static let wantedKeys: [Defaults._AnyKey] = [.notificationLiveActivity, .showDeliveryUpdates]

    /// Starts the reader when it's wanted and stops it when it isn't. It follows
    /// `wantedKeys` itself; others call this when Accessibility comes back.
    func sync() async {
        if Self.isWanted { await start() } else { stop() }
    }

    /// The helper restarted without the reader: started again if it's wanted.
    func helperRestarted() async {
        if Self.isWanted { await start() }
    }

    @discardableResult
    private func start() async -> Bool {
        guard await XPCHelperClient.shared.isAccessibilityAuthorized() else { return false }
        updateFilter()
        switch await XPCHelperClient.shared.startNotificationWatching() {
        case .started?, .alreadyRunning?: return true
        case .accessibilityNotTrusted?, .notificationCenterNotRunning?, .observerFailed?, nil: return false
        }
    }

    func stop() {
        XPCHelperClient.shared.stopNotificationWatching()
        queuedNotifications.removeAll()
        isUserPresent = false
        dismissActive()
    }

    func holdActive() {
        isUserPresent = true
        dismissTask?.cancel()
        dismissTask = nil
    }

    func resumeDismiss(after delay: TimeInterval = 2) {
        isUserPresent = false
        queuedNotifications.removeAll()
        guard let notification = activeNotification else { return }
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.dismissActive(token: notification.id)
        }
    }

    func dismissActive(token: String? = nil) {
        guard token == nil || activeNotification?.id == token else { return }
        dismissTask?.cancel()
        dismissTask = nil
        let dismissed = activeNotification?.id
        activeNotification = nil
        if isUserPresent {
            promoteNext(replacing: dismissed)
        } else {
            queuedNotifications.removeAll()
        }
    }

    func showNextQueued() {
        guard isUserPresent, let next = queuedNotifications.first else { return }
        if let activeNotification {
            queuedNotifications.append(activeNotification)
        }
        queuedNotifications.removeFirst()
        show(next, replacing: activeNotification?.id)
    }

    func open(_ notification: SystemNotification) async -> Bool {
        let workspace = NSWorkspace.shared

        for bundleID in candidateBundleIDs(for: notification) {
            let running = workspace.runningApplications.first { application in
                guard !application.isTerminated,
                      let applicationBundleID = application.bundleIdentifier else { return false }
                return normalizeBundleIdentifier(applicationBundleID) == bundleID
            }

            // Opened as the Dock does (AppInfo.activate): activating first could fail yet report success.
            if let running {
                if let appURL = running.bundleURL,
                   await launchApplication(at: appURL) {
                    return true
                }
                if running.activate(options: [.activateAllWindows]) {
                    return true
                }
            }

            if let appURL = workspace.urlForApplication(withBundleIdentifier: bundleID),
               await launchApplication(at: appURL) {
                return true
            }
        }

        return false
    }

    /// A banner from the helper, its text already cleaned there.
    func receive(_ banner: UnderbrimBanner) {
        let appName = banner.appName
        var bundleID = banner.bundleID.map(normalizeBundleIdentifier)

        // The helper only has the banner's display name and can miss when the
        // source is a helper process or is no longer running. Re-resolve here
        // so both the icon and launch action get the real application.
        if bundleID.map(isLaunchable) != true,
           let appName,
           let resolved = AppNameResolver.shared.bundleID(forAppNamed: appName) {
            bundleID = resolved
        }

        let notification = SystemNotification(
            id: banner.token,
            appName: appName,
            bundleID: bundleID,
            title: banner.title,
            subtitle: banner.subtitle,
            body: banner.body,
            receivedAt: Date()
        )
        guard isAllowed(notification) else { return }
        DeliveryTracker.shared.receive(notification)
        guard activeNotification == nil else {
            guard isUserPresent else {
                show(notification, replacing: activeNotification?.id)
                return
            }
            guard !queuedNotifications.contains(where: { $0.id == notification.id }) else { return }
            queuedNotifications.append(notification)
            if queuedNotifications.count > queueLimit {
                queuedNotifications.removeFirst()
            }
            return
        }
        show(notification, replacing: nil)
    }

    private func show(_ notification: SystemNotification, replacing replaced: String?) {
        dismissTask?.cancel()
        replacedID = replaced
        activeNotification = notification
        scheduleDismiss(for: notification.id)
    }

    private func scheduleDismiss(for token: String) {
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.displayDuration ?? 8))
            guard !Task.isCancelled else { return }
            await self?.dismissActive(token: token)
        }
    }

    private func promoteNext(replacing dismissed: String?) {
        guard activeNotification == nil, !queuedNotifications.isEmpty else { return }
        show(queuedNotifications.removeFirst(), replacing: dismissed)
    }

    /// Which banners are read: the apps chosen for notifications in the notch, and the delivery apps.
    @MainActor
    struct Filter: Equatable {
        var mirror = false
        var fromAllApps = false
        var allowed: Set<String> = []
        var deliveries: [String] = []

        static var current: Filter {
            Filter(mirror: Defaults[.notificationLiveActivity], fromAllApps: Defaults[.notificationsFromAllApps],
                   allowed: Defaults[.notificationAllowedApps],
                   deliveries: Defaults[.showDeliveryUpdates] ? Defaults[.deliveryApps] : [])
        }

        /// What the reader is told. Delivery apps are iPhone apps with no Mac counterpart, matched by name;
        /// an Arabic iPhone names them in Arabic and the reader has no alias table, so those names go too.
        var helperBundleIDs: Set<String> {
            let listed = Set(deliveries.map(NotificationPanelDetection.normalizedAppName))
            let arabic = DeliveryTracker.arabicNames.filter { listed.contains(NotificationPanelDetection.normalizedAppName($0.value)) }.keys
            return (mirror ? allowed : []).union(deliveries).union(arabic)
        }
        var helperAllApps: Bool { mirror && fromAllApps }

        func allows(_ notification: SystemNotification) -> Bool {
            if DeliveryTracker.app(of: notification, in: deliveries) != nil { return true }
            guard mirror else { return false }
            if fromAllApps { return true }
            if let bundleID = notification.bundleID { return allowed.contains(bundleID) }
            guard let appName = notification.appName.map(NotificationPanelDetection.normalizedAppName), !appName.isEmpty else { return false }
            return allowed.contains { bundleID in
                guard let lastComponent = bundleID.split(separator: ".").last else { return false }
                return appName == NotificationPanelDetection.normalizedAppName(String(lastComponent))
            }
        }
    }

    func updateFilter() {
        let filter = Filter.current
        XPCHelperClient.shared.setNotificationFilter(bundleIDs: filter.helperBundleIDs, allApps: filter.helperAllApps)
    }

    private func isAllowed(_ notification: SystemNotification) -> Bool {
        Filter.current.allows(notification)
    }

    private func candidateBundleIDs(for notification: SystemNotification) -> [String] {
        let resolved: String?
        if let bundleID = notification.bundleID, isLaunchable(bundleID) {
            resolved = nil
        } else {
            resolved = notification.appName.flatMap {
                AppNameResolver.shared.bundleID(forAppNamed: $0)
            }
        }
        return Self.bundleIDCandidates(for: notification, resolvedBundleID: resolved)
    }

    nonisolated static func bundleIDCandidates(
        for notification: SystemNotification,
        resolvedBundleID: String? = nil
    ) -> [String] {
        var result: [String] = []
        for candidate in [notification.bundleID, resolvedBundleID].compactMap({ $0 }) {
            let normalized = normalizeBundleIdentifier(candidate)
            guard !normalized.isEmpty, !result.contains(normalized) else { continue }
            result.append(normalized)
        }
        return result
    }

    private func isLaunchable(_ bundleID: String) -> Bool {
        let workspace = NSWorkspace.shared
        return workspace.urlForApplication(withBundleIdentifier: bundleID) != nil
            || workspace.runningApplications.contains { application in
                guard !application.isTerminated,
                      let applicationBundleID = application.bundleIdentifier else { return false }
                return normalizeBundleIdentifier(applicationBundleID) == bundleID
            }
    }

    private func launchApplication(at appURL: URL) async -> Bool {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        do {
            _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
            return true
        } catch {
            return false
        }
    }
}
