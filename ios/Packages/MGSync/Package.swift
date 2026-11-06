// swift-tools-version: 5.9
// MGSync — the phone side of the PC Lab sync (ARCHITECTURE §5, WP-14). Talks to app/pclab/mglab over HTTP inside the
// Tailscale tunnel (BRIEF: route B is the default, route A HTTPS is opt-in; the app just uses the base URL from the
// pairing QR). Depends on MGDomain only (ports, contract models, MGJSON). No third-party dependencies (R2).
// `swift test --package-path app/ios/Packages/MGSync` runs on a Mac (macOS 14); the tests read app/shared/fixtures/.
import PackageDescription

let package = Package(
    name: "MGSync",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "MGSync", targets: ["MGSync"])],
    dependencies: [
        .package(path: "../MGDomain"),
    ],
    targets: [
        .target(
            name: "MGSync",
            dependencies: [
                .product(name: "MGDomain", package: "MGDomain"),
            ]
        ),
    ]
)
