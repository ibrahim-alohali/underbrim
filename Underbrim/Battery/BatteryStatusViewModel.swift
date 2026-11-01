import Cocoa
import Defaults
import Foundation
import IOKit.ps
import SwiftUI

/// A view model that manages and monitors the battery status of the device
final class BatteryStatusViewModel: ObservableObject {
    private var wasCharging: Bool = false
    private var powerSourceChangedCallback: IOPowerSourceCallbackType?
    private var runLoopSource: Unmanaged<CFRunLoopSource>?

    @Published private(set) var levelBattery: Float = 0.0
    @Published private(set) var maxCapacity: Float?
    @Published private(set) var isPluggedIn: Bool = false
    @Published private(set) var isCharging: Bool = false
    @Published private(set) var isInLowPowerMode: Bool = false
    @Published private(set) var isInitial: Bool = false
    @Published private(set) var timeToFullCharge: Int = 0
    @Published private(set) var timeToDischarge: Int = 0
    @Published private(set) var maxAdapterWatts: Int = 0
    @Published private(set) var lastStatus: LastStatus = .plugged(false)
    /// When the charger last went in (never at launch; at most once in 5 s): the rim's green light.
    @Published private(set) var pluggedInAt: Date?
    /// When it last came out (likewise): the light draining back.
    @Published private(set) var unpluggedAt: Date?
    /// When the battery last ran down to 20% or 10% on battery: the rim's red pulse.
    @Published private(set) var lowBatteryAt: Date?
    /// The last of those said, so each is said once a run down.
    private var warnedAt: Float?

    enum LastStatus: Equatable {
        case plugged(Bool)
        case lowPower(Bool)
        case charging(isCharging: Bool, level: Float)
        case lowBattery
    }

    /// Down to 20%, and again to 10%, on battery: the level it ran down past, if that's one still to say.
    static func lowThreshold(from before: Float, to level: Float, pluggedIn: Bool, warned: Float?) -> Float? {
        guard !pluggedIn else { return nil }
        return ([10, 20] as [Float]).first { level <= $0 && before > $0 && (warned ?? 100) > $0 }
    }

    var statusText: LocalizedStringKey {
        switch lastStatus {
        case .plugged(let plugged):
            return plugged ? LocalizedStringKey("Plugged In") : LocalizedStringKey("Unplugged")
        case .lowPower(let enabled):
            return enabled ? LocalizedStringKey("Low Power: On") : LocalizedStringKey("Low Power: Off")
        case .lowBattery:
            return LocalizedStringKey("Low Battery")
        case .charging(let isCharging, let level):
            if isCharging {
                return LocalizedStringKey("Charging battery")
            }
            if level < 100 {
                return LocalizedStringKey("Not charging")
            }
            return LocalizedStringKey("Full charge")
        }
    }

    private let managerBattery = BatteryActivityManager.shared
    private var managerBatteryId: Int?

    static let shared = BatteryStatusViewModel()

    init() {
        setupPowerStatus()
        setupMonitor()
    }

    /// Sets up the initial power status by fetching battery information
    private func setupPowerStatus() {
        let batteryInfo = managerBattery.initializeBatteryInfo()
        updateBatteryInfo(batteryInfo)
    }

    /// Sets up the monitor to observe battery events
    private func setupMonitor() {
        managerBatteryId = managerBattery.addObserver { [weak self] events in
            self?.apply(events)
        }
    }

    /// One reading's changes, applied together so the notch never shows half of them.
    func apply(_ events: [BatteryActivityManager.BatteryEvent]) {
        events.forEach(handleBatteryEvent)
    }

    /// Handles battery events and updates the corresponding properties
    /// - Parameter event: The battery event to handle
    private func handleBatteryEvent(_ event: BatteryActivityManager.BatteryEvent) {
        switch event {
        case .powerSourceChanged(let isPluggedIn):
            Log.battery.debug("🔌 Power source: \(isPluggedIn ? "Connected" : "Disconnected")")
            if isPluggedIn, !self.isPluggedIn, pluggedInAt.map({ $0.timeIntervalSinceNow <= -5 }) ?? true { pluggedInAt = .now }
            if !isPluggedIn, self.isPluggedIn, unpluggedAt.map({ $0.timeIntervalSinceNow <= -5 }) ?? true { unpluggedAt = .now }
            if isPluggedIn { warnedAt = nil }
            withAnimation {
                self.isPluggedIn = isPluggedIn
                // remember the last battery-related message so the computed
                // property can translate it later
                self.lastStatus = .plugged(isPluggedIn)
                self.notifyImportanChangeStatus()
            }

        case .batteryLevelChanged(let level):
            Log.battery.debug("🔋 Battery level: \(Int(level))%")
            let before = levelBattery
            withAnimation {
                self.levelBattery = level
            }
            if let threshold = Self.lowThreshold(from: before, to: level, pluggedIn: isPluggedIn, warned: warnedAt) {
                warnedAt = threshold
                lowBatteryAt = .now
                withAnimation { lastStatus = .lowBattery }
                notifyImportanChangeStatus()
            }

        case .lowPowerModeChanged(let isEnabled):
            Log.battery.debug("⚡ Low power mode: \(isEnabled ? "Enabled" : "Disabled")")
            withAnimation {
                self.isInLowPowerMode = isEnabled
                self.lastStatus = .lowPower(isEnabled)
            }
            self.notifyImportanChangeStatus()

        case .isChargingChanged(let isCharging):
            Log.battery.debug("🔌 Charging: \(isCharging ? "Yes" : "No")")
            Log.battery.debug("maxCapacity: \(self.maxCapacity.map { "\($0)" } ?? "Unavailable")")
            Log.battery.debug("levelBattery: \(self.levelBattery)")
            withAnimation {
                self.isCharging = isCharging
            }
            // Charging stops when the cable comes out: "Unplugged" says it.
            guard isPluggedIn else { return }
            self.notifyImportanChangeStatus()
            withAnimation {
                self.lastStatus = .charging(isCharging: isCharging, level: self.levelBattery)
            }

        case .timeToFullChargeChanged(let time):
            Log.battery.debug("🕒 Time to full charge: \(time) minutes")
            withAnimation {
                self.timeToFullCharge = time
            }

        case .timeToDischargeChanged(let time):
            Log.battery.debug("🕒 Time until empty: \(time) minutes")
            withAnimation {
                self.timeToDischarge = time
            }

        case .maxCapacityChanged(let capacity):
            Log.battery.debug("🔋 Max capacity: \(capacity.map { "\($0)" } ?? "Unavailable")")
            withAnimation {
                self.maxCapacity = capacity
            }

        case .adapterWattageChanged(let watts):
            Log.battery.debug("🔌 Power adapter: \(watts)W")
            withAnimation {
                self.maxAdapterWatts = watts
            }

        case .error(let description):
            Log.battery.error("⚠️ Error: \(description)")
        }
    }

    /// Updates the battery information with the given BatteryInfo instance
    /// - Parameter batteryInfo: The BatteryInfo instance containing the battery data
    private func updateBatteryInfo(_ batteryInfo: BatteryInfo) {
        withAnimation {
            self.levelBattery = batteryInfo.currentCapacity
            self.isPluggedIn = batteryInfo.isPluggedIn
            self.isCharging = batteryInfo.isCharging
            self.isInLowPowerMode = batteryInfo.isInLowPowerMode
            self.timeToFullCharge = batteryInfo.timeToFullCharge
            self.timeToDischarge = batteryInfo.timeToDischarge
            self.maxCapacity = batteryInfo.maxCapacity
            self.maxAdapterWatts = batteryInfo.maxAdapterWatts
            self.lastStatus = .plugged(batteryInfo.isPluggedIn)
        }
    }

    #if DEBUG
    /// Test builds: a plug-in for the notch (its pill and its light), the real battery state untouched.
    func debugPlugIn() {
        lastStatus = .plugged(true)
        pluggedInAt = .now
        notifyImportanChangeStatus()
    }

    /// Test builds: an unplug, likewise.
    func debugUnplug() {
        lastStatus = .plugged(false)
        unpluggedAt = .now
        notifyImportanChangeStatus()
    }

    /// Test builds: a low-battery warning, likewise.
    func debugLowBattery() {
        lastStatus = .lowBattery
        lowBatteryAt = .now
        notifyImportanChangeStatus()
    }
    #endif

    /// Notifies important changes in the battery status with an optional delay
    /// - Parameter delay: The delay before notifying the change, default is 0.0
    private func notifyImportanChangeStatus(delay: Double = 0.0) {
        Task { [delay] in
            try? await Task.sleep(for: .seconds(delay))
            NotchUIEventBus.events.send(.expandingView(type: .battery))
        }
    }

    deinit {
        Log.battery.debug("🔌 Cleaning up battery monitoring...")
        if let managerBatteryId: Int = managerBatteryId {
            managerBattery.removeObserver(byId: managerBatteryId)
        }
    }
}
