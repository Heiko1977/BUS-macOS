import Foundation

struct RuntimeStatisticsStore {
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
        url = directory.appendingPathComponent("runtime-sessions.json")
    }

    func load() -> RuntimeStatistics {
        guard let data = try? Data(contentsOf: url),
              let statistics = try? JSONDecoder().decode(
                RuntimeStatistics.self,
                from: data
              ) else {
            return .empty
        }
        return statistics
    }

    func save(_ statistics: RuntimeStatistics) {
        guard let data = try? JSONEncoder().encode(statistics) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func delete() {
        try? FileManager.default.removeItem(at: url)
    }
}
