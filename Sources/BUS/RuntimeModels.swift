import Foundation

struct RuntimeSessionRecord: Identifiable, Codable, Hashable {
    let id: UUID
    let startedAt: Date
    let endedAt: Date
    let usageProfile: UsageProfileKind
    let startPercent: Double
    let endPercent: Double
    let startEnergyMilliwattHours: Double?
    let endEnergyMilliwattHours: Double?
    let averagePowerWatts: Double
    let projectedFullRuntimeHours: Double
    let topConsumers: [String]

    var duration: TimeInterval {
        endedAt.timeIntervalSince(startedAt)
    }

    var consumedPercent: Double {
        max(0, startPercent - endPercent)
    }

    var consumedMilliwattHours: Double? {
        guard let startEnergyMilliwattHours, let endEnergyMilliwattHours else { return nil }
        return max(0, startEnergyMilliwattHours - endEnergyMilliwattHours)
    }

    var isQualified: Bool {
        duration >= 10 * 60 && consumedPercent >= 3 && projectedFullRuntimeHours.isFinite
    }

    private enum CodingKeys: String, CodingKey {
        case id, startedAt, endedAt, usageProfile, startPercent, endPercent
        case startEnergyMilliwattHours, endEnergyMilliwattHours
        case averagePowerWatts, projectedFullRuntimeHours, topConsumers
    }

    init(
        id: UUID,
        startedAt: Date,
        endedAt: Date,
        usageProfile: UsageProfileKind,
        startPercent: Double,
        endPercent: Double,
        startEnergyMilliwattHours: Double?,
        endEnergyMilliwattHours: Double?,
        averagePowerWatts: Double,
        projectedFullRuntimeHours: Double,
        topConsumers: [String]
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.usageProfile = usageProfile
        self.startPercent = startPercent
        self.endPercent = endPercent
        self.startEnergyMilliwattHours = startEnergyMilliwattHours
        self.endEnergyMilliwattHours = endEnergyMilliwattHours
        self.averagePowerWatts = averagePowerWatts
        self.projectedFullRuntimeHours = projectedFullRuntimeHours
        self.topConsumers = topConsumers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        endedAt = try container.decode(Date.self, forKey: .endedAt)
        usageProfile = try container.decodeIfPresent(
            UsageProfileKind.self,
            forKey: .usageProfile
        ) ?? .automatic
        startPercent = try container.decode(Double.self, forKey: .startPercent)
        endPercent = try container.decode(Double.self, forKey: .endPercent)
        startEnergyMilliwattHours = try container.decodeIfPresent(
            Double.self,
            forKey: .startEnergyMilliwattHours
        )
        endEnergyMilliwattHours = try container.decodeIfPresent(
            Double.self,
            forKey: .endEnergyMilliwattHours
        )
        averagePowerWatts = try container.decode(Double.self, forKey: .averagePowerWatts)
        projectedFullRuntimeHours = try container.decode(
            Double.self,
            forKey: .projectedFullRuntimeHours
        )
        topConsumers = try container.decode([String].self, forKey: .topConsumers)
    }
}

struct ActiveRuntimeSession: Codable {
    let startedAt: Date
    let startPercent: Double
    let startEnergyMilliwattHours: Double?
    var latestSnapshot: BatterySnapshot
    var powerSamples: [Double]

    mutating func append(snapshot: BatterySnapshot) {
        latestSnapshot = snapshot
        if let power = snapshot.instantaneousPowerWatts, power > 0, power < 200 {
            powerSamples.append(power)
            if powerSamples.count > 900 {
                powerSamples.removeFirst(powerSamples.count - 900)
            }
        }
    }

    var averagePowerWatts: Double {
        guard !powerSamples.isEmpty else { return 0 }
        return powerSamples.reduce(0, +) / Double(powerSamples.count)
    }
}

struct RuntimeStatistics: Codable {
    var sessions: [RuntimeSessionRecord]
    var active: ActiveRuntimeSession?
    var profileUsage: [ProfileUsageRecord]
    var activeProfileUsage: ActiveProfileUsage?
    var appActivityUsage: [String: LearnedAppActivityUsage]

    static let empty = RuntimeStatistics(
        sessions: [],
        active: nil,
        profileUsage: [],
        activeProfileUsage: nil,
        appActivityUsage: [:]
    )

    private enum CodingKeys: String, CodingKey {
        case sessions, active, profileUsage, activeProfileUsage
        case appActivityUsage
    }

    init(
        sessions: [RuntimeSessionRecord],
        active: ActiveRuntimeSession?,
        profileUsage: [ProfileUsageRecord] = [],
        activeProfileUsage: ActiveProfileUsage? = nil,
        appActivityUsage: [String: LearnedAppActivityUsage] = [:]
    ) {
        self.sessions = sessions
        self.active = active
        self.profileUsage = profileUsage
        self.activeProfileUsage = activeProfileUsage
        self.appActivityUsage = appActivityUsage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessions = try container.decodeIfPresent(
            [RuntimeSessionRecord].self,
            forKey: .sessions
        ) ?? []
        active = try container.decodeIfPresent(
            ActiveRuntimeSession.self,
            forKey: .active
        )
        profileUsage = try container.decodeIfPresent(
            [ProfileUsageRecord].self,
            forKey: .profileUsage
        ) ?? []
        activeProfileUsage = try container.decodeIfPresent(
            ActiveProfileUsage.self,
            forKey: .activeProfileUsage
        )
        appActivityUsage = try container.decodeIfPresent(
            [String: LearnedAppActivityUsage].self,
            forKey: .appActivityUsage
        ) ?? [:]
    }
}

struct AppActivityUsageSample: Identifiable, Codable, Hashable {
    let id: UUID
    let date: Date
    let state: AppActivityState
    let duration: TimeInterval
    let cpuSeconds: Double
    let diskReadBytes: UInt64
    let diskWriteBytes: UInt64
    let wakeups: UInt64
    let score: Double
    let attributedMilliwattHours: Double

    var diskBytes: UInt64 { diskReadBytes &+ diskWriteBytes }
}

struct LearnedAppActivityUsage: Codable, Hashable {
    var name: String
    var bundleIdentifier: String?
    var applicationPath: String?
    var samples: [AppActivityUsageSample]

    mutating func append(_ sample: AppActivityUsageSample) {
        samples.append(sample)
    }

    mutating func prune(before cutoff: Date, maximumSamples: Int) {
        samples.removeAll { $0.date < cutoff }
        if samples.count > maximumSamples {
            samples = Array(samples.suffix(maximumSamples))
        }
    }

    func summary(for state: AppActivityState) -> AppActivityStateRecord {
        samples.filter { $0.state == state }.reduce(
            AppActivityStateRecord()
        ) { partial, sample in
            var record = partial
            record.samples += 1
            record.activeSeconds += sample.duration
            record.cpuSeconds += sample.cpuSeconds
            record.diskReadBytes &+= sample.diskReadBytes
            record.diskWriteBytes &+= sample.diskWriteBytes
            record.wakeups &+= sample.wakeups
            record.score += sample.score
            record.attributedMilliwattHours += sample.attributedMilliwattHours
            record.lastSeen = max(record.lastSeen, sample.date)
            return record
        }
    }
}

/// A local interval used only to establish the personal automatic profile mix.
/// It intentionally records no app or process data.
struct ProfileUsageRecord: Identifiable, Codable, Hashable {
    let id: UUID
    let profile: UsageProfileKind
    let startedAt: Date
    let endedAt: Date

    var duration: TimeInterval {
        max(0, endedAt.timeIntervalSince(startedAt))
    }
}

struct ActiveProfileUsage: Codable, Hashable {
    let profile: UsageProfileKind
    let startedAt: Date
}

struct PersonalRuntimeSummary {
    let qualifiedSessions: [RuntimeSessionRecord]

    var count: Int { qualifiedSessions.count }

    var averageHours: Double? {
        guard !qualifiedSessions.isEmpty else { return nil }
        return qualifiedSessions.map(\.projectedFullRuntimeHours).reduce(0, +)
            / Double(qualifiedSessions.count)
    }

    var medianHours: Double? {
        let values = qualifiedSessions.map(\.projectedFullRuntimeHours).sorted()
        guard !values.isEmpty else { return nil }
        let middle = values.count / 2
        if values.count.isMultiple(of: 2) {
            return (values[middle - 1] + values[middle]) / 2
        }
        return values[middle]
    }

    var thirtyDayAverageHours: Double? {
        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
        let values = qualifiedSessions
            .filter { $0.endedAt >= cutoff }
            .map(\.projectedFullRuntimeHours)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    var bestHours: Double? {
        qualifiedSessions.map(\.projectedFullRuntimeHours).max()
    }

    var worstHours: Double? {
        qualifiedSessions.map(\.projectedFullRuntimeHours).min()
    }
}

struct ProfileRuntimeSummary {
    let profile: UsageProfileKind
    let qualifiedSessions: [RuntimeSessionRecord]

    var count: Int { qualifiedSessions.count }

    var averageHours: Double? {
        guard !qualifiedSessions.isEmpty else { return nil }
        return qualifiedSessions.map(\.projectedFullRuntimeHours).reduce(0, +)
            / Double(qualifiedSessions.count)
    }

    var medianHours: Double? {
        let values = qualifiedSessions.map(\.projectedFullRuntimeHours).sorted()
        guard !values.isEmpty else { return nil }
        let middle = values.count / 2
        if values.count.isMultiple(of: 2) {
            return (values[middle - 1] + values[middle]) / 2
        }
        return values[middle]
    }
}

struct DeviceProfile: Codable, Hashable {
    let modelIdentifier: String
    let displayName: String
    let batteryWattHours: Double?
    let manufacturerWebHours: Double?
    let manufacturerVideoHours: Double?

    var referenceHours: Double? {
        manufacturerWebHours ?? manufacturerVideoHours
    }

    var manufacturerReferenceSource: String? {
        if manufacturerWebHours != nil { return "wireless web" }
        if manufacturerVideoHours != nil { return "video playback" }
        return nil
    }
}

struct ScoreBreakdown {
    let modelScore: Double?
    let personalScore: Double?
    let blendedScore: Double?
    let currentProjectedRuntimeHours: Double?
    let manufacturerReferenceHours: Double?
    let personalReferenceHours: Double?
    let modelWeight: Double
    let personalWeight: Double
    let reason: ScoreAvailability

    var roundedScore: Int? {
        blendedScore.map { Int(max(0, min(100, $0)).rounded()) }
    }
}

enum ScoreAvailability {
    case ready
    case mainsPower
    case collecting
    case missingReference
}
