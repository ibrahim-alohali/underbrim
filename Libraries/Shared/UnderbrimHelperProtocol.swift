//
//  UnderbrimHelperProtocol.swift
//  UnderbrimHelper
//
//  Created by Alexander on 2025-11-16.
//

import Foundation

@objc protocol UnderbrimHelperLunarListener {
    func lunarEventDidUpdate(_ event: UnderbrimLunarBrightnessEvent)
    func lunarStreamDidStop(_ reason: String?)
}

@objc(UnderbrimLunarBrightnessEvent)
final class UnderbrimLunarBrightnessEvent: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }

    let brightness: Double
    let display: Int

    init(brightness: Double, display: Int) {
        self.brightness = brightness
        self.display = display
        super.init()
    }

    required init?(coder: NSCoder) {
        brightness = coder.decodeDouble(forKey: "brightness")
        display = coder.decodeInteger(forKey: "display")
        super.init()
    }

    func encode(with coder: NSCoder) {
        coder.encode(brightness, forKey: "brightness")
        coder.encode(display, forKey: "display")
    }
}

/// A banner Notification Center showed, as the helper read it. Its text comes
/// from another app, so the helper cleans it before it's sent.
@objc(UnderbrimBanner)
final class UnderbrimBanner: NSObject, NSSecureCoding, Sendable {
    static var supportsSecureCoding: Bool { true }

    /// Notification Center's identifier for the banner; never shown.
    let token: String
    let appName: String?
    let bundleID: String?
    let title: String?
    let subtitle: String?
    let body: String?

    init(token: String, appName: String?, bundleID: String?, title: String?, subtitle: String?, body: String?) {
        self.token = token
        self.appName = appName
        self.bundleID = bundleID
        self.title = title
        self.subtitle = subtitle
        self.body = body
        super.init()
    }

    required init?(coder: NSCoder) {
        guard let token = coder.decodeObject(of: NSString.self, forKey: "token") as String?, !token.isEmpty else { return nil }
        self.token = token
        appName = coder.decodeObject(of: NSString.self, forKey: "appName") as String?
        bundleID = coder.decodeObject(of: NSString.self, forKey: "bundleID") as String?
        title = coder.decodeObject(of: NSString.self, forKey: "title") as String?
        subtitle = coder.decodeObject(of: NSString.self, forKey: "subtitle") as String?
        body = coder.decodeObject(of: NSString.self, forKey: "body") as String?
        super.init()
    }

    func encode(with coder: NSCoder) {
        coder.encode(token, forKey: "token")
        coder.encode(appName, forKey: "appName")
        coder.encode(bundleID, forKey: "bundleID")
        coder.encode(title, forKey: "title")
        coder.encode(subtitle, forKey: "subtitle")
        coder.encode(body, forKey: "body")
    }
}

extension UnderbrimBanner {
    /// Banner text the notch may show: Relay.label's rules (no control or direction-override
    /// characters, bounded), line by line so a message keeps its line breaks; nil when nothing's left.
    /// Isolates and embeddings stay: apps wrap names in them, and right-to-left text needs them.
    static func cleaned(_ text: String?, maxLength: Int) -> String? {
        guard let text else { return nil }
        var result = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { Relay.label(String($0), maxLength: maxLength, removing: Relay.directionOverrides) ?? "" }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if result.count > maxLength { result = String(result.prefix(maxLength)) + "…" }
        return result.isEmpty ? nil : result
    }
}

/// What asking the helper to watch for banners did.
@objc enum NotificationWatchStart: Int {
    case started
    /// It was watching this Notification Center already.
    case alreadyRunning
    case accessibilityNotTrusted
    case notificationCenterNotRunning
    /// Notification Center didn't take the observer.
    case observerFailed
}

extension NotificationWatchStart: CustomStringConvertible {
    /// How the helper's log names each result.
    var description: String {
        switch self {
        case .started: "started"
        case .alreadyRunning: "already running"
        case .accessibilityNotTrusted: "Accessibility not allowed"
        case .notificationCenterNotRunning: "Notification Center not running"
        case .observerFailed: "observer not added"
        }
    }
}

@objc protocol UnderbrimHelperProtocol {
    func isAccessibilityAuthorized(with reply: @escaping (Bool) -> Void)
    func requestAccessibilityAuthorization()
    func ensureAccessibilityAuthorization(_ promptIfNeeded: Bool, with reply: @escaping (Bool) -> Void)
    func currentKeyboardBrightness(with reply: @escaping (NSNumber?) -> Void)
    func setKeyboardBrightness(_ value: Float, with reply: @escaping (Bool) -> Void)
    func displayIDForBrightness(with reply: @escaping (NSNumber?) -> Void)
    func currentScreenBrightness(with reply: @escaping (NSNumber?) -> Void)
    func setScreenBrightness(_ value: Float, with reply: @escaping (Bool) -> Void)
    func adjustScreenBrightness(by value: Float, with reply: @escaping (NSNumber?) -> Void)
    func isLunarAvailable(with reply: @escaping (Bool) -> Void)
    func startLunarEventStream(with reply: @escaping (Bool) -> Void)
    func stopLunarEventStream()
    func setLunarOSDHidden(_ hide: Bool, with reply: @escaping (Bool) -> Void)
    func startNotificationWatching(with reply: @escaping (NotificationWatchStart) -> Void)
    func stopNotificationWatching()
    func setNotificationFilter(_ bundleIDs: [String], allApps: Bool)
}

@objc protocol UnderbrimHelperDelegate {
    func notificationDidAppear(_ banner: UnderbrimBanner)
}

@objc protocol UnderbrimHelperAppDelegate: UnderbrimHelperLunarListener, UnderbrimHelperDelegate {}

extension NSXPCInterface {
    /// The app's callback interface, built the same on both ends, with the classes its calls carry.
    static func underbrimAppDelegate() -> NSXPCInterface {
        let interface = NSXPCInterface(with: (any UnderbrimHelperAppDelegate).self)
        interface.setClasses(
            NSSet(array: [UnderbrimLunarBrightnessEvent.self]) as! Set<AnyHashable>,
            for: #selector(UnderbrimHelperLunarListener.lunarEventDidUpdate(_:)),
            argumentIndex: 0,
            ofReply: false
        )
        interface.setClasses(
            NSSet(array: [UnderbrimBanner.self]) as! Set<AnyHashable>,
            for: #selector(UnderbrimHelperDelegate.notificationDidAppear(_:)),
            argumentIndex: 0,
            ofReply: false
        )
        return interface
    }
}
