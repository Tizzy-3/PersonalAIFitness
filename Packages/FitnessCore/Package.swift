// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FitnessCore",
    products: [.library(name: "FitnessCore", targets: ["FitnessCore"])],
    targets: [
        .target(name: "FitnessCore", resources: [.process("Resources")]),
        .testTarget(name: "FitnessCoreTests", dependencies: ["FitnessCore"])
    ]
)
