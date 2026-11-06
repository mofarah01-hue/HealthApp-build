// swift-tools-version: 5.9
// MGStore — the app's durable store (ARCHITECTURE §4.5, WP-05). GRDB is the only third-party dependency,
// pinned EXACT (R2; same pin as noop:Packages/WhoopStore/Package.swift and app/ios/project.yml).
import PackageDescription

let package = Package(
    name: "MGStore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "MGStore", targets: ["MGStore"])],
    dependencies: [
        .package(path: "../MGDomain"),
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "6.29.3"),
    ],
    targets: [
        .target(
            name: "MGStore",
            dependencies: [
                .product(name: "MGDomain", package: "MGDomain"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
    ]
)
