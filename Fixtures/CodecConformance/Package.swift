// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "ImageCraftCodecConformanceFixture",
    platforms: [.macOS(.v12)],
    products: [
        .library(
            name: "ImageCraftCodecConformanceFixture",
            targets: ["ImageCraftCodecConformanceFixture"]
        )
    ],
    dependencies: [
        .package(name: "ImageCraft", path: "../..")
    ],
    targets: [
        .target(
            name: "ImageCraftCodecConformanceFixture",
            dependencies: [
                .product(name: "ImageCraftCore", package: "ImageCraft"),
                .product(name: "ImageCraftImageIO", package: "ImageCraft"),
            ]
        )
    ]
)
