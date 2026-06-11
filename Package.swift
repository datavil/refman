// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RefMan",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RefManCore", targets: ["RefManCore"]),
        .executable(name: "RefMan", targets: ["RefMan"]),
        .executable(name: "refman-agent", targets: ["RefManAgent"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
    ],
    targets: [
        .target(
            name: "RefManCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "RefMan",
            dependencies: ["RefManCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "RefManAgent",
            dependencies: ["RefManCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "RefManCoreTests",
            dependencies: ["RefManCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
