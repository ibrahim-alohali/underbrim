import Foundation
import IOKit
import IOKit.ps

/// Manages and monitors battery status changes on the device
/// - Note: This class uses the IOKit framework to monitor battery status
final class BatteryActivityManager {
    static let shared = BatteryActivityManager()

    private var batterySource: CFRunLoopSource?
    private var observers: [([BatteryEvent]) -> Void] = []
    private var previousBatteryInfo: BatteryInfo?

    enum BatteryEvent {
        case powerSourceChanged(isPluggedIn: Bool)
        case batteryLevelChanged(level: Float)
        case lowPowerModeChanged(isEnabled: Bool)
        case isChargingChanged(isCharging: Bool)
        case timeToFullChargeChanged(time: Int)
        case timeToDischargeChanged(time: Int)
        case maxCapacityChanged(capacity: Float?)
        case adapterWattageChanged(watts: Int)
        case error(description: String)
    }

    enum BatteryError: Error {
        case powerSourceUnavailable
        case batteryInfoUnavailable(String)
        case batteryParameterMissing(String)
    }

    private let defaultBatteryInfo = BatteryInfo(
        isPluggedIn: false,
        isCharging: false,
        currentCapacity: 0,
        maxCapacity: nil,
        isInLowPowerMode: false,
        timeToFullCharge: 0,
        timeToDischarge: 0
    )

    private init() {
        startMonitoring()
        setupLowPowerModeObserver()
    }

    /// Setup observer for low power mode changes
    private func setupLowPowerModeObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(lowPowerModeChanged),
            name: NSNotification.Name.NSProcessInfoPowerStateDidChange,
            object: nil
        )
    }

    /// Low Power Mode changed: posted on a global queue, so it hops to main, where the power callback diffs the same state.
    @objc private func lowPowerModeChanged() {
        DispatchQueue.main.async { self.notifyBatteryChanges() }
    }

    /// Starts monitoring battery changes
    private func startMonitoring() {
        guard let powerSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context = context else { return }
            let manager = Unmanaged<BatteryActivityManager>.fromOpaque(context).takeUnretainedValue()
            manager.notifyBatteryChanges()
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue() else {
            return
        }
        batterySource = powerSource
        CFRunLoopAddSource(CFRunLoopGetCurrent(), powerSource, .defaultMode)
    }

    /// Stops monitoring battery changes
    private func stopMonitoring() {
        if let powerSource = batterySource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), powerSource, .defaultMode)
            batterySource = nil
        }
    }

    private func checkAndNotify<T: Equatable>(
        previous: T,
        current: T,
        into events: inout [BatteryEvent],
        eventGenerator: (T) -> BatteryEvent
    ) {
        if previous != current {
            events.append(eventGenerator(current))
        }
    }

    /// Notifies the observers of battery changes
    /// Checks for changes in battery status and notifies observers
    private func notifyBatteryChanges() {
        let batteryInfo = getBatteryInfo()
        var events: [BatteryEvent] = []

        // Check for changes
        if let previousInfo = previousBatteryInfo {
            // Usar la función auxiliar para cada propiedad
            checkAndNotify(
                previous: previousInfo.isPluggedIn,
                current: batteryInfo.isPluggedIn,
                into: &events,
                eventGenerator: { .powerSourceChanged(isPluggedIn: $0) }
            )

            checkAndNotify(
                previous: previousInfo.currentCapacity,
                current: batteryInfo.currentCapacity,
                into: &events,
                eventGenerator: { .batteryLevelChanged(level: $0) }
            )

            checkAndNotify(
                previous: previousInfo.isCharging,
                current: batteryInfo.isCharging,
                into: &events,
                eventGenerator: { .isChargingChanged(isCharging: $0) }
            )

            checkAndNotify(
                previous: previousInfo.isInLowPowerMode,
                current: batteryInfo.isInLowPowerMode,
                into: &events,
                eventGenerator: { .lowPowerModeChanged(isEnabled: $0) }
            )

            checkAndNotify(
                previous: previousInfo.timeToFullCharge,
                current: batteryInfo.timeToFullCharge,
                into: &events,
                eventGenerator: { .timeToFullChargeChanged(time: $0) }
            )

            checkAndNotify(
                previous: previousInfo.timeToDischarge,
                current: batteryInfo.timeToDischarge,
                into: &events,
                eventGenerator: { .timeToDischargeChanged(time: $0) }
            )

            checkAndNotify(
                previous: previousInfo.maxCapacity,
                current: batteryInfo.maxCapacity,
                into: &events,
                eventGenerator: { .maxCapacityChanged(capacity: $0) }
            )

            checkAndNotify(
                previous: previousInfo.maxAdapterWatts,
                current: batteryInfo.maxAdapterWatts,
                into: &events,
                eventGenerator: { .adapterWattageChanged(watts: $0) }
            )
        } else {
            // First time notification
            events.append(.powerSourceChanged(isPluggedIn: batteryInfo.isPluggedIn))
            events.append(.batteryLevelChanged(level: batteryInfo.currentCapacity))
            events.append(.isChargingChanged(isCharging: batteryInfo.isCharging))
            events.append(.lowPowerModeChanged(isEnabled: batteryInfo.isInLowPowerMode))
            events.append(.timeToFullChargeChanged(time: batteryInfo.timeToFullCharge))
            events.append(.timeToDischargeChanged(time: batteryInfo.timeToDischarge))
            events.append(.maxCapacityChanged(capacity: batteryInfo.maxCapacity))
            events.append(.adapterWattageChanged(watts: batteryInfo.maxAdapterWatts))
        }

        // Update previous battery info
        previousBatteryInfo = batteryInfo

        // One reading's changes land together: a second apart, "Unplugged" shows beside a charging battery.
        guard !events.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            self?.observers.forEach { $0(events) }
        }
    }

    /// Initializes the battery information when the manager starts
    /// - Returns: Current battery information
    func initializeBatteryInfo() -> BatteryInfo {
        previousBatteryInfo = getBatteryInfo()
        guard let batteryInfo = previousBatteryInfo else {
            return BatteryInfo(
                isPluggedIn: false,
                isCharging: false,
                currentCapacity: 0,
                maxCapacity: nil,
                isInLowPowerMode: false,
                timeToFullCharge: 0,
                timeToDischarge: 0
            )
        }
        return batteryInfo
    }

    /// Get the current battery information
    /// - Returns: The current battery information
    private func getBatteryInfo() -> BatteryInfo {
        do {
            // Get power source information
            guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
                throw BatteryError.powerSourceUnavailable
            }

            guard let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
                !sources.isEmpty else {
                throw BatteryError.batteryInfoUnavailable("No power sources available")
            }

            let source = sources.first!

            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else {
                throw BatteryError.batteryInfoUnavailable("Could not get power source description")
            }

            // Extract required battery parameters with error handling
            guard let currentCapacity = description[kIOPSCurrentCapacityKey] as? Float else {
                throw BatteryError.batteryParameterMissing("Current capacity")
            }

            guard let isCharging = description["Is Charging"] as? Bool else {
                throw BatteryError.batteryParameterMissing("Charging state")
            }

            guard let powerSource = description[kIOPSPowerSourceStateKey] as? String else {
                throw BatteryError.batteryParameterMissing("Power source state")
            }

            // Create battery info with the extracted parameters
            var batteryInfo = BatteryInfo(
                isPluggedIn: powerSource == kIOPSACPowerValue,
                // "Is Charging" can lag the cable coming out by a reading.
                isCharging: isCharging && powerSource == kIOPSACPowerValue,
                currentCapacity: currentCapacity,
                maxCapacity: getBatteryHealthCapacity(),
                isInLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                timeToFullCharge: 0,
                timeToDischarge: 0
            )

            // Optional parameters
            if let timeToFullCharge = description[kIOPSTimeToFullChargeKey] as? Int {
                batteryInfo.timeToFullCharge = timeToFullCharge
            }

            if let timeToDischarge = description[kIOPSTimeToEmptyKey] as? Int {
                batteryInfo.timeToDischarge = timeToDischarge
            }

            // Rated adapter wattage; nil on battery or unreported, stays 0
            if let adapterDetails = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any],
               let watts = adapterDetails[kIOPSPowerAdapterWattsKey as String] as? Int {
                batteryInfo.maxAdapterWatts = watts
            }

            return batteryInfo
        } catch BatteryError.powerSourceUnavailable {
            Log.battery.error("⚠️ Error: Power source information unavailable")
            return defaultBatteryInfo
        } catch BatteryError.batteryInfoUnavailable(let reason) {
            Log.battery.error("⚠️ Error: Battery information unavailable - \(reason)")
            return defaultBatteryInfo
        } catch BatteryError.batteryParameterMissing(let parameter) {
            Log.battery.error("⚠️ Error: Battery parameter missing - \(parameter)")
            return defaultBatteryInfo
        } catch {
            Log.battery.error("⚠️ Error: Unexpected error getting battery info - \(error.localizedDescription)")
            return defaultBatteryInfo
        }
    }

    /// Battery-gauge capacity ratio; macOS 27 moved the capacity keys under "BatteryData".
    private func getBatteryHealthCapacity() -> Float? {
        BatteryDetails.gaugeHealth()?.maximumCapacity.map(Float.init)
    }

    /// Adds an observer to listen to battery changes
    /// - Parameter observer: Called on the main queue with one reading's changes
    /// - Returns: The ID of the observer for later removal
    func addObserver(_ observer: @escaping ([BatteryEvent]) -> Void) -> Int {
        observers.append(observer)
        return observers.count - 1
    }

    /// Removes an observer by its ID
    /// - Parameter id: The ID of the observer to be removed
    func removeObserver(byId id: Int) {
        guard id >= 0 && id < observers.count else { return }
        observers.remove(at: id)
    }

    deinit {
        stopMonitoring()
        NotificationCenter.default.removeObserver(self)
    }
}

/// Struct to hold battery information
struct BatteryInfo {
    var isPluggedIn: Bool
    var isCharging: Bool
    var currentCapacity: Float
    var maxCapacity: Float?
    var isInLowPowerMode: Bool
    var timeToFullCharge: Int
    var timeToDischarge: Int
    var maxAdapterWatts: Int = 0
}
