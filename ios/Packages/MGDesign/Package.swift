// swift-tools-version: 5.9
// MGDesign — tokens, themes, typography and shared components (ARCHITECTURE §4.8, owner WP-07).
// UI package: iOS only (ARCHITECTURE R2 exempts UI packages from the macOS host platform).
import PackageDescription

let package = Package(
    name: "MGDesign",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "MGDesign", targets: ["MGDesign"]),
    ],
    dependencies: [
        .package(path: "../MGContext"),
        .package(path: "../MGDomain"),
    ],
    targets: [
        .target(
            name: "MGDesign",
            dependencies: [
                .product(name: "MGContext", package: "MGContext"),
                .product(name: "MGDomain", package: "MGDomain"),
            ],
            path: "Sources/MGDesign"
        ),
    ]
)
