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
    .package(url: "https://github.com/SwiftTUI/swift-tui", .upToNextMinor(from: "0.10.1")),
    .package(url: "https://github.com/swiftlang/swift-subprocess", from: "1.0.0"),
    .package(url: "https://github.com/mattt/swift-toml", from: "2.0.0"),
  ],
)
