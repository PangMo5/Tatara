// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import ProjectDescription

let appVersion = "0.1.0"
let platforms: DeploymentTargets = .macOS("15.0")

func library(_ name: String, dependencies: [TargetDependency] = []) -> Target {
  .target(
    name: name, destinations: .macOS, product: .staticFramework,
    bundleId: "dev.PangMo5.\(name)", deploymentTargets: platforms,
    sources: ["\(name)/Sources/**"], dependencies: dependencies,
  )
}

let project = Project(
  name: "Tatara", organizationName: "PangMo5",
  options: .options(
    defaultKnownRegions: ["en", "ko", "ja", "zh-Hans", "zh-Hant"], developmentRegion: "en",
  ),
  settings: .settings(base: [
    "SWIFT_VERSION": "6.0", "SWIFT_STRICT_CONCURRENCY": "complete",
    "SWIFT_DEFAULT_ACTOR_ISOLATION": "nonisolated",
    "SWIFT_EMIT_LOC_STRINGS": "YES", "CODE_SIGN_IDENTITY": "-",
    "DEAD_CODE_STRIPPING": "YES",
  ]),
  targets: [
    .target(
      name: "TermLoomTextArea", destinations: .macOS, product: .staticFramework,
      bundleId: "dev.PangMo5.TermLoomTextArea", deploymentTargets: platforms,
      // The upstream subpackage uses a local core dependency; compile its pinned sources.
      sources: ["Tuist/.build/checkouts/termloom/Packages/TermLoomTextArea/Sources/TermLoomTextArea/**"],
      dependencies: [.external(name: "TermLoom")],
    ),
    library("TataraCore"),
    library("TataraKit", dependencies: [.target(name: "TataraCore"), .external(name: "ComposableArchitecture")]),
    library("TataraSystem", dependencies: [.target(name: "TataraKit"), .external(name: "Subprocess"), .external(name: "TOML")]),
    library("TataraGitHub", dependencies: [.target(name: "TataraSystem")]),
    library("TataraPersistence", dependencies: [.target(name: "TataraKit"), .external(name: "SQLiteData")]),
    .target(
      name: "Tatara", destinations: .macOS, product: .commandLineTool,
      bundleId: "dev.PangMo5.tatara", deploymentTargets: platforms,
      sources: ["TataraTUI/Sources/**"],
      scripts: [.pre(
        script: "set -e\nswift \"$SRCROOT/Scripts/Tatara.swift\" localizations --check\nswift \"$SRCROOT/Scripts/Tatara.swift\" patch-dependencies --check",
        name: "Validate Catalog and Dependencies",
        basedOnDependencyAnalysis: false,
      )],
      dependencies: [.target(name: "TataraGitHub"), .target(name: "TataraPersistence"), .external(name: "TermLoom"),
                     .target(name: "TermLoomTextArea"), .external(name: "ArgumentParser")],
      settings: .settings(base: [
        "PRODUCT_NAME": "tatara", "GENERATE_INFOPLIST_FILE": "YES",
        "CREATE_INFOPLIST_SECTION_IN_BINARY": "YES", "MARKETING_VERSION": .string(appVersion),
      ]),
    ),
    .target(
      name: "TataraTests", destinations: .macOS, product: .unitTests,
      bundleId: "dev.PangMo5.Tatara.Tests", deploymentTargets: platforms,
      // Exercise the stateless renderer without linking the executable entry point.
      sources: ["TataraTests/Sources/**", "TataraTUI/Sources/DocumentRenderer.swift", "TataraTUI/Sources/Palette.swift",
                "TataraTUI/Sources/CommentRenderer.swift", "TataraTUI/Sources/CommentPresentation.swift",
                "TataraTUI/Sources/WorkspacePresentation.swift", "TataraTUI/Sources/EditorPresentation.swift",
                "TataraTUI/Sources/TerminalScreen.swift", "TataraTUI/Sources/Localization.swift",
                "TataraTUI/Sources/Generated/LocalizedStrings.swift"],
      dependencies: [
        .target(name: "TataraGitHub"),
        .target(name: "TataraPersistence"),
        .target(name: "TermLoomTextArea"),
      ],
    ),
  ],
)
