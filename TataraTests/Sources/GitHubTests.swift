// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TataraCore
import TataraGitHub
import TataraSystem
import Testing

struct GitHubTests {
  @Test func `issue page skips P rs but preserves pagination`() async throws {
    let repository = try RepositoryID("owner/repo", host: "github.example.com")
    let runner = CommandRunner { executable, arguments, _ in
      #expect(executable == "gh")
      #expect(arguments.contains("github.example.com"))
      let values: [[String: Any]] = (1 ... 100).map { number in
        [
          "number": number,
          "title": "PR",
          "user": ["login": "person"],
          "body": "",
          "html_url": "https://github.example.com/owner/repo/pull/\(number)",
          "state": "open",
          "labels": [],
          "pull_request": [:],
        ]
      }
      return try CommandResult(output: JSONSerialization.data(withJSONObject: values))
    }
    let page = try await GitHubAdapter(runner: runner).list(repository, .issue, 1)
    #expect(page.items.isEmpty)
    #expect(page.nextPage == 2)
  }

  @Test func `content paths are encoded as data`() async throws {
    let runner = CommandRunner { executable, arguments, _ in
      #expect(executable == "gh")
      #expect(arguments
        .last == "repos/owner/repo/contents/Sources/odd%20%23%3F%3B%2Eswift?ref=\(String(repeating: "a", count: 40))")
      return CommandResult(output: Data([0, 255, 1]))
    }
    let data = try await GitHubAdapter(runner: runner).content(
      RepositoryID("owner/repo"),
      String(repeating: "a", count: 40),
      "Sources/odd #?;.swift",
    )
    #expect(data == Data([0, 255, 1]))
  }

  @Test func `process error is visible`() async throws {
    let runner = CommandRunner { _, _, _ in CommandResult(error: "HTTP 401: gh auth login", status: 1) }
    await #expect(throws: TataraError(.authentication, detail: "gh: HTTP 401: gh auth login")) {
      try await runner.checked("gh", ["api", "user"])
    }
  }
}
