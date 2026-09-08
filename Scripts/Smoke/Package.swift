// swift-tools-version: 6.3
// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import PackageDescription

let package = Package(
  name: "TataraSmoke",
  platforms: [.macOS(.v15)],
  products: [.executable(name: "tatara-smoke", targets: ["TataraSmoke"])],
  dependencies: [.package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.20.0")],
  targets: [.executableTarget(
    name: "TataraSmoke",
    dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
    path: ".",
    sources: ["PTY.swift", "Smoke.swift"],
  )],
  swiftLanguageModes: [.v6],
)
