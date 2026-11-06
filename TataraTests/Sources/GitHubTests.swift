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

  static func listData(_ numbers: [Int], nullStatus: Bool = false, overflowing: Bool = false) throws -> Data {
    let nodes = numbers.map { number -> [String: Any] in
      var value = summary(number, nullStatus: nullStatus)
      value["labels"] = ["nodes": [["name": "bug"]], "pageInfo": ["hasNextPage": overflowing]]
      value["assignees"] = ["nodes": [["login": "owner"]], "pageInfo": ["hasNextPage": false]]
      value["milestone"] = ["title": "v2"]
      value["reviewRequests"] = ["nodes": [["requestedReviewer": ["slug": "ios"]]], "pageInfo": ["hasNextPage": false]]
      return value
    }
    return try JSONSerialization.data(withJSONObject: ["data": ["repository": ["pullRequests": [
      "nodes": nodes,
      "pageInfo": ["hasNextPage": numbers.count == 100],
    ]]]])
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
  func `initial PR page fetches complete typed metadata in one command`() async throws {
    let calls = Mutex(0)
    let runner = CommandRunner { _, arguments, input in
      calls.withLock { $0 += 1 }
      #expect(arguments.contains("graphql"))
      let json = try JSONSerialization.jsonObject(with: Data(#require(input).utf8)) as? [String: Any]
      #expect((json?["query"] as? String)?.contains("pullRequests(first: 100") == true)
      return try .init(output: Self.listData(Array(1 ... 100)))
    }
    let page = try await GitHubAdapter(runner: runner).list(RepositoryID("owner/repo"), .pullRequest, 1)
    #expect(calls.withLock { $0 } == 1)
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
        return try .init(output: Self.listData([1], nullStatus: true))
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
  func `overflowing nested list metadata is completed without truncating labels`() async throws {
    let runner = CommandRunner { _, arguments, _ in
      if arguments.contains("graphql") {
        return try .init(output: Self.listData([1], overflowing: true))
      }
      #expect(arguments.last == "repos/owner/repo/pulls/1")
      return try .init(output: JSONSerialization.data(withJSONObject: [
        "number": 1,
        "title": "PR 1",
        "html_url": "https://github.com/owner/repo/pull/1",
        "state": "open",
        "updated_at": "2026-09-10T00:00:00Z",
        "labels": (0 ..< 101).map { ["name": "label-\($0)"] },
      ]))
    }
    let page = try await GitHubAdapter(runner: runner).list(RepositoryID("owner/repo"), .pullRequest, 1)
    #expect(page.items[0].labels.count == 101)
    #expect(page.items[0].github?.commits == 2)
  }

  @Test
  func `later PR pages preserve native REST pagination and metadata enrichment`() async throws {
    let runner = CommandRunner { _, arguments, _ in
      if arguments.contains("graphql") {
        return try .init(output: Self.summaryData([101]))
      }
      #expect(arguments.last?.contains("page=2") == true)
      return .init(
        output: Data(
          #"[{"number":101,"title":"PR 101","html_url":"https://github.com/owner/repo/pull/101","state":"open","labels":[]}]"#
            .utf8
        )
      )
    }
    let page = try await GitHubAdapter(runner: runner).list(RepositoryID("owner/repo"), .pullRequest, 2)
    #expect(page.items.first?.id.number == 101)
    #expect(page.items.first?.github?.changedFiles == 3)
  }

  @Test
  func `metadata from another update snapshot is rejected`() async throws {
    let runner = CommandRunner { _, arguments, _ in
      if arguments.contains("graphql") {
        return try .init(output: Self.listData([1], overflowing: true))
      }
      return .init(
        output: Data(
          #"{"number":1,"title":"PR","html_url":"https://github.com/owner/repo/pull/1","state":"open","labels":[],"updated_at":"2026-09-09T00:00:00Z"}"#
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
