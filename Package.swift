// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Susurro",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Susurro",
            path: "Sources/Susurro"
        ),
        .testTarget(
            name: "SusurroTests",
            dependencies: ["Susurro"],
            path: "Tests/SusurroTests"
        ),
    ]
)
