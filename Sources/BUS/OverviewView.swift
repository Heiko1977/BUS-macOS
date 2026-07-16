import AppKit
import Charts
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
                VStack(alignment: .leading, spacing: 14) {
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
            HStack(alignment: .top, spacing: 14) {
                scoreCard.frame(width: min(310, width * 0.26))
                metricGrid(columns: 4)
            }
        } else if width >= 700 {
            HStack(alignment: .top, spacing: 14) {
                scoreCard.frame(width: min(290, width * 0.38))
                metricGrid(columns: 2)
            }
        } else {
            VStack(spacing: 14) {
                scoreCard
                metricGrid(columns: width >= 470 ? 2 : 1)
            }
        }
    }

    private var scoreCard: some View {
        GlassCard {
            VStack(spacing: 9) {
                Text("BUS Score")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                ScoreRing(
                    score: frame.busScore,
                    label: monitor.scoreLabel(l),
                    diameter: 168
                )

                Text(monitor.scoreExplanation(l))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
            .frame(maxWidth: .infinity, minHeight: 238)
        }
    }

    private func metricGrid(columns count: Int) -> some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: 12),
                count: count
            ),
            spacing: 12
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
    }

    @ViewBuilder
    private func charts(width: CGFloat) -> some View {
        if width >= 920 {
            HStack(alignment: .top, spacing: 14) {
                BatteryChartCard(compact: true)
                PowerChartCard(compact: true)
            }
        } else {
            VStack(spacing: 14) {
                BatteryChartCard(compact: true)
                PowerChartCard(compact: true)
            }
        }
    }

    @ViewBuilder
    private func details(width: CGFloat) -> some View {
        if width >= 1120 {
            HStack(alignment: .top, spacing: 14) {
                RuntimeStatisticsCard()
                ScoreBreakdownCard()
                TopConsumersCard()
            }
            PrivacyCard()
        } else if width >= 760 {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 14),
                    GridItem(.flexible(), spacing: 14)
                ],
                spacing: 14
            ) {
                RuntimeStatisticsCard()
                ScoreBreakdownCard()
                TopConsumersCard()
                PrivacyCard()
            }
        } else {
            VStack(spacing: 14) {
                RuntimeStatisticsCard()
                ScoreBreakdownCard()
                TopConsumersCard()
                PrivacyCard()
            }
        }
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
    @EnvironmentObject private var monitor: EnergyMonitor
    @EnvironmentObject private var l: Localizer

    var compact = false

    private var points: [BatteryHistoryPoint] {
        Array(monitor.session.history.suffix(compact ? 720 : 2_000))
    }

    private var lowerBound: Double {
        max(0, (points.map(\.percent).min() ?? 0) - 4)
    }

    var body: some View {
        GlassCard {
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
                    .frame(height: compact ? 205 : 285)
                    .clipped()
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var chart: some View {
        if points.count < 2 {
            emptyChart(symbol: "chart.xyaxis.line")
        } else {
            Chart(points) { point in
                AreaMark(
                    x: .value("Time", point.date),
                    y: .value("Battery", point.percent)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            Color.green.opacity(0.30),
                            Color.green.opacity(0.015)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                LineMark(
                    x: .value("Time", point.date),
                    y: .value("Battery", point.percent)
                )
                .foregroundStyle(Color.green)
                .lineStyle(
                    StrokeStyle(
                        lineWidth: 2.4,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
            }
            .chartYScale(domain: lowerBound...100)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) {
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.hour().minute())
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) {
                    AxisGridLine()
                    AxisValueLabel()
                }
            }
            .chartPlotStyle { plotArea in
                plotArea
                    .background(Color.black.opacity(0.035))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
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

struct PowerChartCard: View {
    @EnvironmentObject private var monitor: EnergyMonitor
    @EnvironmentObject private var l: Localizer

    var compact = false

    private var points: [BatteryHistoryPoint] {
        Array(
            monitor.session.history
                .filter {
                    $0.signedPowerWatts != nil || $0.powerWatts != nil
                }
                .suffix(compact ? 720 : 2_000)
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
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
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
                    .frame(height: compact ? 205 : 285)
                    .clipped()

                HStack(spacing: 18) {
                    Label(l.t("energyDraw"), systemImage: "circle.fill")
                        .foregroundStyle(.orange)
                    Label(l.t("energyInput"), systemImage: "circle.fill")
                        .foregroundStyle(.green)
                }
                .font(.caption)
            }
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
            Chart {
                RuleMark(y: .value("Neutral", 0))
                    .foregroundStyle(Color.secondary.opacity(0.58))
                    .lineStyle(StrokeStyle(lineWidth: 1))

                ForEach(drawSamples) { sample in
                    AreaMark(
                        x: .value("Time", sample.date),
                        yStart: .value("Neutral", 0),
                        yEnd: .value("Draw", sample.watts),
                        series: .value("Draw area run", sample.seriesID)
                    )
                    .foregroundStyle(Color.orange.opacity(0.18))

                    LineMark(
                        x: .value("Time", sample.date),
                        y: .value("Draw", sample.watts),
                        series: .value("Draw run", sample.seriesID)
                    )
                    .foregroundStyle(Color.orange)
                    .lineStyle(
                        StrokeStyle(
                            lineWidth: 2.2,
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                }

                ForEach(chargeSamples) { sample in
                    AreaMark(
                        x: .value("Time", sample.date),
                        yStart: .value("Neutral", 0),
                        yEnd: .value("Charge", sample.watts),
                        series: .value("Charge area run", sample.seriesID)
                    )
                    .foregroundStyle(Color.green.opacity(0.20))

                    LineMark(
                        x: .value("Time", sample.date),
                        y: .value("Charge", sample.watts),
                        series: .value("Charge run", sample.seriesID)
                    )
                    .foregroundStyle(Color.green)
                    .lineStyle(
                        StrokeStyle(
                            lineWidth: 2.2,
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                }
            }
            .chartYScale(domain: symmetricPowerDomain)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) {
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.hour().minute())
                }
            }
            .chartYAxis {
                AxisMarks(
                    position: .leading,
                    values: .automatic(desiredCount: 7)
                ) { value in
                    AxisGridLine(
                        stroke: StrokeStyle(
                            lineWidth: value.as(Double.self) == 0 ? 1.2 : 0.6
                        )
                    )
                    AxisValueLabel()
                }
            }
            .chartPlotStyle { plotArea in
                plotArea
                    .background(Color.black.opacity(0.035))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

struct TopConsumersCard: View {
    @EnvironmentObject private var monitor: EnergyMonitor
    @EnvironmentObject private var l: Localizer

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(l.t("topConsumers"))
                    .font(.headline)

                if monitor.sortedRecords.isEmpty {
                    Text(l.t("noData"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(monitor.sortedRecords.prefix(5)) { item in
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
            .frame(maxWidth: .infinity, minHeight: 185, alignment: .topLeading)
        }
    }
}

struct PrivacyCard: View {
    @EnvironmentObject private var l: Localizer

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Label(
                    l.t("privacyTitle"),
                    systemImage: "lock.shield.fill"
                )
                .font(.headline)
                .foregroundStyle(.green)

                Text(l.t("privacyText"))
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Divider()

                Label(
                    l.t("offlineBadge"),
                    systemImage: "network.slash"
                )
                .font(.subheadline.bold())
            }
            .frame(maxWidth: .infinity, minHeight: 185, alignment: .topLeading)
        }
    }
}
