// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SingBoxMenuBar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "SingBoxMenuBar",
            path: "Sources/SingBoxMenuBar"
        )
    ]
)
