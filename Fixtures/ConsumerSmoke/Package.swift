// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "ImageCraftConsumerSmoke",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        .library(
            name: "ImageCraftConsumerSmoke",
            targets: ["ImageCraftConsumerSmoke"]
        ),
    ],
    dependencies: [
        .package(name: "ImageCraft", path: "../.."),
    ],
    targets: [
        .target(
            name: "ImageCraftConsumerSmoke",
            dependencies: [
                .product(name: "ImageCraftCore", package: "ImageCraft"),
                .product(name: "ImageCraftImageIO", package: "ImageCraft"),
            ]
        ),
        .testTarget(
            name: "ImageCraftConsumerSmokeTests",
            dependencies: [
                "ImageCraftConsumerSmoke",
                .product(name: "ImageCraftCore", package: "ImageCraft"),
                .product(name: "ImageCraftImageIO", package: "ImageCraft"),
            ],
            resources: [.copy("Resources/jpeg-progressive-420.jpg")]
        ),
    ]
)
