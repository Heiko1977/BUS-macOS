import Foundation

struct HardwareTelemetry: Codable {
    let schema: Int
    let timestamp: TimeInterval
    let helperVersion: String
    let smcAvailable: Bool
    let externalConnected: Bool
    let isCharging: Bool
    let batteryPowerWatts: Double?
    let batteryPowerSource: String
    let adapterInputWatts: Double?
    let adapterInputSource: String
    let systemPowerWatts: Double?
    let systemPowerSource: String

    var date: Date {
        Date(timeIntervalSince1970: timestamp)
    }

    var isFresh: Bool {
        abs(date.timeIntervalSinceNow) <= 8
    }
}

struct HardwareTelemetryReader {
    static let fileURL = URL(
        fileURLWithPath:
            "/Library/Application Support/BUS/hardware.json"
    )

    func read() -> HardwareTelemetry? {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let telemetry = try? JSONDecoder().decode(
                HardwareTelemetry.self,
                from: data
              ),
              telemetry.isFresh else {
            return nil
        }
        return telemetry
    }
}
