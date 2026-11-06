// swift-tools-version: 5.9
// MGBLE — the WHOOP 5/MG strap link (ARCHITECTURE §4.4, WP-04). Ported from noop's BLE manager, not copied
// (D3): only the sanctioned command set exists here (§4.4.3). Depends on MGDomain (ports, records) and the
// WhoopProtocol copy (framing, CRC, decoders). No third-party dependencies (R2).
import PackageDescription

let package = Package(
    name: "MGBLE",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "MGBLE", targets: ["MGBLE"])],
    dependencies: [
        .package(path: "../MGDomain"),
        .package(path: "../WhoopProtocol"),
    ],
    targets: [
        .target(
            name: "MGBLE",
            dependencies: [
                .product(name: "MGDomain", package: "MGDomain"),
                .product(name: "WhoopProtocol", package: "WhoopProtocol"),
            ]
        ),
    ]
)
