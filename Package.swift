// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PiAgentCore",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "PiAgentCore", targets: ["PiAgentCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/quyansiyuanwang/pi-ai-swift.git", exact: "0.1.2")
    ],
    targets: [
        .target(
            name: "PiAgentCore",
            dependencies: [.product(name: "PiAI", package: "pi-ai-swift")],
            path: "Sources/PiAgentCore"
        ),
        .testTarget(
            name: "PiAgentCoreTests",
            dependencies: ["PiAgentCore"],
            path: "Tests/PiAgentCoreTests"
        )
    ]
)
