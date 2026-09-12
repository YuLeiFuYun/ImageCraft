// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "ImageCraftPackedRGB8ConformanceFixture",
    platforms: [.macOS(.v12)],
    products: [
        .library(
            name: "ImageCraftPackedRGB8ConformanceFixture",
            targets: ["ImageCraftPackedRGB8ConformanceFixture"]
        )
    ],
    dependencies: [
        .package(name: "ImageCraft", path: "../..")
    ],
    targets: [
        .target(
            name: "ImageCraftPackedRGB8ConformanceFixture",
            dependencies: [
                .product(name: "ImageCraftCore", package: "ImageCraft"),
                .product(name: "ImageCraftImageIO", package: "ImageCraft"),
            ]
        )
    ]
)
