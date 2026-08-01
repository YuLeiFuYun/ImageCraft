// swift-tools-version: 6.4
import PackageDescription

let concurrencySettings: [SwiftSetting] = [
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let package = Package(
    name: "ImageCraft",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        .library(name: "ImageCraftCore", targets: ["ImageCraftCore"]),
        .library(name: "ImageCraftImageIO", targets: ["ImageCraftImageIO"]),
        .executable(name: "ImageCraftEvidence", targets: ["ImageCraftEvidence"]),
    ],
    targets: [
        .target(
            name: "ImageCraftCore",
            swiftSettings: concurrencySettings
        ),
        .target(
            name: "ImageCraftImageIO",
            dependencies: ["ImageCraftCore"],
            swiftSettings: concurrencySettings
        ),
        .executableTarget(
            name: "ImageCraftEvidence",
            dependencies: ["ImageCraftCore", "ImageCraftImageIO"],
            swiftSettings: concurrencySettings
        ),
        .testTarget(
            name: "ImageCraftCoreTests",
            dependencies: ["ImageCraftCore"],
            swiftSettings: concurrencySettings
        ),
        .testTarget(
            name: "ImageCraftImageIOTests",
            dependencies: ["ImageCraftCore", "ImageCraftImageIO"],
            resources: [.copy("Resources/Corpus")],
            swiftSettings: concurrencySettings
        ),
    ]
)
