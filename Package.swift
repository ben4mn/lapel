// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LapelKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LapelKit", targets: ["LapelKit"])
    ],
    targets: [
        .target(name: "LapelKit"),
        .testTarget(name: "LapelKitTests", dependencies: ["LapelKit"])
    ]
)
