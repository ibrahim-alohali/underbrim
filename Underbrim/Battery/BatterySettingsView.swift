//
//  BatterySettingsView.swift
//  Underbrim
//
//  Created by Richard Kunkli on 07/08/2024.
//

import Defaults
import SwiftUI

/// Live Activities › Battery.
struct BatterySettingsSection: View {
    var body: some View {
        Section {
            Defaults.Toggle(key: .showBatteryIndicator) {
                Text("Show battery indicator")
            }
            .settingsItem("Show battery indicator")
            Defaults.Toggle(key: .showBatteryPercentage) {
                Text("Show battery percentage")
            }
            .settingsItem("Show battery percentage")
            Defaults.Toggle(key: .showPowerStatusNotifications) {
                Text("Show power status notifications")
            }
            .settingsItem("Show power status notifications")
            Defaults.Toggle(key: .showHeadphoneBattery) {
                SettingsLabel("Show headphone battery",
                              info: "For AirPods and other Bluetooth headphones that report it. macOS will ask for Bluetooth permission.",
                              "Uses battery properties macOS doesn't document. Left, right and case levels appear only when the headphones report them.")
            }
            .settingsItem("Show headphone battery")
        } header: {
            Text("Battery")
        }
    }
}

/// Advanced › Battery.
struct BatteryAdvancedSettings: View {
    var body: some View {
        Section {
            Defaults.Toggle(key: .showPowerStatusIcons) {
                Text("Show power status icons")
            }
            .settingsItem("Show power status icons")
            Defaults.Toggle(key: .showChargingWattage) {
                Text("Show charging wattage")
            }
            .settingsItem("Show charging wattage")
        } header: {
            AdvancedHeader(area: .battery)
        }
    }
}
