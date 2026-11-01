//
//  PrayerCalculation.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Prayer times from adhan-swift, unmodified, with the method of the place's country, and one
//  rule of our own: never earlier. A start rounds up to its minute; sunrise and Imsak, which end
//  something, round down. Checked against official timetables in UnderbrimTests.
//

@preconcurrency import Adhan
import Foundation

enum PrayerName: String, CaseIterable {
    case fajr, sunrise, dhuhr, asr, maghrib, isha

    var isPrayer: Bool { self != .sunrise }

    func title(friday: Bool = false) -> String {
        switch self {
        case .fajr: String(localized: "Fajr")
        case .sunrise: String(localized: "Sunrise")
        case .dhuhr: friday ? String(localized: "Jumu'ah") : String(localized: "Dhuhr")
        case .asr: String(localized: "Asr")
        case .maghrib: String(localized: "Maghrib")
        case .isha: String(localized: "Isha")
        }
    }

    fileprivate var adhan: Adhan.Prayer {
        switch self {
        case .fajr: .fajr
        case .sunrise: .sunrise
        case .dhuhr: .dhuhr
        case .asr: .asr
        case .maghrib: .maghrib
        case .isha: .isha
        }
    }
}

struct PrayerPlace: Codable, Equatable {
    var name: String
    var latitude: Double
    var longitude: Double
    var timeZone: String
    var country: String?

    var fromLocation: Bool { name.isEmpty }
    var zone: TimeZone { TimeZone(identifier: timeZone) ?? .current }
    var title: String { name.isEmpty ? String(localized: "Your location") : name }

    /// To two decimals (about a kilometre) for a place found from this Mac's location: the times
    /// move by a second or two at most, and the preferences file doesn't keep the exact spot.
    var rounded: PrayerPlace {
        var place = self
        place.latitude = (latitude * 100).rounded() / 100
        place.longitude = (longitude * 100).rounded() / 100
        return place
    }
}

/// A country's way of calculating: an adhan-swift preset or its angles, plus minutes fitted to the
/// authority's own timetable, so the result is never earlier than the authority's and at most a
/// minute later where possible (see the tests for the exceptions).
struct PrayerMethod: Identifiable, Equatable {
    let id: String
    let name: String
    var countries: Set<String> = []
    let base: CalculationMethod
    var fajrAngle: Double?
    var ishaAngle: Double?
    var ishaInterval: Minute?
    /// Minutes added before rounding (fractions are seconds).
    var offsets: [PrayerName: Double] = [:]
    /// Umm al-Qura: Isha two hours after Maghrib in Ramadan instead of 90 minutes.
    var ramadanIshaInterval: Minute?
    var imsakMinutes: Int?

    static let muslimWorldLeague = PrayerMethod(id: "mwl", name: String(localized: "Muslim World League"), base: .muslimWorldLeague)

    // Offsets fitted to each authority's 2026 timetable (UnderbrimTests/PrayerFixtures.swift).
    static let all: [PrayerMethod] = [
        PrayerMethod(id: "ummAlQura", name: String(localized: "Umm al-Qura, Makkah"), countries: ["SA"], base: .ummAlQura,
                     ramadanIshaInterval: 120),
        PrayerMethod(id: "qatar", name: String(localized: "Qatar"), countries: ["QA"], base: .other, fajrAngle: 18.25,
                     ishaInterval: 90, offsets: [.maghrib: 2.57, .isha: 2.57]),
        // Two days of the authority's table only (June 2025).
        PrayerMethod(id: "dubai", name: String(localized: "United Arab Emirates"), countries: ["AE"], base: .other,
                     fajrAngle: 18.2, ishaAngle: 18, offsets: [.sunrise: -3.85, .dhuhr: 0.93, .maghrib: 2.03]),
        PrayerMethod(id: "kuwait", name: String(localized: "Kuwait"), countries: ["KW"], base: .kuwait),
        // No official page online: fitted to Manama timetables published in Bahrain.
        PrayerMethod(id: "bahrain", name: String(localized: "Bahrain"), countries: ["BH"], base: .other,
                     fajrAngle: 18, ishaAngle: 18, offsets: [.asr: 1, .maghrib: 1]),
        PrayerMethod(id: "egypt", name: String(localized: "Egyptian General Authority of Survey"), countries: ["EG"],
                     base: .other, fajrAngle: 19.5, ishaAngle: 17.5),
        PrayerMethod(id: "jordan", name: String(localized: "Jordan"), countries: ["JO"], base: .other,
                     fajrAngle: 18, ishaAngle: 18, offsets: [.sunrise: -6.35, .maghrib: 7]),
        PrayerMethod(id: "morocco", name: String(localized: "Morocco"), countries: ["MA"], base: .other,
                     fajrAngle: 19, ishaAngle: 17, offsets: [.sunrise: -3, .dhuhr: 5, .asr: 0.35, .maghrib: 4]),
        PrayerMethod(id: "turkey", name: String(localized: "Diyanet, Türkiye"), countries: ["TR"], base: .other,
                     fajrAngle: 18, ishaAngle: 17,
                     offsets: [.sunrise: -6.7, .dhuhr: 4.85, .asr: 4.67, .maghrib: 7.85, .isha: 0.8]),
        PrayerMethod(id: "malaysia", name: String(localized: "JAKIM, Malaysia"), countries: ["MY"], base: .other,
                     fajrAngle: 18, ishaAngle: 18,
                     offsets: [.fajr: 0.92, .sunrise: -2.35, .dhuhr: 1.33, .asr: 0.1, .maghrib: 0.58, .isha: 0.65],
                     imsakMinutes: 10),
        PrayerMethod(id: "indonesia", name: String(localized: "Kemenag, Indonesia"), countries: ["ID"], base: .other,
                     fajrAngle: 20, ishaAngle: 18,
                     offsets: [.fajr: 2.07, .sunrise: -2.95, .dhuhr: 3.22, .asr: 2.23, .maghrib: 2.85, .isha: 2.12],
                     imsakMinutes: 10),
        PrayerMethod(id: "singapore", name: String(localized: "MUIS, Singapore"), countries: ["SG"], base: .other,
                     fajrAngle: 20, ishaAngle: 18, offsets: [.fajr: 0.18, .dhuhr: 1.62, .asr: 0.58, .maghrib: 0.75, .isha: 0.18]),
        PrayerMethod(id: "karachi", name: String(localized: "University of Islamic Sciences, Karachi"),
                     countries: ["PK", "IN", "BD", "AF"], base: .karachi),
        PrayerMethod(id: "northAmerica", name: String(localized: "Islamic Society of North America"), countries: ["US"],
                     base: .northAmerica),
        PrayerMethod(id: "canada", name: String(localized: "Canada"), countries: ["CA"], base: .other, fajrAngle: 13, ishaAngle: 13),
        PrayerMethod(id: "moonsighting", name: String(localized: "Moonsighting Committee"), countries: ["GB"],
                     base: .moonsightingCommittee),
        muslimWorldLeague,
    ]

    static func forCountry(_ code: String?) -> PrayerMethod {
        all.first { $0.countries.contains(code?.uppercased() ?? "") } ?? muslimWorldLeague
    }

    static func withID(_ id: String?) -> PrayerMethod? { all.first { $0.id == id } }

    func parameters(madhab: Madhab, ramadan: Bool, extra: PrayerAdjustments) -> CalculationParameters {
        var p = base.params
        if let fajrAngle { p.fajrAngle = fajrAngle }
        if let ishaAngle { p.ishaAngle = ishaAngle }
        if let ishaInterval { p.ishaInterval = ishaInterval }
        if ramadan, let ramadanIshaInterval { p.ishaInterval = ramadanIshaInterval }
        p.adjustments = extra
        p.madhab = madhab
        // Explicit: the library's default picks by latitude and skips the southern hemisphere.
        p.highLatitudeRule = .middleOfTheNight
        p.rounding = .none  // ours, after the offsets
        return p
    }
}

struct PrayerDay: Equatable {
    let times: [PrayerName: Date]
    let imsak: Date?
    let friday: Bool
    let ramadan: Bool
    let hijri: DateComponents

    subscript(name: PrayerName) -> Date { times[name]! }

    /// Its own time, or moved a minute past the day before's Isha far north (see `moments`).
    func holds(_ moment: PrayerMoment) -> Bool {
        abs(self[moment.name].timeIntervalSince(moment.at)) < 12 * 3600
    }
}

struct PrayerMoment: Equatable, Hashable {
    let name: PrayerName
    let at: Date
    let friday: Bool
    var ramadan = false
    var imsak: Date?

    var title: String { name.title(friday: friday) }
}

enum PrayerCalculation {
    /// The day containing `date` in the place's time zone, or nil where the sun doesn't rise or set.
    static func day(containing date: Date, at place: PrayerPlace, method: PrayerMethod, madhab: Madhab = .shafi,
                    adjustments: PrayerAdjustments = PrayerAdjustments(), hijriOffset: Int = 0) -> PrayerDay? {
        let zone = place.zone
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = zone
        let ymd = gregorian.dateComponents([.year, .month, .day, .weekday], from: date)
        let hijri = hijriDate(of: date, in: zone, offset: hijriOffset)
        let ramadan = hijri.month == 9
        let params = method.parameters(madhab: madhab, ramadan: ramadan, extra: adjustments)
        func computed(shiftedBy days: Int) -> Adhan.PrayerTimes? {
            let shifted = gregorian.date(byAdding: .day, value: days, to: date) ?? date
            let parts = gregorian.dateComponents([.year, .month, .day], from: shifted)
            return Adhan.PrayerTimes(coordinates: Coordinates(latitude: place.latitude, longitude: place.longitude),
                                     date: DateComponents(year: parts.year, month: parts.month, day: parts.day),
                                     calculationParameters: params)
        }
        guard var times = computed(shiftedBy: 0) else { return nil }
        // The library's day is the UTC date: east of UTC+12 (Tonga, Samoa) its
        // noon falls on the next local day, so ask for the day before.
        let drift = gregorian.dateComponents([.day], from: gregorian.startOfDay(for: date),
                                             to: gregorian.startOfDay(for: times.dhuhr)).day ?? 0
        if drift != 0 {
            guard let corrected = computed(shiftedBy: -drift) else { return nil }
            times = corrected
        }
        func time(_ name: PrayerName) -> Date { times.time(for: name.adhan).addingTimeInterval((method.offsets[name] ?? 0) * 60) }
        var rounded: [PrayerName: Date] = [:]
        for name in PrayerName.allCases {
            rounded[name] = name.isPrayer ? roundedUp(time(name)) : roundedDown(time(name))
        }
        let imsak = method.imsakMinutes.map { roundedDown(time(.fajr).addingTimeInterval(-Double($0) * 60)) }
        return PrayerDay(times: rounded, imsak: imsak, friday: ymd.weekday == 6, ramadan: ramadan, hijri: hijri)
    }

    static func hijriDate(of date: Date, in zone: TimeZone, offset: Int) -> DateComponents {
        var calendar = Calendar(identifier: .islamicUmmAlQura)
        calendar.timeZone = zone
        let shifted = calendar.date(byAdding: .day, value: offset, to: date) ?? date
        return calendar.dateComponents([.year, .month, .day], from: shifted)
    }

    /// The prayers of consecutive days, in order. Far north in summer a night's Isha can come after
    /// the next day's Fajr (the library bounds each by its own night): that Fajr waits for the Isha.
    static func moments(_ days: [PrayerDay]) -> [PrayerMoment] {
        var moments: [PrayerMoment] = []
        for day in days {
            for name in PrayerName.allCases where name.isPrayer {
                var at = day[name]
                if name == .fajr, let previous = moments.last, previous.at >= at { at = previous.at.addingTimeInterval(60) }
                moments.append(PrayerMoment(name: name, at: at, friday: day.friday, ramadan: day.ramadan,
                                            imsak: name == .fajr ? day.imsak : nil))
            }
        }
        return moments
    }

    static func roundedUp(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 60).rounded(.up) * 60)
    }

    static func roundedDown(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60)
    }

    /// The country a time zone belongs to, from macOS's own table, without sending the place anywhere.
    static func country(forTimeZone identifier: String) -> String? {
        let table = try? String(contentsOfFile: "/usr/share/zoneinfo/zone.tab", encoding: .utf8)
        for line in (table ?? "").split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t")
            if fields.count >= 3, fields[2] == identifier { return String(fields[0]) }
        }
        return nil
    }
}
