// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ProcLensCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ProcLensCore", targets: ["ProcLensCore"]),
    ],
    targets: [
        .target(
            name: "ProcLensCore",
            resources: [.process("Resources")],
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        .executableTarget(
            name: "ProcLensBench",
            dependencies: ["ProcLensCore"],
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        .testTarget(
            name: "ProcLensCoreTests",
            dependencies: ["ProcLensCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
