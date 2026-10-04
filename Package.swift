// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Commander",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Commander", targets: ["Commander"])],
    dependencies: [
        .package(url: "https://github.com/CleanCocoa/TextBuffer.git", revision: "3dfbfc13fe4e7f898a3b7c3d13d3eb1451eb8386"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .target(name: "CFileCopy"),
        .target(name: "FileManagerCore", dependencies: ["CFileCopy"]),
        .target(name: "EditorCore", dependencies: [.product(name: "TextBuffer", package: "TextBuffer")]),
        .target(name: "CommanderUI", dependencies: [
            "FileManagerCore",
            "EditorCore",
            .product(name: "Sparkle", package: "Sparkle"),
        ]),
        .testTarget(name: "EditorCoreTests", dependencies: ["EditorCore"]),
        .executableTarget(name: "EditorBenchmark", dependencies: ["EditorCore"]),
        .executableTarget(
            name: "Commander",
            dependencies: ["CommanderUI"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "FileManagerCoreTests", dependencies: ["FileManagerCore"]),
        .testTarget(name: "CommanderUITests", dependencies: ["CommanderUI"]),
    ]
)
