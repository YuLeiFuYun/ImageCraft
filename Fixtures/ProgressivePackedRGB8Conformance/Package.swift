// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "ImageCraftProgressivePackedRGB8ConformanceFixture",
    platforms: [.macOS(.v12)],
    products: [
        .library(
            name: "ImageCraftProgressivePackedRGB8ConformanceFixture",
            targets: ["ImageCraftProgressivePackedRGB8ConformanceFixture"]
        )
    ],
    dependencies: [
        .package(name: "ImageCraft", path: "../..")
    ],
    targets: [
        .target(
            name: "ImageCraftProgressivePackedRGB8ConformanceFixture",
            dependencies: [
                .product(name: "ImageCraftCore", package: "ImageCraft"),
                .product(name: "ImageCraftImageIO", package: "ImageCraft"),
            ]
        )
    ]
)
