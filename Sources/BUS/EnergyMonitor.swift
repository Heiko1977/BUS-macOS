import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

/// Owns mutable sampling state and is only used by `samplingQueue` after the
/// initial prime. Keeping it outside the main-actor monitor prevents process
/// enumeration and I/O Registry reads from blocking scrolling and layout.
private final class SamplingWorker: @unchecked Sendable {
    private let batteryReader = BatteryReader()
    private let processSampler = ProcessSampler()

    func readBattery() -> BatterySnapshot? {
        batteryReader.read()
    }

    func sampleProcesses() -> [ProcessDelta] {
        processSampler.sample()
    }
}

@MainActor
final class EnergyMonitor: ObservableObject {
    static let shared = EnergyMonitor()

    // These high-frequency values are published manually as one atomic batch
    // per completed sample. Direct @Published value-type mutations used to
    // invalidate SwiftUI once for every updated process record.
    private(set) var session: MonitorSession
    private(set) var battery: BatterySnapshot?
    @Published private(set) var isRunning = true
    private(set) var runtimeStatistics: RuntimeStatistics

    @Published private(set) var sampleInterval: Double {
        didSet {
            UserDefaults.standard.set(
                sampleInterval,
                forKey: "BUS.sampleInterval"
            )
            restartTimer()
        }
    }

    @Published var resetAfterChargingEnds: Bool {
        didSet {
            UserDefaults.standard.set(
                resetAfterChargingEnds,
                forKey: "BUS.resetAfterChargingEnds"
            )
        }
    }

    @Published var resetAfterFullCharge: Bool {
        didSet {
            UserDefaults.standard.set(
                resetAfterFullCharge,
                forKey: "BUS.resetAfterFullCharge"
            )
        }
    }

    @Published private(set) var manufacturerRuntimeOverrideHours: Double {
        didSet {
            UserDefaults.standard.set(
                manufacturerRuntimeOverrideHours,
                forKey: "BUS.manufacturerRuntimeOverrideHours"
            )
        }
    }

    @Published private(set) var selectedUsageProfile: UsageProfileKind {
        didSet {
            UserDefaults.standard.set(
                selectedUsageProfile.rawValue,
                forKey: "BUS.selectedUsageProfile"
            )
        }
    }

    @Published private(set) var automaticProfileLookbackDays: Int {
        didSet {
            UserDefaults.standard.set(
                automaticProfileLookbackDays,
                forKey: "BUS.automaticProfileLookbackDays"
            )
        }
    }

    @Published private(set) var lowPowerModePreference: LowPowerModePreference {
        didSet {
            UserDefaults.standard.set(
                lowPowerModePreference.rawValue,
                forKey: "BUS.lowPowerModePreference"
            )
        }
    }

    @Published private(set) var lowPowerAutomaticThresholdPercent: Int {
        didSet {
            UserDefaults.standard.set(
                lowPowerAutomaticThresholdPercent,
                forKey: "BUS.lowPowerAutomaticThresholdPercent"
            )
        }
    }
    private(set) var detectedUsageProfileSnapshot:
        UsageProfileDetection

    let deviceProfile = DeviceProfileDatabase.current
    @Published private(set) var gpuDetails =
        HardwareProfileStore.load() ?? DeviceProfileDatabase.gpuDetails

    private let batteryReader = BatteryReader()
    private let samplingWorker = SamplingWorker()
    private let store = SessionStore()
    private let runtimeStore = RuntimeStatisticsStore()
    private let chargeLearningStore = ChargeLearningStore()
    private let samplingQueue = DispatchQueue(
        label: "de.heikogrosse.bus.sampling",
        qos: .utility
    )
    private let persistenceQueue = DispatchQueue(
        label: "de.heikogrosse.bus.persistence",
        qos: .utility
    )
    private var timer: Timer?
    private var collectionIsInFlight = false
    private var previousBattery: BatterySnapshot?
    private var chargeLearningSamples: [ChargeLearningSample]
    private var chargeLearningAnchor: BatterySnapshot?
    private var learningStartedAt: Date
    private var activeProfileStartedAt: Date
    private var saveCounter = 0
    private var cachedMacOSLowPowerModeIsEnabled =
        ProcessInfo.processInfo.isLowPowerModeEnabled
    private var lowPowerModeRefreshIsInFlight = false
    private var lastLowPowerModeRefresh = Date.distantPast
    private static let lowPowerModeRequestURL = URL(
        fileURLWithPath:
            "/Library/Application Support/BUS/lowpowermode.request"
    )

    private init() {
        let defaults = UserDefaults.standard
        let interval = defaults.object(forKey: "BUS.sampleInterval") as? Double ?? 10
        let autoReset = defaults.object(
            forKey: "BUS.resetAfterChargingEnds"
        ) as? Bool ?? false
        let autoResetAtFull = defaults.object(
            forKey: "BUS.resetAfterFullCharge"
        ) as? Bool ?? false
        let override = defaults.object(
            forKey: "BUS.manufacturerRuntimeOverrideHours"
        ) as? Double ?? 0

        let selectedProfile = UsageProfileKind(
            rawValue: defaults.string(
                forKey: "BUS.selectedUsageProfile"
            ) ?? ""
        ) ?? .automatic
        let lookback = Self.clampedAutomaticProfileLookbackDays(
            defaults.object(forKey: "BUS.automaticProfileLookbackDays") as? Int ?? 3
        )
        let lowPowerPreference = LowPowerModePreference(
            rawValue: defaults.string(forKey: "BUS.lowPowerModePreference") ?? ""
        ) ?? .automatic
        let lowPowerThreshold = Self.clampedLowPowerThreshold(
            defaults.object(forKey: "BUS.lowPowerAutomaticThresholdPercent") as? Int ?? 20
        )

        let initialBattery = batteryReader.read()
        let loadedSession = store.load() ?? MonitorSession.fresh(
            snapshot: initialBattery
        )
        let initialSession = AppGrouping.normalize(session: loadedSession)
        var loadedRuntime = runtimeStore.load()
        let maximumDataCutoff = Date.now.addingTimeInterval(-30 * 24 * 3600)
        let learnedChargeSamples = ChargeLearningStore().load().filter {
            $0.date >= maximumDataCutoff
        }
        learningStartedAt = defaults.object(forKey: "BUS.learningStartedAt") as? Date
            ?? maximumDataCutoff

        if let initialBattery, !initialBattery.externalConnected {
            if var active = loadedRuntime.active {
                active.append(snapshot: initialBattery)
                loadedRuntime.active = active
            } else {
                loadedRuntime.active = Self.newActiveSession(initialBattery)
            }
        } else {
            loadedRuntime.active = nil
        }

        sampleInterval = Self.clampedSampleInterval(interval)
        resetAfterChargingEnds = autoReset
        resetAfterFullCharge = autoResetAtFull
        manufacturerRuntimeOverrideHours =
            Self.clampedManufacturerRuntimeOverride(override)
        selectedUsageProfile = selectedProfile
        automaticProfileLookbackDays = lookback
        lowPowerModePreference = lowPowerPreference
        lowPowerAutomaticThresholdPercent = lowPowerThreshold
        detectedUsageProfileSnapshot = UsageProfileDetector.detect(
            from: Array(initialSession.records.values)
        )
        battery = initialBattery
        session = initialSession
        runtimeStatistics = loadedRuntime
        previousBattery = initialBattery
        chargeLearningSamples = learnedChargeSamples
        chargeLearningAnchor = initialBattery?.isCharging == true
            && initialBattery?.externalConnected == true ? initialBattery : nil
        activeProfileStartedAt = initialBattery?.date ?? .now
        runtimeStatistics.sessions.removeAll {
            $0.endedAt < profileReferenceCutoffDate
        }
        runtimeStatistics.profileUsage.removeAll {
            $0.endedAt < profileReferenceCutoffDate
        }
        if initialBattery?.externalConnected == false {
            let currentProfile = activeUsageProfile
            if runtimeStatistics.activeProfileUsage?.profile != currentProfile {
                runtimeStatistics.activeProfileUsage = ActiveProfileUsage(
                    profile: currentProfile,
                    startedAt: initialBattery?.date ?? .now
                )
            }
        } else {
            runtimeStatistics.activeProfileUsage = nil
        }

        _ = samplingWorker.sampleProcesses()
        runtimeStore.save(runtimeStatistics)
        restartTimer()
        refreshMacOSLowPowerMode()

        Task { [weak self] in
            let details = await Task.detached(priority: .utility) {
                DeviceProfileDatabase.readGPUDetails()
            }.value
            self?.gpuDetails = details
            HardwareProfileStore.save(details)
        }
    }

    var sortedRecords: [AppEnergyRecord] {
        session.records.values.sorted {
            if $0.attributedMilliwattHours == $1.attributedMilliwattHours {
                return $0.score > $1.score
            }
            return $0.attributedMilliwattHours > $1.attributedMilliwattHours
        }
    }

    var isOnBattery: Bool {
        !(battery?.externalConnected ?? true)
    }

    var menuBarLabel: String {
        if let score = scoreBreakdown.roundedScore {
            return "BUS \(score)"
        }
        return "BUS –"
    }

    var batteryDropPercent: Double {
        max(0, session.initialBatteryPercent - session.latestBatteryPercent)
    }

    var currentPowerWatts: Double {
        battery?.instantaneousPowerWatts ?? 0
    }

    var isChargingSession: Bool {
        battery?.externalConnected == true
    }

    var batteryChargingPowerWatts: Double {
        guard battery?.externalConnected == true,
              battery?.isCharging == true else {
            return 0
        }

        if let measured = battery?.helperBatteryPowerWatts,
           measured.isFinite,
           measured >= 0 {
            return measured
        }

        return max(0, battery?.instantaneousPowerWatts ?? 0)
    }

    /// Maximum/rated wattage reported by the connected adapter.
    /// This is not the current wall input.
    var adapterRatedPowerWatts: Double? {
        guard let value = battery?.adapterPowerWatts, value > 0 else {
            return nil
        }
        return value
    }

    var adapterPowerWatts: Double? {
        adapterRatedPowerWatts
    }

    var measuredAdapterInputWatts: Double? {
        guard let value = battery?.measuredAdapterInputWatts,
              value.isFinite,
              value > 0 else {
            return nil
        }
        return value
    }

    var measuredSystemPowerWatts: Double? {
        guard let value = battery?.measuredSystemPowerWatts,
              value.isFinite,
              value >= 0 else {
            return nil
        }
        return value
    }

    var helperIsAvailable: Bool {
        battery?.hardwareSource != nil
    }

    var helperUsesSMC: Bool {
        battery?.helperSMCAvailable == true
    }

    var estimatedSystemPowerWhileChargingWatts: Double {
        if let measuredSystemPowerWatts {
            return measuredSystemPowerWatts
        }

        if let input = measuredAdapterInputWatts {
            return max(0, input - batteryChargingPowerWatts)
        }

        if let recent = recentBatteryDrawMedianWatts, recent > 0 {
            return recent
        }

        if let personalPower = personalAveragePowerWatts, personalPower > 0 {
            return personalPower
        }

        if let runtime = usageProfileReferenceHours
                ?? manufacturerReferenceHours,
           runtime > 0,
           let capacity = detectedMaximumBatteryWattHours
                ?? deviceProfile.batteryWattHours {
            return max(4, capacity / runtime * 1.75)
        }

        return 9
    }

    var displayedAdapterPowerWatts: Double {
        if let measuredAdapterInputWatts {
            return measuredAdapterInputWatts
        }

        let estimatedInput = max(
            0,
            estimatedSystemPowerWhileChargingWatts
                + batteryChargingPowerWatts
        )

        if let rated = adapterRatedPowerWatts {
            return min(rated, estimatedInput)
        }

        return estimatedInput
    }

    var adapterInputIsEstimated: Bool {
        measuredAdapterInputWatts == nil
    }

    var macOSLowPowerModeIsEnabled: Bool {
        cachedMacOSLowPowerModeIsEnabled
    }

    var effectiveLowPowerModeIsEnabled: Bool {
        if macOSLowPowerModeIsEnabled {
            return true
        }
        switch lowPowerModePreference {
        case .off:
            return false
        case .on:
            return true
        case .automatic:
            guard let percent = battery?.percent else { return false }
            return percent <= Double(lowPowerAutomaticThresholdPercent)
        }
    }

    var lowPowerModeStatusKey: String {
        if macOSLowPowerModeIsEnabled {
            return "lowPowerModeSystemActive"
        }
        switch lowPowerModePreference {
        case .off:
            return "lowPowerModeOffStatus"
        case .on:
            return "lowPowerModeOnStatus"
        case .automatic:
            if effectiveLowPowerModeIsEnabled {
                return "lowPowerModeAutomaticActive"
            }
            return "lowPowerModeAutomaticWaiting"
        }
    }

    private var lowPowerRuntimeMultiplier: Double {
        effectiveLowPowerModeIsEnabled ? 1.10 : 1.0
    }

    private func adjustedRuntimeHours(_ hours: Double) -> Double {
        hours * lowPowerRuntimeMultiplier
    }

    var powerMeasurementQualityKey: String {
        if measuredAdapterInputWatts != nil {
            return "hardwareMeasured"
        }
        if helperIsAvailable {
            return "hardwarePartiallyMeasured"
        }
        return "locallyEstimated"
    }

    private var recentBatteryDrawMedianWatts: Double? {
        guard let now = battery?.date else { return nil }

        let cutoff = now.addingTimeInterval(-2 * 60 * 60)
        let values = session.history
            .filter { point in
                point.date >= cutoff
                    && !point.externalConnected
                    && (point.signedPowerWatts ?? point.powerWatts ?? 0) > 0
            }
            .compactMap { point -> Double? in
                let value = point.signedPowerWatts ?? point.powerWatts
                guard let value, value > 0, value < 200 else { return nil }
                return value
            }
            .suffix(60)
            .sorted()

        guard !values.isEmpty else { return nil }

        let middle = values.count / 2
        if values.count.isMultiple(of: 2) {
            return (values[middle - 1] + values[middle]) / 2
        }
        return values[middle]
    }

    var chargeRatePercentPerHour: Double? {
        guard let snapshot = battery,
              snapshot.externalConnected,
              snapshot.isCharging,
              batteryChargingPowerWatts > 0,
              let capacityWh = detectedMaximumBatteryWattHours
                ?? deviceProfile.batteryWattHours,
              capacityWh > 0 else {
            return nil
        }

        return min(100, batteryChargingPowerWatts / capacityWh * 100)
    }

    var estimatedChargeTimeTo80Hours: Double? {
        estimatedChargeTimeHours(targetPercent: 80)
    }

    var estimatedChargeTimeToFullHours: Double? {
        estimatedChargeTimeHours(targetPercent: 100)
    }

    /// Number of comparable, local charge windows currently available for the
    /// connected power source. It intentionally excludes samples from other
    /// Mac models and adapter classes.
    var learnedChargeWindowCount: Int {
        guard let snapshot = battery else { return 0 }
        let sourceBucket = chargeSourcePowerBucket(for: snapshot)
        return chargeLearningSamples.filter {
            $0.modelIdentifier == deviceProfile.modelIdentifier
                && $0.sourcePowerBucketWatts == sourceBucket
        }.count
    }

    var chargeLearningConfidenceKey: String {
        switch learnedChargeWindowCount {
        case 30...:
            return "chargeLearningHigh"
        case 12...:
            return "chargeLearningMedium"
        default:
            return "chargeLearningCollecting"
        }
    }

    var estimatedRuntimeAtCurrentChargeHours: Double? {
        let reference = personalRuntimeSummary.medianHours
            ?? usageProfileReferenceHours
            ?? manufacturerReferenceHours
        guard let reference,
              let percent = battery?.percent else {
            return nil
        }
        return adjustedRuntimeHours(reference)
            * max(0, min(100, percent)) / 100
    }

    var estimatedRuntimeAtFullChargeHours: Double? {
        guard let reference = personalRuntimeSummary.medianHours
            ?? usageProfileReferenceHours
            ?? manufacturerReferenceHours else {
            return nil
        }
        return adjustedRuntimeHours(reference)
    }

    private var personalAveragePowerWatts: Double? {
        let values = runtimeStatistics.sessions
            .filter(\.isQualified)
            .map(\.averagePowerWatts)
            .filter { $0 > 0 && $0 < 200 }

        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private func estimatedChargeTimeHours(
        targetPercent: Double
    ) -> Double? {
        guard let snapshot = battery,
              snapshot.externalConnected,
              snapshot.isCharging,
              snapshot.percent < targetPercent,
              batteryChargingPowerWatts >= 0.5,
              let capacityWh = detectedMaximumBatteryWattHours
                ?? deviceProfile.batteryWattHours,
              capacityWh > 0 else {
            return nil
        }

        let startPercent = max(0, min(100, snapshot.percent))
        let target = max(startPercent, min(100, targetPercent))
        let sourceBucket = chargeSourcePowerBucket(for: snapshot)
        let baseRate = batteryChargingPowerWatts / capacityWh * 100
        var cursor = startPercent
        var result = 0.0

        // Charge controllers do not charge linearly. BUS learns a robust,
        // local rate in each state-of-charge band and falls back to a
        // conservative taper only until enough comparable data exists.
        while cursor < target - 0.0001 {
            let segment = chargeSegment(for: cursor)
            let upperBound = min(target, Self.chargeSegmentBounds[segment + 1])
            let percentInSegment = max(0, upperBound - cursor)
            let learned = learnedChargeRate(
                segment: segment,
                sourceBucket: sourceBucket,
                displayIsActive: snapshot.displayIsActive
            )
            let rate = learned?.rate ?? baseRate * Self.chargeFallbackMultipliers[segment]
            guard rate.isFinite, rate >= 0.15 else { return nil }
            result += percentInSegment / rate
            cursor = upperBound
        }

        guard result.isFinite, result > 0, result < 24 else {
            return nil
        }
        return result
    }

    private static let chargeSegmentBounds: [Double] = [0, 50, 80, 90, 95, 100]
    private static let chargeFallbackMultipliers: [Double] = [1, 1, 0.57, 0.43, 0.28]

    private func chargeSegment(for percent: Double) -> Int {
        let bounded = max(0, min(99.999, percent))
        for index in 0..<(Self.chargeSegmentBounds.count - 1) {
            if bounded < Self.chargeSegmentBounds[index + 1] {
                return index
            }
        }
        return Self.chargeSegmentBounds.count - 2
    }

    private func chargeSourcePowerBucket(for snapshot: BatterySnapshot) -> Int {
        let watts = snapshot.adapterPowerWatts
            ?? snapshot.measuredAdapterInputWatts
            ?? 0
        guard watts > 0 else { return 0 }
        return Int((watts / 5).rounded() * 5)
    }

    private func learnedChargeRate(
        segment: Int,
        sourceBucket: Int,
        displayIsActive: Bool?
    ) -> (rate: Double, count: Int)? {
        var candidates = chargeLearningSamples.filter {
            $0.modelIdentifier == deviceProfile.modelIdentifier
                && $0.segment == segment
                && $0.sourcePowerBucketWatts == sourceBucket
        }
        guard candidates.count >= 3 else { return nil }

        let matchingDisplay = candidates.filter {
            $0.displayIsActive == displayIsActive
        }
        if matchingDisplay.count >= 3 {
            candidates = matchingDisplay
        }

        let sorted = candidates.map(\.percentPerHour).sorted()
        let trim = sorted.count >= 7 ? Int(Double(sorted.count) * 0.15) : 0
        let retained = Array(sorted.dropFirst(trim).dropLast(trim))
        guard !retained.isEmpty else { return nil }
        let middle = retained.count / 2
        let rate = retained.count.isMultiple(of: 2)
            ? (retained[middle - 1] + retained[middle]) / 2
            : retained[middle]
        return (rate, candidates.count)
    }

    var detectedUsageProfile: UsageProfileKind {
        detectedUsageProfileSnapshot.kind
    }

    var detectedUsageProfileConfidence: Double {
        detectedUsageProfileSnapshot.confidence
    }

    var activeUsageProfile: UsageProfileKind {
        selectedUsageProfile == .automatic
            ? detectedUsageProfile
            : selectedUsageProfile
    }

    var activeUsageProfileElapsed: TimeInterval {
        max(0, Date.now.timeIntervalSince(activeProfileStartedAt))
    }

    var activeUsageProfileElapsedText: String {
        let minutes = max(0, Int((activeUsageProfileElapsed / 60).rounded()))
        return "\(minutes / 60) h \(minutes % 60) min"
    }

    private var predictionCutoffDate: Date {
        Date.now.addingTimeInterval(
            -Double(automaticProfileLookbackDays) * 24 * 3600
        )
    }

    private var profileReferenceCutoffDate: Date {
        Date.now.addingTimeInterval(-30 * 24 * 3600)
    }

    private var predictionSessions: [RuntimeSessionRecord] {
        runtimeStatistics.sessions.filter {
            $0.isQualified && $0.endedAt >= predictionCutoffDate
        }
    }

    private var profileReferenceSessions: [RuntimeSessionRecord] {
        runtimeStatistics.sessions.filter {
            $0.isQualified && $0.endedAt >= profileReferenceCutoffDate
        }
    }

    /// The recent profile distribution determines the automatic comparison
    /// mix. The actual runtime reference of each profile remains based on up
    /// to 30 days of comparable sessions.
    private var automaticProfileMix: [UsageProfileKind: Double] {
        let cutoff = predictionCutoffDate
        var durations: [UsageProfileKind: TimeInterval] = [:]

        for record in runtimeStatistics.profileUsage where record.profile != .automatic {
            let start = max(record.startedAt, cutoff)
            let duration = max(0, record.endedAt.timeIntervalSince(start))
            guard duration > 0 else { continue }
            durations[record.profile, default: 0] += duration
        }

        if let active = runtimeStatistics.activeProfileUsage,
           active.profile != .automatic,
           battery?.externalConnected == false {
            let start = max(active.startedAt, cutoff)
            let duration = max(0, Date.now.timeIntervalSince(start))
            if duration > 0 {
                durations[active.profile, default: 0] += duration
            }
        }

        // Existing installations do not yet have interval-level profile data.
        // Use their qualified session durations as a migration fallback until
        // BUS has collected the more precise intervals above.
        if durations.isEmpty {
            for session in predictionSessions where session.usageProfile != .automatic {
                durations[session.usageProfile, default: 0] += session.duration
            }
        }

        let total = durations.values.reduce(0, +)
        guard total > 0 else { return [:] }
        return durations.mapValues { $0 / total }
    }

    /// The qualified local sessions currently used for the personal reference.
    var predictionSessionCount: Int { predictionSessions.count }

    /// Charge-learning data is intentionally limited to 30 days, independent
    /// of the shorter automatic-profile comparison window.
    var chargeLearningSampleCount: Int {
        chargeLearningSamples.filter { $0.date >= learningStartedAt }.count
    }

    var learnedAppActivitySampleCount: Int {
        runtimeStatistics.appActivityUsage.values.reduce(0) {
            $0 + $1.samples.count
        }
    }

    var learnedAppActivityHours: Double {
        learningObservationHours(measuredOnly: false)
    }

    var measuredEnergyHours: Double {
        learningObservationHours(measuredOnly: true)
    }

    /// Returns wall-clock observation time, not the sum of parallel app
    /// intervals. Several apps are sampled simultaneously and must therefore
    /// contribute only once to the learning period.
    private func learningObservationHours(measuredOnly: Bool) -> Double {
        let samples = runtimeStatistics.appActivityUsage.values
            .flatMap(\.samples)
            .filter { $0.date >= learningStartedAt }
            .filter { !measuredOnly || $0.attributedMilliwattHours > 0 }
        guard let first = samples.map(\.date).min(),
              let last = samples.map(\.date).max() else { return 0 }
        let end = last.addingTimeInterval(sampleInterval)
        return max(0, end.timeIntervalSince(max(first, learningStartedAt))) / 3600
    }

    var personalAppUsageSummaries: [PersonalAppUsageSummary] {
        let cutoff = Date.now.addingTimeInterval(-30 * 24 * 3600)
        return runtimeStatistics.appActivityUsage.compactMap { key, usage in
            let samples = usage.samples.filter {
                $0.date >= cutoff && $0.date >= learningStartedAt
            }
            guard !samples.isEmpty else { return nil }
            return PersonalAppUsageSummary(
                id: key,
                name: usage.name,
                bundleIdentifier: usage.bundleIdentifier,
                applicationPath: usage.applicationPath,
                usedSeconds: samples.reduce(0) { $0 + $1.duration },
                foregroundSeconds: samples.filter { $0.state == .foreground }
                    .reduce(0) { $0 + $1.duration },
                backgroundSeconds: samples.filter { $0.state != .foreground }
                    .reduce(0) { $0 + $1.duration },
                attributedMilliwattHours: samples.reduce(0) {
                    $0 + $1.attributedMilliwattHours
                },
                sampleCount: samples.count
            )
        }
        .sorted { $0.attributedMilliwattHours > $1.attributedMilliwattHours }
    }

    var personalPredictionConfidenceKey: String {
        switch predictionSessionCount {
        case 12...:
            return "predictionConfidenceHigh"
        case 3...:
            return "predictionConfidenceMedium"
        default:
            return "predictionConfidenceLearning"
        }
    }

    func referenceHours(for profile: UsageProfileKind) -> Double? {
        if profile == .automatic,
           let mixedReference = automaticMixedReferenceHours {
            return mixedReference
        }

        let effective = profile == .automatic ? detectedUsageProfile : profile
        return referenceHoursForSingleProfile(effective)
    }

    private func referenceHoursForSingleProfile(
        _ profile: UsageProfileKind
    ) -> Double? {
        let learnedSummary = learnedProfileSummary(for: profile)
        if learnedSummary.count >= 3, let learned = learnedSummary.medianHours {
            return learned
        }

        guard let base = manufacturerReferenceHours else { return nil }
        return base
            * profile.referenceMultiplier
            * profile.gpuHardwareMultiplier(
                gpuCoreCount: gpuDetails.gpuCoreCount
            )
    }

    private var automaticMixedReferenceHours: Double? {
        let mix = automaticProfileMix
        guard !mix.isEmpty else { return nil }

        var weightedHours = 0.0
        var resolvedWeight = 0.0
        for (profile, weight) in mix {
            guard let hours = referenceHoursForSingleProfile(profile) else {
                continue
            }
            weightedHours += hours * weight
            resolvedWeight += weight
        }
        guard resolvedWeight >= 0.6 else { return nil }
        return weightedHours / resolvedWeight
    }

    var usageProfileReferenceHours: Double? {
        guard let hours = referenceHours(
            for: selectedUsageProfile == .automatic
                ? .automatic
                : activeUsageProfile
        ) else { return nil }
        return adjustedRuntimeHours(hours)
    }

    var usageProfileEfficiencyPercent: Double? {
        guard let actual = currentProjectedFullRuntimeHours,
              let reference = usageProfileReferenceHours,
              reference > 0 else {
            return nil
        }
        return min(150, max(0, actual / reference * 100))
    }

    var manufacturerReferenceHours: Double? {
        if manufacturerRuntimeOverrideHours > 0 {
            return manufacturerRuntimeOverrideHours
        }
        return deviceProfile.referenceHours
    }

    var personalRuntimeSummary: PersonalRuntimeSummary {
        PersonalRuntimeSummary(
            qualifiedSessions: predictionSessions
        )
    }

    func learnedProfileSummary(
        for profile: UsageProfileKind
    ) -> ProfileRuntimeSummary {
        ProfileRuntimeSummary(
            profile: profile,
            qualifiedSessions: profileReferenceSessions.filter {
                $0.usageProfile == profile
            }
        )
    }

    var smoothedPowerWatts: Double? {
        guard let now = battery?.date else { return nil }
        let cutoff = now.addingTimeInterval(-15 * 60)
        let values = session.history
            .filter {
                $0.date >= cutoff
                    && !$0.externalConnected
                    && ($0.powerWatts ?? 0) > 0
                    && ($0.powerWatts ?? 0) < 200
            }
            .compactMap(\.powerWatts)

        if !values.isEmpty {
            return values.reduce(0, +) / Double(values.count)
        }

        if let activePower = runtimeStatistics.active?.averagePowerWatts,
           activePower > 0 {
            return activePower
        }

        return currentPowerWatts > 0 ? currentPowerWatts : nil
    }

    var currentProjectedFullRuntimeHours: Double? {
        if let power = smoothedPowerWatts, power > 0 {
            let batteryWh = detectedMaximumBatteryWattHours
                ?? deviceProfile.batteryWattHours
            if let batteryWh, batteryWh > 0 {
                return adjustedRuntimeHours(batteryWh / power)
            }
        }

        // Compare against active sampling time only. A long gap between
        // battery samples indicates display/system sleep and must not count
        // as productive runtime against Apple's active-use references.
        let elapsedHours = activeSamplingSeconds / 3600
        guard elapsedHours >= 0.05, batteryDropPercent >= 0.5 else {
            return nil
        }
        return adjustedRuntimeHours(elapsedHours * 100 / batteryDropPercent)
    }

    private var activeSamplingSeconds: TimeInterval {
        let ordered = session.history.sorted { $0.date < $1.date }
        guard ordered.count > 1 else { return 0 }
        let maximumGap = max(30, sampleInterval * 3)
        return zip(ordered, ordered.dropFirst()).reduce(0) { total, pair in
            let gap = pair.1.date.timeIntervalSince(pair.0.date)
            return total + (gap > 0 && gap <= maximumGap ? gap : 0)
        }
    }

    var currentRemainingRuntimeHours: Double? {
        guard let full = currentProjectedFullRuntimeHours,
              let percent = battery?.percent else {
            return nil
        }
        return full * max(0, min(100, percent)) / 100
    }

    var scoreBreakdown: ScoreBreakdown {
        guard isOnBattery else {
            return ScoreBreakdown(
                modelScore: nil,
                personalScore: nil,
                blendedScore: nil,
                currentProjectedRuntimeHours: nil,
                manufacturerReferenceHours: manufacturerReferenceHours,
                personalReferenceHours: personalRuntimeSummary.medianHours,
                modelWeight: 0,
                personalWeight: 0,
                reason: .mainsPower
            )
        }

        let elapsed = runtimeStatistics.active.map {
            Date().timeIntervalSince($0.startedAt)
        } ?? 0

        guard elapsed >= 3 * 60,
              let currentHours = currentProjectedFullRuntimeHours,
              currentHours.isFinite,
              currentHours > 0 else {
            return ScoreBreakdown(
                modelScore: nil,
                personalScore: nil,
                blendedScore: nil,
                currentProjectedRuntimeHours: currentProjectedFullRuntimeHours,
                manufacturerReferenceHours: manufacturerReferenceHours,
                personalReferenceHours: personalRuntimeSummary.medianHours,
                modelWeight: 0,
                personalWeight: 0,
                reason: .collecting
            )
        }

        let modelReference = usageProfileReferenceHours
            ?? manufacturerReferenceHours
        let personalReference = personalRuntimeSummary.medianHours

        let modelScore = modelReference.map {
            Self.efficiencyScore(actual: currentHours, reference: $0)
        }
        let personalScore = personalReference.map {
            Self.efficiencyScore(actual: currentHours, reference: $0)
        }

        let count = personalRuntimeSummary.count
        let personalWeight: Double
        if personalScore == nil {
            personalWeight = 0
        } else if count >= 20 {
            personalWeight = 0.60
        } else if count >= 5 {
            personalWeight = 0.40
        } else {
            personalWeight = 0
        }

        let modelWeight: Double
        if modelScore == nil {
            modelWeight = personalScore == nil ? 0 : 1 - personalWeight
        } else {
            modelWeight = 1 - personalWeight
        }

        let blended: Double?
        if let modelScore, let personalScore, personalWeight > 0 {
            blended = modelScore * modelWeight + personalScore * personalWeight
        } else {
            blended = modelScore ?? personalScore
        }

        return ScoreBreakdown(
            modelScore: modelScore,
            personalScore: personalScore,
            blendedScore: blended,
            currentProjectedRuntimeHours: currentHours,
            manufacturerReferenceHours: modelReference,
            personalReferenceHours: personalReference,
            modelWeight: modelWeight,
            personalWeight: personalWeight,
            reason: blended == nil ? .missingReference : .ready
        )
    }

    var busScore: Int {
        scoreBreakdown.roundedScore ?? 0
    }

    func scoreLabel(_ l: Localizer) -> String {
        switch scoreBreakdown.reason {
        case .mainsPower:
            return l.t("scorePaused")
        case .collecting:
            return l.t("scoreCollecting")
        case .missingReference:
            return l.t("scoreReferenceMissing")
        case .ready:
            switch busScore {
            case 90...:
                return l.t("excellent")
            case 75..<90:
                return l.t("veryGood")
            case 60..<75:
                return l.t("good")
            case 40..<60:
                return l.t("elevated")
            default:
                return l.t("high")
            }
        }
    }

    func scoreExplanation(_ l: Localizer) -> String {
        let breakdown = scoreBreakdown
        switch breakdown.reason {
        case .mainsPower:
            return l.t("scorePausedExplanation")
        case .collecting:
            return l.t("scoreCollectingExplanation")
        case .missingReference:
            return l.t("scoreReferenceMissingExplanation")
        case .ready:
            guard let current = breakdown.currentProjectedRuntimeHours else {
                return l.t("scoreExplanation")
            }
            let reference = breakdown.personalWeight > 0
                ? breakdown.personalReferenceHours
                : breakdown.manufacturerReferenceHours
            if let reference {
                return String(
                    format: l.t("scoreRuntimeComparison"),
                    current,
                    reference
                )
            }
            return l.t("scoreExplanation")
        }
    }

    func share(for record: AppEnergyRecord) -> Double {
        guard session.observedDischargeMilliwattHours > 0 else {
            let total = session.records.values.reduce(0) { $0 + $1.score }
            return total > 0 ? record.score / total : 0
        }
        return record.attributedMilliwattHours
            / session.observedDischargeMilliwattHours
    }

    func attributedBatteryPercent(for record: AppEnergyRecord) -> Double {
        batteryDropPercent * share(for: record)
    }

    func share(
        for process: ProcessEnergyRecord,
        in app: AppEnergyRecord
    ) -> Double {
        guard app.attributedMilliwattHours > 0 else {
            return app.score > 0 ? process.score / app.score : 0
        }
        return process.attributedMilliwattHours
            / app.attributedMilliwattHours
    }

    func attributedBatteryPercent(
        for process: ProcessEnergyRecord
    ) -> Double {
        guard session.observedDischargeMilliwattHours > 0 else {
            let total = session.records.values.reduce(0) { $0 + $1.score }
            return total > 0
                ? batteryDropPercent * process.score / total
                : 0
        }
        return batteryDropPercent
            * process.attributedMilliwattHours
            / session.observedDischargeMilliwattHours
    }

    func updateSampleInterval(_ value: Double) {
        let sanitized = Self.clampedSampleInterval(value)
        guard sanitized != sampleInterval else { return }
        sampleInterval = sanitized
    }

    func updateManufacturerRuntimeOverrideHours(_ value: Double) {
        let sanitized = Self.clampedManufacturerRuntimeOverride(value)
        guard sanitized != manufacturerRuntimeOverrideHours else { return }
        manufacturerRuntimeOverrideHours = sanitized
    }

    func updateUsageProfile(_ profile: UsageProfileKind) {
        guard profile != selectedUsageProfile else { return }
        selectedUsageProfile = profile
        let now = Date.now
        transitionActiveProfileUsage(
            to: activeUsageProfile,
            at: now,
            snapshot: battery
        )
        activeProfileStartedAt = now
    }

    func updateAutomaticProfileLookbackDays(_ value: Int) {
        let sanitized = Self.clampedAutomaticProfileLookbackDays(value)
        guard sanitized != automaticProfileLookbackDays else { return }
        automaticProfileLookbackDays = sanitized
    }

    func updateLowPowerModePreference(_ preference: LowPowerModePreference) {
        guard preference != lowPowerModePreference else { return }
        lowPowerModePreference = preference
        switch preference {
        case .on:
            setMacOSLowPowerMode(true)
        case .off:
            setMacOSLowPowerMode(false)
        case .automatic:
            reconcileMacOSLowPowerMode(for: battery?.percent)
        }
    }

    func updateLowPowerAutomaticThresholdPercent(_ value: Int) {
        let sanitized = Self.clampedLowPowerThreshold(value)
        guard sanitized != lowPowerAutomaticThresholdPercent else { return }
        lowPowerAutomaticThresholdPercent = sanitized
        if lowPowerModePreference == .automatic {
            reconcileMacOSLowPowerMode(for: battery?.percent)
        }
    }

    /// Synchronises the real macOS "Low Power Mode" setting through the
    /// installed BUS hardware helper. The helper already runs as root after
    /// installation, so changing this setting does not need a second password
    /// prompt inside the app.
    private func reconcileMacOSLowPowerMode(for percent: Double?) {
        guard let percent else { return }
        let shouldEnable = percent <= Double(lowPowerAutomaticThresholdPercent)
        guard macOSLowPowerModeIsEnabled != shouldEnable else { return }
        setMacOSLowPowerMode(shouldEnable)
    }

    private func setMacOSLowPowerMode(_ enabled: Bool) {
        let state = enabled ? "1" : "0"
        let requestURL = Self.lowPowerModeRequestURL
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let payload = "\(state)\n"
            try? payload.write(
                to: requestURL,
                atomically: false,
                encoding: .utf8
            )
            DispatchQueue.main.async { [weak self] in
                self?.refreshMacOSLowPowerMode(force: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    self?.refreshMacOSLowPowerMode(force: true)
                }
            }
        }
    }

    private func refreshMacOSLowPowerMode(force: Bool = false) {
        guard !lowPowerModeRefreshIsInFlight else { return }
        guard force || Date().timeIntervalSince(lastLowPowerModeRefresh) >= 30
        else { return }

        lowPowerModeRefreshIsInFlight = true
        lastLowPowerModeRefresh = .now
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let value = Self.readMacOSLowPowerMode()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lowPowerModeRefreshIsInFlight = false
                guard let value,
                      value != self.cachedMacOSLowPowerModeIsEnabled else {
                    return
                }
                self.objectWillChange.send()
                self.cachedMacOSLowPowerModeIsEnabled = value
            }
        }
    }

    nonisolated private static func readMacOSLowPowerMode() -> Bool? {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        task.arguments = ["-g", "custom"]
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            let text = String(
                data: pipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            guard let range = text.range(of: "lowpowermode") else { return nil }
            let suffix = text[range.upperBound...]
            let digits = suffix.split(whereSeparator: { !$0.isNumber })
            return digits.first.map { $0 == "1" }
        } catch {
            return nil
        }
    }

    private static func clampedSampleInterval(_ value: Double) -> Double {
        min(max(value, 2), 60)
    }

    private static func clampedManufacturerRuntimeOverride(
        _ value: Double
    ) -> Double {
        min(max(value, 0), 40)
    }

    private static func clampedAutomaticProfileLookbackDays(
        _ value: Int
    ) -> Int {
        min(max(value, 1), 30)
    }

    private static func clampedLowPowerThreshold(_ value: Int) -> Int {
        min(max(value, 5), 100)
    }

    func toggleRunning() {
        isRunning.toggle()
        restartTimer()
    }

    func resetSession() {
        objectWillChange.send()
        startFreshSession(with: batteryReader.read())
    }

    func deleteAllLocalData() {
        objectWillChange.send()
        // Finish queued writes first; otherwise an older snapshot can land
        // after the reset and resurrect the deleted activity samples.
        persistenceQueue.sync {}
        learningStartedAt = .now
        UserDefaults.standard.set(learningStartedAt, forKey: "BUS.learningStartedAt")
        store.deleteAll()
        runtimeStore.delete()
        chargeLearningStore.delete()
        chargeLearningSamples = []
        chargeLearningAnchor = nil
        runtimeStatistics = .empty
        if let snapshot = batteryReader.read(), !snapshot.externalConnected {
            runtimeStatistics.active = Self.newActiveSession(snapshot)
            runtimeStatistics.activeProfileUsage = ActiveProfileUsage(
                profile: activeUsageProfile,
                startedAt: snapshot.date
            )
        }
        runtimeStore.save(runtimeStatistics)
        startFreshSession(with: batteryReader.read())
    }

    /// Clears only the local information used for learned runtime and charge
    /// predictions, while retaining the current dashboard and app records.
    func deletePersonalPredictionData() {
        objectWillChange.send()
        persistenceQueue.sync {}
        learningStartedAt = .now
        UserDefaults.standard.set(learningStartedAt, forKey: "BUS.learningStartedAt")
        runtimeStatistics = .empty
        if let snapshot = batteryReader.read(), !snapshot.externalConnected {
            runtimeStatistics.active = Self.newActiveSession(snapshot)
        }
        runtimeStore.save(runtimeStatistics)

        chargeLearningStore.delete()
        chargeLearningSamples = []
        chargeLearningAnchor = battery?.isCharging == true
            && battery?.externalConnected == true ? battery : nil
        activeProfileStartedAt = battery?.date ?? .now
    }

    private func startFreshSession(with snapshot: BatterySnapshot?) {
        battery = snapshot
        previousBattery = snapshot
        session = MonitorSession.fresh(snapshot: snapshot)
        chargeLearningAnchor = snapshot?.isCharging == true
            && snapshot?.externalConnected == true ? snapshot : nil
        if let snapshot, !snapshot.externalConnected {
            runtimeStatistics.activeProfileUsage = ActiveProfileUsage(
                profile: activeUsageProfile,
                startedAt: snapshot.date
            )
        } else {
            runtimeStatistics.activeProfileUsage = nil
        }
        activeProfileStartedAt = snapshot?.date ?? .now
        saveCounter = 0
        _ = samplingWorker.sampleProcesses()
        store.save(session)
    }

    func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "BUS-\(Self.fileDate.string(from: .now)).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var lines = [
            "Typ;App;Prozess;PID;Bundle-ID;Akkuanteil Prozentpunkte;Anteil Prozent;mWh geschätzt;CPU Sekunden;Disk MB;Wakeups"
        ]

        for record in sortedRecords {
            lines.append([
                "App",
                csv(record.name),
                "",
                "",
                csv(record.bundleIdentifier ?? ""),
                decimal(attributedBatteryPercent(for: record)),
                decimal(share(for: record) * 100),
                decimal(record.attributedMilliwattHours),
                decimal(record.cpuSeconds),
                decimal(Double(record.diskBytes) / 1_000_000),
                String(record.wakeups)
            ].joined(separator: ";"))

            for process in record.sortedProcesses {
                lines.append([
                    "Prozess",
                    csv(record.name),
                    csv(process.name),
                    String(process.pid),
                    csv(process.bundleIdentifier ?? ""),
                    decimal(attributedBatteryPercent(for: process)),
                    decimal(share(for: process, in: record) * 100),
                    decimal(process.attributedMilliwattHours),
                    decimal(process.cpuSeconds),
                    decimal(Double(process.diskBytes) / 1_000_000),
                    String(process.wakeups)
                ].joined(separator: ";"))
            }
        }

        lines.append("")
        lines.append(
            "Batteriesitzung;Start;Ende;Dauer Stunden;Start Prozent;Ende Prozent;Verbrauch Prozent;Durchschnitt Watt;Hochgerechnete Gesamtlaufzeit Stunden"
        )
        for item in runtimeStatistics.sessions {
            lines.append([
                "Laufzeit",
                Self.isoDate.string(from: item.startedAt),
                Self.isoDate.string(from: item.endedAt),
                decimal(item.duration / 3600),
                decimal(item.startPercent),
                decimal(item.endPercent),
                decimal(item.consumedPercent),
                decimal(item.averagePowerWatts),
                decimal(item.projectedFullRuntimeHours)
            ].joined(separator: ";"))
        }

        try? lines.joined(separator: "\n").write(
            to: url,
            atomically: true,
            encoding: .utf8
        )
    }

    private func restartTimer() {
        timer?.invalidate()
        guard isRunning else { return }
        timer = Timer.scheduledTimer(
            withTimeInterval: sampleInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.requestCollection()
            }
        }
        // Energy First: macOS may coalesce this timer with other work.
        // A generous tolerance lowers wakeups without changing the selected
        // nominal sampling interval shown to the user.
        timer?.tolerance = min(2.0, max(0.5, sampleInterval * 0.30))
    }

    private func requestCollection() {
        guard isRunning, !collectionIsInFlight else { return }
        collectionIsInFlight = true
        let worker = samplingWorker
        // Copy the previous profile input once. String matching and process
        // name aggregation then happen on the sampling queue, never while the
        // main thread is handling trackpad events.
        let profileRecords = Array(session.records.values)

        samplingQueue.async { [weak self, worker] in
            let newBattery = worker.readBattery()
            let deltas = worker.sampleProcesses()
            let profileDetection = UsageProfileDetector.detect(
                from: profileRecords
            )

            DispatchQueue.main.async { [weak self] in
                self?.applyCollection(
                    battery: newBattery,
                    deltas: deltas,
                    profileDetection: profileDetection
                )
            }
        }
    }

    private func applyCollection(
        battery newBattery: BatterySnapshot?,
        deltas: [ProcessDelta],
        profileDetection: UsageProfileDetection
    ) {
        collectionIsInFlight = false
        guard isRunning else { return }
        refreshMacOSLowPowerMode()

        // Exactly one invalidation for the complete sensor transaction.
        objectWillChange.send()

        handleRuntimeTransition(from: previousBattery, to: newBattery)

        if shouldResetAfterChargingEnds(
            from: previousBattery,
            to: newBattery
        ) {
            startFreshSession(with: newBattery)
            return
        }

        battery = newBattery
        if lowPowerModePreference == .automatic {
            reconcileMacOSLowPowerMode(for: newBattery?.percent)
        }
        learnChargeCurve(with: newBattery)
        let discharge = observedDischarge(
            from: previousBattery,
            to: newBattery
        )
        let totalScore = deltas.reduce(0) { $0 + $1.score }
        let measuredIntervalEnergy = (newBattery?.measuredSystemPowerWatts
            ?? newBattery?.instantaneousPowerWatts ?? 0)
            * sampleInterval / 3600 * 1000
        let energyForAttribution = discharge > 0
            ? discharge
            : max(0, measuredIntervalEnergy)

        for delta in deltas {
            let appKey = delta.app.bundleIdentifier ?? delta.app.name
            let attributedEnergy = totalScore > 0
                ? energyForAttribution * delta.score / totalScore
                : 0

            var appRecord = session.records[appKey] ?? AppEnergyRecord(
                name: delta.app.name,
                bundleIdentifier: delta.app.bundleIdentifier,
                applicationPath: delta.app.applicationPath
            )
            if appRecord.applicationPath == nil {
                appRecord.applicationPath = delta.app.applicationPath
            }
            appRecord.cpuSeconds += delta.cpuSeconds
            appRecord.diskReadBytes &+= delta.diskReadBytes
            appRecord.diskWriteBytes &+= delta.diskWriteBytes
            appRecord.wakeups &+= delta.wakeups
            appRecord.score += delta.score
            appRecord.attributedMilliwattHours += attributedEnergy
            appRecord.lastSeen = .now
            appRecord.activityStates = updatedActivityStates(
                appRecord.activityStates,
                state: delta.activityState,
                delta: delta,
                attributedEnergy: attributedEnergy
            )

            var processRecords = appRecord.processes ?? [:]
            var processRecord = processRecords[delta.process.key]
                ?? ProcessEnergyRecord(
                    key: delta.process.key,
                    name: delta.process.name,
                    bundleIdentifier: delta.process.bundleIdentifier,
                    pid: delta.process.pid
                )
            processRecord.pid = delta.process.pid
            processRecord.activityState = delta.activityState
            processRecord.cpuSeconds += delta.cpuSeconds
            processRecord.diskReadBytes &+= delta.diskReadBytes
            processRecord.diskWriteBytes &+= delta.diskWriteBytes
            processRecord.wakeups &+= delta.wakeups
            processRecord.score += delta.score
            processRecord.attributedMilliwattHours += attributedEnergy
            processRecord.lastSeen = .now
            processRecords[delta.process.key] = processRecord

            if processRecords.count > 100 {
                let keep = processRecords.values.sorted {
                    if $0.lastSeen == $1.lastSeen {
                        return $0.score > $1.score
                    }
                    return $0.lastSeen > $1.lastSeen
                }.prefix(100)
                processRecords = Dictionary(
                    uniqueKeysWithValues: keep.map { ($0.key, $0) }
                )
            }

            appRecord.processes = processRecords
            session.records[appKey] = appRecord

            learnAppActivity(
                appKey: appKey,
                app: delta.app,
                delta: delta,
                attributedEnergy: attributedEnergy,
                at: newBattery?.date ?? .now
            )
        }

        let profileBeforeUpdate = activeUsageProfile
        if profileDetection != detectedUsageProfileSnapshot {
            detectedUsageProfileSnapshot = profileDetection
        }
        if activeUsageProfile != profileBeforeUpdate {
            let transitionDate = newBattery?.date ?? .now
            transitionActiveProfileUsage(
                to: activeUsageProfile,
                at: transitionDate,
                snapshot: newBattery
            )
            activeProfileStartedAt = transitionDate
        }

        session.observedDischargeMilliwattHours += discharge
        session.updatedAt = .now

        if let newBattery {
            session.latestBatteryPercent = newBattery.percent
            appendHistoryIfNeeded(newBattery)

            if !newBattery.externalConnected {
                if var active = runtimeStatistics.active {
                    active.append(snapshot: newBattery)
                    runtimeStatistics.active = active
                } else {
                    runtimeStatistics.active = Self.newActiveSession(newBattery)
                }
            }
        }

        previousBattery = newBattery
        saveCounter += 1

        if saveCounter >= max(1, Int(30 / sampleInterval)) {
            saveCounter = 0
            persistSnapshots(
                session: session,
                runtimeStatistics: runtimeStatistics,
                chargeLearningSamples: chargeLearningSamples
            )
        }
    }

    private func persistSnapshots(
        session: MonitorSession,
        runtimeStatistics: RuntimeStatistics,
        chargeLearningSamples: [ChargeLearningSample]
    ) {
        let store = self.store
        let runtimeStore = self.runtimeStore
        let chargeLearningStore = self.chargeLearningStore
        persistenceQueue.async {
            store.save(session)
            runtimeStore.save(runtimeStatistics)
            chargeLearningStore.save(chargeLearningSamples)
        }
    }

    private func updatedActivityStates(
        _ existing: [AppActivityState: AppActivityStateRecord]?,
        state: AppActivityState,
        delta: ProcessDelta,
        attributedEnergy: Double
    ) -> [AppActivityState: AppActivityStateRecord] {
        var states = existing ?? [:]
        var record = states[state] ?? AppActivityStateRecord()
        record.samples += 1
        record.activeSeconds += sampleInterval
        record.cpuSeconds += delta.cpuSeconds
        record.diskReadBytes &+= delta.diskReadBytes
        record.diskWriteBytes &+= delta.diskWriteBytes
        record.wakeups &+= delta.wakeups
        record.score += delta.score
        record.attributedMilliwattHours += attributedEnergy
        record.lastSeen = .now
        states[state] = record
        return states
    }

    private func learnAppActivity(
        appKey: String,
        app: AppIdentity,
        delta: ProcessDelta,
        attributedEnergy: Double,
        at date: Date
    ) {
        guard delta.score > 0 || attributedEnergy > 0 else { return }

        var usage = runtimeStatistics.appActivityUsage[appKey]
            ?? LearnedAppActivityUsage(
                name: app.name,
                bundleIdentifier: app.bundleIdentifier,
                applicationPath: app.applicationPath,
                samples: []
            )
        usage.name = app.name
        usage.bundleIdentifier = app.bundleIdentifier
        usage.applicationPath = usage.applicationPath ?? app.applicationPath
        usage.append(
            AppActivityUsageSample(
                id: UUID(),
                date: date,
                state: delta.activityState,
                duration: sampleInterval,
                cpuSeconds: delta.cpuSeconds,
                diskReadBytes: delta.diskReadBytes,
                diskWriteBytes: delta.diskWriteBytes,
                wakeups: delta.wakeups,
                score: delta.score,
                attributedMilliwattHours: attributedEnergy
            )
        )
        usage.prune(
            before: date.addingTimeInterval(-30 * 24 * 3600),
            maximumSamples: 720
        )
        runtimeStatistics.appActivityUsage[appKey] = usage

        if runtimeStatistics.appActivityUsage.count > 150 {
            let keep = runtimeStatistics.appActivityUsage.sorted {
                ($0.value.samples.last?.date ?? .distantPast)
                    > ($1.value.samples.last?.date ?? .distantPast)
            }
            .prefix(150)
            runtimeStatistics.appActivityUsage = Dictionary(
                uniqueKeysWithValues: keep.map { ($0.key, $0.value) }
            )
        }
    }

    /// Learns only from uninterrupted, comparable charging windows. Long gaps
    /// are treated as sleep/standby or an interrupted measurement rather than
    /// as a rate sample, so they cannot distort the forecast.
    private func learnChargeCurve(with snapshot: BatterySnapshot?) {
        guard let snapshot,
              snapshot.externalConnected,
              snapshot.isCharging else {
            chargeLearningAnchor = nil
            return
        }

        guard let anchor = chargeLearningAnchor else {
            chargeLearningAnchor = snapshot
            return
        }

        guard anchor.externalConnected,
              anchor.isCharging,
              anchor.displayIsActive == snapshot.displayIsActive,
              chargeSourcePowerBucket(for: anchor)
                == chargeSourcePowerBucket(for: snapshot) else {
            chargeLearningAnchor = snapshot
            return
        }

        let elapsed = snapshot.date.timeIntervalSince(anchor.date)
        let minimumWindow = max(60, sampleInterval * 8)
        let maximumWindow = max(5 * 60, sampleInterval * 24)
        guard elapsed >= minimumWindow else { return }
        guard elapsed <= maximumWindow else {
            chargeLearningAnchor = snapshot
            return
        }

        let percentDelta: Double
        if let oldEnergy = anchor.energyMilliwattHours,
           let newEnergy = snapshot.energyMilliwattHours,
           let capacityWh = detectedMaximumBatteryWattHours
                ?? deviceProfile.batteryWattHours,
           capacityWh > 0 {
            percentDelta = max(0, newEnergy - oldEnergy) / (capacityWh * 1000) * 100
        } else {
            percentDelta = max(0, snapshot.percent - anchor.percent)
        }

        // Keep accumulating a very slow but valid charge instead of storing a
        // noisy near-zero value. The anchor is deliberately retained here.
        guard percentDelta >= 0.03 else { return }

        let rate = percentDelta / elapsed * 3600
        guard rate.isFinite, rate >= 0.15, rate <= 120 else {
            chargeLearningAnchor = snapshot
            return
        }

        let midpoint = (anchor.percent + snapshot.percent) / 2
        let sample = ChargeLearningSample(
            date: snapshot.date,
            modelIdentifier: deviceProfile.modelIdentifier,
            sourcePowerBucketWatts: chargeSourcePowerBucket(for: snapshot),
            segment: chargeSegment(for: midpoint),
            displayIsActive: snapshot.displayIsActive,
            percentPerHour: rate
        )
        chargeLearningSamples.append(sample)

        // Keep at most the most recent 30 days. Older charge behaviour is not
        // representative enough for a minute-accurate personal estimate.
        let cutoff = snapshot.date.addingTimeInterval(-30 * 24 * 3600)
        chargeLearningSamples.removeAll { $0.date < cutoff }
        if chargeLearningSamples.count > 3_000 {
            chargeLearningSamples.removeFirst(chargeLearningSamples.count - 3_000)
        }
        chargeLearningAnchor = snapshot
    }

    private func handleRuntimeTransition(
        from old: BatterySnapshot?,
        to new: BatterySnapshot?
    ) {
        guard let new else { return }

        if old?.externalConnected == true && !new.externalConnected {
            runtimeStatistics.active = Self.newActiveSession(new)
            runtimeStatistics.activeProfileUsage = ActiveProfileUsage(
                profile: activeUsageProfile,
                startedAt: new.date
            )
            runtimeStore.save(runtimeStatistics)
            return
        }

        if old?.externalConnected == false && new.externalConnected {
            finalizeActiveRuntimeSession(endingWith: new)
            finishActiveProfileUsage(at: new.date)
        }
    }

    private func transitionActiveProfileUsage(
        to profile: UsageProfileKind,
        at date: Date,
        snapshot: BatterySnapshot?
    ) {
        guard snapshot?.externalConnected == false else {
            finishActiveProfileUsage(at: date)
            return
        }
        guard runtimeStatistics.activeProfileUsage?.profile != profile else {
            return
        }
        finishActiveProfileUsage(at: date)
        runtimeStatistics.activeProfileUsage = ActiveProfileUsage(
            profile: profile,
            startedAt: date
        )
    }

    private func finishActiveProfileUsage(at date: Date) {
        guard let active = runtimeStatistics.activeProfileUsage else { return }
        if date.timeIntervalSince(active.startedAt) >= 60 {
            runtimeStatistics.profileUsage.append(ProfileUsageRecord(
                id: UUID(),
                profile: active.profile,
                startedAt: active.startedAt,
                endedAt: date
            ))
            runtimeStatistics.profileUsage.sort { $0.endedAt > $1.endedAt }
            runtimeStatistics.profileUsage.removeAll {
                $0.endedAt < profileReferenceCutoffDate
            }
        }
        runtimeStatistics.activeProfileUsage = nil
    }

    private func finalizeActiveRuntimeSession(
        endingWith snapshot: BatterySnapshot
    ) {
        guard let active = runtimeStatistics.active else { return }

        let duration = snapshot.date.timeIntervalSince(active.startedAt)
        let consumedPercent = max(
            0,
            active.startPercent - active.latestSnapshot.percent
        )
        let averagePower = active.averagePowerWatts
        let projected: Double

        if averagePower > 0,
           let batteryWh = detectedMaximumBatteryWattHours
                ?? deviceProfile.batteryWattHours {
            projected = batteryWh / averagePower
        } else if duration > 0, consumedPercent > 0 {
            projected = duration / 3600 * 100 / consumedPercent
        } else {
            projected = 0
        }

        let record = RuntimeSessionRecord(
            id: UUID(),
            startedAt: active.startedAt,
            endedAt: active.latestSnapshot.date,
            usageProfile: activeUsageProfile,
            startPercent: active.startPercent,
            endPercent: active.latestSnapshot.percent,
            startEnergyMilliwattHours: active.startEnergyMilliwattHours,
            endEnergyMilliwattHours: active.latestSnapshot.energyMilliwattHours,
            averagePowerWatts: averagePower,
            projectedFullRuntimeHours: projected,
            topConsumers: Array(sortedRecords.prefix(3).map(\.name))
        )

        if record.isQualified {
            runtimeStatistics.sessions.append(record)
            runtimeStatistics.sessions.sort { $0.endedAt > $1.endedAt }

            let cutoff = profileReferenceCutoffDate
            runtimeStatistics.sessions.removeAll { $0.endedAt < cutoff }

            if runtimeStatistics.sessions.count > 500 {
                runtimeStatistics.sessions = Array(
                    runtimeStatistics.sessions.prefix(500)
                )
            }
        }

        runtimeStatistics.active = nil
        runtimeStore.save(runtimeStatistics)
    }

    private var detectedMaximumBatteryWattHours: Double? {
        guard let snapshot = battery,
              let maxCapacity = snapshot.rawMaxCapacityMAh,
              let voltage = snapshot.voltageMV else {
            return nil
        }
        return maxCapacity * voltage / 1_000_000
    }

    private func appendHistoryIfNeeded(_ snapshot: BatterySnapshot) {
        let last = session.history.last
        let elapsed = snapshot.date.timeIntervalSince(
            last?.date ?? .distantPast
        )
        let sourceChanged = last?.externalConnected != snapshot.externalConnected
        let percentChanged = abs(
            (last?.percent ?? -1) - snapshot.percent
        ) >= 0.1

        guard elapsed >= 60 || sourceChanged || percentChanged else {
            return
        }

        if let last,
           elapsed >= historyGapThreshold {
            appendEstimatedPowerGap(
                after: last,
                before: snapshot,
                elapsed: elapsed
            )
        }

        session.history.append(BatteryHistoryPoint(snapshot: snapshot))
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        session.history.removeAll { $0.date < cutoff }
    }

    /// Gaps caused by sleep, a terminated BUS process or a reboot used to be
    /// connected by a diagonal line in the power chart. Insert two explicit
    /// boundary samples so that the gap has a plausible state instead. A
    /// reboot is known from the macOS boot time and is always shown as 0 W;
    /// otherwise the estimate prefers the actual energy lost over the gap.
    private var historyGapThreshold: TimeInterval {
        max(5 * 60, sampleInterval * 6)
    }

    private func appendEstimatedPowerGap(
        after previous: BatteryHistoryPoint,
        before snapshot: BatterySnapshot,
        elapsed: TimeInterval
    ) {
        let bootDate = Date().addingTimeInterval(-ProcessInfo.processInfo.systemUptime)
        let state: HistoryPowerState = previous.date < bootDate
            ? .poweredOff
            : .standbyEstimate
        let signedWatts = estimatedGapPowerWatts(
            from: previous,
            to: snapshot,
            elapsed: elapsed,
            state: state
        )

        // Keep the transitions near the live readings. The centre of the gap
        // is then a stable standby/offline segment, not an invented ramp.
        let transition = min(120, max(30, elapsed * 0.025))
        let startDate = previous.date.addingTimeInterval(transition)
        let endDate = snapshot.date.addingTimeInterval(-transition)
        guard startDate < endDate else { return }

        session.history.append(
            BatteryHistoryPoint(
                date: startDate,
                percent: previous.percent,
                signedPowerWatts: signedWatts,
                externalConnected: snapshot.externalConnected,
                energyMilliwattHours: previous.energyMilliwattHours,
                estimatedPowerState: state
            )
        )
        session.history.append(
            BatteryHistoryPoint(
                date: endDate,
                percent: snapshot.percent,
                signedPowerWatts: signedWatts,
                externalConnected: snapshot.externalConnected,
                energyMilliwattHours: snapshot.energyMilliwattHours,
                estimatedPowerState: state
            )
        )
    }

    private func estimatedGapPowerWatts(
        from previous: BatteryHistoryPoint,
        to snapshot: BatterySnapshot,
        elapsed: TimeInterval,
        state: HistoryPowerState
    ) -> Double {
        guard state != .poweredOff else { return 0 }

        if let oldEnergy = previous.energyMilliwattHours,
           let newEnergy = snapshot.energyMilliwattHours {
            let watts = (newEnergy - oldEnergy) / elapsed * 3.6
            // Values outside this range almost always mean a capacity gauge
            // recalibration rather than a sleeping/offline power draw.
            if watts.isFinite, abs(watts) >= 0.01, abs(watts) <= 5 {
                return -watts
            }
        }

        // Apple does not expose a measured per-model sleep-watt API. This is
        // intentionally conservative and capacity-scaled until BUS has a
        // local energy delta for the individual Mac.
        let capacity = deviceProfile.batteryWattHours ?? 60
        let standbyWatts = min(max(capacity * 0.002, 0.08), 0.22)
        return snapshot.externalConnected && snapshot.isCharging
            ? -standbyWatts
            : standbyWatts
    }

    private func shouldResetAfterChargingEnds(
        from old: BatterySnapshot?,
        to new: BatterySnapshot?
    ) -> Bool {
        guard let old, let new else {
            return false
        }

        if resetAfterFullCharge {
            let reachedFullCharge = old.percent < 99.9 && new.percent >= 99.9
            return new.externalConnected && reachedFullCharge
        }

        guard resetAfterChargingEnds else {
            return false
        }

        return old.externalConnected && !new.externalConnected
    }

    private func observedDischarge(
        from old: BatterySnapshot?,
        to new: BatterySnapshot?
    ) -> Double {
        guard let old,
              let new,
              !new.externalConnected,
              !new.isCharging else {
            return 0
        }

        if let oldEnergy = old.energyMilliwattHours,
           let newEnergy = new.energyMilliwattHours {
            return max(0, oldEnergy - newEnergy)
        }

        guard let maxCapacity = new.rawMaxCapacityMAh,
              let voltage = new.voltageMV else {
            return 0
        }

        return max(
            0,
            (old.percent - new.percent)
                / 100
                * maxCapacity
                * voltage
                / 1000
        )
    }

    private static func newActiveSession(
        _ snapshot: BatterySnapshot
    ) -> ActiveRuntimeSession {
        ActiveRuntimeSession(
            startedAt: snapshot.date,
            startPercent: snapshot.percent,
            startEnergyMilliwattHours: snapshot.energyMilliwattHours,
            latestSnapshot: snapshot,
            powerSamples: snapshot.instantaneousPowerWatts.map { [$0] } ?? []
        )
    }

    private static func efficiencyScore(
        actual: Double,
        reference: Double
    ) -> Double {
        guard reference > 0 else { return 0 }
        let ratio = actual / reference
        return max(0, min(100, ratio * 100))
    }

    private func csv(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private func decimal(_ value: Double) -> String {
        String(format: "%.3f", value)
            .replacingOccurrences(of: ".", with: ",")
    }

    private static let fileDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter
    }()

    private static let isoDate: ISO8601DateFormatter = {
        ISO8601DateFormatter()
    }()
}
