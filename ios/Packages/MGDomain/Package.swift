// swift-tools-version: 5.9
// MGDomain: contract models, ids, JSON coding and cross-module ports (ARCHITECTURE.md 4.3). No dependencies.
// `swift test --package-path app/ios/Packages/MGDomain` runs on a Mac (macOS 14); the tests read
// app/shared/fixtures/ in place.
import PackageDescription

let package = Package(
    name: "MGDomain",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "MGDomain", targets: ["MGDomain"]),
    ],
    targets: [
        .target(name: "MGDomain"),
    ]
)
