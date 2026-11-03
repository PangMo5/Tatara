// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Synchronization
import TataraCore
import TataraGitHub
import TataraSystem
import Testing

struct GitHubTests {
  static func summary(_ number: Int, state: String = "OPEN", nullStatus: Bool = false) -> [String: Any] {
    [
      "number": number,
      "url": "https://github.com/owner/repo/pull/\(number)",
      "state": state,
      "title": "PR \(number)",
      "body": "Body",
      "author": ["login": "author"],
      "isDraft": false,
      "createdAt": "2026-09-08T00:00:00Z",
      "updatedAt": "2026-09-10T00:00:00Z",
      "headRefOid": String(repeating: "b", count: 40),
      "headRefName": "feature",
      "baseRefName": "main",
      "reviewDecision": nullStatus ? NSNull() : "CHANGES_REQUESTED",
      "statusCheckRollup": nullStatus ? NSNull() : ["state": "FAILURE"],
      "totalCommentsCount": nullStatus ? NSNull() : 7,
      "additions": 10,
      "deletions": 2,
      "changedFiles": 3,
      "commits": ["totalCount": 2],
    ]
  }

  static func summaryData(_ numbers: [Int], state: String = "OPEN", nullStatus: Bool = false) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["data": ["repository": Dictionary(uniqueKeysWithValues:
      numbers.map { ("p\($0)", summary($0, state: state, nullStatus: nullStatus)) })]])
  }

  @Test
  func `issue page skips P rs but preserves pagination`() async throws {
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

  @Test
  func `content paths are encoded as data`() async throws {
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

  @Test
  func `process error is visible`() async throws {
    let runner = CommandRunner { _, _, _ in CommandResult(error: "HTTP 401: gh auth login", status: 1) }
    await #expect(throws: TataraError(.authentication, detail: "gh: HTTP 401: gh auth login")) {
      try await runner.checked("gh", ["api", "user"])
    }
  }

  @Test
  func `PR page batches typed metadata without per item commands`() async throws {
    let calls = Mutex(0)
    let runner = CommandRunner { _, arguments, input in
      calls.withLock { $0 += 1 }
      if arguments.contains("graphql") {
        let json = try JSONSerialization.jsonObject(with: Data(#require(input).utf8)) as? [String: Any]
        #expect((json?["query"] as? String)?.contains("p100: pullRequest(number: 100)") == true)
        return try .init(output: Self.summaryData(Array(1 ... 100)))
      }
      let values: [[String: Any]] = (1 ... 100).map { number in
        [
          "number": number,
          "title": "PR",
          "html_url": "https://github.com/owner/repo/pull/\(number)",
          "state": "open",
          "labels": [["name": "bug"]],
          "updated_at": "2026-09-10T00:00:00Z",
          "assignees": [["login": "owner"]],
          "milestone": ["title": "v2"],
          "requested_teams": [["slug": "ios"]],
        ]
      }
      return try .init(output: JSONSerialization.data(withJSONObject: values))
    }
    let page = try await GitHubAdapter(runner: runner).list(RepositoryID("owner/repo"), .pullRequest, 1)
    #expect(calls.withLock { $0 } == 2)
    #expect(page.nextPage == 2)
    let info = try #require(page.items.last?.github)
    #expect(info.reviewDecision == .changesRequested)
    #expect(info.checksState == .failure)
    #expect(info.commentCount == 7)
    #expect(info.assignees == ["owner"])
    #expect(info.milestone == "v2")
    #expect(info.requestedTeams == ["ios"])
    #expect(info.additions == 10 && info.deletions == 2 && info.commits == 2)
  }

  @Test
  func `null status and comment counts remain absent`() async throws {
    let runner = CommandRunner { _, arguments, _ in
      if arguments.contains("graphql") {
        return try .init(output: Self.summaryData([1], nullStatus: true))
      }
      return .init(
        output: Data(#"[{"number":1,"title":"PR","html_url":"https://github.com/owner/repo/pull/1","state":"open","labels":[]}]"#
          .utf8)
      )
    }
    let page = try await GitHubAdapter(runner: runner).list(RepositoryID("owner/repo"), .pullRequest, 1)
    let info = try #require(page.items.first?.github)
    #expect(info.reviewDecision == nil && info.checksState == nil && info.commentCount == nil)
    #expect(info.reviewTitleKey == "Not reported")
  }

  @Test
  func `partial GraphQL errors and omitted metadata fail visibly`() async throws {
    for payload in [
      #"{"data":{"repository":{}},"errors":[{"message":"Access denied"}]}"#,
      #"{"data":{"repository":{"p1":null}}}"#,
    ] {
      let runner = CommandRunner { _, arguments, _ in
        if arguments.contains("graphql") {
          return .init(output: Data(payload.utf8))
        }
        return .init(
          output: Data(
            #"[{"number":1,"title":"PR","html_url":"https://github.com/owner/repo/pull/1","state":"open","labels":[]}]"#
              .utf8
          )
        )
      }
      await #expect(throws: TataraError.self) { try await GitHubAdapter(runner: runner).list(
        RepositoryID("owner/repo"),
        .pullRequest,
        1,
      ) }
    }
  }

  @Test
  func `metadata from another update snapshot is rejected`() async throws {
    let runner = CommandRunner { _, arguments, _ in
      if arguments.contains("graphql") {
        return try .init(output: Self.summaryData([1]))
      }
      return .init(
        output: Data(
          #"[{"number":1,"title":"PR","html_url":"https://github.com/owner/repo/pull/1","state":"open","labels":[],"updated_at":"2026-09-09T00:00:00Z"}]"#
            .utf8
        )
      )
    }
    do {
      _ = try await GitHubAdapter(runner: runner).list(RepositoryID("owner/repo"), .pullRequest, 1)
      Issue.record("Mixed snapshots were accepted.")
    } catch { #expect((error as? TataraError)?.code == .revisionChanged) }
  }
}
