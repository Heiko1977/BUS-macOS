import Foundation

enum MenuBarBatteryDisplayMode: String, CaseIterable, Identifiable {
    case iconOnly
    case iconWithPercent

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .iconOnly:
            return "menuBarIconOnly"
        case .iconWithPercent:
            return "menuBarIconWithPercent"
        }
    }
}

enum MenuBarPreferenceKey {
    static let batteryDisplayMode = "BUS.menuBarBatteryDisplayMode"
    static let colorizeBatteryIcon = "BUS.menuBarColorizeBatteryIcon"
    static let showRemainingTime = "BUS.menuBarShowRemainingTime.v2"
}
