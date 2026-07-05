// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ndi-region",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CNDI"),
        .target(name: "RegionCore", dependencies: ["CNDI"]),
        .executableTarget(
            name: "ndi-region",
            dependencies: ["RegionCore"]
        ),
        .executableTarget(
            name: "NDIRegion",
            dependencies: ["RegionCore"]
        ),
    ]
)
