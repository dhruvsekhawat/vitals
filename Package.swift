// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Vitals",
    platforms: [.macOS(.v14)],
    targets: [
        // Everything that can be unit-tested lives here: sampling, rules, history, remedies.
        // No SwiftUI, no notifications, no process-wide side effects at import time.
        .target(
            name: "VitalsCore",
            path: "Sources/VitalsCore",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .executableTarget(
            name: "Vitals",
            dependencies: ["VitalsCore"],
            path: "Sources/Vitals",
            linkerSettings: [
                .linkedFramework("UserNotifications"),
            ]
        ),
        .testTarget(
            name: "VitalsCoreTests",
            dependencies: ["VitalsCore"],
            path: "Tests/VitalsCoreTests"
        ),
    ]
)
