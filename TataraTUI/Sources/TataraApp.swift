// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import Foundation
import SwiftTUI
import TataraCore
import TataraGitHub
import TataraKit
import TataraSystem

@main
struct TataraApp: App {
  @OptionGroup var swiftTUIOptions: SwiftTUIOptions
  @Option(name: .shortAndLong, help: "Repository in OWNER/REPO format. Defaults to the current repository.") var repo: String?
  @Option(help: "GitHub hostname, including GitHub Enterprise.") var host: String?
  @Option(help: "Catppuccin flavor: latte, frappe, macchiato, mocha.") var theme: String?
  @Option(help: "Language: en, ko, ja, zh-Hans, zh-Hant.") var language: String?
  @Option(help: "Path to config.toml.") var config: String?
  @Flag(help: "Explore synthetic review data without a GitHub account.") var demo = false

  nonisolated static var configuration: CommandConfiguration {
    CommandConfiguration(
      commandName: "tatara",
      abstract: "A structural code review workspace for your terminal.",
      version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development",
    )
  }

  var body: some Scene {
    WindowGroup("Tatara") {
      BootstrapView(repo: repo, host: host, theme: theme, language: language, config: config, demo: demo)
    }
  }
}

struct BootstrapView: View {
  let repo: String?
  let host: String?
  let theme: String?
  let language: String?
  let config: String?
  let demo: Bool
  @SwiftTUI.State private var store: StoreOf<WorkspaceFeature>?
  @SwiftTUI.State private var localization: Localization?
  @SwiftTUI.State private var failure: String?
  @SwiftTUI.Environment(\.requestTermination) private var quit

  var body: some View {
    Group {
      if let store, let localization {
        WorkspaceView(store: store, l10n: localization, demo: demo)
      } else if let failure {
        VStack(alignment: .leading, spacing: 1) {
          Text("Tatara").bold()
          Text(failure)
          Text("q · Quit")
        }.padding(2).focusable().onKeyPress(.character("q")) { _ in quit()
          return .handled
        }
      } else {
        Text("Tatara · Loading…").padding(2)
      }
    }
    .task {
      guard store == nil, failure == nil else { return }
      do {
        var preferences = try Configuration.load(path: config)
        if let theme {
          guard let value = TataraCore.Theme(rawValue: theme) else { throw TataraError(
            .configuration,
            detail: "Unknown theme: \(theme)",
          ) }
          preferences.theme = value
        }
        if let language {
          guard let value = Language(rawValue: language) else { throw TataraError(
            .configuration,
            detail: "Unknown language: \(language)",
          ) }
          preferences.language = value
        }
        localization = Localization(language: preferences.language)
        let adapter = GitHubAdapter()
        let repository: RepositoryID = if demo {
          try RepositoryID("PangMo5/Tatara")
        } else if let repo {
          try RepositoryID(repo, host: host ?? "github.com")
        } else {
          try await adapter.detectRepository(host: host)
        }
        let forge = demo ? DemoData.client(repository) : adapter.client
        let diff = Difftastic(forge: forge).client
        store = Store(initialState: WorkspaceFeature.State(repository: repository, preferences: preferences)) {
          WorkspaceFeature()
        } withDependencies: {
          $0[ForgeClient.self] = forge
          $0[DiffClient.self] = diff
        }
      } catch { failure = localization?.error(.wrapping(error)) ?? String(describing: error) }
    }
  }
}

enum DemoData {
  static func client(_ repository: RepositoryID) -> ForgeClient {
    let before = """
    struct ReviewQueue {
      var files: [String] = []

      func next(after index: Int) -> String? {
        files[index + 1]
      }
    }
    """
    let after = """
    struct ReviewQueue {
      var files: [String] = []

      func next(after index: Int) -> String? {
        guard files.indices.contains(index + 1) else { return nil }
        return files[index + 1]
      }
    }
    """
    return ForgeClient(
      list: { _, kind, _ in
        let titles = kind == .pullRequest ? [
          "Keep review navigation within bounds",
          "Preserve source paths when files move",
          "Add Catppuccin Latte",
        ] : ["Remember the last reviewed file", "Support GitLab merge requests"]
        return ItemPage(items: titles.enumerated().map { offset, title in
          ForgeItem(
            id: .init(repository: repository, number: 42 + offset),
            kind: kind,
            title: title,
            author: "contributor",
            body: "A small change that keeps the next review step predictable.\n\nPlease check the empty collection and the last file.",
            url: URL(string: "https://github.com/\(repository.slug)/\(kind == .pullRequest ? "pull" : "issues")/\(42 + offset)")!,
            labels: ["enhancement"],
          )
        })
      },
      detail: { item in
        ItemDetail(
          item: item,
          revision: item.kind == .pullRequest ? .init(mergeBase: String(repeating: "a", count: 40), head: String(
            repeating: "b",
            count: 40,
          )) : nil,
          files: item.kind == .pullRequest ? [.init(
            path: "Sources/ReviewQueue.swift",
            additions: 2,
            deletions: 1,
            patch: "@@ -4,3 +4,4 @@\n   func next(after index: Int) -> String? {\n-    files[index + 1]\n+    guard files.indices.contains(index + 1) else { return nil }\n+    return files[index + 1]\n   }",
          )] : [],
          comments: [.init(id: 1, author: "reviewer", body: "Please keep the empty collection case covered by a test.")],
          metadata: item.kind == .pullRequest ? .github(.init(
            baseBranch: "main",
            headBranch: "fix/review-navigation",
            mergeableState: "clean",
            checks: ["Swift Testing: success", "REUSE: success"],
            reviews: ["@reviewer: COMMENTED"],
          )) : nil,
        )
      },
      content: { _, revision, _ in Data((revision.hasPrefix("a") ? before : after).utf8) },
      submit: { _ in throw TataraError(.unavailable, detail: "Demo mode cannot publish reviews.") },
    )
  }
}
