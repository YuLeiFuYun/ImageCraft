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
        .library(name: "ImageCraftPDF", targets: ["ImageCraftPDF"]),
        .library(name: "ImageCraftSVG", targets: ["ImageCraftSVG"]),
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
        .target(
            name: "ImageCraftPDF",
            dependencies: ["ImageCraftCore"],
            swiftSettings: concurrencySettings
        ),
        .target(
            name: "ImageCraftSVG",
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
        .testTarget(
            name: "ImageCraftPDFTests",
            dependencies: ["ImageCraftCore", "ImageCraftPDF"],
            swiftSettings: concurrencySettings
        ),
        .testTarget(
            name: "ImageCraftSVGTests",
            dependencies: ["ImageCraftCore", "ImageCraftSVG"],
            swiftSettings: concurrencySettings
        ),
    ]
)
