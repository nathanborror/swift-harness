// swift-tools-version: 6.4
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "swift-harness",
    platforms: [
        .macOS(.v27),
        .iOS(.v27),
    ],
    products: [
        .library(name: "Harness", targets: ["Harness"]),
        .executable(name: "harness", targets: ["HarnessCLI"]),
    ],
    targets: [
        .target(
            name: "Harness",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
        .executableTarget(
            name: "HarnessCLI",
            dependencies: ["Harness"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
        .testTarget(
            name: "HarnessTests",
            dependencies: ["Harness"],
            resources: [
                .copy("Fixtures"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
    ]
)
