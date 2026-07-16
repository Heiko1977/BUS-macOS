import AppKit
import Foundation

struct CanonicalAppIdentity: Hashable {
    let name: String
    let bundleIdentifier: String?
    let applicationPath: String?
}

enum AppGrouping {
    static func canonicalIdentity(
        processName: String,
        processBundleIdentifier: String?,
        executableURL: URL?,
        detectedAppURL: URL?
    ) -> CanonicalAppIdentity {
        let bundleID = processBundleIdentifier ?? ""
        let lowerName = processName.lowercased()

        // Safari/WebKit helpers are separate helper bundles, but belong to Safari.
        if bundleID == "com.apple.Safari"
            || bundleID.hasPrefix("com.apple.WebKit.")
            || lowerName.hasPrefix("safari")
            || lowerName.contains("webkit") {
            return identity(
                name: "Safari",
                bundleIdentifier: "com.apple.Safari",
                preferredURL: NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari")
            )
        }

        // Chromium families.
        if bundleID == "com.brave.Browser"
            || bundleID.hasPrefix("com.brave.Browser.helper")
            || lowerName.hasPrefix("brave browser helper") {
            return identity(
                name: "Brave Browser",
                bundleIdentifier: "com.brave.Browser",
                preferredURL: NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.brave.Browser")
            )
        }

        if bundleID == "com.google.Chrome"
            || bundleID.hasPrefix("com.google.Chrome.helper")
            || lowerName.hasPrefix("google chrome helper") {
            return identity(
                name: "Google Chrome",
                bundleIdentifier: "com.google.Chrome",
                preferredURL: NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome")
            )
        }

        if bundleID == "com.microsoft.edgemac"
            || bundleID.hasPrefix("com.microsoft.edgemac.helper")
            || lowerName.hasPrefix("microsoft edge helper") {
            return identity(
                name: "Microsoft Edge",
                bundleIdentifier: "com.microsoft.edgemac",
                preferredURL: NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.edgemac")
            )
        }

        if bundleID == "com.operasoftware.Opera"
            || bundleID.hasPrefix("com.operasoftware.Opera.helper")
            || lowerName.hasPrefix("opera helper") {
            return identity(
                name: "Opera",
                bundleIdentifier: "com.operasoftware.Opera",
                preferredURL: NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.operasoftware.Opera")
            )
        }

        // ChatGPT and BUS helper processes.
        if bundleID == "com.openai.chat"
            || bundleID.hasPrefix("com.openai.chat.")
            || lowerName.hasPrefix("chatgpt helper") {
            return identity(
                name: "ChatGPT",
                bundleIdentifier: "com.openai.chat",
                preferredURL: NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.chat")
            )
        }

        if bundleID == "de.heikogrosse.batteryusagescore"
            || bundleID.hasPrefix("de.heikogrosse.batteryusagescore.") {
            return identity(
                name: "BUS – Battery Usage Score",
                bundleIdentifier: "de.heikogrosse.batteryusagescore",
                preferredURL: Bundle.main.bundleURL
            )
        }

        // Generic helper-bundle fallback.
        if let normalizedBundle = normalizedParentBundleID(bundleID),
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: normalizedBundle) {
            return identity(
                name: displayName(at: appURL),
                bundleIdentifier: normalizedBundle,
                preferredURL: appURL
            )
        }

        if let appURL = detectedAppURL {
            let bundle = Bundle(url: appURL)
            return CanonicalAppIdentity(
                name: bundleDisplayName(bundle: bundle, appURL: appURL),
                bundleIdentifier: bundle?.bundleIdentifier ?? processBundleIdentifier,
                applicationPath: appURL.path
            )
        }

        if let executableURL,
           let installedURL = nearestInstalledApplication(for: executableURL) {
            let bundle = Bundle(url: installedURL)
            return CanonicalAppIdentity(
                name: bundleDisplayName(bundle: bundle, appURL: installedURL),
                bundleIdentifier: bundle?.bundleIdentifier ?? processBundleIdentifier,
                applicationPath: installedURL.path
            )
        }

        return CanonicalAppIdentity(
            name: processName,
            bundleIdentifier: processBundleIdentifier,
            applicationPath: nil
        )
    }

    static func normalize(session: MonitorSession) -> MonitorSession {
        var normalized = session
        var grouped: [String: AppEnergyRecord] = [:]

        for oldApp in session.records.values {
            let canonical = canonicalIdentity(
                processName: oldApp.name,
                processBundleIdentifier: oldApp.bundleIdentifier,
                executableURL: nil,
                detectedAppURL: oldApp.applicationPath.map { URL(fileURLWithPath: $0) }
            )
            let key = canonical.bundleIdentifier ?? canonical.name

            var target = grouped[key] ?? AppEnergyRecord(
                name: canonical.name,
                bundleIdentifier: canonical.bundleIdentifier,
                applicationPath: canonical.applicationPath
            )
            target.cpuSeconds += oldApp.cpuSeconds
            target.diskReadBytes &+= oldApp.diskReadBytes
            target.diskWriteBytes &+= oldApp.diskWriteBytes
            target.wakeups &+= oldApp.wakeups
            target.score += oldApp.score
            target.attributedMilliwattHours += oldApp.attributedMilliwattHours
            target.lastSeen = max(target.lastSeen, oldApp.lastSeen)
            if target.applicationPath == nil { target.applicationPath = canonical.applicationPath }

            var processes = target.processes ?? [:]
            if let oldProcesses = oldApp.processes, !oldProcesses.isEmpty {
                for process in oldProcesses.values {
                    processes[process.key] = merge(processes[process.key], process)
                }
            } else {
                // Older versions stored helper processes as separate top-level apps.
                let processKey = "migrated|\(oldApp.bundleIdentifier ?? "")|\(oldApp.name)"
                let migrated = ProcessEnergyRecord(
                    key: processKey,
                    name: oldApp.name,
                    bundleIdentifier: oldApp.bundleIdentifier,
                    pid: 0,
                    cpuSeconds: oldApp.cpuSeconds,
                    diskReadBytes: oldApp.diskReadBytes,
                    diskWriteBytes: oldApp.diskWriteBytes,
                    wakeups: oldApp.wakeups,
                    score: oldApp.score,
                    attributedMilliwattHours: oldApp.attributedMilliwattHours,
                    lastSeen: oldApp.lastSeen
                )
                processes[processKey] = merge(processes[processKey], migrated)
            }
            target.processes = processes
            grouped[key] = target
        }

        normalized.records = grouped
        return normalized
    }

    private static func merge(
        _ existing: ProcessEnergyRecord?,
        _ incoming: ProcessEnergyRecord
    ) -> ProcessEnergyRecord {
        guard var merged = existing else { return incoming }
        merged.pid = incoming.pid
        merged.cpuSeconds += incoming.cpuSeconds
        merged.diskReadBytes &+= incoming.diskReadBytes
        merged.diskWriteBytes &+= incoming.diskWriteBytes
        merged.wakeups &+= incoming.wakeups
        merged.score += incoming.score
        merged.attributedMilliwattHours += incoming.attributedMilliwattHours
        merged.lastSeen = max(merged.lastSeen, incoming.lastSeen)
        return merged
    }

    private static func normalizedParentBundleID(_ bundleID: String) -> String? {
        guard !bundleID.isEmpty else { return nil }
        let markers = [".helper", ".Helper", ".renderer", ".Renderer", ".gpu", ".GPU"]
        for marker in markers {
            if let range = bundleID.range(of: marker) {
                return String(bundleID[..<range.lowerBound])
            }
        }
        return nil
    }

    private static func identity(
        name: String,
        bundleIdentifier: String,
        preferredURL: URL?
    ) -> CanonicalAppIdentity {
        CanonicalAppIdentity(
            name: name,
            bundleIdentifier: bundleIdentifier,
            applicationPath: preferredURL?.path
        )
    }

    private static func displayName(at appURL: URL) -> String {
        bundleDisplayName(bundle: Bundle(url: appURL), appURL: appURL)
    }

    private static func bundleDisplayName(bundle: Bundle?, appURL: URL) -> String {
        bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? appURL.deletingPathExtension().lastPathComponent
    }

    private static func nearestInstalledApplication(for executableURL: URL) -> URL? {
        let components = executableURL.standardizedFileURL.pathComponents
        guard let appIndex = components.firstIndex(where: { $0.lowercased().hasSuffix(".app") }) else {
            return nil
        }
        var path = NSString.path(withComponents: Array(components.prefix(appIndex + 1)))
        if !path.hasPrefix("/") { path = "/" + path }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}

enum AppIconProvider {
    static func icon(for record: AppEnergyRecord) -> NSImage {
        if let path = record.applicationPath,
           FileManager.default.fileExists(atPath: path) {
            return NSWorkspace.shared.icon(forFile: path)
        }

        if let bundleID = record.bundleIdentifier,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }

        return NSImage(systemSymbolName: "app.fill", accessibilityDescription: record.name)
            ?? NSImage(size: NSSize(width: 32, height: 32))
    }
}
