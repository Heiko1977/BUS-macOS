import SwiftUI

final class BUSSettingsState: ObservableObject {
    @Published var confirmDelete = false
    @Published var confirmDeletePrediction = false
}

struct BUSSettingsView: View {
    @EnvironmentObject private var monitor: EnergyMonitor
    @EnvironmentObject private var l: Localizer
    @StateObject private var login = LoginItemManager.shared
    @StateObject private var launchBehavior = LaunchBehaviorManager.shared
    @StateObject private var state = BUSSettingsState()
    @AppStorage(MenuBarPreferenceKey.batteryDisplayMode)
    private var menuBarBatteryDisplayMode =
        MenuBarBatteryDisplayMode.iconWithPercent.rawValue
    @AppStorage(MenuBarPreferenceKey.colorizeBatteryIcon)
    private var colorizeMenuBarBatteryIcon = true
    @AppStorage(MenuBarPreferenceKey.showRemainingTime)
    private var showMenuBarRemainingTime = true

    var body: some View {
        Form {
            Section(l.t("general")) {
                Toggle(l.t("startAtLogin"), isOn: Binding(
                    get: { login.isEnabled },
                    set: { login.setEnabled($0) }
                ))
                if let error = login.lastError { Text(error).font(.caption).foregroundStyle(.red) }

                Toggle(
                    l.t("startHiddenAtLogin"),
                    isOn: Binding(
                        get: { launchBehavior.startHiddenAtLogin },
                        set: { launchBehavior.startHiddenAtLogin = $0 }
                    )
                )
                .disabled(!login.isEnabled)
                Text(l.t("startHiddenAtLoginHelp"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

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

            Section(l.t("menuBar")) {
                Picker(
                    l.t("menuBarBatteryDisplay"),
                    selection: $menuBarBatteryDisplayMode
                ) {
                    ForEach(MenuBarBatteryDisplayMode.allCases) { mode in
                        Text(l.t(mode.titleKey)).tag(mode.rawValue)
                    }
                }

                Toggle(
                    l.t("menuBarColorizeBattery"),
                    isOn: $colorizeMenuBarBatteryIcon
                )

                Toggle(
                    l.t("menuBarShowRemainingTime"),
                    isOn: $showMenuBarRemainingTime
                )

                Text(l.t("menuBarRemainingTimeHelp"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(l.t("debugging")) {
                Toggle(
                    l.t("debugLogging"),
                    isOn: Binding(
                        get: { DebugLogger.isEnabled },
                        set: {
                            UserDefaults.standard.set(
                                $0,
                                forKey: DebugLogPreferenceKey.enabled
                            )
                            DebugLogger.log("debug logging enabled from settings")
                        }
                    )
                )
                Text(l.t("debugLoggingHelp"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

                Stepper(
                    value: Binding(
                        get: { monitor.automaticProfileLookbackDays },
                        set: { monitor.updateAutomaticProfileLookbackDays($0) }
                    ),
                    in: 1...30
                ) {
                    HStack {
                        Text(l.t("automaticLookback"))
                        Spacer()
                        Text("\(monitor.automaticProfileLookbackDays) \(l.t("days"))")
                            .monospacedDigit()
                    }
                }

                Text(
                    String(
                        format: l.t("automaticLookbackHelp"),
                        monitor.automaticProfileLookbackDays
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section(l.t("predictionData")) {
                LabeledContent(l.t("qualifiedSessions")) {
                    Text("\(monitor.predictionSessionCount)")
                        .monospacedDigit()
                }
                LabeledContent(l.t("chargeLearningData")) {
                    Text("\(monitor.chargeLearningSampleCount)")
                        .monospacedDigit()
                }
                LabeledContent(l.t("predictionStatus")) {
                    Text(l.t(monitor.personalPredictionConfidenceKey))
                }
                Text(l.t("predictionDataHelp"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(role: .destructive) {
                    state.confirmDeletePrediction = true
                } label: {
                    Label(
                        l.t("deletePredictionData"),
                        systemImage: "trash"
                    )
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
        .alert(
            l.t("confirmDeletePredictionData"),
            isPresented: $state.confirmDeletePrediction
        ) {
            Button(l.t("cancel"), role: .cancel) {}
            Button(l.t("delete"), role: .destructive) {
                monitor.deletePersonalPredictionData()
            }
        }
    }
}
