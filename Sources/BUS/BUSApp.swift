import SwiftUI

@main
struct BUSApp: App {
    @NSApplicationDelegateAdaptor(BUSAppDelegate.self) private var appDelegate
    @StateObject private var localizer = Localizer.shared
    private let monitor = EnergyMonitor.shared
    private let presentation = DashboardPresentationStore.shared
    private let chartPresentation = DashboardChartStore.shared

    var body: some Scene {
        Window(AppMetadata.windowTitle, id: "main") {
            RootView()
                .environmentObject(monitor)
                .environmentObject(localizer)
                .environmentObject(presentation)
                .environmentObject(chartPresentation)
                .localizedEnvironment(localizer)
                .frame(minWidth: 760, minHeight: 620)
        }
        .defaultSize(width: 1280, height: 820)

        MenuBarExtra {
            MenuBarView()
                .environmentObject(monitor)
                .environmentObject(localizer)
                .environmentObject(presentation)
                .environmentObject(chartPresentation)
                .localizedEnvironment(localizer)
        } label: {
            MenuBarStatusLabel()
                .environmentObject(presentation)
        }
        .menuBarExtraStyle(.window)

        Settings {
            BUSSettingsView()
                .environmentObject(monitor)
                .environmentObject(localizer)
                .environmentObject(presentation)
                .environmentObject(chartPresentation)
                .localizedEnvironment(localizer)
                .frame(width: 620)
        }
    }
}

private struct MenuBarStatusLabel: View {
    @EnvironmentObject private var presentation: DashboardPresentationStore

    var body: some View {
        Label(
            presentation.frame.busScore > 0
                ? "BUS \(presentation.frame.busScore)"
                : "BUS –",
            systemImage: presentation.frame.isOnBattery
                ? "battery.75percent"
                : "battery.100percent.bolt"
        )
    }
}
