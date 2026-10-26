// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FitnessCore",
    products: [.library(name: "FitnessCore", targets: ["FitnessCore"])],
    targets: [
        .target(name: "FitnessCore"),
        .testTarget(name: "FitnessCoreTests", dependencies: ["FitnessCore"])
    ]
)
