import Combine
import Foundation

struct DashboardPresentationFrame: Equatable {
    var isRunning: Bool
    var isChargingSession: Bool
    var isOnBattery: Bool
    var batteryPercent: Double?
    var isCharging: Bool
    var sessionStartedAt: Date
    var busScore: Int
    var currentPowerWatts: Double
    var displayedAdapterPowerWatts: Double
    var adapterInputIsEstimated: Bool
    var adapterRatedPowerWatts: Double?
    var estimatedSystemPowerWatts: Double
    var batteryChargingPowerWatts: Double
    var powerMeasurementQualityKey: String
    var estimatedChargeTimeTo80Hours: Double?
    var estimatedChargeTimeToFullHours: Double?
    var estimatedRuntimeAtCurrentChargeHours: Double?
    var estimatedRuntimeAtFullChargeHours: Double?
    var chargeRatePercentPerHour: Double?
    var selectedUsageProfile: UsageProfileKind
    var activeUsageProfile: UsageProfileKind
    var detectedUsageProfileConfidence: Double
    var usageProfileReferenceHours: Double?
    var usageProfileEfficiencyPercent: Double?

    @MainActor
    static func capture(from monitor: EnergyMonitor) -> Self {
        Self(
            isRunning: monitor.isRunning,
            isChargingSession: monitor.isChargingSession,
            isOnBattery: monitor.isOnBattery,
            batteryPercent: monitor.battery?.percent,
            isCharging: monitor.battery?.isCharging == true,
            sessionStartedAt: monitor.session.startedAt,
            busScore: monitor.busScore,
            currentPowerWatts: monitor.currentPowerWatts,
            displayedAdapterPowerWatts:
                monitor.displayedAdapterPowerWatts,
            adapterInputIsEstimated:
                monitor.adapterInputIsEstimated,
            adapterRatedPowerWatts:
                monitor.adapterRatedPowerWatts,
            estimatedSystemPowerWatts:
                monitor.estimatedSystemPowerWhileChargingWatts,
            batteryChargingPowerWatts:
                monitor.batteryChargingPowerWatts,
            powerMeasurementQualityKey:
                monitor.powerMeasurementQualityKey,
            estimatedChargeTimeTo80Hours:
                monitor.estimatedChargeTimeTo80Hours,
            estimatedChargeTimeToFullHours:
                monitor.estimatedChargeTimeToFullHours,
            estimatedRuntimeAtCurrentChargeHours:
                monitor.estimatedRuntimeAtCurrentChargeHours,
            estimatedRuntimeAtFullChargeHours:
                monitor.estimatedRuntimeAtFullChargeHours,
            chargeRatePercentPerHour:
                monitor.chargeRatePercentPerHour,
            selectedUsageProfile: monitor.selectedUsageProfile,
            activeUsageProfile: monitor.activeUsageProfile,
            detectedUsageProfileConfidence:
                monitor.detectedUsageProfileConfidence,
            usageProfileReferenceHours:
                monitor.usageProfileReferenceHours,
            usageProfileEfficiencyPercent:
                monitor.usageProfileEfficiencyPercent
        )
    }
}

@MainActor
final class DashboardPresentationStore: ObservableObject {
    static let shared = DashboardPresentationStore()

    @Published private(set) var frame:
        DashboardPresentationFrame
    private let monitor = EnergyMonitor.shared
    private var monitorSubscription: AnyCancellable?

    private init() {
        frame = DashboardPresentationFrame.capture(
            from: EnergyMonitor.shared
        )
        observeMonitor()
    }

    func refreshImmediately() {
        publishIfChanged()
    }

    private func observeMonitor() {
        // EnergyMonitor publishes before its value changes. A short debounce
        // coalesces a complete sensor sample and captures the finished state.
        // Unlike the old 4 Hz polling timer this creates no idle wakeups.
        monitorSubscription = monitor.objectWillChange
            .receive(on: RunLoop.main)
            .debounce(for: .milliseconds(20), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.publishIfChanged()
            }
    }

    private func publishIfChanged() {
        let next = DashboardPresentationFrame.capture(
            from: monitor
        )
        guard next != frame else { return }
        frame = next
    }
}

/// Separate observable domain for diagrams. Publishing new chart data must
/// never invalidate the surrounding dashboard, navigation list or controls.
@MainActor
final class DashboardChartStore: ObservableObject {
    static let shared = DashboardChartStore()

    @Published private(set) var history: [BatteryHistoryPoint]

    private let monitor = EnergyMonitor.shared
    private var monitorSubscription: AnyCancellable?
    private var lastChartRefresh = Date.distantPast

    private init() {
        history = monitor.session.history
        lastChartRefresh = .now
        monitorSubscription = monitor.objectWillChange
            .receive(on: RunLoop.main)
            .debounce(for: .milliseconds(30), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.refreshIfNeeded() }
    }

    private func refreshIfNeeded() {
        let source = monitor.session.history
        let changed = source.last?.id != history.last?.id
            || source.first?.id != history.first?.id
            || source.count < history.count
        guard changed else { return }

        let now = Date.now
        let resetOccurred = source.count < history.count
        guard resetOccurred
            || now.timeIntervalSince(lastChartRefresh) >= 5 else { return }
        history = source
        lastChartRefresh = now
    }
}
