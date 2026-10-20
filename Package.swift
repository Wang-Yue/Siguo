// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SiguoJunqi",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "SiguoCore",
            targets: ["SiguoCore"]
        ),
        .executable(
            name: "SiguoApp",
            targets: ["SiguoApp"]
        )
    ],
    targets: [
        .target(
            name: "SiguoCore",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "SiguoApp",
            dependencies: ["SiguoCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "SiguoCoreTests",
            dependencies: ["SiguoCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
