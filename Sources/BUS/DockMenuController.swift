import AppKit
import Foundation

@MainActor
final class BUSAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let shouldStartHidden = LoginItemManager.shared.isEnabled
            && LaunchBehaviorManager.shared.startHiddenAtLogin
        DebugLogger.log(
            "didFinishLaunching startHidden=\(shouldStartHidden) loginEnabled=\(LoginItemManager.shared.isEnabled) activationPolicyBefore=\(NSApp.activationPolicy().rawValue)"
        )
        NSApp.setActivationPolicy(shouldStartHidden ? .accessory : .regular)

        if shouldStartHidden {
            DispatchQueue.main.async {
                if let window = NSApp.windows.first(where: {
                    $0.title.contains(AppMetadata.appName)
                }) {
                    DebugLogger.log("closing main window for hidden login start")
                    window.close()
                }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            DebugLogger.log(
                "postLaunch windows=\(NSApp.windows.count) visibleWindows=\(NSApp.windows.filter { $0.isVisible }.count) activationPolicy=\(NSApp.activationPolicy().rawValue)"
            )
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        DebugLogger.log("dock reopen visibleWindows=\(flag)")
        if !flag {
            bringMainWindowForward()
        }
        return true
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
        DebugLogger.log("bringMainWindowForward")
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
            DebugLogger.log("main window ordered front title=\(window.title)")
        } else {
            DebugLogger.log("main window not found")
        }
    }
}

extension Notification.Name {
    static let busOpenSection = Notification.Name("BUS.openSection")
}
