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
        .library(name: "HarnessCoding", targets: ["HarnessCoding"]),
        .executable(name: "harness", targets: ["HarnessCLI"]),
    ],
    targets: [
        .target(
            name: "Harness",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
        .target(
            name: "HarnessCoding",
            dependencies: ["Harness"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
        .executableTarget(
            name: "HarnessCLI",
            dependencies: ["Harness", "HarnessCoding"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
        .target(
            name: "HarnessTestSupport",
            path: "Tests/HarnessTestSupport",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
        .testTarget(
            name: "HarnessTests",
            dependencies: ["Harness", "HarnessTestSupport"],
            resources: [
                .copy("Fixtures"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
        .testTarget(
            name: "HarnessCodingTests",
            dependencies: ["Harness", "HarnessCoding", "HarnessTestSupport"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
    ]
)
