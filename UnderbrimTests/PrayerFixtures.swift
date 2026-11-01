//
//  PrayerFixtures.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Official timetables, as the authorities publish them (fetched 2026-10-09;
//  each one names its source). Local times.
//

import Foundation
import Testing

struct PrayerFixture: CustomTestStringConvertible, Sendable {
    struct Day: Sendable {
        let date: String
        /// Fajr, sunrise, Dhuhr, Asr, Maghrib, Isha.
        let times: [String]
        var imsak: String?
        init(_ date: String, _ times: [String], imsak: String? = nil) {
            self.date = date
            self.times = times
            self.imsak = imsak
        }
    }

    let city: String
    let country: String
    let latitude: Double
    let longitude: Double
    let timeZone: String
    let days: [Day]

    var testDescription: String { city }

    static let all: [PrayerFixture] = [
        // Ministry of Awqaf, Islamic Affairs and Holy Places, Jordan (awqaf.gov.jo): Annual Calendar 2026, zone 'عمان/ ا. https://www.awqaf.gov.jo/ebv4.0/root_storage/ar/eb_list_page/%D8%A7%D9%84%D8%AA%D9%82%D9%88%D9%8A%D9%85_2026_%D9%83%D8%A7%D9%85%D9%84_-%D9%85%D8%B6%D8%BA%D9%88%D8%B7.pdf
        PrayerFixture(city: "Amman", country: "JO", latitude: 31.9539, longitude: 35.9106, timeZone: "Asia/Amman", days: [
            .init("2026-01-15", ["06:11", "07:30", "12:46", "15:36", "18:01", "19:21"]),
            .init("2026-02-20", ["05:52", "07:07", "12:50", "16:02", "18:33", "19:49"]),
            .init("2026-03-05", ["05:38", "06:53", "12:48", "16:07", "18:43", "19:58"]),
            .init("2026-03-18", ["05:21", "06:37", "12:45", "16:11", "18:53", "20:08"]),
            .init("2026-03-20", ["05:19", "06:34", "12:44", "16:12", "18:54", "20:10"]),
            .init("2026-06-21", ["03:50", "05:24", "12:38", "16:19", "19:53", "21:26"]),
            .init("2026-09-23", ["05:03", "06:19", "12:29", "15:56", "18:38", "19:54"]),
            .init("2026-12-21", ["06:05", "07:26", "12:35", "15:18", "17:43", "19:04"]),
        ]),
        // Diyanet İşleri Başkanlığı (Presidency of Religious Affairs, Türkiye), namazvakitleri.diyanet.gov.tr. https://namazvakitleri.diyanet.gov.tr/tr-TR/9206/ankara-icin-namaz-vakti
        PrayerFixture(city: "Ankara", country: "TR", latitude: 39.938, longitude: 32.848, timeZone: "Europe/Istanbul", days: [
            .init("2026-01-15", ["06:33", "08:02", "13:03", "15:32", "17:54", "19:17"], imsak: "06:33"),
            .init("2026-02-20", ["06:05", "07:28", "13:07", "16:07", "18:36", "19:55"], imsak: "06:05"),
            .init("2026-03-05", ["05:47", "07:09", "13:05", "16:17", "18:51", "20:08"], imsak: "05:47"),
            .init("2026-03-18", ["05:25", "06:49", "13:02", "16:24", "19:05", "20:23"], imsak: "05:25"),
            .init("2026-03-20", ["05:22", "06:46", "13:01", "16:25", "19:07", "20:25"], imsak: "05:22"),
            .init("2026-06-21", ["03:17", "05:13", "12:55", "16:53", "20:28", "22:15"], imsak: "03:17"),
            .init("2026-09-23", ["05:06", "06:30", "12:46", "16:11", "18:53", "20:11"], imsak: "05:06"),
            .init("2026-12-21", ["06:29", "08:00", "12:51", "15:13", "17:33", "18:59"], imsak: "06:29"),
            .init("2027-02-10", ["06:17", "07:41", "13:08", "15:58", "18:24", "19:44"], imsak: "06:17"),
            .init("2027-02-24", ["06:00", "07:23", "13:07", "16:10", "18:41", "19:59"], imsak: "06:00"),
            .init("2027-03-06", ["05:45", "07:08", "13:05", "16:17", "18:52", "20:09"], imsak: "05:45"),
        ]),
        // Dar al-Ifta al-Misriyyah (Egyptian Fatwa House), dar-alifta.org: monthly prayer table for القاهرة (Cairo). https://www.dar-alifta.org/ar/prayer
        PrayerFixture(city: "Cairo", country: "EG", latitude: 30.0444, longitude: 31.2357, timeZone: "Africa/Cairo", days: [
            .init("2026-01-15", ["05:20", "06:52", "12:04", "14:58", "17:17", "18:39"]),
            .init("2026-02-20", ["05:03", "06:30", "12:09", "15:22", "17:47", "19:05"]),
            .init("2026-03-05", ["04:50", "06:17", "12:06", "15:27", "17:57", "19:14"]),
            .init("2026-03-18", ["04:35", "06:01", "12:03", "15:29", "18:05", "19:22"]),
            .init("2026-03-20", ["04:32", "05:59", "12:02", "15:30", "18:06", "19:24"]),
            .init("2026-06-21", ["04:08", "05:54", "12:57", "16:32", "19:59", "21:33"]),
        ]),
        // Ministry of Awqaf and Islamic Affairs, State of Qatar (www.islam.gov.qa). https://meiaservicesext.islam.gov.qa/ServicesBrokerGatewayAPI/api/PrayerTimes
        PrayerFixture(city: "Doha", country: "QA", latitude: 25.2854, longitude: 51.531, timeZone: "Asia/Qatar", days: [
            .init("2026-01-15", ["05:00", "06:21", "11:43", "14:45", "17:07", "18:37"]),
            .init("2026-02-20", ["04:47", "06:05", "11:48", "15:04", "17:34", "19:04"]),
            .init("2026-03-05", ["04:36", "05:53", "11:45", "15:07", "17:41", "19:11"]),
            .init("2026-03-18", ["04:23", "05:40", "11:42", "15:08", "17:47", "19:17"]),
            .init("2026-03-20", ["04:21", "05:38", "11:41", "15:08", "17:47", "19:17"]),
            .init("2026-06-21", ["03:13", "04:44", "11:36", "14:58", "18:29", "19:59"]),
            .init("2026-09-23", ["04:05", "05:23", "11:26", "14:52", "17:32", "19:02"]),
            .init("2026-12-21", ["04:52", "06:15", "11:32", "14:29", "16:51", "18:21"]),
            .init("2027-02-10", ["04:54", "06:12", "11:48", "15:00", "17:27", "18:57"]),
            .init("2027-02-24", ["04:44", "06:02", "11:47", "15:05", "17:36", "19:06"]),
            .init("2027-03-06", ["04:35", "05:52", "11:45", "15:07", "17:41", "19:11"]),
        ]),
        // General Authority of Islamic Affairs, Endowments and Zakat (UAE Awqaf), awqaf.gov.ae. https://mobileappapi.awqaf.gov.ae/APIS/v3/prayer-time/prayertimes/2025-06-16/2025-06-17
        PrayerFixture(city: "Dubai", country: "AE", latitude: 25.113055, longitude: 55.108333, timeZone: "Asia/Dubai", days: [
            .init("2025-06-16", ["03:58", "05:25", "12:22", "15:43", "19:14", "20:40"], imsak: "03:58"),
            .init("2025-06-17", ["03:59", "05:25", "12:22", "15:43", "19:14", "20:41"], imsak: "03:59"),
        ]),
        // Diyanet İşleri Başkanlığı (Presidency of Religious Affairs, Türkiye), namazvakitleri.diyanet.gov.tr. https://namazvakitleri.diyanet.gov.tr/tr-TR/9541/istanbul-icin-namaz-vakti
        PrayerFixture(city: "Istanbul", country: "TR", latitude: 41.012, longitude: 28.974, timeZone: "Europe/Istanbul", days: [
            .init("2026-01-15", ["06:50", "08:20", "13:18", "15:45", "18:07", "19:31"], imsak: "06:50"),
            .init("2026-02-20", ["06:20", "07:45", "13:23", "16:21", "18:51", "20:10"], imsak: "06:20"),
            .init("2026-03-05", ["06:01", "07:26", "13:21", "16:31", "19:06", "20:25"], imsak: "06:01"),
            .init("2026-03-18", ["05:40", "07:04", "13:17", "16:39", "19:20", "20:40"], imsak: "05:40"),
            .init("2026-03-20", ["05:36", "07:01", "13:17", "16:41", "19:22", "20:42"], imsak: "05:36"),
            .init("2026-06-21", ["03:24", "05:25", "13:11", "17:11", "20:47", "22:38"], imsak: "03:24"),
            .init("2026-09-23", ["05:20", "06:45", "13:02", "16:26", "19:08", "20:28"], imsak: "05:20"),
            .init("2026-12-21", ["06:46", "08:18", "13:07", "15:25", "17:46", "19:12"], imsak: "06:46"),
            .init("2027-02-10", ["06:33", "07:59", "13:23", "16:11", "18:38", "19:59"], imsak: "06:33"),
            .init("2027-02-24", ["06:15", "07:40", "13:22", "16:24", "18:55", "20:14"], imsak: "06:15"),
            .init("2027-03-06", ["06:00", "07:24", "13:21", "16:32", "19:07", "20:25"], imsak: "06:00"),
        ]),
        // Kementerian Agama RI, Direktorat Jenderal Bimbingan Masyarakat Islam (bimasislam.kemenag.go.id), regency 'KOTA. https://bimasislam.kemenag.go.id/jadwalshalat
        PrayerFixture(city: "Jakarta", country: "ID", latitude: -6.1754, longitude: 106.8272, timeZone: "Asia/Jakarta", days: [
            .init("2026-01-15", ["04:27", "05:45", "12:05", "15:30", "18:18", "19:33"], imsak: "04:17"),
            .init("2026-02-20", ["04:42", "05:55", "12:10", "15:19", "18:18", "19:28"], imsak: "04:32"),
            .init("2026-03-05", ["04:43", "05:55", "12:08", "15:08", "18:13", "19:22"], imsak: "04:33"),
            .init("2026-03-18", ["04:42", "05:54", "12:04", "15:12", "18:08", "19:16"], imsak: "04:32"),
            .init("2026-03-20", ["04:42", "05:54", "12:04", "15:13", "18:07", "19:15"], imsak: "04:32"),
            .init("2026-06-21", ["04:40", "05:58", "11:58", "15:19", "17:51", "19:05"], imsak: "04:30"),
            .init("2026-09-23", ["04:27", "05:39", "11:49", "14:58", "17:52", "19:00"], imsak: "04:17"),
            .init("2026-12-21", ["04:13", "05:33", "11:54", "15:20", "18:08", "19:24"], imsak: "04:03"),
            .init("2027-02-10", ["04:39", "05:54", "12:10", "15:26", "18:20", "19:31"], imsak: "04:29"),
            .init("2027-02-24", ["04:42", "05:55", "12:09", "15:17", "18:17", "19:26"], imsak: "04:32"),
            .init("2027-03-06", ["04:43", "05:55", "12:08", "15:08", "18:13", "19:22"], imsak: "04:33"),
        ]),
        // Jabatan Kemajuan Islam Malaysia (JAKIM), e-Solat. https://www.e-solat.gov.my/index.php
        PrayerFixture(city: "Kuala Lumpur", country: "MY", latitude: 3.733333, longitude: 101.383333, timeZone: "Asia/Kuala_Lumpur", days: [
            .init("2026-01-15", ["06:13", "07:23", "13:25", "16:48", "19:23", "20:36"], imsak: "06:03"),
            .init("2026-02-20", ["06:18", "07:25", "13:30", "16:47", "19:29", "20:39"], imsak: "06:08"),
            .init("2026-03-05", ["06:16", "07:22", "13:28", "16:41", "19:28", "20:37"], imsak: "06:06"),
            .init("2026-03-18", ["06:11", "07:17", "13:24", "16:31", "19:26", "20:35"], imsak: "06:01"),
            .init("2026-03-20", ["06:10", "07:17", "13:24", "16:29", "19:26", "20:35"], imsak: "06:00"),
            .init("2026-06-21", ["05:52", "07:05", "13:18", "16:44", "19:27", "20:43"], imsak: "05:42"),
            .init("2026-09-23", ["05:55", "07:02", "13:09", "16:14", "19:11", "20:20"], imsak: "05:45"),
            .init("2026-12-21", ["06:01", "07:12", "13:14", "16:37", "19:11", "20:26"], imsak: "05:51"),
        ]),
        // Umm al-Qura Calendar, King Abdulaziz City for Science and Technology (KACST). https://umqserv.kacst.gov.sa/api/v1/Prayer/GetPrayerByYear
        PrayerFixture(city: "Makkah", country: "SA", latitude: 21.426666, longitude: 39.831666, timeZone: "Asia/Riyadh", days: [
            .init("2026-01-15", ["05:41", "07:00", "12:31", "15:38", "18:00", "19:30"]),
            .init("2026-02-20", ["05:32", "06:48", "12:35", "15:54", "18:21", "20:21"]),
            .init("2026-03-05", ["05:22", "06:38", "12:33", "15:55", "18:27", "20:27"]),
            .init("2026-03-18", ["05:11", "06:26", "12:29", "15:54", "18:32", "20:32"]),
            .init("2026-03-20", ["05:09", "06:24", "12:29", "15:53", "18:32", "20:02"]),
            .init("2026-06-21", ["04:12", "05:39", "12:23", "15:43", "19:06", "20:36"]),
            .init("2026-09-23", ["04:54", "06:09", "12:14", "15:38", "18:17", "19:47"]),
            .init("2026-12-21", ["05:33", "06:53", "12:19", "15:23", "17:44", "19:14"]),
            .init("2027-02-10", ["05:37", "06:54", "12:35", "15:51", "18:16", "20:16"]),
            .init("2027-02-24", ["05:29", "06:45", "12:34", "15:54", "18:23", "20:23"]),
            .init("2027-03-06", ["05:22", "06:37", "12:32", "15:55", "18:27", "20:27"]),
        ]),
        // Ministry of Habous and Islamic Affairs, Kingdom of Morocco (habous.gov.ma), city الرباط (ville=1). https://www.habous.gov.ma/prieres/index.php
        PrayerFixture(city: "Rabat", country: "MA", latitude: 34.0209, longitude: -6.8416, timeZone: "Africa/Casablanca", days: [
            .init("2026-02-20", ["05:38", "07:04", "12:46", "15:50", "18:20", "19:35"]),
            .init("2026-03-05", ["05:23", "06:48", "12:44", "15:57", "18:31", "19:45"]),
            .init("2026-03-18", ["05:05", "06:31", "12:40", "16:02", "18:41", "19:56"]),
            .init("2026-03-20", ["05:02", "06:28", "12:40", "16:02", "18:43", "19:58"]),
            .init("2026-09-23", ["04:47", "06:13", "12:25", "15:47", "18:27", "19:41"]),
        ]),
        // Umm al-Qura Calendar, King Abdulaziz City for Science and Technology (KACST). https://umqserv.kacst.gov.sa/api/v1/Prayer/GetPrayerByYear
        PrayerFixture(city: "Riyadh", country: "SA", latitude: 24.67, longitude: 46.69, timeZone: "Asia/Riyadh", days: [
            .init("2026-01-15", ["05:17", "06:39", "12:03", "15:06", "17:26", "18:56"]),
            .init("2026-02-20", ["05:05", "06:23", "12:07", "15:25", "17:51", "19:51"]),
            .init("2026-03-05", ["04:54", "06:12", "12:05", "15:27", "17:58", "19:58"]),
            .init("2026-03-18", ["04:41", "05:59", "12:02", "15:28", "18:04", "20:04"]),
            .init("2026-03-20", ["04:39", "05:57", "12:01", "15:27", "18:05", "19:35"]),
            .init("2026-06-21", ["03:34", "05:04", "11:56", "15:16", "18:46", "20:16"]),
            .init("2026-09-23", ["04:25", "05:42", "11:46", "15:12", "17:49", "19:19"]),
            .init("2026-12-21", ["05:10", "06:33", "11:52", "14:50", "17:10", "18:40"]),
            .init("2027-02-10", ["05:12", "06:31", "12:08", "15:20", "17:44", "19:44"]),
            .init("2027-02-24", ["05:02", "06:20", "12:07", "15:26", "17:53", "19:53"]),
            .init("2027-03-06", ["04:54", "06:11", "12:05", "15:27", "17:58", "19:58"]),
        ]),
        // Majlis Ugama Islam Singapura (MUIS), dataset 'Muslim Prayer Timetable 2026' published on data.gov.sg. https://data.gov.sg/datasets/d_d441e7242e78efc566024dd5b0d9829c/view
        PrayerFixture(city: "Singapore", country: "SG", latitude: 1.3521, longitude: 103.8198, timeZone: "Asia/Singapore", days: [
            .init("2026-01-15", ["05:51", "07:13", "13:16", "16:39", "19:17", "20:30"]),
            .init("2026-02-20", ["05:58", "07:16", "13:20", "16:36", "19:22", "20:31"]),
            .init("2026-03-05", ["05:57", "07:14", "13:18", "16:28", "19:20", "20:28"]),
            .init("2026-03-18", ["05:53", "07:10", "13:14", "16:17", "19:17", "20:25"]),
            .init("2026-03-20", ["05:52", "07:09", "13:14", "16:14", "19:17", "20:25"]),
            .init("2026-06-21", ["05:37", "07:01", "13:08", "16:33", "19:13", "20:28"]),
            .init("2026-09-23", ["05:37", "06:54", "12:58", "16:01", "19:01", "20:09"]),
            .init("2026-12-21", ["05:38", "07:02", "13:05", "16:29", "19:05", "20:20"]),
        ]),
        // Bahrain: pray.bh (a Bahraini site; the ministry publishes only in its Islamiyat app).
        PrayerFixture(city: "Manama", country: "BH", latitude: 26.2235, longitude: 50.5876, timeZone: "Asia/Bahrain", days: [
            .init("2026-07-28", ["03:35", "05:01", "11:44", "15:13", "18:27", "19:53"]),
            .init("2026-10-09", ["04:17", "05:34", "11:25", "14:47", "17:17", "18:33"]),
        ]),
    ]
}
