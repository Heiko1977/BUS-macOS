import AppKit
import SwiftUI

struct OverviewView: View {
    @EnvironmentObject private var presentation:
        DashboardPresentationStore
    @EnvironmentObject private var l: Localizer

    private var monitor: EnergyMonitor {
        EnergyMonitor.shared
    }

    private var frame: DashboardPresentationFrame {
        presentation.frame
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: DashboardTileLayout.spacing) {
                    header(width: proxy.size.width - 40)
                    if frame.isChargingSession {
                        ChargingDashboardCard()
                    } else {
                        summary(width: proxy.size.width - 40)
                    }

                    ActiveProfileCard()
                    charts(width: proxy.size.width - 40)
                    details(width: proxy.size.width - 40)

                    Text(AppMetadata.creditLine)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .allowsHitTesting(false)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background(
                LinearGradient(
                    colors: [
                        Color.black.opacity(0.025),
                        Color.green.opacity(0.018)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .transaction { transaction in
                // Fresh battery samples must not trigger implicit layout or
                // chart animations while the user is moving the scroll view.
                transaction.animation = nil
            }
        }
    }

    @ViewBuilder
    private func header(width: CGFloat) -> some View {
        if width >= 720 {
            HStack(alignment: .top, spacing: 16) {
                titleBlock
                Spacer(minLength: 10)
                actionButtons
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                titleBlock
                actionButtons
            }
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(l.t("overview"))
                .font(.system(size: 27, weight: .bold))
            Text(l.t("overviewSubtitle"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .allowsHitTesting(false)
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            Button {
                monitor.toggleRunning()
                presentation.refreshImmediately()
            } label: {
                Label(
                    frame.isRunning ? l.t("pause") : l.t("start"),
                    systemImage: frame.isRunning ? "pause.fill" : "play.fill"
                )
            }

            Button { monitor.exportCSV() } label: {
                Label(l.t("export"), systemImage: "square.and.arrow.up")
            }

            Button {
                monitor.resetSession()
                presentation.refreshImmediately()
            } label: {
                Label(l.t("reset"), systemImage: "arrow.counterclockwise")
            }
        }
        .buttonStyle(.bordered)
    }

    @ViewBuilder
    private func summary(width: CGFloat) -> some View {
        if width >= 1040 {
            HStack(alignment: .top, spacing: DashboardTileLayout.spacing) {
                scoreCard.frame(width: min(250, width * 0.24))
                hardwareCard.frame(width: min(250, width * 0.24))
                metricGrid(columns: 2)
            }
        } else if width >= 700 {
            HStack(alignment: .top, spacing: DashboardTileLayout.spacing) {
                scoreCard.frame(width: min(220, width * 0.27))
                hardwareCard.frame(width: min(220, width * 0.27))
                metricGrid(columns: 2)
            }
        } else {
            VStack(spacing: DashboardTileLayout.spacing) {
                scoreCard
                hardwareCard
                metricGrid(columns: width >= 470 ? 2 : 1)
            }
        }
    }

    private var scoreCard: some View {
        GlassCard {
            VStack(spacing: 14) {
                Text("BUS Score")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)

                ScoreRing(
                    score: frame.busScore,
                    label: monitor.scoreLabel(l),
                    diameter: 154
                )

                Text(monitor.scoreExplanation(l))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.bottom, 2)
            }
            .frame(
                maxWidth: .infinity,
                minHeight: DashboardTileLayout.scoreContentHeight
            )
        }
        .allowsHitTesting(false)
    }

    private var hardwareCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("MacBook Hardware", systemImage: "laptopcomputer")
                    .font(.headline)
                    .foregroundStyle(.green)

                Text(monitor.deviceProfile.displayName)
                    .font(.title3.bold())
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)

                Text(monitor.deviceProfile.modelIdentifier)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospaced()

                Divider()

                hardwareRow("Prozessor", DeviceProfileDatabase.processorDescription)
                hardwareRow("GPU", monitor.gpuDetails.name)
                hardwareRow("GPU-Kerne", monitor.gpuDetails.cores)
                hardwareRow("Arbeitsspeicher", DeviceProfileDatabase.memoryDescription)
                hardwareRow("Kerne", DeviceProfileDatabase.coreDescription)
                hardwareRow("Akku-Referenz", monitor.deviceProfile.batteryWattHours.map { String(format: "%.1f Wh", $0) } ?? "–")
            }
            .frame(maxWidth: .infinity, minHeight: DashboardTileLayout.scoreContentHeight, alignment: .topLeading)
        }
        .allowsHitTesting(false)
    }

    private func hardwareRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).font(.caption.bold()).multilineTextAlignment(.trailing).lineLimit(2)
        }
    }

    private func metricGrid(columns count: Int) -> some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: DashboardTileLayout.metricSpacing),
                count: count
            ),
            spacing: DashboardTileLayout.metricSpacing
        ) {
            MetricCard(
                icon: "battery.75percent",
                title: l.t("remaining"),
                value: frame.batteryPercent.map {
                    String(format: "%.0f %%", $0)
                } ?? "–"
            )

            MetricCard(
                icon: "bolt.fill",
                title: l.t("power"),
                value: String(format: "%.1f W", frame.currentPowerWatts)
            )

            MetricCard(
                icon: "clock.fill",
                title: l.t("duration"),
                value: duration(Date().timeIntervalSince(frame.sessionStartedAt))
            )

            MetricCard(
                icon: frame.isOnBattery ? "bolt.slash.fill" : "powerplug.fill",
                title: l.t("status"),
                value: frame.isOnBattery ? l.t("batteryMode") : l.t("mainsMode")
            )
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func charts(width: CGFloat) -> some View {
        Group {
            if width >= 920 {
                HStack(alignment: .top, spacing: DashboardTileLayout.spacing) {
                    BatteryChartCard(compact: true)
                    PowerChartCard(compact: true)
                }
            } else {
                VStack(spacing: DashboardTileLayout.spacing) {
                    BatteryChartCard(compact: true)
                    PowerChartCard(compact: true)
                }
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func details(width: CGFloat) -> some View {
        Group {
            if width >= 1120 {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: DashboardTileLayout.spacing),
                        GridItem(.flexible(), spacing: DashboardTileLayout.spacing)
                    ],
                    spacing: DashboardTileLayout.spacing
                ) {
                    RuntimeStatisticsCard(dashboardMode: true)
                    ScoreBreakdownCard(dashboardMode: true)
                    TopConsumersCard(limit: 3)
                    PrivacyCard(dashboardMode: true)
                        .gridCellColumns(2)
                }
            } else if width >= 760 {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 14),
                        GridItem(.flexible(), spacing: 14)
                    ],
                    spacing: DashboardTileLayout.spacing
                ) {
                    RuntimeStatisticsCard(dashboardMode: true)
                    ScoreBreakdownCard(dashboardMode: true)
                    TopConsumersCard(limit: 3)
                    PrivacyCard(dashboardMode: true)
                        .gridCellColumns(2)
                }
            } else {
                VStack(spacing: DashboardTileLayout.spacing) {
                    RuntimeStatisticsCard(dashboardMode: true)
                    ScoreBreakdownCard(dashboardMode: true)
                    TopConsumersCard(limit: 3)
                    PrivacyCard(dashboardMode: true)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func duration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600
            ? [.hour, .minute]
            : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: seconds) ?? "0"
    }
}

struct BatteryChartCard: View {
    @EnvironmentObject private var charts: DashboardChartStore
    @EnvironmentObject private var l: Localizer

    private var monitor: EnergyMonitor { .shared }

    var compact = false

    private var points: [BatteryHistoryPoint] {
        chartSamples(
            Array(charts.history.suffix(compact ? 720 : 2_000)),
            limit: compact ? 160 : 240
        )
    }

    private var lowerBound: Double {
        max(0, (points.map(\.percent).min() ?? 0) - 4)
    }

    var body: some View {
        PerformanceChartCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(l.t("batteryHistory"))
                            .font(.headline)
                        Text(l.t("lastHours"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text("−\(String(format: "%.2f", monitor.batteryDropPercent)) %")
                        .font(.headline)
                        .monospacedDigit()
                }

                chart
                    .frame(
                        height: compact
                            ? DashboardTileLayout.compactBatteryChartHeight
                            : DashboardTileLayout.regularBatteryChartHeight
                    )
                    .clipped()
            }
            .frame(height: compact ? DashboardTileLayout.compactChartCardHeight : DashboardTileLayout.regularChartCardHeight,
                   alignment: .topLeading)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var chart: some View {
        if points.count < 2 {
            emptyChart(symbol: "chart.xyaxis.line")
        } else {
            LightweightBatteryChart(
                points: points,
                lowerBound: lowerBound
            )
        }
    }

    private func emptyChart(symbol: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text(l.t("noData"))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PowerBalanceSample: Identifiable {
    let id: UUID
    let date: Date
    let watts: Double
    let seriesID: String
}

/// Reduces chart complexity while retaining the first and latest reading.
/// Hundreds of individual Swift Charts marks inside a scrolling material view
/// are expensive to composite and add no visible detail at this card width.
private func chartSamples(
    _ points: [BatteryHistoryPoint],
    limit: Int
) -> [BatteryHistoryPoint] {
    guard points.count > limit, limit > 2 else { return points }
    let stride = max(1, Int(ceil(Double(points.count) / Double(limit))))
    var result = Swift.stride(from: 0, to: points.count, by: stride)
        .map { points[$0] }
    if result.last?.id != points.last?.id, let last = points.last {
        result.append(last)
    }
    return result
}

struct PowerChartCard: View {
    @EnvironmentObject private var charts: DashboardChartStore
    @EnvironmentObject private var l: Localizer

    private var monitor: EnergyMonitor { .shared }

    var compact = false

    private var points: [BatteryHistoryPoint] {
        chartSamples(
            Array(
            charts.history
                .filter {
                    $0.signedPowerWatts != nil || $0.powerWatts != nil
                }
                .suffix(compact ? 720 : 2_000)
            ),
            limit: compact ? 160 : 240
        )
    }

    private func signedPower(_ point: BatteryHistoryPoint) -> Double? {
        if let signed = point.signedPowerWatts {
            return signed
        }
        guard let power = point.powerWatts else { return nil }
        return point.externalConnected ? -abs(power) : abs(power)
    }

    private var drawSamples: [PowerBalanceSample] {
        samples(positive: true)
    }

    private var chargeSamples: [PowerBalanceSample] {
        samples(positive: false)
    }

    private func samples(positive: Bool) -> [PowerBalanceSample] {
        var result: [PowerBalanceSample] = []
        var run = 0
        var wasIncluded = false

        for point in points {
            guard let value = signedPower(point) else {
                wasIncluded = false
                continue
            }

            let included = positive ? value >= 0 : value < 0
            if included {
                if !wasIncluded {
                    run += 1
                }
                result.append(
                    PowerBalanceSample(
                        id: point.id,
                        date: point.date,
                        watts: value,
                        seriesID: "\(positive ? "draw" : "charge")-\(run)"
                    )
                )
            }
            wasIncluded = included
        }

        return result
    }

    private var averageDraw: Double {
        let values = drawSamples.map(\.watts).filter { $0 > 0 }
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private var averageCharge: Double {
        let values = chargeSamples.map { abs($0.watts) }
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private var symmetricPowerDomain: ClosedRange<Double> {
        let peak = points
            .compactMap(signedPower)
            .map(abs)
            .max() ?? 10
        let padded = max(10, ceil(peak * 1.15 / 5) * 5)
        return (-padded)...padded
    }

    var body: some View {
        PerformanceChartCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(l.t("powerBalance"))
                            .font(.headline)
                        Text(l.t("powerBalanceSubtitle"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    HStack(spacing: 12) {
                        Label(
                            String(format: "Ø %.1f W", averageDraw),
                            systemImage: "arrow.up.right"
                        )
                        .foregroundStyle(.orange)

                        Label(
                            String(format: "Ø %.1f W", averageCharge),
                            systemImage: "arrow.down.left"
                        )
                        .foregroundStyle(.green)
                    }
                    .font(.caption.bold())
                    .monospacedDigit()
                }

                chart
                    .frame(
                        height: compact
                            ? DashboardTileLayout.compactPowerChartHeight
                            : DashboardTileLayout.regularPowerChartHeight
                    )
                    .clipped()

                HStack(spacing: 18) {
                    Label(l.t("energyDraw"), systemImage: "circle.fill")
                        .foregroundStyle(.orange)
                    Label(l.t("energyInput"), systemImage: "circle.fill")
                        .foregroundStyle(.green)
                }
                .font(.caption)
            }
            .frame(height: compact ? DashboardTileLayout.compactChartCardHeight : DashboardTileLayout.regularChartCardHeight,
                   alignment: .topLeading)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var chart: some View {
        if points.count < 2 {
            VStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 30))
                    .foregroundStyle(.secondary)
                Text(l.t("noData"))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            LightweightPowerChart(
                points: points,
                domain: symmetricPowerDomain
            )
        }
    }
}

struct TopConsumersCard: View {
    @EnvironmentObject private var l: Localizer

    private var monitor: EnergyMonitor { .shared }
    var limit: Int = 5

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(l.t("topConsumers"))
                    .font(.headline)

                if monitor.sortedRecords.isEmpty {
                    Text(l.t("noData"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(monitor.sortedRecords.prefix(limit)) { item in
                        HStack(spacing: 8) {
                            Image(nsImage: AppIconProvider.icon(for: item))
                                .resizable()
                                .interpolation(.high)
                                .frame(width: 19, height: 19)

                            Text(item.name)
                                .lineLimit(1)

                            Spacer()

                            Text(
                                String(
                                    format: "%.1f %%",
                                    monitor.share(for: item) * 100
                                )
                            )
                            .font(.callout.bold())
                            .monospacedDigit()
                        }

                        ProgressView(value: monitor.share(for: item))
                            .tint(.green)
                    }
                }
            }
            .frame(
                maxWidth: .infinity,
                minHeight: DashboardTileLayout.topConsumersContentHeight,
                alignment: .topLeading
            )
        }
        .allowsHitTesting(false)
    }
}

struct PrivacyCard: View {
    @EnvironmentObject private var l: Localizer
    var dashboardMode: Bool = false

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: dashboardMode ? 10 : 12) {
                Label(
                    l.t("privacyTitle"),
                    systemImage: "lock.shield.fill"
                )
                .font(.headline)
                .foregroundStyle(.green)

                Text(l.t("privacyText"))
                    .font(dashboardMode ? .callout : .callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(dashboardMode ? 3 : nil)

                Divider()

                Label(
                    l.t("offlineBadge"),
                    systemImage: "network.slash"
                )
                .font(.subheadline.bold())
            }
            .frame(
                maxWidth: .infinity,
                minHeight: dashboardMode
                    ? DashboardTileLayout.topConsumersContentHeight
                    : DashboardTileLayout.privacyContentHeight,
                alignment: .topLeading
            )
        }
        .allowsHitTesting(false)
    }
}
