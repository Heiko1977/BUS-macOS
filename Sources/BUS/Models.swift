import Foundation

struct ProcessEnergyRecord: Identifiable, Codable, Hashable {
    let key: String
    var id: String { key }
    let name: String
    let bundleIdentifier: String?
    var pid: Int32
    var cpuSeconds: Double = 0
    var diskReadBytes: UInt64 = 0
    var diskWriteBytes: UInt64 = 0
    var wakeups: UInt64 = 0
    var score: Double = 0
    var attributedMilliwattHours: Double = 0
    var lastSeen: Date = .now

    var diskBytes: UInt64 { diskReadBytes &+ diskWriteBytes }
}

struct AppEnergyRecord: Identifiable, Codable, Hashable {
    var id: String { bundleIdentifier ?? name }
    let name: String
    let bundleIdentifier: String?
    var applicationPath: String? = nil
    var cpuSeconds: Double = 0
    var diskReadBytes: UInt64 = 0
    var diskWriteBytes: UInt64 = 0
    var wakeups: UInt64 = 0
    var score: Double = 0
    var attributedMilliwattHours: Double = 0
    var lastSeen: Date = .now
    var processes: [String: ProcessEnergyRecord]? = nil

    var diskBytes: UInt64 { diskReadBytes &+ diskWriteBytes }

    var sortedProcesses: [ProcessEnergyRecord] {
        (processes ?? [:]).values.sorted {
            if $0.attributedMilliwattHours == $1.attributedMilliwattHours {
                return $0.score > $1.score
            }
            return $0.attributedMilliwattHours > $1.attributedMilliwattHours
        }
    }
}

struct BatterySnapshot: Codable, Equatable {
    let date: Date
    let percent: Double
    let rawCurrentCapacityMAh: Double?
    let rawMaxCapacityMAh: Double?
    let voltageMV: Double?
    let amperageMA: Double?
    let adapterPowerWatts: Double?
    let measuredAdapterInputWatts: Double?
    let measuredSystemPowerWatts: Double?
    let helperBatteryPowerWatts: Double?
    let hardwareSource: String?
    let helperSMCAvailable: Bool
    /// `false` means that the display is off while macOS is still awake.
    /// It is optional so existing locally stored runtime sessions remain valid.
    let displayIsActive: Bool?
    let isCharging: Bool
    let externalConnected: Bool

    var energyMilliwattHours: Double? {
        guard let capacity = rawCurrentCapacityMAh, let voltage = voltageMV else { return nil }
        return capacity * voltage / 1000.0
    }

    var instantaneousPowerWatts: Double? {
        guard let voltage = voltageMV, let amperage = amperageMA else {
            return nil
        }
        return abs(voltage * amperage / 1_000_000.0)
    }

    var signedBatteryPowerWatts: Double? {
        guard let absolute = instantaneousPowerWatts else { return nil }

        // Positive values represent energy drawn from the battery.
        // Negative values represent energy added to the battery.
        if externalConnected && isCharging {
            return -absolute
        }
        return absolute
    }
}

enum HistoryPowerState: String, Codable, Hashable {
    /// An estimated low-power interval while the Mac was asleep or BUS was
    /// unable to sample. This is deliberately distinct from a live reading.
    case standbyEstimate
    /// The preceding session predates the current system boot, so no power was
    /// consumed while the machine was switched off.
    case poweredOff
}

struct BatteryHistoryPoint: Identifiable, Codable, Hashable {
    let id: UUID
    let date: Date
    let percent: Double
    let powerWatts: Double?
    let signedPowerWatts: Double?
    let externalConnected: Bool
    /// Stored so a later sampling gap can derive a standby draw from the
    /// actual energy lost by this Mac, rather than joining two live samples.
    let energyMilliwattHours: Double?
    let estimatedPowerState: HistoryPowerState?

    init(snapshot: BatterySnapshot) {
        id = UUID()
        date = snapshot.date
        percent = snapshot.percent
        powerWatts = snapshot.instantaneousPowerWatts
        signedPowerWatts = snapshot.signedBatteryPowerWatts
        externalConnected = snapshot.externalConnected
        energyMilliwattHours = snapshot.energyMilliwattHours
        estimatedPowerState = nil
    }

    init(
        date: Date,
        percent: Double,
        signedPowerWatts: Double,
        externalConnected: Bool,
        energyMilliwattHours: Double?,
        estimatedPowerState: HistoryPowerState
    ) {
        id = UUID()
        self.date = date
        self.percent = percent
        powerWatts = abs(signedPowerWatts)
        self.signedPowerWatts = signedPowerWatts
        self.externalConnected = externalConnected
        self.energyMilliwattHours = energyMilliwattHours
        self.estimatedPowerState = estimatedPowerState
    }

    private enum CodingKeys: String, CodingKey {
        case id, date, percent, powerWatts, signedPowerWatts
        case externalConnected, energyMilliwattHours, estimatedPowerState
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        date = try container.decode(Date.self, forKey: .date)
        percent = try container.decode(Double.self, forKey: .percent)
        powerWatts = try container.decodeIfPresent(
            Double.self,
            forKey: .powerWatts
        )
        externalConnected = try container.decodeIfPresent(
            Bool.self,
            forKey: .externalConnected
        ) ?? false
        energyMilliwattHours = try container.decodeIfPresent(
            Double.self,
            forKey: .energyMilliwattHours
        )
        estimatedPowerState = try container.decodeIfPresent(
            HistoryPowerState.self,
            forKey: .estimatedPowerState
        )

        if let stored = try container.decodeIfPresent(
            Double.self,
            forKey: .signedPowerWatts
        ) {
            signedPowerWatts = stored
        } else if let powerWatts {
            signedPowerWatts = externalConnected
                ? -abs(powerWatts)
                : abs(powerWatts)
        } else {
            signedPowerWatts = nil
        }
    }
}

struct MonitorSession: Codable {
    var startedAt: Date
    var updatedAt: Date
    var initialBatteryPercent: Double
    var latestBatteryPercent: Double
    var observedDischargeMilliwattHours: Double
    var records: [String: AppEnergyRecord]
    var history: [BatteryHistoryPoint]

    static func fresh(snapshot: BatterySnapshot?) -> MonitorSession {
        let percent = snapshot?.percent ?? 0
        return MonitorSession(
            startedAt: .now,
            updatedAt: .now,
            initialBatteryPercent: percent,
            latestBatteryPercent: percent,
            observedDischargeMilliwattHours: 0,
            records: [:],
            history: snapshot.map { [BatteryHistoryPoint(snapshot: $0)] } ?? []
        )
    }

    private enum CodingKeys: String, CodingKey {
        case startedAt, updatedAt, initialBatteryPercent, latestBatteryPercent
        case observedDischargeMilliwattHours, records, history
    }

    init(startedAt: Date, updatedAt: Date, initialBatteryPercent: Double,
         latestBatteryPercent: Double, observedDischargeMilliwattHours: Double,
         records: [String: AppEnergyRecord], history: [BatteryHistoryPoint]) {
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.initialBatteryPercent = initialBatteryPercent
        self.latestBatteryPercent = latestBatteryPercent
        self.observedDischargeMilliwattHours = observedDischargeMilliwattHours
        self.records = records
        self.history = history
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        initialBatteryPercent = try c.decode(Double.self, forKey: .initialBatteryPercent)
        latestBatteryPercent = try c.decode(Double.self, forKey: .latestBatteryPercent)
        observedDischargeMilliwattHours = try c.decode(Double.self, forKey: .observedDischargeMilliwattHours)
        records = try c.decode([String: AppEnergyRecord].self, forKey: .records)
        history = try c.decodeIfPresent([BatteryHistoryPoint].self, forKey: .history) ?? []
    }
}
