// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TataraCore
import TataraKit

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
      invalidate: { _ in },
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
            github: .init(
              createdAt: "2026-09-08T03:00:00Z",
              updatedAt: "2026-09-10T03:00:00Z",
              assignees: ["maintainer"],
              milestone: "Next release",
              requestedReviewers: ["reviewer"],
              commentCount: 3 + offset,
              reviewDecision: kind == .issue ? nil : offset == 0 ? .approved : .reviewRequired,
              checksState: kind == .issue ? nil : offset == 2 ? .pending : .success,
              headOID: kind == .issue ? nil : String(repeating: "b", count: 40),
              headBranch: kind == .issue ? nil : "fix/review-navigation",
              baseBranch: kind == .issue ? nil : "main",
              additions: kind == .issue ? nil : 12,
              deletions: kind == .issue ? nil : 4,
              changedFiles: kind == .issue ? nil : 2,
              commits: kind == .issue ? nil : 1,
            ),
          )
        })
      },
      search: { repository, kind, query, page in
        if LabelQuery.contains("bug", in: query) || LabelQuery.contains("documentation", in: query) {
          return ItemPage(items: [])
        }
        if query.contains("is:closed") || query.contains("is:merged") || query
          .contains("draft:true")
        {
          return ItemPage(items: [])
        }
        return try await client(repository).list(repository, kind, page)
      },
      labels: { _ in ["bug", "documentation", "enhancement", "good first issue"] },
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
          ), .init(
            path: "Sources/Selection.swift", additions: 2, deletions: 1,
            patch: "@@ -4,3 +4,4 @@\n   func next(after index: Int) -> String? {\n-    files[index + 1]\n+    guard files.indices.contains(index + 1) else { return nil }\n+    return files[index + 1]\n   }",
          )] : [],
          comments: [
            .init(id: 1, author: "reviewer", body: "Please keep the empty collection case covered by a test."),
            .init(
              id: 2,
              author: "reviewer",
              body: """
              Boundary case checked.

              **Keep the empty collection case covered.** Check `nil` before accessing the next file.

              > Preserve the selected file when the list refreshes.

              - Empty collection
              - Last selected file
              - Repeated navigation during loading

              ```swift
              let hasNext = files.indices.contains(index + 1)
              ```
              """,
              anchor: item.kind == .pullRequest ? .init(path: "Sources/ReviewQueue.swift", line: 5, side: .right) : nil,
            ),
            .init(
              id: 3,
              author: "reviewer",
              body: "Previous implementation discussion.",
              anchor: item.kind == .pullRequest ? .init(
                path: "Sources/ReviewQueue.swift",
                line: nil,
                side: .left,
                originalLine: 5,
              ) : nil,
            ),
          ],
          metadata: item.kind == .pullRequest ? .github(.init(
            baseBranch: "main",
            headBranch: "fix/review-navigation",
            mergeableState: "clean",
            checks: ["Swift Testing: success", "REUSE: success"],
            reviews: ["@reviewer: COMMENTED"],
          )) : nil,
        )
      },
      content: { _, revision, path in
        let source = revision.hasPrefix("a") ? before : after
        return Data((path.hasSuffix("Selection.swift") ? source
            .replacingOccurrences(of: "ReviewQueue", with: "Selection") : source).utf8)
      },
      submit: { _ in throw TataraError(.unavailable, detail: "Demo mode cannot publish reviews.") },
    )
  }
}
