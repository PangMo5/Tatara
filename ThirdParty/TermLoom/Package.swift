// swift-tools-version: 6.4
// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: MIT

import PackageDescription

let package = Package(
  name: "termloom",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "TermLoom", targets: ["TermLoom"]),
    .library(name: "TermLoomTextArea", targets: ["TermLoomTextArea"]),
  ],
  targets: [
    .target(name: "TermLoom"),
    .target(name: "TermLoomTextArea", dependencies: ["TermLoom"]),
  ],
  swiftLanguageModes: [.v6],
)
