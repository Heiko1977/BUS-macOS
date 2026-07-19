import Foundation

/// A compact, local-only record of an observed charging window. The rate is
/// stored in battery percent per hour so it remains useful after a battery's
/// reported capacity changes slightly with age.
struct ChargeLearningSample: Codable, Hashable {
    let date: Date
    let modelIdentifier: String
    let sourcePowerBucketWatts: Int
    let segment: Int
    let displayIsActive: Bool?
    let percentPerHour: Double
}

struct ChargeLearningStore {
    private let directory: URL
    private let url: URL

    init() {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        directory = base.appendingPathComponent("BUS", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        url = directory.appendingPathComponent("charge-learning.json")
    }

    func load() -> [ChargeLearningSample] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([ChargeLearningSample].self, from: data)) ?? []
    }

    func save(_ samples: [ChargeLearningSample]) {
        guard let data = try? JSONEncoder().encode(samples) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func delete() {
        try? FileManager.default.removeItem(at: url)
    }
}
