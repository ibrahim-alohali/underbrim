import Foundation
import Cocoa
import AsyncXPCConnection
import Defaults

/// Why a helper call failed. Methods still degrade to false/nil for
/// backward compatibility, but never silently: every transport failure —
/// a thrown XPC error or a dropped connection — is recorded in `lastError`
/// (interruption/invalidation record `.unavailable`), and connection loss
/// also flips `helperAvailable` for Settings to surface. A helper that
/// answers, even with false/nil, is a result, not an error, and leaves
/// `lastError` untouched.
enum XPCHelperError: Error {
    /// The XPC service could not be reached (crashed or restarting).
    case unavailable
    /// The helper refused the request (e.g. accessibility not granted).
    case declined
    /// Connection dropped mid-call.
    case transport(underlying: Error)
}

@MainActor
final class XPCHelperClient: NSObject, ObservableObject {
    nonisolated static let shared = XPCHelperClient()

    override nonisolated private init() {
        super.init()
    }

    private let serviceName = "\(bundleIdentifier).helper"

    /// Coarse, UI-friendly view of helper connectivity. Flips to false from
    /// the connection's interruption/invalidation handlers so a crashed
    /// helper is visible in Settings instead of features silently degrading;
    /// flips back to true when a live connection is (re)established.
    @MainActor @Published private(set) var helperAvailable = true
    /// Whether macOS allows Accessibility, as last checked (see
    /// startMonitoringAccessibilityAuthorization). Settings shows this.
    @MainActor @Published private(set) var accessibilityGranted = true
    @MainActor private(set) var lastError: XPCHelperError?

    private var remoteService: RemoteXPCService<UnderbrimHelperProtocol>?
    private var connection: NSXPCConnection?
    /// The last Accessibility answer, so a change is announced once.
    private var lastKnownAuthorization: Bool?
    /// When what the helper held was last set up again (see helperRestarted).
    @MainActor private var lastRearm = Date.distantPast
    @MainActor private var rearmScheduled = false
    private let notificationDelegate = NotificationXPCDelegate()
    @MainActor private var activationObserver: (any NSObjectProtocol)?
    @MainActor private var pollTimer: Timer?
    @MainActor private var monitoring = false
    @MainActor private var settingsWatch: Task<Void, Never>?
    private var lunarListener: UnderbrimHelperLunarListener?
    /// Sets the HUD's brightness and volume sources up again after a restart (HUDPresenter).
    @MainActor var onHelperRestart: (@MainActor () -> Void)?

    // MARK: - Connection Management (Main Actor Isolated)

    /// Underbrim: the helper went away (a crash, launchd reclaiming it), taking
    /// notification watching, its filter and Lunar's stream with it. The next
    /// call relaunches it; this sets them up again, at most every 30 s (later,
    /// not never) so a helper that dies on start doesn't loop.
    @MainActor private func helperRestarted() {
        let wait = 30 - Date().timeIntervalSince(lastRearm)
        guard wait <= 0 else {
            guard !rearmScheduled else { return }
            rearmScheduled = true
            Task {
                try? await Task.sleep(for: .seconds(wait))
                rearmScheduled = false
                helperRestarted()
            }
            return
        }
        lastRearm = Date()
        Task { await SystemNotificationManager.shared.helperRestarted() }
        LunarManager.shared.helperRestarted()
        onHelperRestart?()
    }

    private func ensureRemoteService() -> RemoteXPCService<UnderbrimHelperProtocol> {
        // Always reuse a live connection — never tear one down to attach a
        // listener. The exported object below serves *both* callback
        // protocols from the moment the connection is created, so there's
        // nothing to re-negotiate.
        //
        // This previously invalidated and rebuilt the connection whenever
        // Lunar/OSD asked for a listener. The helper captures its callback
        // proxy once, when notification watching starts; invalidating that
        // connection left it holding a dead proxy, so banners kept being
        // captured in the helper and silently never arrived in the app.
        if let existing = remoteService {
            notificationDelegate.lunarListener = lunarListener
            helperAvailable = true
            return existing
        }

        let conn = NSXPCConnection(serviceName: serviceName)

        // One exported object serves both callback protocols.
        notificationDelegate.lunarListener = lunarListener
        conn.exportedInterface = .underbrimAppDelegate()
        conn.exportedObject = notificationDelegate

        conn.interruptionHandler = { [weak self, weak conn] in
            Task { @MainActor in
                // Ignore stale handlers: an interruption from a deallocated
                // connection must not nil a freshly-built one.
                guard let self, let conn, self.connection === conn else { return }
                self.connection = nil
                self.remoteService = nil
                self.helperAvailable = false
                self.lastError = .unavailable
                conn.invalidate()
                self.helperRestarted()
            }
        }

        conn.invalidationHandler = { [weak self, weak conn] in
            Task { @MainActor in
                guard let self, let conn, self.connection === conn else { return }
                self.connection = nil
                self.remoteService = nil
                self.helperAvailable = false
                self.lastError = .unavailable
            }
        }

        conn.resume()

        let service = RemoteXPCService<UnderbrimHelperProtocol>(
            connection: conn,
            remoteInterface: UnderbrimHelperProtocol.self
        )

        connection = conn
        remoteService = service
        helperAvailable = true
        lastError = nil
        return service
    }

    private func notifyAuthorizationChange(_ granted: Bool) {
        guard lastKnownAuthorization != granted else { return }
        lastKnownAuthorization = granted
        accessibilityGranted = granted
        updatePolling()
        NotificationCenter.default.post(
            name: .accessibilityAuthorizationChanged,
            object: nil,
            userInfo: ["granted": granted]
        )
    }

    // MARK: - Monitoring

    /// AX trust has no public change notification. Check at startup, whenever
    /// the app becomes active, and every few seconds while it's missing and
    /// needed. Every AX-needing call also publishes changes.
    func startMonitoringAccessibilityAuthorization() {
        stopMonitoringAccessibilityAuthorization()
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { _ = await self?.isAccessibilityAuthorized() }
        }
        monitoring = true
        settingsWatch = Defaults.whenChanged(AccessibilityPermission.keys) { [weak self] in self?.updatePolling() }
        updatePolling()
        // Initial probe so observers get the current state without waiting
        // for the first activation.
        Task { _ = await isAccessibilityAuthorized() }
    }

    /// Granted in System Settings while Underbrim stays in the background (an
    /// accessory app: nothing makes it active), so while access is missing and
    /// something needs it, look every few seconds. Underbrim: only then, so
    /// the app isn't woken every 3 s for as long as it runs.
    private func updatePolling() {
        let wanted = monitoring && lastKnownAuthorization == false && AccessibilityPermission.needed
        if wanted, pollTimer == nil {
            pollTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                Task { @MainActor in _ = await self?.isAccessibilityAuthorized() }
            }
            pollTimer?.tolerance = 1  // its wakeups can share the system's
        } else if !wanted {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }

    func stopMonitoringAccessibilityAuthorization() {
        monitoring = false
        settingsWatch?.cancel()
        settingsWatch = nil
        updatePolling()
        guard let activationObserver else { return }
        NotificationCenter.default.removeObserver(activationObserver)
        self.activationObserver = nil
    }

    // MARK: - Accessibility

    // Fire-and-forget: callers invoke this from non-isolated contexts, and the work
    // itself hops onto the main actor.
    nonisolated func requestAccessibilityAuthorization() {
        Task { @MainActor in
            let service = ensureRemoteService()
            do {
                try await service.withService { service in
                    service.requestAccessibilityAuthorization()
                }
            } catch {
                lastError = .transport(underlying: error)
            }
        }
    }

    func isAccessibilityAuthorized() async -> Bool {
        do {
            let service = ensureRemoteService()
            let result: Bool = try await service.withContinuation { service, continuation in
                service.isAccessibilityAuthorized { authorized in
                    continuation.resume(returning: authorized)
                }
            }
            notifyAuthorizationChange(result)
            return result
        } catch {
            lastError = .transport(underlying: error)
            return false
        }
    }

    func ensureAccessibilityAuthorization(promptIfNeeded: Bool) async -> Bool {
        do {
            let service = ensureRemoteService()
            let result: Bool = try await service.withContinuation { service, continuation in
                service.ensureAccessibilityAuthorization(promptIfNeeded) { authorized in
                    continuation.resume(returning: authorized)
                }
            }
            notifyAuthorizationChange(result)
            return result
        } catch {
            lastError = .transport(underlying: error)
            return false
        }
    }

    // MARK: - Keyboard Brightness

    func currentKeyboardBrightness() async -> Float? {
        do {
            let service = ensureRemoteService()
            let result: NSNumber? = try await service.withContinuation { service, continuation in
                service.currentKeyboardBrightness { value in
                    continuation.resume(returning: value)
                }
            }
            return result?.floatValue
        } catch {
            lastError = .transport(underlying: error)
            return nil
        }
    }

    func setKeyboardBrightness(_ value: Float) async -> Bool {
        do {
            let service = ensureRemoteService()
            return try await service.withContinuation { service, continuation in
                service.setKeyboardBrightness(value) { success in
                    continuation.resume(returning: success)
                }
            }
        } catch {
            lastError = .transport(underlying: error)
            return false
        }
    }

    // MARK: - Screen Brightness

    func currentScreenBrightness() async -> Float? {
        do {
            let service = ensureRemoteService()
            let result: NSNumber? = try await service.withContinuation { service, continuation in
                service.currentScreenBrightness { value in
                    continuation.resume(returning: value)
                }
            }
            return result?.floatValue
        } catch {
            lastError = .transport(underlying: error)
            return nil
        }
    }

    func displayIDForBrightness() async -> CGDirectDisplayID? {
        do {
            let service = ensureRemoteService()
            let result: NSNumber? = try await service.withContinuation { service, continuation in
                service.displayIDForBrightness(with: { value in
                    continuation.resume(returning: value)
                })
            }
            guard let num = result else { return nil }
            return CGDirectDisplayID(num.uint32Value)
        } catch {
            lastError = .transport(underlying: error)
            return nil
        }
    }

    func setScreenBrightness(_ value: Float) async -> Bool {
        do {
            let service = ensureRemoteService()
            return try await service.withContinuation { service, continuation in
                service.setScreenBrightness(value) { success in
                    continuation.resume(returning: success)
                }
            }
        } catch {
            lastError = .transport(underlying: error)
            return false
        }
    }
    /// Returns the resulting brightness, or nil on failure.
    func adjustScreenBrightness(by value: Float) async -> Float? {
        do {
            let service = ensureRemoteService()
            return try await service.withContinuation { service, continuation in
                service.adjustScreenBrightness(by: value) { result in
                    continuation.resume(returning: result?.floatValue)
                }
            }
        } catch {
            lastError = .transport(underlying: error)
            return nil
        }
    }

    // MARK: - Lunar Events

    func isLunarAvailable() async -> Bool {
        do {
            let service = ensureRemoteService()
            return try await service.withContinuation { service, continuation in
                service.isLunarAvailable { available in
                    continuation.resume(returning: available)
                }
            }
        } catch {
            lastError = .transport(underlying: error)
            return false
        }
    }

    func startLunarEventStream(listener: UnderbrimHelperLunarListener) async -> Bool {
        lunarListener = listener
        // Register on the shared exported object too: the connection may
        // already exist (it isn't rebuilt for listeners any more), in
        // which case this is the only path that hooks Lunar events up.
        notificationDelegate.lunarListener = listener
        do {
            let service = ensureRemoteService()
            return try await service.withContinuation { service, continuation in
                service.startLunarEventStream { started in
                    continuation.resume(returning: started)
                }
            }
        } catch {
            lastError = .transport(underlying: error)
            return false
        }
    }

    func stopLunarEventStream() async {
        do {
            let service = ensureRemoteService()
            try await service.withService { service in
                service.stopLunarEventStream()
            }
        } catch {
            lastError = .transport(underlying: error)
            return
        }
    }

    func setLunarOSDHidden(_ hide: Bool) async -> Bool {
        do {
            let service = ensureRemoteService()
            return try await service.withContinuation { service, continuation in
                service.setLunarOSDHidden(hide) { ok in
                    continuation.resume(returning: ok)
                }
            }
        } catch {
            lastError = .transport(underlying: error)
            return false
        }
    }
}

// MARK: - Notification Center banners

/// The app's single exported XPC object. Banners go to the notification manager;
/// Lunar events are forwarded to whichever listener the OSD code registered,
/// since both callbacks share one connection.
final class NotificationXPCDelegate: NSObject, UnderbrimHelperAppDelegate {
    /// Written on the MainActor (connection setup, `startLunarEventStream`),
    /// read on the XPC connection's private delivery queue. The lock
    /// synchronizes cross-thread publication; the listener itself is still
    /// invoked on the delivery queue — no per-event actor hop on this hot
    /// path.
    private let lunarListenerLock = NSLock()
    private var _lunarListener: UnderbrimHelperLunarListener?

    var lunarListener: UnderbrimHelperLunarListener? {
        get {
            lunarListenerLock.lock()
            defer { lunarListenerLock.unlock() }
            return _lunarListener
        }
        set {
            lunarListenerLock.lock()
            _lunarListener = newValue
            lunarListenerLock.unlock()
        }
    }

    func lunarEventDidUpdate(_ event: UnderbrimLunarBrightnessEvent) {
        lunarListener?.lunarEventDidUpdate(event)
    }

    func lunarStreamDidStop(_ reason: String?) {
        lunarListener?.lunarStreamDidStop(reason)
    }

    func notificationDidAppear(_ banner: UnderbrimBanner) {
        Task { @MainActor in SystemNotificationManager.shared.receive(banner) }
    }
}

extension XPCHelperClient {
    /// What the helper did, or nil when it couldn't be reached.
    nonisolated func startNotificationWatching() async -> NotificationWatchStart? {
        do {
            let service = await MainActor.run { ensureRemoteService() }
            return try await service.withContinuation { service, continuation in
                service.startNotificationWatching { result in
                    continuation.resume(returning: result)
                }
            }
        } catch {
            await MainActor.run { self.lastError = .transport(underlying: error) }
            return nil
        }
    }

    nonisolated func setNotificationFilter(bundleIDs: Set<String>, allApps: Bool) {
        Task {
            let service = await MainActor.run { ensureRemoteService() }
            do {
                try await service.withService {
                    $0.setNotificationFilter(Array(bundleIDs), allApps: allApps)
                }
            } catch {
                await MainActor.run { self.lastError = .transport(underlying: error) }
            }
        }
    }

    nonisolated func stopNotificationWatching() {
        Task {
            let service = await MainActor.run { ensureRemoteService() }
            do {
                try await service.withService { $0.stopNotificationWatching() }
            } catch {
                await MainActor.run { self.lastError = .transport(underlying: error) }
            }
        }
    }
}
