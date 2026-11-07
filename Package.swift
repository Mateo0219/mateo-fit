// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "XuXu", platforms: [.macOS(.v14), .iOS(.v17)], products: [
    .library(name: "FitnessCore", targets: ["FitnessCore"]),
    .executable(name: "XuXuDesktop", targets: ["FitnessApp"]),
    .executable(name: "CoreChecks", targets: ["CoreChecks"])
], targets: [
    .target(name: "FitnessCore"),
    .executableTarget(name: "FitnessApp", dependencies: ["FitnessCore"], exclude: ["Assets.xcassets"]),
    .executableTarget(name: "CoreChecks", dependencies: ["FitnessCore"])
])
