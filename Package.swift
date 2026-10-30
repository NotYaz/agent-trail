// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentTrail",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AgentTrail", targets: ["AgentTrail"]),
        .executable(name: "AgentTrailInspect", targets: ["AgentTrailInspect"]),
        .library(name: "AgentTrailCore", targets: ["AgentTrailCore"])
    ],
    targets: [
        .target(name: "AgentTrailCore"),
        .executableTarget(name: "AgentTrail", dependencies: ["AgentTrailCore"]),
        .executableTarget(name: "AgentTrailInspect", dependencies: ["AgentTrailCore"]),
        .testTarget(name: "AgentTrailCoreTests", dependencies: ["AgentTrailCore"])
    ],
    swiftLanguageModes: [.v5]
)
