import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var monitor: EnergyMonitor
    @EnvironmentObject private var l: Localizer
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                ScoreRing(
                    score: monitor.busScore,
                    label: monitor.scoreLabel(l),
                    diameter: 184
                )
                .scaleEffect(0.42, anchor: .topLeading)
                .frame(width: 96, height: 96, alignment: .topLeading)

                VStack(alignment: .leading, spacing: 6) {
                    Text(AppMetadata.appName)
                        .font(.title3.bold())
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 7) {
                        Text(AppMetadata.license)
                        Text("·")
                        Text(AppMetadata.versionLabel)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                    Text(AppMetadata.creators)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(
                        monitor.isOnBattery
                            ? l.t("batteryMode")
                            : l.t("mainsMode")
                    )
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.green)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Label(monitor.battery.map { String(format: "%.0f %%", $0.percent) } ?? "–", systemImage: "battery.75percent")
                Spacer()
                Label(
                    String(
                        format: "%.1f W",
                        monitor.displayedAdapterPowerWatts
                    ),
                    systemImage: "bolt.fill"
                )
            }
            .font(.headline).monospacedDigit()

            if monitor.isChargingSession {
                AnimatedChargingFlow(compact: true)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label(
                            l.t("timeTo80"),
                            systemImage: "clock"
                        )
                        Spacer()
                        Text(
                            monitor.battery?.percent ?? 0 >= 80
                                ? l.t("reached")
                                : menuTime(monitor.estimatedChargeTimeTo80Hours)
                        )
                        .font(.subheadline.weight(.medium))
                        .monospacedDigit()
                    }

                    HStack {
                        Label(
                            l.t("timeToFull"),
                            systemImage: "battery.100percent"
                        )
                        Spacer()
                        Text(
                            menuTime(
                                monitor.estimatedChargeTimeToFullHours
                            )
                        )
                        .font(.subheadline.weight(.medium))
                        .monospacedDigit()
                    }

                    HStack {
                        Label(
                            l.t("runtimeFullCharge"),
                            systemImage: "hourglass"
                        )
                        Spacer()
                        Text(
                            menuTime(
                                monitor.estimatedRuntimeAtFullChargeHours
                            )
                        )
                        .font(.subheadline.weight(.medium))
                        .monospacedDigit()
                    }
                }
                .font(.subheadline)
            }

            Divider()

            HStack(spacing: 10) {
                Image(systemName: monitor.activeUsageProfile.icon)
                    .font(.title3)
                    .foregroundStyle(monitor.activeUsageProfile.accent)

                VStack(alignment: .leading, spacing: 1) {
                    Text(l.t("activeProfile"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(l.t(monitor.activeUsageProfile.titleKey))
                        .font(.body.bold())
                    Text(
                        "\(l.t("currentProfileTime")): \(monitor.activeUsageProfileElapsedText)"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                }

                Spacer()

                if let efficiency = monitor.usageProfileEfficiencyPercent {
                    Text(String(format: "%.0f %%", efficiency))
                        .font(.body.bold())
                        .foregroundStyle(efficiency >= 85 ? .green : .orange)
                }
            }

            Picker(
                l.t("comparisonProfile"),
                selection: Binding(
                    get: { monitor.selectedUsageProfile },
                    set: { monitor.updateUsageProfile($0) }
                )
            ) {
                ForEach(UsageProfileKind.allCases) { profile in
                    Label(
                        l.t(profile.titleKey),
                        systemImage: profile.icon
                    )
                    .tag(profile)
                }
            }
            .pickerStyle(.menu)

            Divider()

            HStack(spacing: 10) {
                Image(systemName: "leaf.fill")
                    .foregroundStyle(
                        monitor.effectiveLowPowerModeIsEnabled
                            ? .green
                            : .secondary
                    )

                VStack(alignment: .leading, spacing: 1) {
                    Text(l.t("lowPowerMode"))
                        .font(.subheadline.weight(.semibold))
                    Text(l.t(monitor.lowPowerModeStatusKey))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            Picker(
                l.t("lowPowerMode"),
                selection: Binding(
                    get: { monitor.lowPowerModePreference },
                    set: { monitor.updateLowPowerModePreference($0) }
                )
            ) {
                ForEach(LowPowerModePreference.allCases) { preference in
                    Text(l.t(preference.titleKey))
                        .tag(preference)
                }
            }
            .pickerStyle(.segmented)

            Divider()
            Text(l.t("topConsumers")).font(.caption.bold()).foregroundStyle(.secondary)
            if monitor.sortedRecords.isEmpty {
                Text(l.t("noData")).foregroundStyle(.secondary)
            } else {
                ForEach(monitor.sortedRecords.prefix(5)) { record in
                    HStack {
                        Text(record.name).lineLimit(1)
                        Spacer()
                        Text(String(format: "%.1f %%", monitor.share(for: record) * 100)).monospacedDigit()
                    }
                }
            }

            Divider()
            Label(l.t("offlineBadge"), systemImage: "lock.shield.fill")
                .font(.caption).foregroundStyle(.green)

            HStack {
                Button(l.t("openOverview")) {
                    dismiss()
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "main")
                }
                Spacer()
                Button(monitor.isRunning ? l.t("pause") : l.t("start")) { monitor.toggleRunning() }
                Button(l.t("quit")) { NSApp.terminate(nil) }
            }
        }
        .padding(16)
        .frame(width: 460)
    }

    private func menuTime(_ hours: Double?) -> String {
        guard let hours,
              hours.isFinite,
              hours > 0 else {
            return l.t("calculating")
        }
        let minutes = max(1, Int((hours * 60).rounded()))
        return "\(minutes / 60) h \(minutes % 60) min"
    }
}
