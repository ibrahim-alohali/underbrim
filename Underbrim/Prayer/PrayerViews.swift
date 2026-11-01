//
//  PrayerViews.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Prayer times in the notch: the closed notch at each prayer's time, the Home widget and the
//  day's page. Amber fills only a prayer whose time has come; passed ones are dimmed.
//

import AppKit
import SwiftUI

extension PrayerMoment {
    func spokenText(in zone: TimeZone) -> String {
        String(localized: "It's time for \(title), \(PrayerFormat.time(at, zone))")
    }
}

enum PrayerFormat {
    static func zone(_ place: PrayerPlace?) -> TimeZone { place?.zone ?? .current }

    static func time(_ date: Date, _ zone: TimeZone) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: zone))
    }

    /// "Tomorrow at 4:43 AM" when it isn't today where the place is. From `now`, not the clock.
    static func when(_ date: Date, zone: TimeZone, now: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let time = time(date, zone)
        return calendar.isDate(date, inSameDayAs: now) ? time : String(localized: "Tomorrow at \(time)")
    }

    static func span(_ seconds: TimeInterval, roundingUp: Bool) -> String {
        let minutes = Int((max(0, seconds) / 60).rounded(roundingUp ? .up : .down))
        let units: Set<Duration.UnitsFormatStyle.Unit> = minutes >= 60 ? [.hours, .minutes] : [.minutes]
        return Duration.seconds(minutes * 60).formatted(.units(allowed: units, width: .abbreviated))
    }

    static func countdown(to date: Date, now: Date) -> String {
        String(localized: "in \(span(date.timeIntervalSince(now), roundingUp: true))")
    }

    /// The countdown at its widest before its form changes (minutes at 59): digits are
    /// monospaced, so what's drawn never outgrows it.
    static func countdownTemplate(to date: Date, now: Date) -> String {
        let minutes = Int((max(0, date.timeIntervalSince(now)) / 60).rounded(.up))
        let template = minutes >= 60 ? minutes / 60 * 60 + 59 : 59
        return countdown(to: date, now: date.addingTimeInterval(-Double(template * 60)))
    }

    static func ago(_ moment: PrayerMoment, now: Date) -> String {
        String(localized: "\(span(now.timeIntervalSince(moment.at), roundingUp: false)) ago")
    }

    /// Before a fast's Fajr: when suhoor ends. Imsak where the authority has one, else the minute
    /// before Fajr (which is rounded up), so never later than the real time.
    static func suhoorEnds(before moment: PrayerMoment, zone: TimeZone, now: Date) -> String? {
        guard let end = suhoorEnd(before: moment), end > now else { return nil }
        return String(localized: "Suhoor ends at \(time(end, zone))")
    }

    static func suhoorEnd(before moment: PrayerMoment) -> Date? {
        guard moment.name == .fajr, moment.ramadan else { return nil }
        return moment.imsak ?? moment.at.addingTimeInterval(-60)
    }

    static func hijri(_ components: DateComponents, zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .islamicUmmAlQura)
        calendar.timeZone = zone
        guard let date = calendar.date(from: components) else { return "" }
        var style = Date.FormatStyle(date: .long, time: .omitted, calendar: calendar, timeZone: zone)
        style.locale = .current
        return date.formatted(style)
    }
}

extension PrayerName {
    var symbol: String {
        switch self {
        case .fajr: "sun.horizon.fill"
        case .sunrise: "sunrise.fill"
        case .dhuhr: "sun.max.fill"
        case .asr: "sun.min.fill"
        case .maghrib: "sunset.fill"
        case .isha: "moon.stars.fill"
        }
    }
}

private extension Font {
    static let prayerHero = Font.system(size: 22, weight: .semibold, design: .rounded)
}

private extension Color {
    /// Passed: dimmed, still readable (about 5.3:1 on black).
    static let passed = Color.white.opacity(0.5)
}

private struct PrayerHeadline: View {
    let moment: PrayerMoment
    let now: Date

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: PrayerSummary.afterName) {
            Text(moment.title)
                .font(.prayerHero)
                .foregroundStyle(.white)
            if moment.at <= now {
                Text("Now")
                    .font(.notchCaption.weight(.semibold))
                    .foregroundStyle(Color.onNotchAccent)
                    .padding(.horizontal, PrayerSummary.capsulePadding)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.notchAccent))
            } else {
                Text(PrayerFormat.countdown(to: moment.at, now: now))
                    .font(.notchTitle.monospacedDigit())
                    .foregroundStyle(Color.notchAccent)
            }
        }
    }
}

private struct PrayerWhen: View {
    let moment: PrayerMoment
    let zone: TimeZone
    let now: Date

    var body: some View {
        Group {
            if moment.at <= now {
                HStack(spacing: 0) {
                    Text(PrayerFormat.time(moment.at, zone))
                    if now.timeIntervalSince(moment.at) >= 60 {
                        Text(verbatim: " · " + PrayerFormat.ago(moment, now: now)).foregroundStyle(.secondary)
                    }
                }
            } else if moment.ramadan && moment.name == .maghrib {
                Text("Iftar · \(PrayerFormat.time(moment.at, zone))")
            } else {
                Text(PrayerFormat.when(moment.at, zone: zone, now: now))
            }
        }
        .foregroundStyle(.white)
    }
}

// MARK: - Closed notch, at the prayer's time

struct PrayerLiveActivity: View {
    @EnvironmentObject private var vm: NotchViewModel
    let moment: PrayerMoment

    private var itemSize: CGFloat { vm.closedItemSize }
    static let extraWidth: CGFloat = 34

    var body: some View {
        let zone = PrayerFormat.zone(PrayerTimesStore.shared.place)
        HStack {
            HStack(spacing: 5) {
                Image(systemName: moment.name.symbol)
                    .font(.notchSymbol(size: 12))
                    .foregroundStyle(Color.notchAccent)
                Text(moment.title)
                    .font(.notchCaption.weight(.semibold))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }
            .frame(width: itemSize + Self.extraWidth, height: itemSize, alignment: .leading)
            Rectangle()
                .fill(.black)
                .frame(width: vm.closedMiddleWidth)
            Text(PrayerFormat.time(moment.at, zone))
                .font(.notchCaption.weight(.semibold).monospacedDigit())
                .foregroundStyle(Color.notchAccent)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .frame(width: itemSize + Self.extraWidth, height: itemSize, alignment: .trailing)
        }
        .frame(height: vm.effectiveClosedNotchHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(moment.spokenText(in: zone))
    }
}

// MARK: - Home widget

struct PrayerWidget: View {
    private var store: PrayerTimesStore { .shared }
    /// On the lock screen, where the island shows only Home: it only shows.
    let locked: Bool
    var alone = false

    var body: some View {
        if alone {
            PrayerAlone(locked: locked)
        } else {
            home
        }
    }

    private var home: some View {
        // Ready, the whole widget opens the day's page (one element to VoiceOver); before that, its Set Up… button.
        let opens = store.status == .ready && !locked
        return Group {
            switch store.status {
            case .ready:
                TimelineView(.everyMinute) { context in
                    PrayerSummary(next: store.next, last: store.last, zone: PrayerFormat.zone(store.place), now: context.date)
                }
            case .off, .needsPlace:
                PrayerSetupPrompt(locked: locked)
            case .unavailable:
                PrayerUnavailableText()
            }
        }
        // As wide as its words, so Home leaves no gap beside it.
        .frame(width: PrayerWidgetWidth.shared.width, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .accessibilityElement(children: store.status == .ready ? .combine : .contain)
        .modifier(OpensPrayerPage(enabled: opens))
    }
}

private struct PrayerAlone: View {
    let locked: Bool
    private var store: PrayerTimesStore { .shared }

    var body: some View {
        if store.status == .ready, let day = store.day {
            TimelineView(.everyMinute) { context in
                let now = context.date
                let hero = PrayerTimesStore.lit(at: now, last: store.last, next: store.next)
                AloneFrame(widget: .prayer) {
                    if let hero {
                        AloneTitle(symbol: hero.name.symbol, title: hero.title, tint: hero.at <= now ? .notchAccent : .white)
                    }
                } trailing: {
                    if let hero {
                        if hero.at <= now {
                            Text("Now")
                                .font(.notchCaption.weight(.semibold))
                                .foregroundStyle(Color.onNotchAccent)
                                .padding(.horizontal, PrayerSummary.capsulePadding)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.notchAccent))
                        } else {
                            // As wide as its widest digits, so the island keeps its size as it counts down.
                            ZStack(alignment: .trailing) {
                                Text(PrayerFormat.countdownTemplate(to: hero.at, now: now)).hidden()
                                Text(PrayerFormat.countdown(to: hero.at, now: now))
                            }
                            .font(.notchTitle.monospacedDigit())
                            .foregroundStyle(Color.notchAccent)
                        }
                    }
                } row: {
                    times(day, lit: hero, zone: PrayerFormat.zone(store.place))
                }
            }
        } else {
            AloneFrame(widget: .prayer) {
                AloneTitle(symbol: HomeWidget.prayer.symbol, title: HomeWidget.prayer.title)
            } trailing: {
                // On the lock screen Settings would open behind the lock: no button there.
                if store.status != .unavailable, !locked {
                    NotchTextButton(title: String(localized: "Set Up…")) {
                        SettingsWindowController.shared.showWindow(tab: .prayer)
                    }
                }
            } row: {
                if store.status == .unavailable {
                    Text("There are no prayer times for this place today: the sun doesn't rise or set.")
                        .font(.notchCaption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func times(_ day: PrayerDay, lit: PrayerMoment?, zone: TimeZone) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(PrayerName.allCases.filter(\.isPrayer).enumerated()), id: \.element) { index, name in
                if index > 0 { Spacer(minLength: 12) }
                let shown = lit.map { $0.name == name && day.holds($0) } ?? false
                HStack(spacing: 4) {
                    Text(name.title(friday: day.friday)).foregroundStyle(shown ? Color.notchAccent : .secondary)
                    Text(PrayerFormat.time(day[name], zone)).foregroundStyle(shown ? Color.notchAccent : .white)
                }
                .font(.notchCaption.monospacedDigit())
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// The whole widget as a button to the day's page; not a button at all where it
/// can't open it (SwiftUI shows any tappable view to VoiceOver as a button).
private struct OpensPrayerPage: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content
                .onTapGesture { open() }
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { open() }
        } else {
            content
        }
    }

    /// The page, not a tab pick; the island grows to it on its spring, as for a tab.
    private func open() {
        withAnimation(StandardAnimations.open) { NotchViewCoordinator.shared.currentView = .prayer }
    }
}

struct PrayerSummary: View {
    let next: PrayerMoment?
    let last: PrayerMoment?
    let zone: TimeZone
    let now: Date

    var body: some View {
        let hero = PrayerTimesStore.lit(at: now, last: last, next: next)
        let begun = hero.map { $0.at <= now } ?? false
        HStack(spacing: 10) {
            if let hero {
                Image(systemName: hero.name.symbol)
                    .font(.notchSymbol(size: 26))
                    .foregroundStyle(begun ? Color.notchAccent : .white)
                    .frame(width: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    PrayerHeadline(moment: hero, now: now)
                    PrayerWhen(moment: hero, zone: zone, now: now)
                        .font(.notchBody.monospacedDigit())
                    // The store's rule, not the clock's: at the adhan, until the store
                    // catches up (under a second), it would name the prayer under itself.
                    footnote(after: hero, begun: hero == last)
                        .font(.notchCaption.monospacedDigit())
                        .padding(.top, 6)
                }
            }
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityValue(hero == nil || begun ? "" : String(localized: "Next prayer"))
    }

    @ViewBuilder private func footnote(after hero: PrayerMoment, begun: Bool) -> some View {
        if let suhoor = PrayerFormat.suhoorEnds(before: hero, zone: zone, now: now) {
            Text(suhoor).foregroundStyle(.white)
        } else if let other = begun ? next : last {
            HStack(spacing: 5) {
                Image(systemName: other.name.symbol)
                    .font(.notchSymbol(size: 9))
                    .accessibilityHidden(true)
                Text(other.title)
                Text(begun ? PrayerFormat.countdown(to: other.at, now: now) : PrayerFormat.time(other.at, zone))
            }
            .foregroundStyle(begun ? Color.secondary : Color.passed)
        }
    }
}

/// The Prayer widget's width on Home now: as wide as its words, changing on the island's own spring
/// (the store's state changes on a timer, outside any animation, and the island would jump).
@MainActor
@Observable
final class PrayerWidgetWidth {
    static let shared = PrayerWidgetWidth()

    private(set) var width = PrayerSummary.promptWidth

    private init() { measure() }

    private func measure() {
        let store = PrayerTimesStore.shared
        let width = withObservationTracking {
            Self.width(of: store)
        } onChange: {
            // Called before the change: measured once the store has finished changing.
            Task { @MainActor [weak self] in self?.measure() }
        }
        guard width != self.width else { return }
        if store.status == .ready {
            withAnimation(StandardAnimations.open) { self.width = width }
        } else {
            self.width = width
        }
    }

    private static func width(of store: PrayerTimesStore) -> CGFloat {
        guard store.status == .ready, let now = store.asOf, let place = store.place else { return PrayerSummary.promptWidth }
        let lit = store.lit
        return PrayerSummary.width(lit: lit, other: lit == store.last ? store.next : store.last, zone: place.zone, now: now)
    }
}

extension PrayerSummary {
    /// Its width for this state, laid out as `body` lays it out. The countdown is measured at
    /// its longest form, so the width holds while it ticks.
    static func width(lit: PrayerMoment?, other: PrayerMoment?, zone: TimeZone, now: Date) -> CGFloat {
        guard let lit else { return promptWidth }
        let begun = lit.at <= now
        let headline = Measure.text(lit.title, Measure.hero) + afterName
            + (begun ? Measure.text(String(localized: "Now"), Measure.captionBold) + 2 * capsulePadding
                     : Measure.text(PrayerFormat.countdownTemplate(to: lit.at, now: now), Measure.title))
        let when: String
        if begun {
            when = PrayerFormat.time(lit.at, zone) + " · " + PrayerFormat.ago(lit, now: lit.at.addingTimeInterval(litMinutes * 60))
        } else if lit.ramadan && lit.name == .maghrib {
            when = String(localized: "Iftar · \(PrayerFormat.time(lit.at, zone))")
        } else {
            when = PrayerFormat.when(lit.at, zone: zone, now: now)
        }
        var footnote: CGFloat = 0
        if let suhoor = PrayerFormat.suhoorEnds(before: lit, zone: zone, now: now) {
            footnote = Measure.text(suhoor, Measure.caption)
        } else if let other {
            let detail = begun ? PrayerFormat.countdownTemplate(to: other.at, now: now) : PrayerFormat.time(other.at, zone)
            footnote = 12 + 5 + Measure.text(other.title, Measure.caption) + 5 + Measure.text(detail, Measure.caption)
        }
        let lines = [headline, Measure.text(when, Measure.body), footnote]
        return (32 + 10 + (lines.max() ?? 0) + 4).rounded(.up)
    }

    static let afterName: CGFloat = 7
    static let capsulePadding: CGFloat = 6

    static let promptWidth: CGFloat = 150

    /// The most it can need in this language, for fitting Home's row.
    static let widest: CGFloat = {
        let times = [0, 12].compactMap { Calendar.current.date(bySettingHour: $0, minute: 59, second: 0, of: Date()) }
        let moments = PrayerName.allCases.filter(\.isPrayer).flatMap { name in
            times.flatMap { at in [false, true].map { PrayerMoment(name: name, at: at, friday: $0, ramadan: true, imsak: at) } }
        }
        let widths = moments.flatMap { lit in
            [lit.at.addingTimeInterval(-(10 * 3600 + 1)), lit.at.addingTimeInterval(-7200), lit.at.addingTimeInterval(1)].flatMap { now in
                moments.map { width(lit: lit, other: $0, zone: .current, now: now) }
            }
        }
        return max(widths.max() ?? 236, promptWidth)
    }()

    private static let litMinutes = PrayerTimesStore.litFor / 60 - 1
}

private enum Measure {
    static let hero: NSFont = {
        let base = NSFont.systemFont(ofSize: 22, weight: .semibold)
        return NSFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor, size: 22) ?? base
    }()
    static let title = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
    static let body = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    static let caption = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    static let captionBold = NSFont.systemFont(ofSize: 11, weight: .semibold)

    static func text(_ string: String, _ font: NSFont) -> CGFloat {
        ceil((string as NSString).size(withAttributes: [.font: font]).width)
    }
}

private struct PrayerSetupPrompt: View {
    let locked: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(String(localized: "Prayer Times"), systemImage: "moon.stars").font(.notchCaption).foregroundStyle(.secondary)
            if !locked {
                NotchTextButton(title: String(localized: "Set Up…")) {
                    SettingsWindowController.shared.showWindow(tab: .prayer)
                }
            }
        }
        .padding(.top, 6)
    }
}

private struct PrayerUnavailableText: View {
    var body: some View {
        Text("There are no prayer times for this place today: the sun doesn't rise or set.")
            .font(.notchCaption)
            .foregroundStyle(.secondary)
            .padding(.top, 6)
    }
}

// MARK: - The prayer page (opened from the widget or the closed notch)

struct PrayerExpandedView: View {
    private var store: PrayerTimesStore { .shared }

    var body: some View {
        Group {
            if store.status == .ready, let day = store.day {
                TimelineView(.everyMinute) { context in
                    // Today's row until midnight: after Isha it's all passed, and the hero says tomorrow.
                    PrayerPage(day: day, next: store.next, last: store.last, zone: PrayerFormat.zone(store.place),
                               place: store.place, now: context.date)
                }
            } else if store.status == .unavailable {
                PrayerUnavailableText()
            } else {
                PrayerSetupPrompt(locked: false)  // the page never shows on the lock screen
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: NotchMetrics.tabHeight)
    }
}

struct PrayerPage: View {
    let day: PrayerDay
    let next: PrayerMoment?
    let last: PrayerMoment?
    let zone: TimeZone
    let place: PrayerPlace?
    let now: Date

    var body: some View {
        let lit = PrayerTimesStore.lit(at: now, last: last, next: next)
        HStack(alignment: .center, spacing: 14) {
            if let lit { hero(lit) }
            HStack(spacing: 4) {
                ForEach(PrayerName.allCases, id: \.self) { name in
                    column(name, state: Self.state(of: name, in: day, lit: lit, now: now))
                }
            }
        }
        .lineLimit(1)
    }

    private func hero(_ moment: PrayerMoment) -> some View {
        HStack(spacing: 12) {
            Image(systemName: moment.name.symbol)
                .font(.notchSymbol(size: 30))
                .foregroundStyle(moment.at <= now ? Color.notchAccent : .white)
                .frame(width: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                // French on a Friday ("Joumoua dans 10 h et 59 min") needs 0.84.
                PrayerHeadline(moment: moment, now: now)
                    .minimumScaleFactor(0.8)
                PrayerWhen(moment: moment, zone: zone, now: now)
                    .font(.notchBody.monospacedDigit())
                if let suhoor = PrayerFormat.suhoorEnds(before: moment, zone: zone, now: now) {
                    Text(suhoor).font(.notchCaption).foregroundStyle(.white)
                } else {
                    Text(verbatim: [PrayerFormat.hijri(day.hijri, zone: zone), place?.title ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.notchCaption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 236, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    enum ColumnState { case now, next, passed, later }

    /// Only its own row: after Isha's half hour the lit prayer is tomorrow's Fajr, and every
    /// column of today's has passed.
    nonisolated static func state(of name: PrayerName, in day: PrayerDay, lit: PrayerMoment?, now: Date) -> ColumnState {
        if let lit, lit.name == name, day.holds(lit) { return lit.at <= now ? .now : .next }
        return day[name] <= now ? .passed : .later
    }

    private func column(_ name: PrayerName, state: ColumnState) -> some View {
        let shape = RoundedRectangle(cornerRadius: NotchMetrics.innerRadius, style: .continuous)
        let color: Color = switch state {
        case .now: .onNotchAccent
        case .passed: .passed
        case .next: .white
        case .later: name.isPrayer ? .white : .white.opacity(0.75)
        }
        let spoken = switch state {
        case .now: String(localized: "Now")
        case .next: String(localized: "Next prayer")
        case .passed: String(localized: "Passed")
        case .later: ""
        }
        return VStack(spacing: 4) {
            Image(systemName: name.symbol)
                .font(.notchSymbol(size: 14))
                .accessibilityHidden(true)
            Text(name.title(friday: day.friday))
                .font(.notchCaption)
            // Shrinks a little for Spanish's "12:05 p.m.".
            Text(PrayerFormat.time(day[name], zone))
                .font(.notchTitle.monospacedDigit())
                .minimumScaleFactor(0.9)
                .foregroundStyle(state == .next ? Color.notchAccent : color)
        }
        .foregroundStyle(color)
        .frame(width: 72, height: 76)
        .background(shape.fill(state == .now ? Color.notchAccent : .clear))
        .overlay(shape.strokeBorder(state == .next ? Color.notchAccent : .clear, lineWidth: 1.5))
        .accessibilityElement(children: .combine)
        .accessibilityValue(spoken)
    }
}
