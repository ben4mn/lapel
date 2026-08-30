// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LapelKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LapelKit", targets: ["LapelKit"]),
        .executable(name: "lapel-probe", targets: ["lapel-probe"]),
    ],
    targets: [
        .target(name: "LapelKit"),
        .executableTarget(name: "lapel-probe", dependencies: ["LapelKit"]),
        .testTarget(name: "LapelKitTests", dependencies: ["LapelKit"])
    ]
)
