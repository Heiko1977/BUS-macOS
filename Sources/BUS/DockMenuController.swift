import AppKit
import Foundation

@MainActor
final class BUSAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu(title: AppMetadata.appName)

        menu.addItem(
            item(
                title: Localizer.shared.t("openOverview"),
                action: #selector(openOverview)
            )
        )
        menu.addItem(
            item(
                title: Localizer.shared.t("history"),
                action: #selector(openHistory)
            )
        )
        menu.addItem(
            item(
                title: Localizer.shared.t("consumers"),
                action: #selector(openConsumers)
            )
        )
        menu.addItem(
            item(
                title: Localizer.shared.t("profiles"),
                action: #selector(openProfiles)
            )
        )

        menu.addItem(.separator())

        let monitor = EnergyMonitor.shared
        menu.addItem(
            item(
                title: monitor.isRunning
                    ? Localizer.shared.t("pause")
                    : Localizer.shared.t("start"),
                action: #selector(toggleMeasurement)
            )
        )
        menu.addItem(
            item(
                title: Localizer.shared.t("export"),
                action: #selector(exportData)
            )
        )

        menu.addItem(.separator())
        menu.addItem(
            item(
                title: Localizer.shared.t("quit"),
                action: #selector(quitApp)
            )
        )

        return menu
    }

    private func item(title: String, action: Selector) -> NSMenuItem {
        let result = NSMenuItem(
            title: title,
            action: action,
            keyEquivalent: ""
        )
        result.target = self
        return result
    }

    @objc private func openOverview() {
        open(section: "overview")
    }

    @objc private func openHistory() {
        open(section: "history")
    }

    @objc private func openConsumers() {
        open(section: "consumers")
    }

    @objc private func openProfiles() {
        open(section: "profiles")
    }

    @objc private func toggleMeasurement() {
        EnergyMonitor.shared.toggleRunning()
    }

    @objc private func exportData() {
        bringMainWindowForward()
        EnergyMonitor.shared.exportCSV()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func open(section: String) {
        NotificationCenter.default.post(
            name: .busOpenSection,
            object: nil,
            userInfo: ["section": section]
        )
        bringMainWindowForward()
    }

    private func bringMainWindowForward() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if let window = NSApp.windows.first(where: {
            $0.title.contains("BUS") && $0.canBecomeKey
        }) {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }
}

extension Notification.Name {
    static let busOpenSection = Notification.Name("BUS.openSection")
}
