// swift-tools-version: 6.3
import PackageDescription

#if TUIST
  import struct ProjectDescription.PackageSettings

  let packageSettings = PackageSettings(productTypes: [:])
#endif

let package = Package(
  name: "Tatara",
  dependencies: [
    .package(url: "https://github.com/pointfreeco/swift-composable-architecture", from: "1.26.2"),
    .package(url: "https://github.com/Frank-III/termloom", revision: "b746967794ad2753c39f695f5923c5cdf2f6425a", traits: []),
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.0"),
    .package(url: "https://github.com/swiftlang/swift-subprocess", from: "1.0.0"),
    .package(url: "https://github.com/mattt/swift-toml", from: "2.0.0"),
    .package(url: "https://github.com/pointfreeco/sqlite-data", from: "1.12.0"),
  ],
)
