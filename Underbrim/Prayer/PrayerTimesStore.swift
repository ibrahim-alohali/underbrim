//
//  PrayerTimesStore.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Today's prayer times at the chosen place, the next and last adhan, and the prayer whose time
//  has just come. One timer, set for the next boundary; recomputed on settings, day or time zone
//  changes, and wake.
//

@preconcurrency import Adhan
import AppKit
import CoreLocation
import Defaults

@MainActor
@Observable
final class PrayerTimesStore {
    static let shared = PrayerTimesStore()

    enum Status: Equatable { case off, needsPlace, unavailable, ready }

    private(set) var status: Status = .off
    /// The page's row: today's, or yesterday's while its Isha (past midnight far north) is still lit.
    private(set) var day: PrayerDay?
    private(set) var next: PrayerMoment?
    private(set) var last: PrayerMoment?
    private(set) var arrived: PrayerMoment?
    private(set) var lit: PrayerMoment?
    /// When the state above was last worked out: what depends on the time as well, such as the form
    /// a countdown takes, is as of then. Nil unless ready.
    private(set) var asOf: Date?
    private(set) var method: PrayerMethod = .muslimWorldLeague
    private(set) var locating = false
    private(set) var locationError: String?

    static let arrivedFor: TimeInterval = 5
    /// A prayer stays lit this long after its adhan (the wait for the iqama) before the next takes over.
    static let litFor: TimeInterval = 30 * 60
    /// Before a prayer, when its countdown changes form (and the widget's width): losing the tens of
    /// hours and the hours. It rounds up, so a minute before 10 hours and 1 hour.
    static let countdownSteps: [TimeInterval] = [599 * 60, 59 * 60]

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private lazy var locator = PrayerLocator { [weak self] place, error in
        self?.located(place, error: error)
    }

    var place: PrayerPlace? { Defaults[.prayerPlace] }
    /// The place when a location fix was asked for: a town picked meanwhile wins.
    @ObservationIgnored private var askedFor: PrayerPlace?

    func start() {
        // A location saved before fixes were rounded.
        if let place, place.fromLocation, place.rounded != place { Defaults[.prayerPlace] = place.rounded }
        Defaults.whenChanged([.prayerTimesEnabled, .prayerPlace, .prayerMethod, .prayerAsrHanafi,
                              .prayerAdjustments, .hijriAdjustment]) { [weak self] in self?.refresh() }
        // Turned back on after a trip: "your location" is looked up again.
        Defaults.whenChanged([.prayerTimesEnabled]) { [weak self] in
            guard let self, Defaults[.prayerTimesEnabled], let place = self.place, place.fromLocation,
                  place.timeZone != TimeZone.current.identifier, !self.locating else { return }
            self.locate()
        }
        // The widget put on Home wants prayer times: off, the next refresh would take it away again.
        Defaults.whenChanged([.showPrayerWidget]) {
            if Defaults[.showPrayerWidget], !Defaults[.prayerTimesEnabled] { Defaults[.prayerTimesEnabled] = true }
        }
        let center = NotificationCenter.default
        for name in [Notification.Name.NSSystemTimeZoneDidChange, .NSCalendarDayChanged, .NSSystemClockDidChange] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    // Travelling: a new zone usually means a new place (only while prayer times are on).
                    if note.name == .NSSystemTimeZoneDidChange, Defaults[.prayerTimesEnabled],
                       Defaults[.prayerPlace]?.fromLocation == true { self?.locate() }
                    self?.refresh()
                }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    func turnOn() {
        Defaults[.prayerTimesEnabled] = true
        guard !Defaults[.showPrayerWidget], HomeWidget.fit(HomeWidget.enabled + [.prayer], within: HomeWidget.room) else { return }
        Defaults[.homeWidgetOrder] = HomeWidget.adding(.prayer, to: HomeWidget.ordered(Defaults[.homeWidgetOrder]),
                                                       after: Set(HomeWidget.enabled))
        Defaults[.showPrayerWidget] = true
    }

    func locate() {
        locating = true
        locationError = nil
        askedFor = Defaults[.prayerPlace]
        locator.request()
    }

    /// Kept only if prayer times are still on and no town was picked while locating.
    private func located(_ place: PrayerPlace?, error: String?) {
        locating = false
        locationError = error
        if let place, Defaults[.prayerTimesEnabled], Defaults[.prayerPlace] == askedFor { Defaults[.prayerPlace] = place }
    }

    func refresh() {
        #if DEBUG
        let now = Date().addingTimeInterval(clockOffset)
        #else
        let now = Date()
        #endif
        timer?.invalidate()
        timer = nil
        guard Defaults[.prayerTimesEnabled] else {
            // Off, its Home widget goes too (turnOn brings it back), rather than a "Set Up…" tile
            // for a feature that's off.
            if Defaults[.showPrayerWidget] { Defaults[.showPrayerWidget] = false }
            return clear(.off)
        }
        guard let place = Defaults[.prayerPlace] else { return clear(.needsPlace) }
        method = PrayerMethod.withID(Defaults[.prayerMethod]) ?? .forCountry(place.country)
        var zoned = Calendar(identifier: .gregorian)
        zoned.timeZone = place.zone
        // Calendar days, not 24 hours: a day around a clock change is 23 or 25 hours long.
        let days = (-1...1).map { offset in
            PrayerCalculation.day(containing: zoned.date(byAdding: .day, value: offset, to: now) ?? now, at: place, method: method,
                                  madhab: Defaults[.prayerAsrHanafi] ? .hanafi : .shafi,
                                  adjustments: Defaults[.prayerAdjustments].adhan,
                                  hijriOffset: Defaults[.hijriAdjustment])
        }
        guard let today = days[1] else { return clear(.unavailable) }
        let found = days.compactMap { $0 }
        let moments = PrayerCalculation.moments(found)
        let state = Self.state(at: now, moments: moments)
        if next != state.next { next = state.next }
        if last != state.last { last = state.last }
        if arrived != state.arrived {
            if state.arrived != nil { chime(at: now) }
            arrived = state.arrived
        }
        let lit = Self.lit(at: now, last: state.last, next: state.next)
        if self.lit != lit { self.lit = lit }
        let day = Self.shownDay(yesterday: days[0], today: today, lit: lit)
        if self.day != day { self.day = day }
        asOf = now
        if status != .ready { status = .ready }

        // The next boundary: a prayer arriving or leaving the closed notch, one no longer lit, its
        // countdown changing form, suhoor ending, or midnight.
        let midnight = zoned.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0), matchingPolicy: .nextTime)
        let wake = ([state.next?.at, state.arrived.map { $0.at.addingTimeInterval(Self.arrivedFor) },
                    state.last.map { $0.at.addingTimeInterval(Self.litFor) },
                    state.next.flatMap(PrayerFormat.suhoorEnd(before:)), midnight] + Self.countdownSteps.map { step in state.next.map { $0.at.addingTimeInterval(-step) } })
            .compactMap { $0 }.filter { $0 > now }.min()
        if let wake {
            // Common modes: it fires on time while a menu, a slider or a dialog runs the loop.
            let timer = Timer(timeInterval: max(1, wake.timeIntervalSince(now) + 0.5), repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            timer.tolerance = 0.5
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    private func chime(at now: Date) {
        guard Defaults[.prayerSound], !Self.busy(at: now) else { return }
        NSSound(named: "Glass")?.play()
    }

    static func busy(at now: Date) -> Bool {
        // The whole meeting, not just the five minutes its countdown stays featured.
        CallActivity.shared.inCall || MeetingStore.shared.inMeeting(at: now)
    }

    private func clear(_ status: Status) {
        self.status = status
        day = nil
        next = nil
        last = nil
        arrived = nil
        lit = nil
        asOf = nil
    }

    #if DEBUG
    /// Shifts the store's clock (see `arriveSoon`).
    @ObservationIgnored private var clockOffset: TimeInterval = 0

    /// The next adhan arrives in three seconds, through the real timer; the clock is right again
    /// once its pill has gone.
    func arriveSoon() {
        guard let next else { return }
        clockOffset = next.at.timeIntervalSinceNow - 3
        refresh()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3 + Self.arrivedFor + 2))
            self?.clockOffset = 0
            self?.refresh()
        }
    }
    #endif

    nonisolated static func shownDay(yesterday: PrayerDay?, today: PrayerDay, lit: PrayerMoment?) -> PrayerDay {
        if let yesterday, let lit, yesterday.holds(lit) { return yesterday }
        return today
    }

    nonisolated static func lit(at now: Date, last: PrayerMoment?, next: PrayerMoment?) -> PrayerMoment? {
        if let last, now.timeIntervalSince(last.at) < litFor { return last }
        return next
    }

    nonisolated static func state(at now: Date, moments: [PrayerMoment])
        -> (next: PrayerMoment?, last: PrayerMoment?, arrived: PrayerMoment?) {
        let last = moments.last { $0.at <= now }
        let next = moments.first { $0.at > now }
        let arrived = last.flatMap { now.timeIntervalSince($0.at) < arrivedFor ? $0 : nil }
        return (next, last, arrived)
    }
}

struct PrayerAdjustmentSet: Codable, Equatable, Defaults.Serializable {
    var minutes: [String: Int] = [:]

    subscript(name: PrayerName) -> Int {
        get { minutes[name.rawValue] ?? 0 }
        set { minutes[name.rawValue] = newValue == 0 ? nil : max(-15, min(15, newValue)) }
    }

    var adhan: PrayerAdjustments {
        PrayerAdjustments(fajr: self[.fajr], sunrise: self[.sunrise], dhuhr: self[.dhuhr],
                          asr: self[.asr], maghrib: self[.maghrib], isha: self[.isha])
    }
}

extension PrayerPlace: Defaults.Serializable {}

/// One location fix for prayer times (Core Location, on this Mac); the country comes from the time zone.
@MainActor
final class PrayerLocator: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let done: (PrayerPlace?, String?) -> Void
    private var waiting = false

    init(done: @escaping (PrayerPlace?, String?) -> Void) {
        self.done = done
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func request() {
        waiting = true
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .denied, .restricted: finish(nil, String(localized: "Location Services are off for Underbrim. Choose a town instead, or allow it in System Settings › Privacy & Security › Location Services."))
        default: manager.requestLocation()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            guard waiting else { return }
            switch manager.authorizationStatus {
            case .notDetermined: break
            case .denied, .restricted: request()
            default: manager.requestLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        MainActor.assumeIsolated {
            let zone = TimeZone.current.identifier
            finish(PrayerPlace(name: "", latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                               timeZone: zone, country: PrayerCalculation.country(forTimeZone: zone)).rounded, nil)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            finish(nil, String(localized: "Underbrim couldn't find your location. Choose a town instead."))
        }
    }

    private func finish(_ place: PrayerPlace?, _ error: String?) {
        guard waiting else { return }
        waiting = false
        done(place, error)
    }
}
