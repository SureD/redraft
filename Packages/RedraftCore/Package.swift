// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "RedraftCore",
  platforms: [.macOS(.v26)],
  products: [.library(name: "RedraftCore", targets: ["RedraftCore"])],
  targets: [
    .target(name: "RedraftCore"),
    .testTarget(name: "RedraftCoreTests", dependencies: ["RedraftCore"]),
  ]
)
