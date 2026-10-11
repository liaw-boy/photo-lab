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
    targets: [
        .target(name: "PhotoLabCore"),
        .executableTarget(name: "photolab-render", dependencies: ["PhotoLabCore"]),
        .testTarget(name: "PhotoLabCoreTests", dependencies: ["PhotoLabCore"]),
        .executableTarget(name: "PhotoLabApp", dependencies: ["PhotoLabCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
