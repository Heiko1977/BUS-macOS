import AppKit
import Foundation
import SwiftUI

enum UsageProfileKind: String, CaseIterable, Codable, Identifiable {
    case automatic
    case office
    case browser
    case developer
    case creative
    case video
    case gaming
    case audio
    case mixed

    var id: String { rawValue }

    var titleKey: String {
        "profile.\(rawValue).title"
    }

    var descriptionKey: String {
        "profile.\(rawValue).description"
    }

    var icon: String {
        switch self {
        case .automatic: return "wand.and.stars"
        case .office: return "briefcase.fill"
        case .browser: return "globe"
        case .developer: return "chevron.left.forwardslash.chevron.right"
        case .creative: return "paintpalette.fill"
        case .video: return "play.rectangle.fill"
        case .gaming: return "gamecontroller.fill"
        case .audio: return "music.note"
        case .mixed: return "square.stack.3d.up.fill"
        }
    }

    var referenceMultiplier: Double {
        switch self {
        case .automatic: return 1.00
        case .office: return 0.86
        case .browser: return 0.79
        case .developer: return 0.60
        case .creative: return 0.47
        case .video: return 0.43
        case .gaming: return 0.29
        case .audio: return 0.64
        case .mixed: return 0.69
        }
    }

    var accent: Color {
        switch self {
        case .automatic: return .gray
        case .office: return .orange
        case .browser: return .purple
        case .developer: return .indigo
        case .creative: return .pink
        case .video: return .red
        case .gaming: return .green
        case .audio: return .purple
        case .mixed: return .blue
        }
    }

    func gpuHardwareMultiplier(gpuCoreCount: Int?) -> Double {
        guard let gpuCoreCount, gpuCoreCount > 0 else {
            return 1
        }

        switch self {
        case .creative, .video, .gaming:
            let baseline = 8.0
            let delta = Double(gpuCoreCount) - baseline
            let adjustment = delta > 0
                ? 1 - min(0.22, delta * 0.025)
                : 1 + min(0.12, abs(delta) * 0.015)
            return min(1.12, max(0.78, adjustment))
        default:
            return 1
        }
    }
}

struct UsageProfileDetection: Equatable {
    let kind: UsageProfileKind
    let confidence: Double
}

enum UsageProfileDetector {
    static func detect(from records: [AppEnergyRecord]) -> UsageProfileDetection {
        let now = Date.now
        let active = records.filter {
            now.timeIntervalSince($0.lastSeen) <= 3 * 60
        }

        guard !active.isEmpty else {
            return UsageProfileDetection(kind: .mixed, confidence: 0)
        }

        var scores: [UsageProfileKind: Double] = [:]

        for record in active {
            let haystack = [
                record.name,
                record.bundleIdentifier ?? "",
                record.sortedProcesses.map(\.name).joined(separator: " ")
            ]
            .joined(separator: " ")
            .lowercased()

            let age = max(0, now.timeIntervalSince(record.lastSeen))
            let recency = max(0.2, 1 - age / (3 * 60))
            let foregroundSeen = record.activityStates?[.foreground]?.lastSeen
            let foregroundBoost = foregroundSeen.map {
                now.timeIntervalSince($0) <= 30 ? 1.35 : 1.0
            } ?? 1.0
            let weight = max(0.1, record.score) * recency * foregroundBoost

            let runningProcessNames = record.sortedProcesses.compactMap { process -> String? in
                guard let running = NSRunningApplication(
                    processIdentifier: pid_t(process.pid)
                ) else { return nil }
                return running.localizedName ?? process.name
            }

            add(
                .browser,
                weight: weight,
                when: contains(
                    haystack,
                    [
                        "safari", "chrome", "brave", "firefox", "webkit",
                        "edge", "vivaldi", "opera"
                    ]
                ),
                to: &scores
            )

            add(
                .developer,
                weight: weight,
                when: contains(
                    haystack,
                    [
                        "xcode", "swift", "sourcekit", "terminal", "iterm",
                        "visual studio code", "vscode", "docker", "simulator",
                        "jetbrains", "github desktop", "git", "clang"
                    ]
                ),
                to: &scores
            )

            add(
                .office,
                weight: weight,
                when: contains(
                    haystack,
                    [
                        "mail", "outlook", "word", "excel", "powerpoint",
                        "pages", "numbers", "keynote", "notes", "calendar",
                        "teams", "slack"
                    ]
                ),
                to: &scores
            )

            add(
                .creative,
                weight: weight,
                when: contains(
                    haystack,
                    [
                        "photoshop", "lightroom", "affinity", "illustrator",
                        "blender", "pixelmator", "capture one", "figma"
                    ]
                ),
                to: &scores
            )

            add(
                .video,
                weight: weight,
                when: contains(
                    haystack,
                    [
                        "final cut", "davinci", "premiere", "compressor",
                        "handbrake", "after effects", "media encoder"
                    ]
                ),
                to: &scores
            )

            // A launcher is not a game. Steam, Epic or Battle.net may remain
            // open for hours after the actual game has quit. Only count a
            // gaming signal when the corresponding process is still running.
            let gamingTerms = [
                "steamapps", "wine", "whisky", "crossover",
                "unityplayer", "unrealengine", "godot"
            ]
            let directGamingSignal = contains(haystack, gamingTerms)
            let gamingLauncherOnly = contains(
                haystack,
                [
                    "steam", "steamwebhelper", "epic games", "battle.net",
                    "blizzard", "origin", "ubisoft connect"
                ]
            ) && !directGamingSignal
            let gamingProcessStillRunning = record.sortedProcesses.contains {
                guard contains($0.name.lowercased(), gamingTerms) else {
                    return false
                }
                guard let running = NSRunningApplication(
                    processIdentifier: pid_t($0.pid)
                ) else { return false }
                guard let runningName = running.localizedName else { return false }
                return runningName.caseInsensitiveCompare($0.name) == .orderedSame
            }
            // Unknown game titles still count when their own process is live;
            // launcher-only records remain excluded.
            // AppEnergyRecord keeps recently observed process names for
            // attribution. Those names must not be treated as live evidence:
            // a game can have exited while its record is still within the
            // profile look-back window. Require a matching running process
            // for every gaming signal (including direct game/runtime names).
            let gamingSignal = gamingProcessStillRunning
                && (directGamingSignal || !gamingLauncherOnly)

            add(
                .gaming,
                weight: weight,
                when: gamingSignal && !gamingLauncherOnly,
                to: &scores
            )

            add(
                .audio,
                weight: weight,
                when: contains(
                    haystack,
                    [
                        "logic", "ableton", "cubase", "studio one",
                        "reaper", "garageband", "pro tools", "audacity",
                        "mairlist"
                    ]
                ),
                to: &scores
            )

            if DebugLogger.isEnabled {
                let matched = scores
                    .filter { $0.value > 0 }
                    .map { "\($0.key.rawValue)=\(String(format: "%.2f", $0.value))" }
                    .sorted()
                    .joined(separator: ",")
                DebugLogger.log(
                    "profile candidate app=\(record.name) "
                    + "bundle=\(record.bundleIdentifier ?? "-") "
                    + "running=[\(runningProcessNames.joined(separator: ","))] "
                    + "gamingProcessRunning=\(gamingProcessStillRunning) "
                    + "scores=[\(matched)]"
                )
            }
        }

        let ranked = scores.sorted { $0.value > $1.value }
        guard let winner = ranked.first else {
            if DebugLogger.isEnabled {
                DebugLogger.log("profile result kind=mixed confidence=0.000 (no matching signals)")
            }
            return UsageProfileDetection(kind: .mixed, confidence: 0.25)
        }

        let total = max(0.001, ranked.reduce(0) { $0 + $1.value })
        let confidence = min(1, winner.value / total)

        if confidence < 0.42 {
            if DebugLogger.isEnabled {
                DebugLogger.log(
                    "profile result kind=mixed confidence="
                    + String(format: "%.3f", confidence)
                )
            }
            return UsageProfileDetection(kind: .mixed, confidence: confidence)
        }

        if DebugLogger.isEnabled {
            DebugLogger.log(
                "profile result kind=\(winner.key.rawValue) confidence="
                + String(format: "%.3f", confidence)
            )
        }

        return UsageProfileDetection(kind: winner.key, confidence: confidence)
    }

    private static func contains(
        _ haystack: String,
        _ terms: [String]
    ) -> Bool {
        terms.contains { haystack.contains($0) }
    }

    private static func add(
        _ profile: UsageProfileKind,
        weight: Double,
        when condition: Bool,
        to scores: inout [UsageProfileKind: Double]
    ) {
        guard condition else { return }
        scores[profile, default: 0] += weight
    }
}
