// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "kanata-bar",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "Shared",
            path: "Sources/Shared"
        ),
        .target(
            name: "KanataBarLib",
            dependencies: ["Shared"],
            path: "Sources/App",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Network"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Security"),
                .linkedFramework("UserNotifications"),
            ]
        ),
        .executableTarget(
            name: "kanata-bar",
            dependencies: ["KanataBarLib", "Shared"],
            path: "Sources/KanataBar"
        ),
        .executableTarget(
            name: "kanata-bar-helper",
            dependencies: ["Shared"],
            path: "Sources/Helper",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/helper-info.plist",
                ])
            ]
        ),
        .testTarget(
            name: "KanataBarTests",
            dependencies: ["KanataBarLib"],
            path: "Tests/KanataBarTests"
        ),
    ]
)
