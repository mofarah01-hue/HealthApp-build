// swift-tools-version: 5.9
// MGSignal — phone-tier signal maths and pipelines (ARCHITECTURE.md 4.6, 8). WP-08 owns this file, Core/ and HRV/.
// The target is the WHOLE Sources/MGSignal folder, so the other builders' folders (Cardio/, Resp/, Stats/, Sleep/,
// SleepLive/, Day/, Behaviour/, Script/, Pipelines/) and their test folders under Tests/MGSignalTests/ compile without
// touching this file. Each family's README.md is listed in `exclude` below (approved by main); a new non-Swift file
// elsewhere only raises SwiftPM's "unhandled file" warning — ask `main` to add it.
//
// `swift test --package-path app/ios/Packages/MGSignal` runs on a Mac (macOS 14). The golden tests read
// app/shared/golden/ and app/shared/fixtures/ in place via #filePath (no copies in the package).
import PackageDescription

let package = Package(
    name: "MGSignal",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "MGSignal", targets: ["MGSignal"]),
    ],
    dependencies: [
        .package(path: "../MGDomain"),
    ],
    targets: [
        .target(
            name: "MGSignal",
            dependencies: [.product(name: "MGDomain", package: "MGDomain")],
            path: "Sources/MGSignal",
            // Every family README that exists (checked 2026-10-11). SwiftPM complains about an exclude path that does
            // not exist, so add a folder here only once its README.md is in place.
            exclude: [
                "Behaviour/README.md", "Cardio/README.md", "Core/README.md", "Day/README.md", "HRV/README.md",
                "Pipelines/README.md", "Resp/README.md", "Script/README.md", "Sleep/README.md",
                "SleepLive/README.md", "Stats/README.md",
            ]
        ),
    ]
)
