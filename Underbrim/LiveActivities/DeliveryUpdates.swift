//
//  DeliveryUpdates.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Deliveries followed through their mirrored iPhone notifications, for apps without Live Activities
//  (HungerStation, Jahez…). An order shows its newest status until delivered, cancelled or quiet for
//  two hours. Only the banner's text is used, and it stays in memory.
//

import Defaults
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class DeliveryTracker {
    static let shared = DeliveryTracker()

    nonisolated static let defaultApps = ["HungerStation", "Jahez", "Ninja", "Mrsool", "ToYou", "The Chefz", "Talabat", "Keeta",
                              "Careem", "Noon", "Uber Eats", "DoorDash", "Deliveroo"]
    /// The names Arabic iPhones give them, for matching their notifications.
    nonisolated static let arabicNames = ["هنقرستيشن": "HungerStation", "جاهز": "Jahez", "نينجا": "Ninja", "مرسول": "Mrsool",
                                          "تويو": "ToYou", "ذا شفز": "The Chefz", "طلبات": "Talabat", "كيتا": "Keeta", "كريم": "Careem", "نون": "Noon"]
    static let quietLimit: TimeInterval = 2 * 3600
    static let finishedShown: TimeInterval = 3 * 60

    struct Step: Equatable, Sendable {
        let at: Date
        let text: String
    }

    struct Order: Identifiable, Equatable, Sendable {
        /// The app's name, as its notifications show it: one order per app.
        var id: String { app }
        let app: String
        var steps: [Step]
        /// The minutes the latest notification that stated a time gave, and when.
        var minutes: Int?
        var minutesAt: Date?
        var finished = false

        var latest: String { steps.last?.text ?? "" }
        var updatedAt: Date { steps.last?.at ?? .distantPast }

        /// Minutes left by that estimate, counting down; nil once it's run out.
        func minutesLeft(at now: Date) -> Int? {
            guard !finished, let minutes, let minutesAt else { return nil }
            let left = minutes - Int(now.timeIntervalSince(minutesAt) / 60)
            return left > 0 ? left : nil
        }
    }

    private(set) var orders: [Order] = []
    @ObservationIgnored private var cleanup: Task<Void, Never>?

    func start() {
        Defaults.whenChanged([.showDeliveryUpdates]) { [weak self] in
            if !Defaults[.showDeliveryUpdates] { self?.orders = [] }
        }
    }

    static func app(of notification: SystemNotification, in apps: [String]) -> String? {
        guard let appName = notification.appName else { return nil }
        let names = [appName, arabicNames[NotificationPanelDetection.cleanedAppName(appName)]].compactMap { $0 }
            .map(NotificationPanelDetection.normalizedAppName).filter { !$0.isEmpty }
        return apps.first { names.contains(NotificationPanelDetection.normalizedAppName($0)) }
    }

    func receive(_ notification: SystemNotification) {
        guard Defaults[.showDeliveryUpdates], let app = Self.app(of: notification, in: Defaults[.deliveryApps]) else { return }
        let text = [notification.title, notification.body].compactMap { $0 }.joined(separator: " · ")
        guard !text.isEmpty else { return }
        record(app: app, text: notification.body ?? text, fullText: text, at: notification.receivedAt)
    }

    func record(app: String, text: String, fullText full: String, at date: Date) {
        var order = orders.first { $0.app == app && !$0.finished } ?? Order(app: app, steps: [])
        // A promotion doesn't start an order; it only joins one already under way.
        guard !order.steps.isEmpty || Self.isAboutAnOrder(full) else { return }
        order.steps.append(Step(at: date, text: text))
        order.steps = Array(order.steps.suffix(6))
        if let minutes = Self.minutes(in: full) {
            order.minutes = minutes
            order.minutesAt = date
        }
        order.finished = Self.isFinished(full)
        orders.removeAll { $0.app == app }
        orders.insert(order, at: 0)
        scheduleCleanup()
    }

    func dismiss(_ order: Order) {
        orders.removeAll { $0.app == order.app }
    }

    func prune() {
        let now = Date()
        orders.removeAll { order in
            now.timeIntervalSince(order.updatedAt) >= (order.finished ? Self.finishedShown : Self.quietLimit)
        }
    }

    private func scheduleCleanup() {
        cleanup?.cancel()
        let deadlines = orders.map { $0.updatedAt.addingTimeInterval($0.finished ? Self.finishedShown : Self.quietLimit) }
        guard let next = deadlines.min() else { return }
        cleanup = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, next.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            self?.prune()
            self?.scheduleCleanup()
        }
    }

    // MARK: Reading a notification

    /// Without the direction marks some apps wrap Arabic text in, which split words for the rules below.
    private static func plain(_ text: String) -> String {
        text.filter { !"\u{200E}\u{200F}\u{061C}\u{2066}\u{2067}\u{2068}\u{2069}".contains($0) }
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// "12 min", "12 minutes", "١٢ دقيقة", "خلال 12 دقائق": the minutes a notification states ("20 د.إ" is a price).
    static func minutes(in text: String) -> Int? {
        // Arabic-Indic and other decimal digits read as 0–9; "⑩" or "十" aren't digits here.
        let ascii = String(plain(text).map { character -> Character in
            guard character.unicodeScalars.count == 1, character.unicodeScalars.first?.properties.numericType == .decimal,
                  let value = character.wholeNumberValue else { return character }
            return Character(String(value))
        })
        let pattern = #"(\d{1,3})\s*(?:minutes?\b|mins?\b|دقيق[ةه]|دقائق|د(?![.\p{L}]))"#
        guard let range = ascii.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
        return Int(ascii[range].prefix { $0.isNumber })
    }

    /// Delivered or cancelled, in English or Arabic; not "will be delivered" or "سيتم توصيل".
    static func isFinished(_ text: String) -> Bool {
        let text = plain(text)
        return [#"(?<!be )(?<!being )\b(?:delivered|cancell?ed)\b"#, #"\benjoy your\b"#,
                #"(?<!\p{L})تم\s+(?:ال)?(?:توصيل|تسليم|إلغاء|الغاء)"#, #"بالعافية|بالهناء|(?<!\p{L})ألغي"#]
            .contains { matches(text, $0) }
    }

    /// About an order, not a promotion ("50% off today").
    static func isAboutAnOrder(_ text: String) -> Bool {
        let text = plain(text).lowercased()
        let promotion = ["%", "discount", "promo", "offer", "coupon", "خصم", "عرض", "كوبون"].contains { text.contains($0) }
        // A rating prompt after delivery ("How was your order?") isn't a new order.
        let rating = matches(text, #"\b(?:rate|rating|review|feedback|how was)\b|تقييم|كيف كان|(?<!\p{L})قيّ?م(?!\p{L})"#)
        let order = minutes(in: text) != nil || ["order", "driver", "courier", "rider", "deliver", "on the way", "on its way",
                                                 "picked up", "preparing", "arriving", "arrived", "طلب", "مندوب", "السائق",
                                                 "الكابتن", "الطريق", "توصيل", "تحضير", "وصل"].contains { text.contains($0) }
        return order && !promotion && !rating
    }
}
