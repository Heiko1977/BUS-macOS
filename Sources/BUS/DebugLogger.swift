import Foundation

enum DebugLogPreferenceKey {
    static let enabled = "BUS.debugLoggingEnabled"
}

enum DebugLogger {
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: DebugLogPreferenceKey.enabled)
    }

    static func log(_ message: String) {
        guard isEnabled else { return }

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop")
            .appendingPathComponent("BUS-Debug.log")

        guard let data = line.data(using: .utf8) else { return }

        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                _ = try? handle.write(contentsOf: data)
                _ = try? handle.close()
            }
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }
}
