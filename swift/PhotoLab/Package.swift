// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PhotoLab",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PhotoLabCore", targets: ["PhotoLabCore"]),
        .executable(name: "photolab-render", targets: ["photolab-render"]),
        .executable(name: "PhotoLab", targets: ["PhotoLabApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .target(name: "PhotoLabCore"),
        .executableTarget(name: "photolab-render", dependencies: ["PhotoLabCore"]),
        .testTarget(name: "PhotoLabCoreTests", dependencies: ["PhotoLabCore"]),
        .executableTarget(name: "PhotoLabApp", dependencies: ["PhotoLabCore", .product(name: "Sparkle", package: "Sparkle")], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
