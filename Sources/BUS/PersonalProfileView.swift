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
