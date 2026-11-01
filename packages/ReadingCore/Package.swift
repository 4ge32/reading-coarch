// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ReadingCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "ReadingCore", targets: ["ReadingCore"])],
    targets: [
        .target(name: "ReadingCore"),
        .testTarget(name: "ReadingCoreTests", dependencies: ["ReadingCore"])
    ]
)
