// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AIFileOrganizer",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "AIFileOrganizerCore", targets: ["AIFileOrganizerCore"]),
        .executable(name: "AIFileOrganizer", targets: ["AIFileOrganizerApp"]),
        .executable(name: "AIFileOrganizerChecks", targets: ["AIFileOrganizerChecks"]),
    ],
    dependencies: [
        // 7.6.1 is the newest release that also builds with the fallback macOS 15.4 SDK
        // bundled beside the currently mismatched macOS 26 command-line SDK.
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.6.1"),
    ],
    targets: [
        .target(
            name: "AIFileOrganizerCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            linkerSettings: [
                .linkedFramework("PDFKit"),
                .linkedFramework("Vision"),
                .linkedFramework("UniformTypeIdentifiers"),
            ]
        ),
        .executableTarget(
            name: "AIFileOrganizerApp",
            dependencies: ["AIFileOrganizerCore"],
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit"),
                .linkedFramework("QuickLookUI"),
                .linkedFramework("QuickLookThumbnailing"),
            ]
        ),
        .executableTarget(
            name: "AIFileOrganizerChecks",
            dependencies: ["AIFileOrganizerCore"]
        ),
        .testTarget(
            name: "AIFileOrganizerCoreTests",
            dependencies: ["AIFileOrganizerCore"]
        ),
    ]
)
