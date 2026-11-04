// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Amanuensis",
  platforms: [.macOS(.v15)],
  targets: [
    .executableTarget(name: "Amanuensis"),
    .testTarget(name: "AmanuensisTests", dependencies: ["Amanuensis"]),
  ]
)
