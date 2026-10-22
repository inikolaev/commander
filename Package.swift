// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Commander",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Commander", targets: ["Commander"])],
    dependencies: [
        .package(url: "https://github.com/inikolaev/libarchive-bin.git", exact: "3.8.10-1"),
        .package(url: "https://github.com/Lakr233/libghostty-spm.git", revision: "46a3e8f31efca1007198c7d5f43afa35026aaffb"),
        .package(url: "https://github.com/CleanCocoa/TextBuffer.git", revision: "3dfbfc13fe4e7f898a3b7c3d13d3eb1451eb8386"),
        .package(url: "https://github.com/inikolaev/commander-tree-sitter.git", exact: "0.2.2"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .target(name: "CFileCopy"),
        .target(name: "ArchiveCore", dependencies: [.product(name: "CLibArchive", package: "libarchive-bin")]),
        .target(name: "FileManagerCore", dependencies: ["CFileCopy", "ArchiveCore"]),
        .target(name: "ArchiveTestSupport", path: "Tests/ArchiveTestSupport", resources: [.copy("Fixtures")]),
        .testTarget(name: "ArchiveCoreTests", dependencies: ["ArchiveCore", "ArchiveTestSupport"]),
        .target(name: "EditorCore", dependencies: [.product(name: "TextBuffer", package: "TextBuffer")]),
        .target(name: "CommanderUI", dependencies: [
            .product(name: "GhosttyTerminal", package: "libghostty-spm"),
            "FileManagerCore",
            "EditorCore",
            .product(name: "SyntaxCore", package: "commander-tree-sitter"),
            .product(name: "Sparkle", package: "Sparkle"),
        ], resources: [.copy("Resources/TerminalShell")]),
        .testTarget(name: "EditorCoreTests", dependencies: ["EditorCore"]),
        .executableTarget(name: "EditorBenchmark", dependencies: ["EditorCore"]),
        .executableTarget(
            name: "Commander",
            dependencies: ["CommanderUI"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "FileManagerCoreTests", dependencies: ["FileManagerCore", "ArchiveTestSupport"]),
        .testTarget(name: "CommanderUITests", dependencies: ["CommanderUI", "ArchiveTestSupport", .product(name: "SyntaxCore", package: "commander-tree-sitter")]),
    ]
)
