//
//  PhoneActivities.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The iPhone's Live Activities, which macOS 26 shows in the menu bar for iPhone Mirroring. There's
//  no API: MenuBarActivityReader reads them through Accessibility; this file turns their text into the notch's.
//
//  The recognition and text rules are adapted from Islet
//  (github.com/aviralgarg05/casement, MIT, © 2026 The Islet contributors);
//  see THIRD_PARTY_LICENSES.
//

import ApplicationServices
import Defaults
import Foundation
import Observation
import SwiftUI

struct MenuBarItem: Equatable, Sendable {
    var identifier: String?
    var role: String?
    var subrole: String?
    var description: String?
    var title: String?
    var value: String?
    var help: String?
    /// Text of the item's parts, in reading order (a pill is several labels).
    var texts: [String] = []
    var actions: [String] = []
    /// Drawn by the Live Activity renderer rather than MenuBarAgent itself.
    var drawnByRenderer = false
    /// Collapsed into the menu bar's overflow, so the notch is the only place it shows.
    var hidden = false
}

/// MenuBarAgent's own words for a Live Activity, in every language it ships.
struct MenuBarLabels: Equatable, Sendable {
    var liveActivity: Set<String> = ["Live Activity"]
    var actions: Set<String> = ["End Live Activity", "Hide Live Activity"]
    var avControls: Set<String> = ["AV Controls"]
    var generic: Set<String> = ["Expanded"]

    static let english = MenuBarLabels()

    /// From MenuBarCore.loctable (locale → key → string).
    static func from(loctable: [String: [String: String]]) -> MenuBarLabels {
        var labels = english
        for table in loctable.values {
            table["liveActivity.accessibilityLabel"].map { _ = labels.liveActivity.insert($0) }
            for key in ["liveActivity.endLiveActivityMenuItem", "liveActivity.hideLiveActivityMenuItem"] {
                table[key].map { _ = labels.actions.insert($0) }
            }
            table["avModule.accessibilityLabel"].map { _ = labels.avControls.insert($0) }
            for key in ["liveActivity.expandedChevronDescription", "avModule.expandedChevronDescription"] {
                table[key].map { _ = labels.generic.insert($0) }
            }
        }
        return labels
    }

    static let system: MenuBarLabels = {
        let url = URL(fileURLWithPath: "/System/Library/CoreServices/MenuBarAgent.app/Contents/Resources/MenuBarCore.loctable")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return .english }
        return from(loctable: plist.compactMapValues { $0 as? [String: String] })
    }()
}

struct PhoneActivity: Identifiable, Equatable, Sendable {
    /// The menu bar slot: stable while the activity lives, whatever it says.
    let id: String
    var app: String?
    var text: String?
    /// A short value for the right of the notch ("10 min", "2 – 1").
    var value: String?
    var symbol: String
    var tint: Color
    /// What it says besides the value the card shows large ("Almost here!" of "Almost here! · 10 min").
    var textWithoutValue: String? {
        guard let text, let value else { return text }
        if text == value { return nil }
        return text.hasSuffix(" · " + value) ? String(text.dropLast(value.count + 3)) : text
    }
}

enum PhoneActivityText {
    static func isActivity(_ item: MenuBarItem, labels: MenuBarLabels) -> Bool {
        if item.drawnByRenderer { return true }
        let id = item.identifier?.lowercased() ?? ""
        // Battery, Wi-Fi, Now Playing, the Clock app's timer… all have one of these.
        if id.hasPrefix("com.apple.menuextra.") { return false }
        if id.contains("live-activity") || id.contains("liveactivit") { return true }
        let names = [item.description, item.title].compactMap { $0 }
        if names.contains(where: labels.avControls.contains) { return false }
        if names.contains(where: labels.liveActivity.contains) { return true }
        if item.actions.contains(where: labels.actions.contains) { return true }
        // MenuBarAgent gives every item of its own an identifier; one without, with text, is a pill.
        return item.identifier == nil && (item.role == "AXMenuBarItem" || item.subrole == "AXMenuExtra")
            && !content(item, labels: labels).isEmpty
    }

    /// The item's text without MenuBarAgent's own words and apps' picture names, de-duplicated across
    /// attributes but not across parts ("1", "CHE", "1" is a tied score).
    static func content(_ item: MenuBarItem, labels: MenuBarLabels) -> [String] {
        var seen = Set<String>()
        let attributes = [item.description, item.title, item.value, item.help].compactMap { $0 }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        let parts = item.texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return (attributes + parts).filter {
            !labels.liveActivity.contains($0) && !labels.generic.contains($0) && !labels.actions.contains($0) && !isAssetName($0)
        }
    }

    static func activity(from item: MenuBarItem, id: String, labels: MenuBarLabels) -> PhoneActivity? {
        guard isActivity(item, labels: labels) else { return nil }
        var pieces = content(item, labels: labels)
        // "Uber, 4 min" ("أوبر، ٤ د") in one label: split only when a known app stands before the comma.
        if pieces.count == 1, let comma = pieces[0].range(of: ", ") ?? pieces[0].range(of: "، "),
           PhoneActivityCatalog.app(named: String(pieces[0][..<comma.lowerBound])) != nil {
            pieces = [String(pieces[0][..<comma.lowerBound]), String(pieces[0][comma.upperBound...])]
        }
        var app: PhoneActivityCatalog.App?
        if let index = pieces.firstIndex(where: { PhoneActivityCatalog.app(named: $0) != nil }) {
            app = PhoneActivityCatalog.app(named: pieces.remove(at: index))
        }
        let text = joined(pieces)
        // An asset name is never shown, but "food_di_preparing_icon" may be the only clue to the symbol.
        let hint = ([item.description, item.title, item.value] + item.texts).compactMap { $0 }
            .filter(isAssetName).map(words(fromAssetName:)).joined(separator: " ")
        let look = app.map { ($0.symbol, $0.tint) } ?? PhoneActivityCatalog.look(for: [text, hint].joined(separator: " "))
        return PhoneActivity(id: id, app: app?.name, text: text.isEmpty ? nil : text, value: shortValue(text),
                             symbol: look.0, tint: look.1)
    }

    /// Joins the pill's labels: a number and its unit read as one phrase, other facts with a dot between.
    static func joined(_ pieces: [String]) -> String {
        if pieces.count == 2, !pieces[0].contains(" "), pieces[0].last?.isNumber == true, bareWord(pieces[1]) {
            return pieces[0] + " " + pieces[1]
        }
        return pieces.reduce(into: "") { out, piece in
            guard !out.isEmpty else { return out = piece }
            let previous = out.split(separator: " ").last.map(String.init) ?? ""
            // A unit carries on from its number ("12", "دقيقة" in any language) or from the unit before it ("min", "away").
            let afterNumber = previous.last?.isNumber == true && (unit(piece) || bareWord(piece) && piece.count <= 7)
            let carriesOn = afterNumber || unit(piece) && unit(previous)
            out += (carriesOn ? " " : " · ") + piece
        }
    }

    /// The part that fits the right of the notch: the last fact, when short and holding a digit; not a
    /// score with numbers on both sides ("IND 245/3 · AUS 198"), which the card shows whole.
    static func shortValue(_ text: String) -> String? {
        let parts = text.components(separatedBy: " · ")
        guard parts.filter({ $0.contains(where: \.isNumber) }).count < 2,
              let last = parts.last, last.count <= 8, last.contains(where: \.isNumber) else { return nil }
        return last
    }

    static func unit(_ text: String) -> Bool {
        ["min", "mins", "minute", "minutes", "sec", "secs", "h", "hr", "hrs", "hour", "hours",
         "km", "mi", "m", "ft", "%", "°", "left", "away", "remaining"].contains(text.lowercased())
    }

    /// Letters only and short, not capitals ("CHE" is a team; "min", "Minuten" and "دقيقة" are units).
    static func bareWord(_ text: String) -> Bool {
        guard (1...12).contains(text.count),
              text.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) }) else { return false }
        let capitals = text.contains(where: \.isUppercase) && !text.contains(where: \.isLowercase)
        return !capitals || text.count <= 2
    }

    static let assetWords: Set<String> = ["icon", "image", "img", "asset", "glyph", "badge", "ic", "bg", "logo", "pic"]

    /// An app's picture name (`food_di_preparing_icon`, `statusIconSmall`); `washing_machine` and `IND_vs_AUS` are words.
    static func isAssetName(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 64, !text.contains(" "),
              text.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "_" }) else { return false }
        if text.contains("_") {
            return text.lowercased().split(separator: "_").contains { assetWords.contains(String($0)) }
        }
        guard text.contains(where: \.isUppercase), text.first?.isUppercase == false else { return false }
        let words = camelCaseWords(text)
        return words.contains { assetWords.contains($0) } && words.contains { $0.count >= 2 && !assetWords.contains($0) }
    }

    static func camelCaseWords(_ text: String) -> [String] {
        var out: [String] = []
        var word = ""
        for character in text {
            if character.isUppercase, !word.isEmpty {
                out.append(word.lowercased())
                word = ""
            }
            word.append(character)
        }
        if !word.isEmpty { out.append(word.lowercased()) }
        return out
    }

    static func words(fromAssetName name: String) -> String {
        name.split(separator: "_").flatMap { camelCaseWords(String($0)) }.filter { !assetWords.contains($0) }.joined(separator: " ")
    }
}

/// Apps that run Live Activities, with a symbol and colour; most pills don't name their app.
enum PhoneActivityCatalog {
    struct App: Sendable {
        let name: String
        let symbol: String
        let tint: Color
        var arabic: String? = nil
    }

    private static func rgb(_ hex: UInt32) -> Color {
        Color(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    static let delivery = "takeoutbag.and.cup.and.straw.fill"
    static let apps: [App] = [
        App(name: "Uber Eats", symbol: delivery, tint: rgb(0x06C167)),
        App(name: "DoorDash", symbol: delivery, tint: rgb(0xFF3008)),
        App(name: "Deliveroo", symbol: delivery, tint: rgb(0x00CCBC)),
        App(name: "Talabat", symbol: delivery, tint: rgb(0xFF5A00), arabic: "طلبات"),
        App(name: "Keeta", symbol: delivery, tint: rgb(0xFFD100), arabic: "كيتا"),
        App(name: "HungerStation", symbol: delivery, tint: rgb(0xFFC800), arabic: "هنقرستيشن"),
        App(name: "Careem", symbol: delivery, tint: rgb(0x3FBF74), arabic: "كريم"),
        App(name: "Uber", symbol: "car.fill", tint: .white, arabic: "أوبر"),
    ]

    /// Only an exact name counts: "Man United 2 - 1 Arsenal" is a score, not an app.
    static func app(named text: String) -> App? {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return apps.first { app in
            [app.name, app.arabic].compactMap { $0 }.contains { $0.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        }
    }

    static func look(for text: String) -> (String, Color) {
        let lower = text.lowercased()
        func mentions(_ words: [String]) -> Bool { words.contains { lower.contains($0) } }
        if mentions(["order", "deliver", "courier", "driver", "restaurant", "preparing", "picked up", "on the way", "food",
                     "طلب", "توصيل", "مندوب", "المطعم", "الطريق"]) {
            return (delivery, .green)
        }
        if mentions(["ride", "pickup", "pick-up", "trip", "captain", "car ", "رحلة", "الكابتن"]) { return ("car.fill", .white) }
        if mentions(["flight", "gate", "boarding", "departs", "takeoff", "landing", "طيران", "بوابة"]) { return ("airplane", .blue) }
        if text.range(of: #"\d+\s*[-–]\s*\d+"#, options: .regularExpression) != nil { return ("sportscourt.fill", .red) }
        if text.range(of: #"\d+:\d\d"#, options: .regularExpression) != nil { return ("timer", .orange) }
        return ("dot.radiowaves.left.and.right", .white)
    }
}

@MainActor
@Observable
final class PhoneActivityStore {
    static let shared = PhoneActivityStore()

    /// Left to right as in the menu bar, without the ones hidden here.
    private(set) var activities: [PhoneActivity] = []
    var featured: PhoneActivity? { activities.first }

    /// Hidden in the notch until they leave the menu bar.
    @ObservationIgnored private var hidden: Set<String> = []
    @ObservationIgnored private var reader: MenuBarActivityReader?

    static var isSupported: Bool {
        if #available(macOS 26, *) { true } else { false }
    }

    func start() {
        Defaults.whenChanged([.showPhoneActivities]) { [weak self] in self?.refresh() }
        NotificationCenter.default.addObserver(forName: .accessibilityAuthorizationChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    func refresh() {
        let on = Defaults[.showPhoneActivities] && Self.isSupported && AXIsProcessTrusted()
        if on, reader == nil {
            let reader = MenuBarActivityReader { [weak self] in self?.receive($0) }
            self.reader = reader
            reader.start()
        } else if !on, let reader {
            reader.stop()
            self.reader = nil
            receive([])
        }
    }

    func receive(_ list: [PhoneActivity]) {
        hidden.formIntersection(list.map(\.id))
        activities = list.filter { !hidden.contains($0.id) }
    }

    func open(_ activity: PhoneActivity) {
        reader?.press(id: activity.id)
    }

    func hide(_ activity: PhoneActivity) {
        hidden.insert(activity.id)
        activities.removeAll { $0.id == activity.id }
    }
}
