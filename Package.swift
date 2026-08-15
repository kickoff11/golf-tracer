// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GolfTracerCore",
    platforms: [.macOS(.v15)],
    products: [.library(name: "GolfTracerCore", targets: ["GolfTracerCore"])],
    targets: [
        .target(
            name: "GolfTracerCore",
            path: "GolfTracer",
            exclude: [
                "AnimatedTrajectoryView.swift", "Assets.xcassets", "ContentView.swift",
                "GolfTracerApp.swift", "TrajectoryAnalyzer.swift",
                "TrajectoryVideoExporter.swift", "VideoPicker.swift",
            ],
            sources: ["BallTrajectory.swift", "ManualTrajectoryEngine.swift", "TrajectoryRenderMath.swift", "TracerProject.swift"]
        ),
        .testTarget(
            name: "GolfTracerCoreTests",
            dependencies: ["GolfTracerCore"],
            resources: [.process("Fixtures")]
        ),
    ]
)
