// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ProcLensCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ProcLensCore", targets: ["ProcLensCore"]),
        // Shared by the app (via ProcLensCore) and the privileged helper executable.
        .library(name: "ProcLensHelperProtocol", targets: ["ProcLensHelperProtocol"]),
    ],
    targets: [
        .target(
            name: "ProcLensHelperProtocol",
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        .target(
            name: "ProcLensCore",
            dependencies: ["ProcLensHelperProtocol"],
            resources: [.process("Resources")],
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        .executableTarget(
            name: "ProcLensBench",
            dependencies: ["ProcLensCore"],
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        // Sources live in the top-level ProcLensHelper/ folder (symlinked here); XcodeGen builds the shipping binary.
        .executableTarget(
            name: "ProcLensHelper",
            dependencies: ["ProcLensHelperProtocol"],
            exclude: ["com.canberkki.ProcLens.helper.plist"],
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        .testTarget(
            name: "ProcLensCoreTests",
            dependencies: ["ProcLensCore", "ProcLensHelperProtocol"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
