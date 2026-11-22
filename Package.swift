// swift-tools-version:5.9
// Gridwise: a Mac dashboard for Amber Electric customers. Build with ./build.sh (needs only the Command Line Tools).
import PackageDescription

let package = Package(
    name: "Gridwise",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "Gridwise", path: "Sources/Gridwise")]
)
