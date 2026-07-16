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
                monitor.chargeRatePercentPerHour
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
