// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "RedraftCore",
  platforms: [.macOS(.v13)],
  products: [.library(name: "RedraftCore", targets: ["RedraftCore"])],
  targets: [
    .target(name: "RedraftCore"),
    .testTarget(name: "RedraftCoreTests", dependencies: ["RedraftCore"]),
  ]
)
