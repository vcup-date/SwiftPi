// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SwiftPi",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "PiAI", targets: ["PiAI"]),
        .library(name: "PiAgent", targets: ["PiAgent"]),
        .library(name: "PiCodingAgent", targets: ["PiCodingAgent"]),
        .library(name: "TestSwiftPiLib", targets: ["TestSwiftPiLib"]),
        .executable(name: "TestSwiftPi", targets: ["TestSwiftPi"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "PiAI",
            dependencies: [],
            path: "Sources/PiAI"
        ),
        .target(
            name: "PiAgent",
            dependencies: ["PiAI"],
            path: "Sources/PiAgent"
        ),
        .target(
            name: "PiCodingAgent",
            dependencies: ["PiAI", "PiAgent"],
            path: "Sources/PiCodingAgent"
        ),
        .target(
            name: "TestSwiftPiLib",
            dependencies: ["PiAI", "PiAgent", "PiCodingAgent"],
            path: "Sources/TestSwiftPiLib"
        ),
        .executableTarget(
            name: "TestSwiftPi",
            dependencies: ["PiAI", "PiAgent", "PiCodingAgent", "TestSwiftPiLib"],
            path: "TestSwiftPi",
            resources: [.copy("Resources/AppIcon.png")]
        ),
        .testTarget(
            name: "PiAITests",
            dependencies: ["PiAI"],
            path: "Tests/PiAITests"
        ),
        .testTarget(
            name: "PiAgentTests",
            dependencies: ["PiAgent"],
            path: "Tests/PiAgentTests"
        ),
        .testTarget(
            name: "PiCodingAgentTests",
            dependencies: ["PiCodingAgent"],
            path: "Tests/PiCodingAgentTests"
        ),
    ]
)
