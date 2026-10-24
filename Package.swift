// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Lucent",
    platforms: [.macOS(.v26)],          // Liquid Glass API 需要 macOS 26+，macOS 27 直接可用
    targets: [
        .executableTarget(
            name: "Lucent",
            path: "Sources/Lucent",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("SystemConfiguration"),
                .linkedLibrary("sqlite3"),
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
