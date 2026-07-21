import SwiftUI
import AppKit

@MainActor
private final class PersonalProfileViewState: ObservableObject {
    enum SortColumn { case app, consumption, duration, foreground, background, power }
    @Published var sort: SortColumn = .consumption
}

struct PersonalProfileView: View {
    @EnvironmentObject private var monitor: EnergyMonitor
    @EnvironmentObject private var l: Localizer
    @StateObject private var state = PersonalProfileViewState()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(l.t("personalProfile"))
                        .font(.largeTitle.bold())
                    Text(l.t("personalProfileSubtitle"))
                        .foregroundStyle(.secondary)
                }

                learningCard

                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(l.t("personalProfileApps"), systemImage: "app.grid.2x2")
                            .font(.headline)
                        Text(l.t("personalProfileAppsInfo"))
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if monitor.personalAppUsageSummaries.isEmpty {
                            Text(l.t("personalProfileNoData"))
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 20)
                        } else {
                            header
                            ForEach(sortedSummaries.prefix(30)) { app in
                                appRow(app)
                                if app.id != monitor.personalAppUsageSummaries.prefix(30).last?.id {
                                    Divider()
                                }
                            }
                        }
                    }
                }

            }
            .padding()
        }
        .navigationTitle(l.t("personalProfile"))
    }

    private var learningCard: some View {
        let chargeSamples = monitor.chargeLearningSampleCount
        let referenceCount = monitor.predictionSessionCount
        let hasMeasuredEnergy = monitor.measuredEnergyHours > 0
        // These curves deliberately approach, but do not quickly reach, 100 %.
        // A short observation period must not be presented as a finished model.
        let appProgress = learningProgress(monitor.learnedAppActivityHours, target: 168)
        let chargeProgress = learningProgress(chargeSamples, target: 500)
        // Include the currently running observation as a fractional reference.
        // This avoids visible 20-point jumps while a session is being collected.
        let fractionalReference = min(0.99, monitor.activeUsageProfileElapsed / 3600)
        let usageProgress = learningProgress(
            Double(referenceCount) + fractionalReference,
            target: 5
        )
        let consumptionProgress = hasMeasuredEnergy
            ? learningProgress(monitor.measuredEnergyHours, target: 72)
            : 0

        return GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Label(l.t("learningProgress"), systemImage: "brain.head.profile")
                    .font(.headline)
                Text(l.t("learningProgressInfo"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                learningRow(
                    l.t("learningCharging"), chargeProgress,
                    "30 d · \(monitor.chargeLearningSampleCount) " + l.t("samples")
                )
                learningRow(
                    l.t("learningAppUsage"), appProgress,
                    "30 d · \(number(monitor.learnedAppActivityHours)) h · "
                    + learningState(for: appProgress)
                )
                learningRow(
                    l.t("learningConsumption"),
                    consumptionProgress,
                    hasMeasuredEnergy
                        ? "30 d · " + number(monitor.measuredEnergyHours) + " h · "
                            + learningState(for: consumptionProgress)
                        : "30 d · " + l.t("notAvailable")
                )
                learningRow(
                    l.t("learningRuntime"),
                    usageProgress,
                    "\(monitor.automaticProfileLookbackDays) d · \(referenceCount)/5 "
                    + l.t("qualifiedSessions") + " · "
                    + (referenceCount > 0
                        ? learningState(for: usageProgress)
                        : l.t("noQualifiedSessions"))
                )
            }
        }
    }

    private func learningProgress(_ count: Int, target: Double) -> Double {
        learningProgress(Double(count), target: target)
    }

    private func learningProgress(_ value: Double, target: Double) -> Double {
        guard value > 0, target > 0 else { return 0 }
        // Linear progress keeps the percentage honest: 1.8 observed hours
        // out of a 168-hour target must not look like a fifth of the model.
        return min(0.92, value / target)
    }

    private func learningState(for progress: Double) -> String {
        switch progress {
        case ..<0.4: return l.t("learningStateCollecting")
        case ..<0.75: return l.t("learningStatePreliminary")
        default: return l.t("learningStateStable")
        }
    }

    private func learningRow(_ title: String, _ value: Double, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                Spacer()
                // Keep one decimal place so small improvements remain visible;
                // this is especially important for the five-session runtime sample.
                Text(number(value * 100) + " % · " + detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            ProgressView(value: value)
                .tint(Color(hue: value / 3, saturation: 0.72, brightness: 0.9))
        }
    }

    private var sortedSummaries: [PersonalAppUsageSummary] {
        monitor.personalAppUsageSummaries.sorted {
            switch state.sort {
            case .app: return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            case .consumption: return $0.attributedMilliwattHours > $1.attributedMilliwattHours
            case .duration: return $0.usedSeconds > $1.usedSeconds
            case .foreground: return $0.foregroundSeconds > $1.foregroundSeconds
            case .background: return $0.backgroundSeconds > $1.backgroundSeconds
            case .power: return ($0.averagePowerWatts ?? 0) > ($1.averagePowerWatts ?? 0)
            }
        }
    }

    private var header: some View {
        HStack {
            columnButton(l.t("app"), .app)
            Spacer()
            columnButton(l.t("energy"), .consumption)
            columnButton(l.t("duration"), .duration)
            columnButton(l.t("foreground"), .foreground)
            columnButton(l.t("background"), .background)
            columnButton(l.t("power"), .power)
        }
        .font(.caption.bold())
        .foregroundStyle(.secondary)
    }

    private func columnButton(
        _ title: String,
        _ column: PersonalProfileViewState.SortColumn
    ) -> some View {
        Button(title) { state.sort = column }
            .buttonStyle(.plain)
    }

    private func appRow(_ app: PersonalAppUsageSummary) -> some View {
        HStack(spacing: 12) {
            AppIconView(path: app.applicationPath)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name).fontWeight(.medium)
                Text(app.bundleIdentifier ?? l.t("unknownApp"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(number(app.attributedMilliwattHours / 1000) + " Wh")
                    .fontWeight(.semibold)
                    .monospacedDigit()
                Text(number(app.usedHours) + " h · " + powerText(app.averagePowerWatts))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text("V " + number(app.foregroundSeconds / 3600)
                    + " h · H " + number(app.backgroundSeconds / 3600) + " h")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 5)
    }

    private func powerText(_ watts: Double?) -> String {
        guard let watts else { return "–" }
        return number(watts) + " W"
    }

    private func number(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale.current
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        return formatter.string(from: NSNumber(value: value)) ?? "0,0"
    }
}

private struct AppIconView: View {
    let path: String?

    var body: some View {
        Group {
            if let path {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                    .resizable()
            } else {
                Image(systemName: "app.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 28, height: 28)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
