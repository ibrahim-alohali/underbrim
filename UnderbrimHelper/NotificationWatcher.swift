//
//  NotificationWatcher.swift
//  UnderbrimHelper
//
import AppKit
import ApplicationServices
import Foundation

private let notificationCenterBundleID = "com.apple.notificationcenterui"
private let orderedChildrenAttribute = "AXOrderedChildren"
private let stackingIdentifierAttribute = "AXStackingIdentifier"
private let maxAccessibilityNodes = 1_024
private let maxTextNodes = 256
private let structuralIdentifiers: Set<String> = [
    "AXNotificationListItems",
    "widgets-overlay-view"
]
private let settleDelay: TimeInterval = 0.15

private extension AXUIElement {
    /// Both lists an element gives, its children and its ordered children: the reader walks each.
    var childAndOrderedElements: [AXUIElement] { childElements + elements(orderedChildrenAttribute) }
}

final class NotificationWatcher {
    private final class ObserverContext: @unchecked Sendable {
        weak var watcher: NotificationWatcher?
    }

    var onBanner: ((UnderbrimBanner) -> Void)?

    private var appElement: AXUIElement?
    private var axObserver: AXObserver?
    private var observerRunLoop: AXObserverRunLoop?
    private var observerContext: ObserverContext?
    private var scanScheduled = false
    private var settleWorkItem: DispatchWorkItem?
    private var observedWindows: [CFHashCode: AXUIElement] = [:]
    private var liveTokens = Set<String>()
    private var allowedBundleIDs = Set<String>()
    private var mirrorAllApps = false
    private var parkedWindowByToken: [String: Int] = [:]
    private var parkedWindows: [Int: (window: AXUIElement, origin: CGPoint)] = [:]

    var isRunning: Bool { appElement != nil }

    func configureFilter(bundleIDs: Set<String>, allApps: Bool) {
        allowedBundleIDs = bundleIDs
        mirrorAllApps = allApps
    }

    func start() -> NotificationWatchStart {
        guard AXIsProcessTrusted() else { return .accessibilityNotTrusted }
        guard let application = NSRunningApplication.runningApplications(
            withBundleIdentifier: notificationCenterBundleID
        ).first else {
            return .notificationCenterNotRunning
        }
        // Underbrim: Notification Center relaunched (it crashed, or `killall
        // NotificationCenter`) while this watched the old one: start over.
        var boundPID: pid_t = 0
        if let appElement, AXUIElementGetPid(appElement, &boundPID) == .success,
           boundPID != application.processIdentifier {
            stop()
        }
        guard !isRunning else { return .alreadyRunning }

        appElement = AXUIElementCreateApplication(application.processIdentifier)
        guard installObserver(for: application.processIdentifier) else {
            appElement = nil
            return .observerFailed
        }

        refreshObservedWindows()
        scan()
        return .started
    }

    func stop() {
        settleWorkItem?.cancel()
        settleWorkItem = nil
        if let observer = axObserver {
            if let appElement {
                removeObserverNotifications(from: appElement, observer: observer)
            }
            for window in observedWindows.values {
                removeObserverNotifications(from: window, observer: observer)
            }
        }
        observedWindows.removeAll()
        observerRunLoop?.stop()
        axObserver = nil
        observerRunLoop = nil
        observerContext = nil
        scanScheduled = false
        liveTokens.removeAll()
        restoreAllWindows()
        appElement = nil
    }

    private func addObserverNotifications(to element: AXUIElement) -> Bool {
        guard let observer = axObserver, let context = observerContext else { return false }
        let refcon = Unmanaged.passUnretained(context).toOpaque()
        var registered = false
        for notification in NotificationObservationPolicy.structuralNotifications {
            let result = AXObserverAddNotification(
                observer,
                element,
                notification as CFString,
                refcon
            )
            if result == .success {
                registered = true
            }
        }
        return registered
    }

    private func removeObserverNotifications(from element: AXUIElement, observer: AXObserver) {
        for notification in NotificationObservationPolicy.structuralNotifications {
            AXObserverRemoveNotification(observer, element, notification as CFString)
        }
    }

    private func refreshObservedWindows() {
        guard let appElement else { return }
        let windows = appElement.elements(kAXWindowsAttribute)
        var current = Set<CFHashCode>()
        for window in windows {
            let subrole = window.string(kAXSubroleAttribute)
            let identifier = window.string(kAXIdentifierAttribute)
            guard NotificationObservationPolicy.shouldObserveElement(
                subrole: subrole,
                identifier: identifier
            ) else { continue }

            let key = CFHash(window)
            current.insert(key)
            guard observedWindows[key] == nil else { continue }
            _ = addObserverNotifications(to: window)
            observedWindows[key] = window
        }

        let stale = observedWindows.keys.filter { !current.contains($0) }
        for key in stale {
            if let window = observedWindows.removeValue(forKey: key) {
                if let observer = axObserver {
                    removeObserverNotifications(from: window, observer: observer)
                }
            }
        }
    }

    private func installObserver(for processIdentifier: pid_t) -> Bool {
        var observer: AXObserver?
        let result = AXObserverCreate(processIdentifier, { _, element, notification, refcon in
            guard let refcon else { return }
            let context = Unmanaged<ObserverContext>.fromOpaque(refcon).takeUnretainedValue()
            let name = notification as String
            let subrole = name == "AXUIElementDestroyed"
                ? nil
                : element.string(kAXSubroleAttribute)
            let identifier = name == "AXUIElementDestroyed"
                ? nil
                : element.string(kAXIdentifierAttribute)
            DispatchQueue.main.async { [weak context] in
                context?.watcher?.handleObserverEvent(
                    notification: name,
                    subrole: subrole,
                    identifier: identifier
                )
            }
        }, &observer)
        guard result == .success, let observer, let appElement else { return false }

        let context = ObserverContext()
        context.watcher = self
        observerContext = context
        axObserver = observer
        guard addObserverNotifications(to: appElement) else {
            axObserver = nil
            observerContext = nil
            return false
        }

        let runLoop = AXObserverRunLoop(observer: observer)
        guard runLoop.start() else {
            axObserver = nil
            observerContext = nil
            return false
        }
        observerRunLoop = runLoop
        return true
    }

    private func handleObserverEvent(
        notification: String,
        subrole: String?,
        identifier: String?
    ) {
        guard NotificationObservationPolicy.shouldScan(
            notification: notification,
            subrole: subrole,
            identifier: identifier
        ) else { return }

        scheduleScan()
        scheduleSettleScan()
    }

    private func scheduleSettleScan() {
        guard settleWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.settleWorkItem = nil
            self.scan()
        }
        settleWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay, execute: workItem)
    }

    private func scheduleScan() {
        guard !scanScheduled else { return }
        scanScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scanScheduled = false
            self.scan()
        }
    }

    private func scan() {
        autoreleasepool {
            guard let appElement else { return }
            refreshObservedWindows()
            var seen = Set<String>()

            for window in appElement.elements(kAXWindowsAttribute) {
                guard case .banners(let banners) = inspect(window) else { continue }

                for banner in banners {
                    let token = token(for: banner)
                    seen.insert(token)
                    guard !liveTokens.contains(token) else { continue }

                    let notification = capture(banner, token: token)
                    guard mirrorAllApps || isAllowed(notification) else { continue }
                    guard park(window, for: token) else {
                        // The token can name an app's conversation, so it stays out of the log.
                        NSLog("[UnderbrimHelper] could not hide a notification banner")
                        continue
                    }

                    liveTokens.insert(token)
                    onBanner?(notification)
                    // Underbrim: macOS's own banner comes back once the notch's mirror is done;
                    // an alert would otherwise stay off screen for good, with other apps' banners in
                    // its window. The token stays seen, so it isn't parked or sent again.
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.mirrorDuration) { [weak self] in
                        self?.restoreWindowIfUnused(token)
                    }
                }
            }

            let removed = liveTokens.subtracting(seen)
            liveTokens.formIntersection(seen)
            removed.forEach(restoreWindowIfUnused)
        }
    }

    private enum WindowContents {
        case ignored
        case banners([AXUIElement])
    }

    private func inspect(_ root: AXUIElement) -> WindowContents {
        var pending: [(element: AXUIElement, insideBanner: Bool, insideList: Bool)] = [
            (root, false, false)
        ]
        var visited = Set<CFHashCode>()
        var banners: [AXUIElement] = []

        while let node = pending.popLast() {
            let element = node.element
            guard visited.insert(CFHash(element)).inserted else { continue }
            guard visited.count <= maxAccessibilityNodes else { return .ignored }

            let subrole = element.string(kAXSubroleAttribute)
            let identifier = element.string(kAXIdentifierAttribute)
            let stackingIdentifier = node.insideList && subrole == "AXButton"
                ? element.string(stackingIdentifierAttribute)
                : nil
            if NotificationPanelDetection.isPanel(
                subrole: subrole,
                identifier: identifier,
                stackingIdentifier: stackingIdentifier,
                insideNotificationList: node.insideList && !node.insideBanner
            ) || NotificationPanelDetection.isDesktopWidget(identifier: identifier) {
                return .ignored
            }

            if !node.insideBanner, NotificationPanelDetection.isBanner(subrole: subrole) {
                banners.append(element)
            }

            let childInsideBanner = node.insideBanner || NotificationPanelDetection.isBanner(subrole: subrole)
            let childInsideList = node.insideList
                || identifier == NotificationPanelDetection.panelListIdentifier
            pending.append(contentsOf: element.childAndOrderedElements.reversed().map {
                ($0, childInsideBanner, childInsideList)
            })
        }

        return banners.isEmpty ? .ignored : .banners(banners)
    }

    private func token(for banner: AXUIElement) -> String {
        if let identifier = banner.string(kAXIdentifierAttribute),
           !identifier.isEmpty,
           !structuralIdentifiers.contains(identifier) {
            return identifier
        }
        if let stackingIdentifier = banner.string(stackingIdentifierAttribute),
           !stackingIdentifier.isEmpty {
            return stackingIdentifier
        }

        return "ax-\(CFHash(banner))"
    }

    /// How long the app shows a mirrored notification (SystemNotificationManager.displayDuration).
    private static let mirrorDuration: TimeInterval = 8

    private func park(_ window: AXUIElement, for token: String) -> Bool {
        let key = Int(bitPattern: CFHash(window))
        if parkedWindows[key] == nil {
            guard let origin = window.point(kAXPositionAttribute) else { return false }
            parkedWindows[key] = (window, origin)
            var hidden = CGPoint(x: -10000, y: -10000)
            guard let value = AXValueCreate(.cgPoint, &hidden),
                  AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) == .success
            else {
                parkedWindows.removeValue(forKey: key)
                return false
            }
        }
        parkedWindowByToken[token] = key
        return true
    }

    private func restoreWindowIfUnused(_ token: String) {
        guard let key = parkedWindowByToken.removeValue(forKey: token),
              !parkedWindowByToken.values.contains(key),
              let parked = parkedWindows.removeValue(forKey: key)
        else { return }
        var origin = parked.origin
        if let value = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(parked.window, kAXPositionAttribute as CFString, value)
        }
    }

    private func restoreAllWindows() {
        for token in Array(parkedWindowByToken.keys) {
            restoreWindowIfUnused(token)
        }
        parkedWindowByToken.removeAll()
        parkedWindows.removeAll()
    }

    /// The banner's text, cleaned here once: it comes from another app.
    private func capture(_ banner: AXUIElement, token: String) -> UnderbrimBanner {
        let parts = collectText(in: banner)
        let description = (banner["AXAttributedDescription"] as? NSAttributedString)?.string
            ?? banner["AXAttributedDescription"] as? String
        let appName = UnderbrimBanner.cleaned(description.flatMap(NotificationPanelDetection.appName(inDescription:)), maxLength: 100)

        return UnderbrimBanner(
            token: token,
            appName: appName,
            bundleID: appName.flatMap(AppNameResolver.shared.bundleID(forAppNamed:)),
            title: UnderbrimBanner.cleaned(parts["title"], maxLength: 300),
            subtitle: UnderbrimBanner.cleaned(parts["subtitle"], maxLength: 300),
            body: UnderbrimBanner.cleaned(parts["body"], maxLength: 2000)
        )
    }

    private func collectText(in root: AXUIElement) -> [String: String] {
        var parts: [String: String] = [:]
        var pending = [root]
        var visited = Set<CFHashCode>()

        while let element = pending.popLast() {
            guard visited.insert(CFHash(element)).inserted else { continue }
            guard visited.count <= maxTextNodes else { break }

            if let identifier = element.string(kAXIdentifierAttribute),
               let value = element[kAXValueAttribute] as? String {
                let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
                switch identifier {
                case "title":
                    parts["title"] = value
                case "header" where parts["title"] == nil:
                    parts["title"] = value
                case "subtitle":
                    parts["subtitle"] = value
                case "body":
                    parts["body"] = value
                default:
                    break
                }
            }

            pending.append(contentsOf: element.childAndOrderedElements.reversed())
        }

        return parts
    }

    private func isAllowed(_ notification: UnderbrimBanner) -> Bool {
        if let bundleID = notification.bundleID {
            return allowedBundleIDs.contains(bundleID)
        }
        guard let appName = notification.appName?.lowercased(), !appName.isEmpty else {
            return false
        }
        return allowedBundleIDs.contains { bundleID in
            guard let lastComponent = bundleID.split(separator: ".").last else { return false }
            return NotificationPanelDetection.normalizedAppName(appName)
                == NotificationPanelDetection.normalizedAppName(String(lastComponent))
        }
    }
}

private final class AXObserverRunLoop {
    private let observer: AXObserver
    private let ready = DispatchSemaphore(value: 0)
    private var thread: Thread?
    private var runLoop: CFRunLoop?

    init(observer: AXObserver) {
        self.observer = observer
    }

    func start() -> Bool {
        let thread = Thread { [weak self] in
            guard let self else { return }
            let runLoop = CFRunLoopGetCurrent()
            self.runLoop = runLoop
            CFRunLoopAddSource(
                runLoop,
                AXObserverGetRunLoopSource(self.observer),
                .defaultMode
            )
            self.ready.signal()
            CFRunLoopRun()
            CFRunLoopRemoveSource(
                runLoop,
                AXObserverGetRunLoopSource(self.observer),
                .defaultMode
            )
        }
        self.thread = thread
        thread.start()
        return ready.wait(timeout: .now() + 1) == .success
    }

    func stop() {
        guard let runLoop else { return }
        CFRunLoopStop(runLoop)
        CFRunLoopWakeUp(runLoop)
        thread = nil
        self.runLoop = nil
    }
}
