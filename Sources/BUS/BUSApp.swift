import SwiftUI

@main
struct BUSApp: App {
    @NSApplicationDelegateAdaptor(BUSAppDelegate.self) private var appDelegate
    @StateObject private var monitor = EnergyMonitor.shared
    @StateObject private var localizer = Localizer.shared
    @StateObject private var presentation =
        DashboardPresentationStore.shared

    var body: some Scene {
        Window(AppMetadata.windowTitle, id: "main") {
            RootView()
                .environmentObject(monitor)
                .environmentObject(localizer)
                .environmentObject(presentation)
                .localizedEnvironment(localizer)
                .frame(minWidth: 760, minHeight: 620)
        }
        .defaultSize(width: 1280, height: 820)

        MenuBarExtra {
            MenuBarView()
                .environmentObject(monitor)
                .environmentObject(localizer)
                .environmentObject(presentation)
                .localizedEnvironment(localizer)
        } label: {
            Label(
                presentation.frame.busScore > 0
                    ? "BUS \(presentation.frame.busScore)"
                    : "BUS –",
                systemImage: presentation.frame.isOnBattery
                    ? "battery.75percent"
                    : "battery.100percent.bolt"
            )
        }
        .menuBarExtraStyle(.window)

        Settings {
            BUSSettingsView()
                .environmentObject(monitor)
                .environmentObject(localizer)
                .environmentObject(presentation)
                .localizedEnvironment(localizer)
                .frame(width: 620)
        }
    }
}
