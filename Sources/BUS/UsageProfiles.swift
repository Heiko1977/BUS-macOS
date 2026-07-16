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
}

struct UsageProfileDetection {
    let kind: UsageProfileKind
    let confidence: Double
}

enum UsageProfileDetector {
    static func detect(from records: [AppEnergyRecord]) -> UsageProfileDetection {
        let active = records.filter {
            Date().timeIntervalSince($0.lastSeen) <= 10 * 60
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

            let weight = max(0.1, record.score)

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

            add(
                .gaming,
                weight: weight,
                when: contains(
                    haystack,
                    [
                        "steam", "epic games", "battle.net", "wine",
                        "whisky", "crossover", "game"
                    ]
                ),
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
        }

        let ranked = scores.sorted { $0.value > $1.value }
        guard let winner = ranked.first else {
            return UsageProfileDetection(kind: .mixed, confidence: 0.25)
        }

        let total = max(0.001, ranked.reduce(0) { $0 + $1.value })
        let confidence = min(1, winner.value / total)

        if confidence < 0.42 {
            return UsageProfileDetection(kind: .mixed, confidence: confidence)
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
