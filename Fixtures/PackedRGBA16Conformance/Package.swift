// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "ImageCraftPackedRGBA16ConformanceFixture",
    platforms: [.macOS(.v12)],
    products: [
        .library(
            name: "ImageCraftPackedRGBA16ConformanceFixture",
            targets: ["ImageCraftPackedRGBA16ConformanceFixture"]
        )
    ],
    dependencies: [
        .package(name: "ImageCraft", path: "../..")
    ],
    targets: [
        .target(
            name: "ImageCraftPackedRGBA16ConformanceFixture",
            dependencies: [
                .product(name: "ImageCraftCore", package: "ImageCraft"),
                .product(name: "ImageCraftImageIO", package: "ImageCraft"),
            ]
        )
    ]
)
