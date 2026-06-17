// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Refman",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RefmanCore", targets: ["RefmanCore"]),
        .executable(name: "Refman", targets: ["Refman"]),
        .executable(name: "refman-agent", targets: ["RefmanAgent"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
    ],
    targets: [
        .target(
            name: "RefmanCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Refman",
            dependencies: ["RefmanCore"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "RefmanAgent",
            dependencies: ["RefmanCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "RefmanCoreTests",
            dependencies: ["RefmanCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
