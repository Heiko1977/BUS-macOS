import SwiftUI

struct ProfilesView: View {
    @EnvironmentObject private var monitor: EnergyMonitor
    @EnvironmentObject private var l: Localizer

    private let columns = [
        GridItem(.adaptive(minimum: 230), spacing: DashboardTileLayout.spacing)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(l.t("profiles"))
                        .font(.system(size: 27, weight: .bold))
                    Text(l.t("profilesSubtitle"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                currentProfileCard

                LazyVGrid(columns: columns, spacing: DashboardTileLayout.spacing) {
                    ForEach(UsageProfileKind.allCases) { profile in
                        profileCard(profile)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var currentProfileCard: some View {
        GlassCard {
            HStack(spacing: 16) {
                Image(systemName: monitor.activeUsageProfile.icon)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(monitor.activeUsageProfile.accent)
                    .frame(width: 54, height: 54)
                    .background(
                        monitor.activeUsageProfile.accent.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 14)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text(l.t("activeProfile"))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(l.t(monitor.activeUsageProfile.titleKey))
                        .font(.title3.bold())

                    Text(profileStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text(l.t("expectedRuntime"))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(formatHours(monitor.usageProfileReferenceHours))
                        .font(.title3.bold())
                        .monospacedDigit()

                    if let efficiency = monitor.usageProfileEfficiencyPercent {
                        Text(String(format: "%.0f %% %@", efficiency, l.t("profileEfficiency")))
                            .font(.caption.bold())
                            .foregroundStyle(efficiency >= 85 ? .green : .orange)
                    }
                }
            }
        }
    }

    private func profileCard(_ profile: UsageProfileKind) -> some View {
        let selected = monitor.selectedUsageProfile == profile

        return Button {
            monitor.updateUsageProfile(profile)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: profile.icon)
                        .font(.title2)
                        .foregroundStyle(profile.accent)

                    Spacer()

                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }

                Text(l.t(profile.titleKey))
                    .font(.headline)

                Text(l.t(profile.descriptionKey))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .topLeading)

                Divider()

                HStack {
                    Text(l.t("expectedRuntime"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(formatHours(monitor.referenceHours(for: profile)))
                        .font(.callout.bold())
                        .monospacedDigit()
                }
            }
            .padding(15)
            .frame(maxWidth: .infinity, minHeight: 178, alignment: .topLeading)
            .background(
                selected
                    ? profile.accent.opacity(0.12)
                    : Color.primary.opacity(0.025),
                in: RoundedRectangle(cornerRadius: 15)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 15)
                    .stroke(
                        selected
                            ? profile.accent.opacity(0.85)
                            : Color.primary.opacity(0.08),
                        lineWidth: selected ? 1.5 : 1
                    )
            }
        }
        .buttonStyle(.plain)
    }

    private var profileStatus: String {
        if monitor.selectedUsageProfile == .automatic {
            return "\(l.t("automaticallyDetected")) · \(Int((monitor.detectedUsageProfileConfidence * 100).rounded())) %"
        }
        return l.t("manuallySelected")
    }

    private func formatHours(_ hours: Double?) -> String {
        guard let hours, hours.isFinite, hours > 0 else { return "–" }
        let minutes = Int((hours * 60).rounded())
        return "\(minutes / 60) h \(minutes % 60) min"
    }
}

struct ActiveProfileCard: View {
    @EnvironmentObject private var presentation: DashboardPresentationStore
    @EnvironmentObject private var l: Localizer

    private var frame: DashboardPresentationFrame { presentation.frame }

    var body: some View {
        GlassCard {
            HStack(spacing: 14) {
                Image(systemName: frame.activeUsageProfile.icon)
                    .font(.title2)
                    .foregroundStyle(frame.activeUsageProfile.accent)
                    .frame(width: 44, height: 44)
                    .background(
                        frame.activeUsageProfile.accent.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 12)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text(l.t("activeProfile"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(l.t(frame.activeUsageProfile.titleKey))
                        .font(.headline)
                    Text(
                        frame.selectedUsageProfile == .automatic
                            ? l.t("automaticallyDetected")
                            : l.t("manuallySelected")
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 3) {
                    Text(l.t("expectedRuntime"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(formatHours(frame.usageProfileReferenceHours))
                        .font(.headline)
                        .monospacedDigit()
                    if let efficiency = frame.usageProfileEfficiencyPercent {
                        Text(String(format: "%.0f %%", efficiency))
                            .font(.caption.bold())
                            .foregroundStyle(efficiency >= 85 ? .green : .orange)
                    }
                }
            }
        }
    }

    private func formatHours(_ hours: Double?) -> String {
        guard let hours, hours.isFinite, hours > 0 else { return "–" }
        let minutes = Int((hours * 60).rounded())
        return "\(minutes / 60) h \(minutes % 60) min"
    }
}
