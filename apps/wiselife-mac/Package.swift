// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WiseLifeMac",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CompanionCore", targets: ["CompanionCore"]),
        .library(name: "CompanionMLX", targets: ["CompanionMLX"]),
        .executable(name: "WiseLifeCompanion", targets: ["WiseLifeCompanion"]),
        .executable(name: "CompanionBenchmark", targets: ["CompanionBenchmark"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "2.29.3"),
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.29.1"),
        .package(url: "https://github.com/apple/swift-nio", exact: "2.104.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl", exact: "2.37.5"),
        .package(url: "https://github.com/apple/swift-certificates", exact: "1.19.3"),
    ],
    targets: [
        .target(name: "CompanionCore", dependencies: [
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
            .product(name: "X509", package: "swift-certificates"),
        ], resources: [.copy("ModelCatalog.json")]),
        .target(name: "CompanionMLX", dependencies: ["CompanionCore",
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            .product(name: "MLX", package: "mlx-swift"),
        ]),
        .executableTarget(name: "WiseLifeCompanion", dependencies: ["CompanionCore", "CompanionMLX"]),
        .executableTarget(name: "CompanionBenchmark", dependencies: ["CompanionCore", "CompanionMLX"]),
        .testTarget(name: "CompanionCoreTests", dependencies: ["CompanionCore"]),
    ],
    swiftLanguageModes: [.v5]
)
