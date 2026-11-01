//
//  BatteryDetails.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Battery facts from real measurements, never inferred: health as macOS reports it (else the gauge's
//  ratio, labelled an estimate), the power drawn now, and apps' CPU energy (the kernel's estimate).
//

import Darwin
import Foundation
import IOKit
import Observation

@MainActor
@Observable
final class BatteryDetails {
    static let shared = BatteryDetails()

    struct Health: Equatable {
        /// Percent, as macOS shows it in Settings → Battery.
        var maximumCapacity: Int?
        /// "Good", "Service Recommended"… (macOS wording).
        var condition: String?
        var cycles: Int?
        /// True when the figure came from the gauge ratio, not macOS.
        var isEstimate = false

        /// The condition in Settings › Battery's words in the app's language; English as macOS reports it.
        var localizedCondition: String? {
            switch condition {
            case "Good": String(localized: "Battery condition: Good", defaultValue: "Good", comment: "macOS's battery condition, as Settings › Battery words it")
            case "Fair": String(localized: "Battery condition: Fair", defaultValue: "Fair", comment: "macOS's battery condition, as Settings › Battery words it")
            case "Poor": String(localized: "Battery condition: Poor", defaultValue: "Poor", comment: "macOS's battery condition, as Settings › Battery words it")
            case "Check Battery": String(localized: "Battery condition: Check Battery", defaultValue: "Check Battery",
                                         comment: "macOS's battery condition, as Settings › Battery words it")
            default: condition
            }
        }
    }

    private(set) var health: Health?
    @ObservationIgnored private var lastRead: Date?
    @ObservationIgnored private var reading = false

    /// Health changes slowly; read it at most every 6 hours, off the main thread.
    func refreshHealthIfNeeded() {
        guard !reading, lastRead.map({ Date().timeIntervalSince($0) > 6 * 3600 }) ?? true else { return }
        reading = true
        Task.detached(priority: .utility) {
            let value = Self.readSystemHealth() ?? Self.gaugeHealth()
            await MainActor.run {
                self.health = value
                self.lastRead = Date()
                self.reading = false
            }
        }
    }

    // MARK: Sources

    nonisolated static func readSystemHealth() -> Health? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPPowerDataType", "-json"]
        process.environment = Process.cleanEnvironment()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parseSystemHealth(data)
    }

    nonisolated static func parseSystemHealth(_ data: Data) -> Health? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["SPPowerDataType"] as? [[String: Any]],
              let info = entries.lazy.compactMap({ $0["sppower_battery_health_info"] as? [String: Any] }).first
        else { return nil }
        let percent = (info["sppower_battery_health_maximum_capacity"] as? String)
            .flatMap { Int($0.trimmingCharacters(in: CharacterSet(charactersIn: "% "))) }
        return Health(maximumCapacity: percent,
                      condition: info["sppower_battery_health"] as? String,
                      cycles: info["sppower_battery_cycle_count"] as? Int)
    }

    /// Smart-battery registry, which macOS 27 nests under "BatteryData".
    nonisolated static func batteryProperties() -> [String: Any]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS else { return nil }
        return properties?.takeRetainedValue() as? [String: Any]
    }

    nonisolated static func number(_ key: String, in properties: [String: Any]) -> Double? {
        if let value = properties[key] as? NSNumber { return value.doubleValue }
        return ((properties["BatteryData"] as? [String: Any])?[key] as? NSNumber)?.doubleValue
    }

    nonisolated static func gaugeHealth() -> Health? {
        guard let properties = batteryProperties(), let design = number("DesignCapacity", in: properties), design > 0,
              let full = number("NominalChargeCapacity", in: properties) ?? number("AppleRawMaxCapacity", in: properties),
              full > 0 else { return nil }
        return Health(maximumCapacity: Int((min(full / design, 1) * 100).rounded()), condition: nil,
                      cycles: number("CycleCount", in: properties).map { Int($0) }, isEstimate: true)
    }

    nonisolated static func systemPowerWatts() -> Double? {
        guard let telemetry = batteryProperties()?["PowerTelemetryData"] as? [String: Any],
              let milliwatts = (telemetry["SystemLoad"] as? NSNumber)?.doubleValue, milliwatts > 0 else { return nil }
        return milliwatts / 1000
    }
}

/// Per-app CPU energy from the kernel's accounting (rusage v6 `ri_energy_nj`); only your own
/// processes are readable. Sampled when the battery details open, never in the background.
enum EnergyEstimator {
    struct AppEnergy: Identifiable, Equatable {
        var id: String { path }
        let path: String
        let name: String
        let milliwatts: Double
    }

    static func sample() async -> [AppEnergy] {
        let interval: TimeInterval = 1.5
        return await Task.detached(priority: .utility) {
            let first = snapshot()
            try? await Task.sleep(for: .seconds(interval))
            let second = snapshot()
            return rank(first: first, second: second, interval: interval, limit: 3)
        }.value
    }

    /// pid → (energy nJ, app bundle path)
    static func snapshot() -> [pid_t: (energy: UInt64, app: String)] {
        var pids = [pid_t](repeating: 0, count: 4096)
        let count = Int(proc_listallpids(&pids, Int32(MemoryLayout<pid_t>.size * pids.count)))
        var result: [pid_t: (UInt64, String)] = [:]
        for pid in pids.prefix(max(0, count)) where pid > 0 {
            var info = rusage_info_v6()
            let ok = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) == 0
                }
            }
            guard ok, let path = ProcessLineage.info(pid)?.path, let app = ProcessLineage.bundlePath(in: path) else { continue }
            result[pid] = (info.ri_energy_nj, app)
        }
        return result
    }

    static func rank(first: [pid_t: (energy: UInt64, app: String)], second: [pid_t: (energy: UInt64, app: String)],
                     interval: TimeInterval, limit: Int) -> [AppEnergy] {
        var byApp: [String: Double] = [:]
        for (pid, now) in second {
            guard let before = first[pid], before.app == now.app, now.energy >= before.energy else { continue }
            byApp[now.app, default: 0] += Double(now.energy - before.energy) / interval / 1_000_000  // nJ/s → mW
        }
        return byApp.filter { $0.value >= 1 }
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map { AppEnergy(path: $0.key, name: AppInfo.name(url: URL(fileURLWithPath: $0.key)), milliwatts: $0.value) }
    }
}
