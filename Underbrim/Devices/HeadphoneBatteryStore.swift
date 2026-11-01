//
//  HeadphoneBatteryStore.swift
//  Underbrim
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Battery levels of connected Bluetooth headphones. macOS has no public API for them; the
//  undocumented IOBluetoothDevice battery properties are read only when the device responds to them,
//  and missing values are labelled, never guessed. Re-read on connect and when shown, not on a timer.
//

import Defaults
import Foundation
import IOBluetooth
import Observation

@MainActor
@Observable
final class HeadphoneBatteryStore: NSObject {
    static let shared = HeadphoneBatteryStore()

    struct Device: Identifiable, Equatable {
        let id: String          // Bluetooth address
        let name: String
        var left: Int?
        var right: Int?
        var caseLevel: Int?
        /// Single-cell devices (most non-AirPods headphones).
        var single: Int?

        var hasAnyReading: Bool { [left, right, caseLevel, single].contains { $0 != nil } }
        var lowest: Int? { [left, right, single].compactMap { $0 }.min() }
    }

    private(set) var devices: [Device] = []
    private(set) var justConnected: Device?

    @ObservationIgnored private var connectNotification: IOBluetoothUserNotification?
    @ObservationIgnored private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]
    @ObservationIgnored private var pillTask: Task<Void, Never>?

    func start() {
        Defaults.whenChanged([.showHeadphoneBattery]) { [weak self] in self?.refreshEnabled() }
        refreshEnabled()
    }

    func refreshEnabled() {
        if Defaults[.showHeadphoneBattery] {
            guard connectNotification == nil else { return }
            connectNotification = IOBluetoothDevice.register(forConnectNotifications: self,
                                                              selector: #selector(deviceConnected(_:device:)))
            reloadConnected()
        } else {
            connectNotification?.unregister()
            connectNotification = nil
            disconnectNotifications.values.forEach { $0.unregister() }
            disconnectNotifications.removeAll()
            devices = []
        }
    }

    func reloadConnected() {
        guard Defaults[.showHeadphoneBattery] else { return }
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        devices = paired.filter { $0.isConnected() && Self.isAudio($0) }.map(Self.reading)
        for device in paired where device.isConnected() { watchDisconnect(device) }
    }

    @objc private func deviceConnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard Self.isAudio(device) else { return }
        watchDisconnect(device)
        // Levels often arrive a moment after the link comes up.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            reloadConnected()
            if let fresh = devices.first(where: { $0.id == device.addressString }) {
                showPill(fresh)
            }
        }
    }

    @objc private func deviceDisconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        disconnectNotifications.removeValue(forKey: device.addressString ?? "")?.unregister()
        devices.removeAll { $0.id == device.addressString }
        if justConnected?.id == device.addressString { justConnected = nil }
    }

    private func watchDisconnect(_ device: IOBluetoothDevice) {
        guard let address = device.addressString, disconnectNotifications[address] == nil else { return }
        disconnectNotifications[address] = device.register(forDisconnectNotification: self,
                                                           selector: #selector(deviceDisconnected(_:device:)))
    }

    private func showPill(_ device: Device) {
        guard device.hasAnyReading else { return }
        justConnected = device
        pillTask?.cancel()
        pillTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            justConnected = nil
        }
    }

    // MARK: Reading

    nonisolated static func isAudio(_ device: IOBluetoothDevice) -> Bool {
        device.deviceClassMajor == kBluetoothDeviceClassMajorAudio
    }

    nonisolated static func reading(_ device: IOBluetoothDevice) -> Device {
        func level(_ key: String) -> Int? {
            guard device.responds(to: NSSelectorFromString(key)) else { return nil }
            return normalized((device.value(forKey: key) as? NSNumber)?.intValue)
        }
        return Device(id: device.addressString ?? UUID().uuidString,
                      name: device.name ?? String(localized: "Headphones"),
                      left: level("batteryPercentLeft"), right: level("batteryPercentRight"),
                      caseLevel: level("batteryPercentCase"), single: level("batteryPercentSingle"))
    }

    /// 0 means "not reported" for these properties; anything outside 1…100 is ignored.
    nonisolated static func normalized(_ raw: Int?) -> Int? {
        guard let raw, (1...100).contains(raw) else { return nil }
        return raw
    }
}
