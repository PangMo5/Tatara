// swift-tools-version: 6.4
import PackageDescription

#if TUIST
import struct ProjectDescription.PackageSettings

let packageSettings = PackageSettings(productTypes: [:])
#endif

let package = Package(
  name: "Tatara",
  dependencies: [
    .package(url: "https://github.com/pointfreeco/swift-composable-architecture", from: "1.26.2"),
    .package(url: "https://github.com/Frank-III/termloom", revision: "ff6dd74f7daaef393480c24de734c1435719ad46", traits: []),
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.2"),
    .package(url: "https://github.com/swiftlang/swift-subprocess", from: "1.0.2"),
    .package(url: "https://github.com/mattt/swift-toml", from: "2.1.0"),
    .package(url: "https://github.com/pointfreeco/sqlite-data", from: "1.12.1"),
  ],
)
