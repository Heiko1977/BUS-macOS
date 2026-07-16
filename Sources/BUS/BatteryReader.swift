import Foundation
import IOKit
import IOKit.ps

struct BatteryReader {
    private let hardwareReader = HardwareTelemetryReader()

    func read() -> BatterySnapshot? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let properties = unmanaged?.takeRetainedValue() as? [String: Any] else { return nil }

        func number(_ keys: [String]) -> Double? {
            for key in keys {
                if let n = properties[key] as? NSNumber { return n.doubleValue }
            }
            return nil
        }
        func bool(_ key: String) -> Bool {
            (properties[key] as? NSNumber)?.boolValue ?? false
        }

        func adapterWatts() -> Double? {
            let candidates = [
                properties["AdapterDetails"],
                properties["AppleRawAdapterDetails"]
            ]

            for candidate in candidates {
                if let details = candidate as? [String: Any] {
                    for key in ["Watts", "AdapterWattage", "MaxPower"] {
                        if let value = details[key] as? NSNumber {
                            let watts = value.doubleValue
                            if watts > 0 { return watts }
                        }
                    }

                    if let voltage = details["Voltage"] as? NSNumber,
                       let current = details["Current"] as? NSNumber {
                        let watts = voltage.doubleValue
                            * current.doubleValue
                            / 1_000_000.0
                        if watts > 0 { return watts }
                    }
                }
            }

            return number([
                "AdapterWattage",
                "AppleRawAdapterWattage"
            ])
        }

        let current = number(["CurrentCapacity"]) ?? 0
        let maximum = Swift.max(number(["MaxCapacity"]) ?? 100, 1)
        let percent = Swift.min(Swift.max(current / maximum * 100.0, 0), 100)

        let hardware = hardwareReader.read()

        let source: String?
        if hardware?.adapterInputWatts != nil {
            source = "smc:\(hardware?.adapterInputSource ?? "unknown")"
        } else if hardware != nil {
            source = "helper-fallback"
        } else {
            source = nil
        }

        return BatterySnapshot(
            date: .now,
            percent: percent,
            rawCurrentCapacityMAh: number(["AppleRawCurrentCapacity", "NominalChargeCapacity"]),
            rawMaxCapacityMAh: number(["AppleRawMaxCapacity", "AppleRawMaxCapacity"]),
            voltageMV: number(["Voltage"]),
            amperageMA: number(["Amperage"]),
            adapterPowerWatts: adapterWatts(),
            measuredAdapterInputWatts: hardware?.adapterInputWatts,
            measuredSystemPowerWatts: hardware?.systemPowerWatts,
            helperBatteryPowerWatts: hardware?.batteryPowerWatts,
            hardwareSource: source,
            helperSMCAvailable: hardware?.smcAvailable ?? false,
            isCharging: bool("IsCharging"),
            externalConnected: bool("ExternalConnected")
        )
    }
}
