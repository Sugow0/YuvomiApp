// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "YuvomiKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "YuvomiKit", targets: ["YuvomiKit"]),
    ],
    targets: [
        .target(name: "YuvomiKit"),
        .testTarget(name: "YuvomiKitTests", dependencies: ["YuvomiKit"]),
    ]
)
