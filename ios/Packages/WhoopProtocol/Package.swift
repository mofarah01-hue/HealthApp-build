// swift-tools-version: 5.9
// Copied from ryanbr/noop @ e580175 Packages/WhoopProtocol/Package.swift. PolyForm Noncommercial 1.0.0. Required Notice: Copyright 2026 NoopApp.
import PackageDescription

let package = Package(
    name: "WhoopProtocol",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "WhoopProtocol", targets: ["WhoopProtocol"]),
        .executable(name: "whoop-decode", targets: ["whoop-decode"]),
        .executable(name: "whoop-optical-experiment", targets: ["whoop-optical-experiment"]),
        .executable(name: "whoop-re", targets: ["whoop-re"]),
    ],
    targets: [
        .target(
            name: "WhoopProtocol",
            resources: [.process("Resources/whoop_protocol.json")]
        ),
        .executableTarget(
            name: "whoop-decode",
            dependencies: ["WhoopProtocol"]
        ),
        .executableTarget(
            name: "whoop-optical-experiment",
            dependencies: ["WhoopProtocol"]
        ),
        .executableTarget(
            name: "whoop-re",
            dependencies: ["WhoopProtocol"]
        ),
    ]
)
