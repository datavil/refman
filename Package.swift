// swift-tools-version: 6.2
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
            resources: [.copy("Resources/Citeproc")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "Refman",
            dependencies: ["RefmanCore"],
            resources: [.process("Resources")],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .swiftLanguageMode(.v6),
            ]
        ),
        .executableTarget(
            name: "RefmanAgent",
            dependencies: ["RefmanCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "RefmanCoreTests",
            dependencies: ["RefmanCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "RefmanTests",
            dependencies: ["Refman", "RefmanCore"],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
