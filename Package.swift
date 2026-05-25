// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ArgusCLI",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "argus", targets: ["ArgusCLI"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0")
    ],
    targets: [
        .executableTarget(
            name: "ArgusCLI",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "ArgusCLI"
        )
    ]
)
