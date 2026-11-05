// swift-tools-version:6.0
import PackageDescription
import Foundation

// Absolute package root: with a package dependency present, SwiftPM's build
// resolves relative unsafeFlags against the parent directory, not the package.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

// Flags for linking the statically-built whisper.cpp (see `make whisper`).
let whisperLinkerSettings: [LinkerSetting] = [
    .unsafeFlags([
        "-L\(root)/build-whisper/src",
        "-L\(root)/build-whisper/ggml/src",
        "-L\(root)/build-whisper/ggml/src/ggml-metal",
        "-L\(root)/build-whisper/ggml/src/ggml-blas",
        "-lwhisper", "-lggml", "-lggml-cpu", "-lggml-metal", "-lggml-blas", "-lggml-base",
        "-lc++",
    ]),
    .linkedFramework("Metal"),
    .linkedFramework("MetalKit"),
    .linkedFramework("Accelerate"),
    .linkedFramework("Foundation"),
]

// Clang-importer search paths for whisper.h. Every Swift target that (transitively)
// imports CWhisper needs these: cSettings don't reach swiftc's dependency scanner.
let whisperSwiftSettings: [SwiftSetting] = [
    .unsafeFlags([
        "-Xcc", "-I\(root)/vendor/whisper.cpp/include",
        "-Xcc", "-I\(root)/vendor/whisper.cpp/ggml/include",
    ])
]

let package = Package(
    name: "Susurro",
    platforms: [.macOS(.v15)],
    dependencies: [
        // Parakeet TDT (Core ML) speech-to-text engine — see docs/history/PARAKEET_PLAN.md
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.9.1"),
    ],
    targets: [
        // C shim exposing whisper.h to Swift
        .target(
            name: "CWhisper",
            path: "Sources/CWhisper",
            cSettings: [
                .unsafeFlags([
                    "-I\(root)/vendor/whisper.cpp/include",
                    "-I\(root)/vendor/whisper.cpp/ggml/include",
                ])
            ]
        ),
        // Engine, audio, post-processing — shared by app, CLI, tests
        .target(
            name: "SusurroCore",
            dependencies: [
                "CWhisper",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/SusurroCore",
            cSettings: [
                .unsafeFlags([
                    "-I\(root)/vendor/whisper.cpp/include",
                    "-I\(root)/vendor/whisper.cpp/ggml/include",
                ])
            ],
            swiftSettings: whisperSwiftSettings
        ),
        // Menu bar app
        .executableTarget(
            name: "Susurro",
            dependencies: ["SusurroCore"],
            path: "Sources/Susurro",
            swiftSettings: whisperSwiftSettings,
            linkerSettings: whisperLinkerSettings
        ),
        // Bridge test / corpus regression CLI
        .executableTarget(
            name: "susurro-cli",
            dependencies: ["SusurroCore"],
            path: "Sources/susurro-cli",
            swiftSettings: whisperSwiftSettings,
            linkerSettings: whisperLinkerSettings
        ),
        .testTarget(
            name: "SusurroTests",
            dependencies: ["SusurroCore"],
            path: "Tests/SusurroTests",
            swiftSettings: whisperSwiftSettings,
            linkerSettings: whisperLinkerSettings
        ),
    ]
)
