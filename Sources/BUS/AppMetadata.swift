import Foundation

enum AppMetadata {
    static let appName = "BUS – Battery Usage Score"
    static let license = "Freeware"
    static let creators = "von Heiko Große & ChatGPT © 2026"

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.1.6"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "76"
    }

    static var versionLabel: String {
        "Version \(version)"
    }

    static var windowTitle: String {
        "\(appName)  |  \(license)  |  \(versionLabel)  |  \(creators)"
    }

    static var creditLine: String {
        "\(appName) \(creators)"
    }
}
