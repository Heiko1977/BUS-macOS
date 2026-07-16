import Darwin
import Foundation

enum DeviceProfileDatabase {
    static let current: DeviceProfile = {
        let identifier = sysctlString("hw.model") ?? "UnknownMac"
        return profiles[identifier] ?? DeviceProfile(
            modelIdentifier: identifier,
            displayName: identifier,
            batteryWattHours: nil,
            manufacturerWebHours: nil,
            manufacturerVideoHours: nil
        )
    }()

    static var processorDescription: String {
        if let brand = sysctlString("machdep.cpu.brand_string"), !brand.isEmpty {
            return brand
        }
        return sysctlString("hw.optional.arm64") == "1" ? "Apple Silicon" : "Mac-Prozessor"
    }

    static var memoryDescription: String {
        var bytes: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname("hw.memsize", &bytes, &size, nil, 0) == 0 else { return "–" }
        return String(format: "%.0f GB", Double(bytes) / 1_073_741_824)
    }

    static var coreDescription: String {
        var cores: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("hw.ncpu", &cores, &size, nil, 0) == 0 else { return "–" }
        return "\(cores) Kerne"
    }

    // Safe placeholder used until the background system_profiler query returns.
    static let gpuDetails: (name: String, cores: String) = (
        "Integrierte Apple GPU",
        "Nicht verfügbar"
    )

    static func readGPUDetails() -> (name: String, cores: String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPDisplaysDataType", "-json"]
        process.standardOutput = output
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let object = try? JSONSerialization.jsonObject(
                    with: output.fileHandleForReading.readDataToEndOfFile()
                  ) else { return gpuDetails }
            let name = firstValue(in: object, matching: ["sppci_model", "chipset-model", "spdisplays_device-name"]) ?? gpuDetails.name
            let cores = firstValue(in: object, matching: ["sppci_cores", "spdisplays_gpun-core-count", "gpu-core-count"]) ?? gpuDetails.cores
            return (name, cores == "–" ? cores : "\(cores) Kerne")
        } catch {
            return gpuDetails
        }
    }

    // Initial local reference set. Values use Apple's published maximum
    // wireless-web and video-playback specifications for these model families.
    private static let profiles: [String: DeviceProfile] = [
        "MacBookAir10,1": DeviceProfile(
            modelIdentifier: "MacBookAir10,1",
            displayName: "MacBook Air (M1, 2020)",
            batteryWattHours: 49.9,
            manufacturerWebHours: 15,
            manufacturerVideoHours: 18
        ),
        "MacBookPro17,1": DeviceProfile(
            modelIdentifier: "MacBookPro17,1",
            displayName: "MacBook Pro 13″ (M1, 2020)",
            batteryWattHours: 58.2,
            manufacturerWebHours: 17,
            manufacturerVideoHours: 20
        ),
        "MacBookPro18,3": DeviceProfile(
            modelIdentifier: "MacBookPro18,3",
            displayName: "MacBook Pro 14″ (2021)",
            batteryWattHours: 70,
            manufacturerWebHours: 11,
            manufacturerVideoHours: 17
        ),
        "MacBookPro18,4": DeviceProfile(
            modelIdentifier: "MacBookPro18,4",
            displayName: "MacBook Pro 14″ (2021)",
            batteryWattHours: 70,
            manufacturerWebHours: 11,
            manufacturerVideoHours: 17
        ),
        "MacBookPro18,1": DeviceProfile(
            modelIdentifier: "MacBookPro18,1",
            displayName: "MacBook Pro 16″ (2021)",
            batteryWattHours: 100,
            manufacturerWebHours: 14,
            manufacturerVideoHours: 21
        ),
        "MacBookPro18,2": DeviceProfile(
            modelIdentifier: "MacBookPro18,2",
            displayName: "MacBook Pro 16″ (2021)",
            batteryWattHours: 100,
            manufacturerWebHours: 14,
            manufacturerVideoHours: 21
        ),
        "Mac14,2": DeviceProfile(
            modelIdentifier: "Mac14,2",
            displayName: "MacBook Air 13″ (M2, 2022)",
            batteryWattHours: 52.6,
            manufacturerWebHours: 15,
            manufacturerVideoHours: 18
        ),
        "Mac14,15": DeviceProfile(
            modelIdentifier: "Mac14,15",
            displayName: "MacBook Air 15″ (M2, 2023)",
            batteryWattHours: 66.5,
            manufacturerWebHours: 15,
            manufacturerVideoHours: 18
        ),
        "Mac15,3": DeviceProfile(
            modelIdentifier: "Mac15,3",
            displayName: "MacBook Pro 14″ (M3, 2023)",
            batteryWattHours: 70,
            manufacturerWebHours: 15,
            manufacturerVideoHours: 22
        ),
        "Mac15,6": DeviceProfile(
            modelIdentifier: "Mac15,6",
            displayName: "MacBook Pro 14″ (M3 Pro/Max, 2023)",
            batteryWattHours: 72.4,
            manufacturerWebHours: 12,
            manufacturerVideoHours: 18
        ),
        "Mac15,8": DeviceProfile(
            modelIdentifier: "Mac15,8",
            displayName: "MacBook Pro 16″ (M3 Pro/Max, 2023)",
            batteryWattHours: 100,
            manufacturerWebHours: 15,
            manufacturerVideoHours: 22
        )
    ]

    private static func sysctlString(_ name: String) -> String? {
        var size: size_t = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else {
            return nil
        }
        return String(cString: buffer)
    }

    private static func firstValue(in value: Any, matching keys: [String]) -> String? {
        if let dictionary = value as? [String: Any] {
            for key in keys {
                if let result = dictionary[key] as? String, !result.isEmpty { return result }
                if let result = dictionary[key] as? NSNumber { return result.stringValue }
            }
            for child in dictionary.values {
                if let result = firstValue(in: child, matching: keys) { return result }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let result = firstValue(in: child, matching: keys) { return result }
            }
        }
        return nil
    }

}
