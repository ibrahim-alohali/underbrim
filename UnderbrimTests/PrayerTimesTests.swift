//
//  PrayerTimesTests.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Prayer times are never earlier than the authority's own timetable: no
//  start before theirs, no sunrise or Imsak after theirs. And at most a
//  minute later, except where an authority's sums differ from the library's
//  by more than that (named below).
//

import Foundation
import Testing
@testable import Underbrim

struct PrayerTimesTests {
    @Test(arguments: PrayerFixture.all)
    func neverEarlierThanTheAuthority(_ fixture: PrayerFixture) throws {
        let place = PrayerPlace(name: fixture.city, latitude: fixture.latitude, longitude: fixture.longitude,
                                timeZone: fixture.timeZone, country: fixture.country)
        let method = PrayerMethod.forCountry(fixture.country)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: fixture.timeZone))
        for day in fixture.days {
            let ymd = day.date.split(separator: "-").compactMap { Int($0) }
            func at(_ time: String) throws -> Date {
                let hm = time.split(separator: ":").compactMap { Int($0) }
                return try #require(calendar.date(from: DateComponents(year: ymd[0], month: ymd[1], day: ymd[2], hour: hm[0], minute: hm[1])))
            }
            let computed = try #require(PrayerCalculation.day(containing: try at("12:00"), at: place, method: method))
            for (index, name) in PrayerName.allCases.enumerated() {
                let late = computed[name].timeIntervalSince(try at(day.times[index])) / 60
                if name.isPrayer {
                    #expect(late >= 0, "\(fixture.city) \(day.date) \(name): \(-late) min early")
                    #expect(late <= Self.lateness(fixture.country, name), "\(fixture.city) \(day.date) \(name): \(late) min late")
                } else {
                    #expect(late <= 0, "\(fixture.city) \(day.date) sunrise: \(late) min late")
                    #expect(late >= -Self.earlySunrise(fixture.country), "\(fixture.city) \(day.date) sunrise: \(-late) min early")
                }
            }
            if let official = day.imsak, let imsak = computed.imsak {
                let early = try at(official).timeIntervalSince(imsak) / 60
                #expect((0...1).contains(early), "\(fixture.city) \(day.date) Imsak: \(-early) min late")
            }
        }
    }

    /// Diyanet's Asr, Maghrib and Isha, and MUIS's Asr, move against the
    /// library's by more than a minute over the year: the offsets keep them
    /// never earlier, which costs up to this much lateness on some days.
    static func lateness(_ country: String, _ name: PrayerName) -> Double {
        switch (country, name) {
        case ("TR", .isha): 3
        case ("TR", .asr), ("TR", .maghrib), ("SG", .asr): 2
        default: 1
        }
    }

    static func earlySunrise(_ country: String) -> Double { country == "MY" ? 2 : 1 }
}
