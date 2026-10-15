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
        .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter", exact: "0.25.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter", exact: "0.25.10"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-json", revision: "254c42a6476413b776221e03982ac8ae159eeb72"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .target(name: "CFileCopy"),
        .target(name: "ArchiveCore", dependencies: [.product(name: "CLibArchive", package: "libarchive-bin")]),
        .target(name: "FileManagerCore", dependencies: ["CFileCopy", "ArchiveCore"]),
        .target(name: "ArchiveTestSupport", path: "Tests/ArchiveTestSupport", resources: [.copy("Fixtures")]),
        .testTarget(name: "ArchiveCoreTests", dependencies: ["ArchiveCore", "ArchiveTestSupport"]),
        .target(name: "EditorCore", dependencies: [.product(name: "TextBuffer", package: "TextBuffer")]),
        .target(name: "SyntaxCore", dependencies: [
            .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
            .product(name: "TreeSitter", package: "tree-sitter"),
            .product(name: "TreeSitterJSON", package: "tree-sitter-json"),
        ]),
        .target(name: "CommanderUI", dependencies: [
            .product(name: "GhosttyTerminal", package: "libghostty-spm"),
            "FileManagerCore",
            "EditorCore",
            "SyntaxCore",
            .product(name: "Sparkle", package: "Sparkle"),
        ], resources: [.copy("Resources/TerminalShell")]),
        .testTarget(name: "EditorCoreTests", dependencies: ["EditorCore"]),
        .testTarget(name: "SyntaxCoreTests", dependencies: ["SyntaxCore"]),
        .executableTarget(name: "EditorBenchmark", dependencies: ["EditorCore"]),
        .executableTarget(
            name: "Commander",
            dependencies: ["CommanderUI"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "FileManagerCoreTests", dependencies: ["FileManagerCore", "ArchiveTestSupport"]),
        .testTarget(name: "CommanderUITests", dependencies: ["CommanderUI", "ArchiveTestSupport"]),
    ]
)
