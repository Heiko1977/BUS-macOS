import SwiftUI

final class BUSSettingsState: ObservableObject {
    @Published var confirmDelete = false
}

struct BUSSettingsView: View {
    @EnvironmentObject private var monitor: EnergyMonitor
    @EnvironmentObject private var l: Localizer
    @StateObject private var login = LoginItemManager.shared
    @StateObject private var state = BUSSettingsState()

    var body: some View {
        Form {
            Section(l.t("general")) {
                Toggle(l.t("startAtLogin"), isOn: Binding(
                    get: { login.isEnabled },
                    set: { login.setEnabled($0) }
                ))
                if let error = login.lastError { Text(error).font(.caption).foregroundStyle(.red) }

                Picker(
                    l.t("language"),
                    selection: Binding(
                        get: { l.language },
                        set: { newLanguage in
                            guard newLanguage != l.language else { return }
                            l.language = newLanguage
                        }
                    )
                ) {
                    ForEach(AppLanguage.allCases) { language in
                        Text("\(language.symbol) \(language.label)").tag(language)
                    }
                }
            }

            Section(l.t("usageProfile")) {
                Picker(
                    l.t("activeProfile"),
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

                LabeledContent(l.t("detectedProfile")) {
                    Text(l.t(monitor.detectedUsageProfile.titleKey))
                }

                LabeledContent(l.t("expectedRuntime")) {
                    Text(
                        monitor.usageProfileReferenceHours.map {
                            let minutes = Int(($0 * 60).rounded())
                            return "\(minutes / 60) h \(minutes % 60) min"
                        } ?? "–"
                    )
                    .monospacedDigit()
                }
            }

            Section(l.t("measurement")) {
                HStack {
                    Text(l.t("interval"))
                    Slider(
                        value: Binding(
                            get: { monitor.sampleInterval },
                            set: { monitor.updateSampleInterval($0) }
                        ),
                        in: 2...30,
                        step: 1
                    )
                    Text("\(Int(monitor.sampleInterval)) s").monospacedDigit().frame(width: 45)
                }
                Toggle(l.t("autoReset"), isOn: $monitor.resetAfterChargingEnds)
                Toggle(l.t("autoResetAtFull"), isOn: $monitor.resetAfterFullCharge)
                    .disabled(!monitor.resetAfterChargingEnds)
            }

            Section(l.t("deviceReference")) {
                LabeledContent(l.t("detectedModel")) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(monitor.deviceProfile.displayName)
                        Text(monitor.deviceProfile.modelIdentifier)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent(l.t("automaticReference")) {
                    Text(
                        monitor.deviceProfile.referenceHours.map {
                            String(format: "%.1f h", $0)
                        } ?? l.t("notAvailable")
                    )
                    .monospacedDigit()
                }

                Stepper(
                    value: Binding(
                        get: {
                            monitor.manufacturerRuntimeOverrideHours
                        },
                        set: {
                            monitor.updateManufacturerRuntimeOverrideHours($0)
                        }
                    ),
                    in: 0...40,
                    step: 0.5
                ) {
                    HStack {
                        Text(l.t("manualReference"))
                        Spacer()
                        Text(
                            monitor.manufacturerRuntimeOverrideHours > 0
                                ? String(
                                    format: "%.1f h",
                                    monitor.manufacturerRuntimeOverrideHours
                                )
                                : l.t("automatic")
                        )
                        .monospacedDigit()
                    }
                }

                Text(l.t("referenceInfo"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(l.t("privacy")) {
                Label(l.t("privacyTitle"), systemImage: "lock.shield.fill").foregroundStyle(.green)
                Text(l.t("privacyText")).foregroundStyle(.secondary)
                Button(role: .destructive) { state.confirmDelete = true } label: {
                    Label(l.t("deleteData"), systemImage: "trash")
                }
            }
        }
        .formStyle(.grouped)
        .padding(24)
        .navigationTitle(l.t("settings"))
        .alert(l.t("confirmDelete"), isPresented: $state.confirmDelete) {
            Button(l.t("cancel"), role: .cancel) {}
            Button(l.t("delete"), role: .destructive) { monitor.deleteAllLocalData() }
        }
    }
}
