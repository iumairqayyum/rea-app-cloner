// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NeatClone", platforms: [.macOS(.v12)],
    products: [
        .library(name: "NeatCloneCore", targets: ["NeatCloneCore"]),
        .executable(name: "NeatClone", targets: ["NeatClone"]),
        .executable(name: "NeatCloneCLI", targets: ["NeatCloneCLI"]),
        .executable(name: "NeatCloneBridge", targets: ["NeatCloneBridge"])
    ],
    targets: [
        .target(name: "NeatCloneCore"),
        .executableTarget(name: "NeatClone", dependencies: ["NeatCloneCore"]),
        .executableTarget(name: "NeatCloneCLI", dependencies: ["NeatCloneCore"]),
        .executableTarget(name: "NeatCloneBridge", dependencies: ["NeatCloneCore"]),
        .testTarget(name: "NeatCloneCoreTests", dependencies: ["NeatCloneCore"]),
        .testTarget(name: "NeatCloneMacTests", dependencies: ["NeatClone", "NeatCloneCore"])
    ]
)
