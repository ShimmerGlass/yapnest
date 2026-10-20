// swift-tools-version:6.0

import PackageDescription

let package = Package(
    name: "YapnestKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "YapnestKit", targets: ["YapnestKit"]),
        // Apart from YapnestKit so the extensions don't load WebRTC.
        .library(name: "YapnestCallMedia", targets: ["YapnestCallMedia"]),
    ],
    dependencies: [
        // Our own copies, with fixes upstream doesn't have (Vendor/README.md).
        .package(path: "../../Vendor/Martin"),
        .package(path: "../../Vendor/MartinOMEMO"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.9.0"),
        .package(url: "https://github.com/stasel/WebRTC", exact: "154.0.0"),
    ],
    targets: [
        .target(
            name: "YapnestKit",
            dependencies: [
                .product(name: "Martin", package: "Martin"),
                .product(name: "MartinOMEMO", package: "MartinOMEMO"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            // GitHub's gemoji shortcodes; the folder carries its licence.
            resources: [.copy("Resources/Emoji")],
        ),
        .target(
            name: "YapnestCallMedia",
            dependencies: [
                "YapnestKit",
                .product(name: "WebRTC", package: "WebRTC"),
            ],
        ),
        .testTarget(
            name: "YapnestCallMediaTests",
            dependencies: ["YapnestCallMedia", "YapnestKit", .product(name: "WebRTC", package: "WebRTC")],
        ),
        .testTarget(
            name: "YapnestKitTests",
            // WebRTC is linked here only for the live tests of real calls.
            dependencies: ["YapnestKit", "YapnestCallMedia"],
        ),
    ],
)
