import Foundation

struct HardwareDetails: Codable, Equatable {
    var gpuName: String
    var gpuCoreCount: Int?
    var cachedAt: Date

    var gpuCoreDescription: String {
        gpuCoreCount.map { "\($0) Kerne" } ?? "Nicht verfügbar"
    }
}

enum HardwareProfileStore {
    private static let fileURL = URL(
        fileURLWithPath:
            "/Library/Application Support/BUS/hardware-profile.json"
    )

    static func load() -> HardwareDetails? {
        guard let data = try? Data(contentsOf: fileURL),
              let details = try? JSONDecoder().decode(
                HardwareDetails.self,
                from: data
              ) else {
            return nil
        }
        return details
    }

    static func save(_ details: HardwareDetails) {
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        guard let data = try? JSONEncoder().encode(details) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }
}

