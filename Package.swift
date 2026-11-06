// swift-tools-version: 6.4
// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import PackageDescription

let macOSDeploymentTarget = "15.0"
let macOSSDKVersion = "27.2"
let swiftSettings: [SwiftSetting] = [.defaultIsolation(nil)]
/// Record the pinned SDK independently of the linker's inherited SDKROOT.
let linkerSettings: [LinkerSetting] = [.unsafeFlags([
  "-Xlinker",
  "-platform_version",
  "-Xlinker",
  "macos",
  "-Xlinker",
  macOSDeploymentTarget,
  "-Xlinker",
  macOSSDKVersion,
])]

let package = Package(
  name: "Tatara",
  platforms: [.macOS(macOSDeploymentTarget)],
  products: [.executable(name: "tatara", targets: ["TataraTUI"])],
  dependencies: [
    .package(path: "ThirdParty/TermLoom"),
    .package(url: "https://github.com/pointfreeco/swift-composable-architecture", from: "1.26.2"),
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.2"),
    .package(url: "https://github.com/swiftlang/swift-subprocess", from: "1.0.2"),
    .package(url: "https://github.com/mattt/swift-toml", from: "2.1.0"),
    .package(url: "https://github.com/pointfreeco/sqlite-data", from: "1.12.1"),
    .package(url: "https://github.com/pointfreeco/swift-custom-dump", from: "1.0.0"),
  ],
  targets: [
    .target(name: "TataraCore", path: "TataraCore/Sources", swiftSettings: swiftSettings),
    .target(
      name: "TataraKit",
      dependencies: ["TataraCore", .product(name: "ComposableArchitecture", package: "swift-composable-architecture")],
      path: "TataraKit/Sources",
      swiftSettings: swiftSettings,
    ),
    .target(
      name: "TataraSystem",
      dependencies: [
        "TataraCore",
        "TataraKit",
        .product(name: "Subprocess", package: "swift-subprocess"),
        .product(name: "TOML", package: "swift-toml"),
      ],
      path: "TataraSystem/Sources",
      swiftSettings: swiftSettings,
    ),
    .target(
      name: "TataraGitHub",
      dependencies: ["TataraCore", "TataraKit", "TataraSystem"],
      path: "TataraGitHub/Sources",
      swiftSettings: swiftSettings,
    ),
    .target(
      name: "TataraPersistence",
      dependencies: ["TataraCore", "TataraKit", .product(name: "SQLiteData", package: "sqlite-data")],
      path: "TataraPersistence/Sources",
      swiftSettings: swiftSettings,
    ),
    .executableTarget(
      name: "TataraTUI",
      dependencies: [
        "TataraCore",
        "TataraKit",
        "TataraSystem",
        "TataraGitHub",
        "TataraPersistence",
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
        .product(name: "TermLoom", package: "termloom"),
        .product(name: "TermLoomTextArea", package: "termloom"),
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ],
      path: "TataraTUI/Sources",
      swiftSettings: swiftSettings,
      linkerSettings: linkerSettings,
    ),
    .testTarget(
      name: "TataraTests",
      dependencies: [
        "TataraCore",
        "TataraKit",
        "TataraSystem",
        "TataraGitHub",
        "TataraPersistence",
        "TataraTUI",
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
        .product(name: "CustomDump", package: "swift-custom-dump"),
        .product(name: "TermLoom", package: "termloom"),
        .product(name: "TermLoomTextArea", package: "termloom"),
      ],
      path: "TataraTests/Sources",
      swiftSettings: swiftSettings,
      linkerSettings: linkerSettings,
    ),
  ],
  swiftLanguageModes: [.v6],
)
