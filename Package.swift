// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BUS",
    defaultLocalization: "de",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "BUS", targets: ["BUS"])
    ],
    targets: [
        .target(
            name: "EnergySamplerBridge",
            path: "Sources/EnergySamplerBridge",
            publicHeadersPath: "include",
            cSettings: [.define("_DARWIN_C_SOURCE")],
            linkerSettings: [.linkedLibrary("proc")]
        ),
        .executableTarget(
            name: "BUS",
            dependencies: ["EnergySamplerBridge"],
            path: "Sources/BUS",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("UniformTypeIdentifiers")
            ]
        )
    ],
    swiftLanguageModes: [.v5],
    cLanguageStandard: .gnu17
)
