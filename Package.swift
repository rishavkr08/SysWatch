// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SysWatch",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "SysWatch", path: "Sources/SysWatch")]
)
