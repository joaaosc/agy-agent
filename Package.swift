// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "agy-agent",
    platforms: [.macOS("15.0")],
    products: [
        .executable(name: "agy-agent", targets: ["AgyAgentCLI"]),
        .library(name: "AgyAgentKit", targets: ["AgyAgentKit"]),
    ],
    targets: [
        .target(
            name: "AgyAgentKit",
            resources: [
                // Prompts de referência, copiados para ~/.config na primeira
                // execução. Ficam dentro do target para haver uma única fonte
                // da verdade entre o repositório e o binário.
                .copy("Resources/Prompts"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
        .executableTarget(
            name: "AgyAgentCLI",
            dependencies: ["AgyAgentKit"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
        .testTarget(
            name: "AgyAgentKitTests",
            dependencies: ["AgyAgentKit"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
    ]
)
