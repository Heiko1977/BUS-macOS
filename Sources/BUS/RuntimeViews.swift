import SwiftUI

struct ScoreBreakdownCard: View {
    @EnvironmentObject private var monitor: EnergyMonitor
    @EnvironmentObject private var l: Localizer
    var dashboardMode: Bool = false

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: dashboardMode ? 9 : 12) {
                Label(l.t("scoreDetails"), systemImage: "gauge.with.dots.needle.67percent")
                    .font(.headline)

                breakdownRow(
                    title: l.t("currentProjection"),
                    value: formatHours(
                        monitor.scoreBreakdown.currentProjectedRuntimeHours
                    )
                )

                breakdownRow(
                    title: l.t("profileReference"),
                    value: formatHours(
                        monitor.scoreBreakdown.manufacturerReferenceHours
                    )
                )

                breakdownRow(
                    title: l.t("personalMedian"),
                    value: formatHours(
                        monitor.scoreBreakdown.personalReferenceHours
                    )
                )

                Divider()

                if let model = monitor.scoreBreakdown.modelScore {
                    scoreRow(
                        title: l.t("modelScore"),
                        score: model,
                        weight: monitor.scoreBreakdown.modelWeight
                    )
                }

                if let personal = monitor.scoreBreakdown.personalScore {
                    scoreRow(
                        title: l.t("personalScore"),
                        score: personal,
                        weight: monitor.scoreBreakdown.personalWeight
                    )
                }

                Text(monitor.scoreExplanation(l))
                    .font(dashboardMode ? .caption2 : .caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(dashboardMode ? 2 : nil)
            }
            .frame(
                maxWidth: .infinity,
                minHeight: dashboardMode
                    ? DashboardTileLayout.analysisContentHeight - 22
                    : DashboardTileLayout.analysisContentHeight,
                alignment: .topLeading
            )
        }
        .allowsHitTesting(false)
    }

    private func breakdownRow(title: String, value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.semibold).monospacedDigit()
        }
    }

    private func scoreRow(
        title: String,
        score: Double,
        weight: Double
    ) -> some View {
        VStack(spacing: 5) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(score.rounded())) / 100")
                    .fontWeight(.semibold)
                    .monospacedDigit()
                if weight > 0 {
                    Text("· \(Int((weight * 100).rounded())) %")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ProgressView(value: score, total: 100)
                .tint(.green)
        }
    }

    private func formatHours(_ hours: Double?) -> String {
        guard let hours, hours.isFinite, hours > 0 else { return "–" }
        let totalMinutes = Int((hours * 60).rounded())
        return "\(totalMinutes / 60) h \(totalMinutes % 60) min"
    }
}

struct RuntimeStatisticsCard: View {
    @EnvironmentObject private var monitor: EnergyMonitor
    @EnvironmentObject private var l: Localizer
    var dashboardMode: Bool = false

    var body: some View {
        let summary = monitor.personalRuntimeSummary

        GlassCard {
            VStack(alignment: .leading, spacing: dashboardMode ? 9 : 12) {
                Label(l.t("personalRuntime"), systemImage: "clock.arrow.2.circlepath")
                    .font(.headline)

                runtimeRow(
                    l.t("remainingEstimate"),
                    monitor.currentRemainingRuntimeHours
                )
                runtimeRow(
                    l.t("currentProjection"),
                    monitor.currentProjectedFullRuntimeHours
                )
                runtimeRow(
                    l.t("thirtyDayAverage"),
                    summary.thirtyDayAverageHours
                )
                runtimeRow(
                    l.t("personalMedian"),
                    summary.medianHours
                )
                runtimeRow(
                    l.t("manufacturerReference"),
                    monitor.manufacturerReferenceHours
                )

                Divider()

                HStack {
                    Text(l.t("qualifiedSessions"))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(summary.count)")
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }

                Text(l.t("runtimeStatisticsInfo"))
                    .font(dashboardMode ? .caption2 : .caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(dashboardMode ? 2 : nil)
            }
            .frame(
                maxWidth: .infinity,
                minHeight: dashboardMode
                    ? DashboardTileLayout.analysisContentHeight - 22
                    : DashboardTileLayout.analysisContentHeight,
                alignment: .topLeading
            )
        }
        .allowsHitTesting(false)
    }

    private func runtimeRow(
        _ title: String,
        _ hours: Double?
    ) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(formatHours(hours))
                .fontWeight(.semibold)
                .monospacedDigit()
        }
    }

    private func formatHours(_ hours: Double?) -> String {
        guard let hours, hours.isFinite, hours > 0 else { return "–" }
        let totalMinutes = Int((hours * 60).rounded())
        return "\(totalMinutes / 60) h \(totalMinutes % 60) min"
    }
}

struct RuntimeSessionsView: View {
    @EnvironmentObject private var monitor: EnergyMonitor
    @EnvironmentObject private var l: Localizer

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Label(l.t("batterySessions"), systemImage: "list.bullet.rectangle")
                    .font(.headline)

                if monitor.runtimeStatistics.sessions.isEmpty {
                    Text(l.t("noRuntimeSessions"))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 100)
                } else {
                    ForEach(monitor.runtimeStatistics.sessions.prefix(12)) { item in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.startedAt, style: .date)
                                    .fontWeight(.medium)
                                Text(
                                    "\(item.startedAt.formatted(date: .omitted, time: .shortened))–\(item.endedAt.formatted(date: .omitted, time: .shortened))"
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Text(String(format: "−%.1f %%", item.consumedPercent))
                                .monospacedDigit()

                            Text(formatHours(item.projectedFullRuntimeHours))
                                .fontWeight(.semibold)
                                .monospacedDigit()
                                .frame(width: 92, alignment: .trailing)
                        }

                        if item.id != monitor.runtimeStatistics.sessions.prefix(12).last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func formatHours(_ hours: Double) -> String {
        guard hours.isFinite, hours > 0 else { return "–" }
        let totalMinutes = Int((hours * 60).rounded())
        return "\(totalMinutes / 60) h \(totalMinutes % 60) min"
    }
}
