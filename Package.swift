// swift-tools-version:6.0
import PackageDescription

// Flags for linking the statically-built whisper.cpp (see `make whisper`).
let whisperLinkerSettings: [LinkerSetting] = [
    .unsafeFlags([
        "-Lbuild-whisper/src",
        "-Lbuild-whisper/ggml/src",
        "-Lbuild-whisper/ggml/src/ggml-metal",
        "-Lbuild-whisper/ggml/src/ggml-blas",
        "-lwhisper", "-lggml", "-lggml-cpu", "-lggml-metal", "-lggml-blas", "-lggml-base",
        "-lc++",
    ]),
    .linkedFramework("Metal"),
    .linkedFramework("MetalKit"),
    .linkedFramework("Accelerate"),
    .linkedFramework("Foundation"),
]

let package = Package(
    name: "Susurro",
    platforms: [.macOS(.v15)],
    targets: [
        // C shim exposing whisper.h to Swift
        .target(
            name: "CWhisper",
            path: "Sources/CWhisper",
            cSettings: [
                .unsafeFlags([
                    "-Ivendor/whisper.cpp/include",
                    "-Ivendor/whisper.cpp/ggml/include",
                ])
            ]
        ),
        // Engine, audio, post-processing — shared by app, CLI, tests
        .target(
            name: "SusurroCore",
            dependencies: ["CWhisper"],
            path: "Sources/SusurroCore",
            cSettings: [
                .unsafeFlags([
                    "-Ivendor/whisper.cpp/include",
                    "-Ivendor/whisper.cpp/ggml/include",
                ])
            ]
        ),
        // Menu bar app
        .executableTarget(
            name: "Susurro",
            dependencies: ["SusurroCore"],
            path: "Sources/Susurro",
            linkerSettings: whisperLinkerSettings
        ),
        // Bridge test / corpus regression CLI
        .executableTarget(
            name: "susurro-cli",
            dependencies: ["SusurroCore"],
            path: "Sources/susurro-cli",
            linkerSettings: whisperLinkerSettings
        ),
        .testTarget(
            name: "SusurroTests",
            dependencies: ["SusurroCore"],
            path: "Tests/SusurroTests",
            linkerSettings: whisperLinkerSettings
        ),
    ]
)
