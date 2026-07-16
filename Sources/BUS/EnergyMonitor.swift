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
    private(set) var detectedUsageProfileSnapshot:
        UsageProfileDetection

    let deviceProfile = DeviceProfileDatabase.current
    @Published private(set) var gpuDetails = DeviceProfileDatabase.gpuDetails

    private let batteryReader = BatteryReader()
    private let samplingWorker = SamplingWorker()
    private let store = SessionStore()
    private let runtimeStore = RuntimeStatisticsStore()
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
    private var saveCounter = 0

    private init() {
        let defaults = UserDefaults.standard
        let interval = defaults.object(forKey: "BUS.sampleInterval") as? Double ?? 5
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

        let initialBattery = batteryReader.read()
        let loadedSession = store.load() ?? MonitorSession.fresh(
            snapshot: initialBattery
        )
        let initialSession = AppGrouping.normalize(session: loadedSession)
        var loadedRuntime = runtimeStore.load()

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
        detectedUsageProfileSnapshot = UsageProfileDetector.detect(
            from: Array(initialSession.records.values)
        )
        battery = initialBattery
        session = initialSession
        runtimeStatistics = loadedRuntime
        previousBattery = initialBattery

        _ = samplingWorker.sampleProcesses()
        runtimeStore.save(runtimeStatistics)
        restartTimer()

        Task { [weak self] in
            let details = await Task.detached(priority: .utility) {
                DeviceProfileDatabase.readGPUDetails()
            }.value
            self?.gpuDetails = details
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

    var estimatedRuntimeAtCurrentChargeHours: Double? {
        let reference = personalRuntimeSummary.medianHours
            ?? usageProfileReferenceHours
            ?? manufacturerReferenceHours
        guard let reference,
              let percent = battery?.percent else {
            return nil
        }
        return reference * max(0, min(100, percent)) / 100
    }

    var estimatedRuntimeAtFullChargeHours: Double? {
        personalRuntimeSummary.medianHours
            ?? usageProfileReferenceHours
            ?? manufacturerReferenceHours
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

        let directPercent = max(
            0,
            min(target, 80) - startPercent
        )
        let taperPercent = max(
            0,
            target - max(startPercent, 80)
        )

        let directEnergyWh = capacityWh * directPercent / 100
        let taperEnergyWh = capacityWh * taperPercent / 100

        let directHours = directEnergyWh / batteryChargingPowerWatts

        // Above 80%, charging is deliberately tapered. A factor of 1.75
        // avoids an unrealistically linear full-charge estimate.
        let taperHours = taperEnergyWh
            / max(0.5, batteryChargingPowerWatts / 1.75)

        let result = directHours + taperHours
        guard result.isFinite, result > 0, result < 24 else {
            return nil
        }
        return result
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

    func referenceHours(
        for profile: UsageProfileKind
    ) -> Double? {
        let effective = profile == .automatic
            ? detectedUsageProfile
            : profile

        guard let base = manufacturerReferenceHours else { return nil }
        return base * effective.referenceMultiplier
    }

    var usageProfileReferenceHours: Double? {
        referenceHours(for: activeUsageProfile)
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
            qualifiedSessions: runtimeStatistics.sessions.filter(\.isQualified)
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
                return batteryWh / power
            }
        }

        let elapsedHours = Date().timeIntervalSince(session.startedAt) / 3600
        guard elapsedHours >= 0.05, batteryDropPercent >= 0.5 else {
            return nil
        }
        return elapsedHours * 100 / batteryDropPercent
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
    }

    private static func clampedSampleInterval(_ value: Double) -> Double {
        min(max(value, 2), 60)
    }

    private static func clampedManufacturerRuntimeOverride(
        _ value: Double
    ) -> Double {
        min(max(value, 0), 40)
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
        store.deleteAll()
        runtimeStore.delete()
        runtimeStatistics = .empty
        if let snapshot = batteryReader.read(), !snapshot.externalConnected {
            runtimeStatistics.active = Self.newActiveSession(snapshot)
        }
        runtimeStore.save(runtimeStatistics)
        startFreshSession(with: batteryReader.read())
    }

    private func startFreshSession(with snapshot: BatterySnapshot?) {
        battery = snapshot
        previousBattery = snapshot
        session = MonitorSession.fresh(snapshot: snapshot)
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
        let discharge = observedDischarge(
            from: previousBattery,
            to: newBattery
        )
        let totalScore = deltas.reduce(0) { $0 + $1.score }

        for delta in deltas {
            let appKey = delta.app.bundleIdentifier ?? delta.app.name
            let attributedEnergy = totalScore > 0
                ? discharge * delta.score / totalScore
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

            var processRecords = appRecord.processes ?? [:]
            var processRecord = processRecords[delta.process.key]
                ?? ProcessEnergyRecord(
                    key: delta.process.key,
                    name: delta.process.name,
                    bundleIdentifier: delta.process.bundleIdentifier,
                    pid: delta.process.pid
                )
            processRecord.pid = delta.process.pid
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
        }

        if profileDetection != detectedUsageProfileSnapshot {
            detectedUsageProfileSnapshot = profileDetection
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
                runtimeStatistics: runtimeStatistics
            )
        }
    }

    private func persistSnapshots(
        session: MonitorSession,
        runtimeStatistics: RuntimeStatistics
    ) {
        let store = self.store
        let runtimeStore = self.runtimeStore
        persistenceQueue.async {
            store.save(session)
            runtimeStore.save(runtimeStatistics)
        }
    }

    private func handleRuntimeTransition(
        from old: BatterySnapshot?,
        to new: BatterySnapshot?
    ) {
        guard let new else { return }

        if old?.externalConnected == true && !new.externalConnected {
            runtimeStatistics.active = Self.newActiveSession(new)
            runtimeStore.save(runtimeStatistics)
            return
        }

        if old?.externalConnected == false && new.externalConnected {
            finalizeActiveRuntimeSession(endingWith: new)
        }
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

            let cutoff = Date().addingTimeInterval(-365 * 24 * 3600)
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

        session.history.append(BatteryHistoryPoint(snapshot: snapshot))
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        session.history.removeAll { $0.date < cutoff }
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
