// swift-tools-version: 5.9
// MGContext — phase + context engine, UI state, intents, formatters (ARCHITECTURE §4.7, WP-06).
// Pure Foundation + MGDomain. Presenters (Sources/MGContext/Presenters/) belong to WP-23.
import PackageDescription

let package = Package(
    name: "MGContext",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "MGContext", targets: ["MGContext"]),
    ],
    dependencies: [
        .package(path: "../MGDomain"),
    ],
    targets: [
        .target(
            name: "MGContext",
            dependencies: [.product(name: "MGDomain", package: "MGDomain")]
        ),
    ]
)
