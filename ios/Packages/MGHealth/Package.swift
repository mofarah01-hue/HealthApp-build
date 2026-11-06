// swift-tools-version: 5.9
// MGHealth — Apple Health in and out (ARCHITECTURE §4.10, WP-14; PLAN §3.1, APP-110/111).
// - READ: Health samples become `healthkit` events (BP correlations become `bp_cuff` events); this app's own samples
//   are never read back.
// - MIRROR (off by default, D12): measured or directly derived values only, labelled with an HKDevice "WHOOP MG".
// All decisions live in plain Swift that compiles and tests on a Mac; the HealthKit calls are a thin layer behind
// `#if canImport(HealthKit) && os(iOS)`. Depends on MGDomain only (ports, EventRecord). No third-party dependencies (R2).
// `swift test --package-path app/ios/Packages/MGHealth` runs on a Mac (macOS 14).
import PackageDescription

let package = Package(
    name: "MGHealth",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "MGHealth", targets: ["MGHealth"])],
    dependencies: [
        .package(path: "../MGDomain"),
    ],
    targets: [
        .target(
            name: "MGHealth",
            dependencies: [
                .product(name: "MGDomain", package: "MGDomain"),
            ]
        ),
    ]
)
