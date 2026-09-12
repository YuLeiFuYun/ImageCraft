// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "LimitedCodecConformanceFixture",
    platforms: [.macOS(.v12)],
    products: [
        .library(
            name: "LimitedCodecConformanceFixture",
            targets: ["LimitedCodecConformanceFixture"]
        )
    ],
    dependencies: [
        .package(name: "ImageCraft", path: "../.."),
    ],
    targets: [
        .target(
            name: "LimitedCodecConformanceFixture",
            dependencies: [
                .product(name: "ImageCraftCore", package: "ImageCraft"),
                .product(name: "ImageCraftImageIO", package: "ImageCraft"),
            ]
        )
    ]
)
