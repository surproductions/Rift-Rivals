// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RiftCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "RiftCore", targets: ["RiftCore"]),
        .executable(name: "riftsim", targets: ["riftsim"]),
    ],
    targets: [
        .target(name: "RiftCore", path: "Sources/RiftCore",
                linkerSettings: [.linkedLibrary("m", .when(platforms: [.linux]))]),
        .executableTarget(name: "riftsim", dependencies: ["RiftCore"], path: "Sources/riftsim"),
        .testTarget(name: "RiftCoreTests", dependencies: ["RiftCore"], path: "Tests/RiftCoreTests"),
    ]
)
