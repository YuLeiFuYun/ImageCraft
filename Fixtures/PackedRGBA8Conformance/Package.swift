// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "ImageCraftPackedRGBA8ConformanceFixture",
    platforms: [.macOS(.v12)],
    products: [
        .library(
            name: "ImageCraftPackedRGBA8ConformanceFixture",
            targets: ["ImageCraftPackedRGBA8ConformanceFixture"]
        )
    ],
    dependencies: [
        .package(name: "ImageCraft", path: "../..")
    ],
    targets: [
        .target(
            name: "ImageCraftPackedRGBA8ConformanceFixture",
            dependencies: [
                .product(name: "ImageCraftCore", package: "ImageCraft"),
                .product(name: "ImageCraftImageIO", package: "ImageCraft"),
            ]
        )
    ]
)
