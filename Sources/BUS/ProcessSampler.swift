import AppKit
import EnergySamplerBridge
import Foundation

struct AppIdentity: Hashable {
    let name: String
    let bundleIdentifier: String?
    let applicationPath: String?
}

struct ProcessIdentity: Hashable {
    let pid: Int32
    let name: String
    let bundleIdentifier: String?

    var key: String { "\(pid)|\(bundleIdentifier ?? "")|\(name)" }
}

struct ProcessCounters {
    let cpuNanoseconds: UInt64
    let diskReadBytes: UInt64
    let diskWriteBytes: UInt64
    let wakeups: UInt64
}

struct ProcessDelta {
    let app: AppIdentity
    let process: ProcessIdentity
    let activityState: AppActivityState
    let cpuSeconds: Double
    let diskReadBytes: UInt64
    let diskWriteBytes: UInt64
    let wakeups: UInt64

    var score: Double {
        Self.score(
            cpuSeconds: cpuSeconds,
            diskReadBytes: diskReadBytes,
            diskWriteBytes: diskWriteBytes,
            wakeups: wakeups
        )
    }

    static func score(
        cpuSeconds: Double,
        diskReadBytes: UInt64,
        diskWriteBytes: UInt64,
        wakeups: UInt64
    ) -> Double {
        let diskGB = Double(diskReadBytes &+ diskWriteBytes) / 1_000_000_000.0
        return max(0, cpuSeconds + diskGB * 0.35 + Double(wakeups) * 0.00045)
    }
}

final class ProcessSampler {
    private struct CachedIdentity {
        let process: ProcessIdentity
        let app: AppIdentity
    }

    private var previous: [Int32: ProcessCounters] = [:]
    private var identities: [Int32: CachedIdentity] = [:]

    func sample() -> [ProcessDelta] {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let frontmostCanonical = frontmost.map {
            appIdentity(for: $0, fallbackName: $0.localizedName ?? "")
        }
        let frontmostKey = frontmostCanonical.map {
            $0.bundleIdentifier ?? $0.name
        }

        var pids = [Int32](repeating: 0, count: 8192)
        let count = pids.withUnsafeMutableBufferPointer {
            Int(bs_list_all_pids($0.baseAddress, Int32($0.count)))
        }
        guard count > 0 else { return [] }

        var current: [Int32: ProcessCounters] = [:]
        var deltas: [ProcessDelta] = []
        deltas.reserveCapacity(count)

        for pid in pids.prefix(count) where pid > 0 {
            var usage = BSProcessUsage()
            guard bs_process_usage(pid, &usage) == 1 else { continue }

            let counters = ProcessCounters(
                cpuNanoseconds: usage.user_time_ns &+ usage.system_time_ns,
                diskReadBytes: usage.disk_read_bytes,
                diskWriteBytes: usage.disk_write_bytes,
                wakeups: usage.idle_wakeups &+ usage.interrupt_wakeups
            )
            current[pid] = counters
            guard let old = previous[pid] else { continue }

            let identity = identities[pid] ?? resolveIdentity(for: pid)
            identities[pid] = identity
            let process = identity.process
            let app = identity.app
            let appKey = app.bundleIdentifier ?? app.name
            let score = ProcessDelta.score(
                cpuSeconds: secondsDelta(counters.cpuNanoseconds, old.cpuNanoseconds),
                diskReadBytes: safeDelta(counters.diskReadBytes, old.diskReadBytes),
                diskWriteBytes: safeDelta(counters.diskWriteBytes, old.diskWriteBytes),
                wakeups: safeDelta(counters.wakeups, old.wakeups)
            )

            let delta = ProcessDelta(
                app: app,
                process: process,
                activityState: activityState(
                    appKey: appKey,
                    frontmostKey: frontmostKey,
                    score: score
                ),
                cpuSeconds: secondsDelta(counters.cpuNanoseconds, old.cpuNanoseconds),
                diskReadBytes: safeDelta(counters.diskReadBytes, old.diskReadBytes),
                diskWriteBytes: safeDelta(counters.diskWriteBytes, old.diskWriteBytes),
                wakeups: safeDelta(counters.wakeups, old.wakeups)
            )
            if delta.score > 0 { deltas.append(delta) }
        }

        previous = current
        identities = identities.filter { current[$0.key] != nil }
        return deltas
    }

    private func resolveIdentity(for pid: Int32) -> CachedIdentity {
        let running = NSRunningApplication(processIdentifier: pid_t(pid))
        let processName = running?.localizedName
            ?? processName(pid: pid)
            ?? "Prozess \(pid)"
        return CachedIdentity(
            process: ProcessIdentity(
                pid: pid,
                name: processName,
                bundleIdentifier: running?.bundleIdentifier
            ),
            app: appIdentity(for: running, fallbackName: processName)
        )
    }

    private func activityState(
        appKey: String,
        frontmostKey: String?,
        score: Double
    ) -> AppActivityState {
        if let frontmostKey, appKey == frontmostKey {
            return .foreground
        }
        return score >= 0.08 ? .backgroundActive : .backgroundIdle
    }

    private func appIdentity(for running: NSRunningApplication?, fallbackName: String) -> AppIdentity {
        let executableURL = running?.executableURL
        let detectedAppURL = executableURL.flatMap { outermostApplicationURL(containing: $0) }
        let canonical = AppGrouping.canonicalIdentity(
            processName: running?.localizedName ?? fallbackName,
            processBundleIdentifier: running?.bundleIdentifier,
            executableURL: executableURL,
            detectedAppURL: detectedAppURL
        )
        return AppIdentity(
            name: canonical.name,
            bundleIdentifier: canonical.bundleIdentifier,
            applicationPath: canonical.applicationPath
        )
    }

    private func outermostApplicationURL(containing executableURL: URL) -> URL? {
        let components = executableURL.standardizedFileURL.pathComponents
        guard let appIndex = components.firstIndex(where: { $0.lowercased().hasSuffix(".app") }) else {
            return nil
        }
        var path = NSString.path(withComponents: Array(components.prefix(appIndex + 1)))
        if !path.hasPrefix("/") { path = "/" + path }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func safeDelta(_ new: UInt64, _ old: UInt64) -> UInt64 {
        new >= old ? new - old : 0
    }

    private func secondsDelta(_ new: UInt64, _ old: UInt64) -> Double {
        Double(safeDelta(new, old)) / 1_000_000_000.0
    }

    private func processName(pid: Int32) -> String? {
        var name = [CChar](repeating: 0, count: 1024)
        let length = name.withUnsafeMutableBufferPointer {
            bs_process_name(pid, $0.baseAddress, Int32($0.count))
        }
        guard length > 0 else { return nil }
        return String(cString: name)
    }
}
