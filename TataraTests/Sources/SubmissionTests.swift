// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TataraCore
import TataraGitHub
import TataraSystem
import Testing

struct SubmissionTests {

  // MARK: Internal

  @Test
  func `changed head prevents every write`() async throws {
    let response = try pullRequest(head: String(repeating: "c", count: 40))
    let recorder = Recorder()
    let runner = CommandRunner { _, arguments, _ in
      if arguments.contains("POST") {
        await recorder.wrote()
      }
      return CommandResult(output: response)
    }
    let submission = try ReviewSubmission(
      item: item(),
      expectedHead: String(repeating: "b", count: 40),
      event: .approve,
      body: "",
    )
    await #expect(throws: TataraError(.revisionChanged)) { try await GitHubAdapter(runner: runner).submit(submission) }
    #expect(await recorder.writes == 0)
  }

  @Test
  func `review carries exact commit and source anchor in one write`() async throws {
    let head = String(repeating: "b", count: 40)
    let response = try pullRequest(head: head)
    let recorder = Recorder()
    let runner = CommandRunner { executable, arguments, input in
      #expect(executable == "gh")
      if arguments.contains("POST") {
        await recorder.wrote()
        #expect(arguments.contains("repos/owner/repo/pulls/7/reviews"))
        #expect(arguments.suffix(2) == ["--input", "-"])
        let payload = try #require(JSONSerialization.jsonObject(with: Data((input ?? "").utf8)) as? [String: Any])
        #expect(payload["commit_id"] as? String == head)
        #expect(payload["event"] as? String == "COMMENT")
        let comment = try #require((payload["comments"] as? [[String: Any]])?.first)
        #expect(comment["path"] as? String == "Sources/File.swift")
        #expect(comment["line"] as? Int == 12)
        #expect(comment["side"] as? String == "RIGHT")
        #expect(comment["body"] as? String == "Check this boundary.")
        return CommandResult()
      }
      return CommandResult(output: response)
    }
    let submission = try ReviewSubmission(
      item: item(),
      expectedHead: head,
      event: .comment,
      body: "",
      comments: [.init(path: "Sources/File.swift", line: 12, side: .right, body: "Check this boundary.")],
    )
    try await GitHubAdapter(runner: runner).submit(submission)
    #expect(await recorder.writes == 1)
  }

  @Test
  func `misspelled configuration does not silently default`() throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("tatara-config-\(UUID()).toml")
    defer { try? FileManager.default.removeItem(at: path) }
    try "them = \"latte\"".write(to: path, atomically: true, encoding: .utf8)
    #expect(throws: TataraError.self) { try Configuration.load(path: path.path) }
  }

  // MARK: Private

  private actor Recorder {
    var writes = 0

    func wrote() {
      writes += 1
    }
  }

  private func item() throws -> ForgeItem {
    try ForgeItem(
      id: .init(repository: RepositoryID("owner/repo"), number: 7),
      kind: .pullRequest,
      title: "Example",
      author: "author",
      url: #require(URL(string: "https://github.com/owner/repo/pull/7")),
    )
  }

  private func pullRequest(head: String) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
      "number": 7,
      "title": "Example",
      "user": ["login": "author"],
      "body": "",
      "html_url": "https://github.com/owner/repo/pull/7",
      "state": "open",
      "labels": [],
      "draft": false,
      "merged": false,
      "changed_files": 1,
      "mergeable_state": "clean",
      "base": ["sha": String(repeating: "a", count: 40), "ref": "main", "label": "owner:main"],
      "head": ["sha": head, "ref": "feature", "label": "owner:feature"],
    ])
  }

}
