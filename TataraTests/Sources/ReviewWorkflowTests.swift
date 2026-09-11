// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import Foundation
import TataraCore
import TataraGitHub
import TataraKit
import TataraPersistence
import TataraSystem
import Testing

struct ReviewWorkflowTests {
  @Test func `live difftastic adapter returns structured source rows`() async throws {
    var forge = ForgeClient()
    forge.content = { _, revision, _ in Data((revision.hasPrefix("a") ? "let a = 1\n" : "let a = 2\n").utf8) }
    let renderer = Difftastic(forge: forge)
    let request = try DiffRequest(
      repository: RepositoryID("owner/repo"),
      revision: .init(
        mergeBase: String(repeating: "a", count: 40),
        head: String(repeating: "b", count: 40),
      ),
      file: .init(path: "File.swift"),
      width: 130,
      theme: .mocha,
    )
    let diff = try await renderer.render(request)
    #expect(diff.rows.first?.right?.number == 1)
    #expect(diff.revision == request.revision)
  }

  @Test func `tree keeps directories distinct from files and filters with ancestors`() {
    let tree = FileTree(paths: ["a", "a/b.swift", "Sources/File10.swift", "Sources/File2.swift", "README.md"])
    #expect(Set(tree.rows.map(\.id)).count == tree.rows.count)
    #expect(tree.rows.filter { !$0.isDirectory }.map(\.path) == [
      "a/b.swift",
      "Sources/File2.swift",
      "Sources/File10.swift",
      "a",
      "README.md",
    ])
    #expect(!tree.visible(collapsed: ["Sources"]).contains { $0.path == "Sources/File2.swift" })
    #expect(tree.visible(collapsed: ["Sources"], matching: ["Sources/File2.swift"]).map(\.path) == [
      "Sources",
      "Sources/File2.swift",
    ])
  }

  @Test func `configuration selects a flat file list and rejects unknown layouts`() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".toml")
    defer { try? FileManager.default.removeItem(at: file) }
    try "files_view = \"list\"".write(to: file, atomically: true, encoding: .utf8)
    #expect(try Configuration.load(path: file.path).filesView == .list)
    #expect(Preferences().filesView == .tree)
    try "files_view = \"invalid\"".write(to: file, atomically: true, encoding: .utf8)
    #expect(throws: TataraError.self) { try Configuration.load(path: file.path) }
  }

  @Test func `sidebar width is configurable and invalid dimensions are visible errors`() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".toml")
    defer { try? FileManager.default.removeItem(at: file) }
    #expect(Preferences().sidebarWidth == 52)
    try "sidebar_width = 64".write(to: file, atomically: true, encoding: .utf8)
    #expect(try Configuration.load(path: file.path).sidebarWidth == 64)
    for invalid in ["-1", "23", "\"wide\""] {
      try "sidebar_width = \(invalid)".write(to: file, atomically: true, encoding: .utf8)
      #expect(throws: TataraError.self) { try Configuration.load(path: file.path) }
    }
  }

  @Test func `structured diff maps original source coordinates and changed tokens`() throws {
    let json = #"{"language":"Swift","status":"changed","aligned_lines":[[0,0],[1,1],[null,2],[2,3]],"chunks":[[{"lhs":{"line_number":0,"changes":[{"start":8,"end":9,"content":"1","highlight":"normal"}]},"rhs":{"line_number":0,"changes":[{"start":8,"end":9,"content":"3","highlight":"normal"}]}},{"rhs":{"line_number":2,"changes":[{"start":0,"end":3,"content":"let","highlight":"keyword"}]}}]]}"#
    let diff = try ReviewDiff.decode(
      Data(json.utf8),
      before: "let a = 1\nlet b = 2\n",
      after: "let a = 3\nlet b = 2\nlet c = 4\n",
      path: "File.swift",
    )
    #expect(diff.rows.count == 3)
    #expect(diff.rows[0].left?.number == 1)
    #expect(diff.rows[2].left == nil)
    #expect(diff.rows[2].right?.number == 3)
    #expect(diff.rows[0].right?.spans.contains(.init(text: "3", role: .added)) == true)
    let invalid = json.replacingOccurrences(of: "\"start\":8", with: "\"start\":99")
    #expect(throws: TataraError.self) { try ReviewDiff.decode(
      Data(invalid.utf8),
      before: "let a = 1\nlet b = 2\n",
      after: "let a = 3\nlet b = 2\nlet c = 4\n",
      path: "File.swift",
    ) }
  }

  @Test func `line ranges stay within a single actual patch hunk`() throws {
    let patch = "@@ -1,2 +1,2 @@ function name\n-old\n+new\n context\n@@ -20 +20 @@ next function\n-next\n+updated"
    #expect(ReviewAnchor.contains(range: 1 ... 2, side: .right, patch: patch))
    #expect(!ReviewAnchor.contains(range: 2 ... 20, side: .right, patch: patch))
    #expect(!ReviewAnchor.contains(line: 1, side: .right, patch: "+not a hunk"))
    let comment = InlineComment(path: "File.swift", line: 2, side: .right, body: "Check this range", startLine: 1)
    let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(comment)) as? [String: Any])
    #expect(json["start_line"] as? Int == 1)
    #expect(json["start_side"] as? String == "RIGHT")
    #expect(json["line"] as? Int == 2)
    #expect(json["startLine"] == nil)
  }

  @MainActor @Test func `Shift V selects a reverse range and opens its locked comment editor`() async throws {
    let repository = try RepositoryID("owner/repo")
    let item = try ForgeItem(
      id: .init(repository: repository, number: 1),
      kind: .pullRequest,
      title: "Review",
      author: "author",
      body: "",
      url: #require(URL(string: "https://github.com/owner/repo/pull/1")),
    )
    let file = ChangedFile(path: "File.swift", patch: "@@ -1,2 +1,2 @@\n-a\n-b\n+c\n+d")
    let rows = (1 ... 2).map { n in ReviewDiffRow(
      left: .init(number: n, spans: [.init(text: "old")]),
      right: .init(number: n, spans: [.init(text: "new")]),
    ) }
    var state = WorkspaceFeature.State(repository: repository)
    state.items = [item]
    state.selectedItemID = item.id
    state.detail = .init(item: item, revision: .init(mergeBase: "base", head: "head"), files: [file])
    state.selectedFilePath = file.path
    state.pane = .content
    state.tab = .diff
    state.diffCursor = 1
    state.document = .init(
      lines: [[.init(text: "a")], [.init(text: "b")]],
      diff: .init(path: file.path, language: "Swift", status: "changed", rows: rows, revision: state.detail?.revision),
      checkingCancellation: {},
    )
    let diff = try #require(state.document.diff)
    let store = TestStore(initialState: state) { WorkspaceFeature() } withDependencies: {
      $0[DiffClient.self].render = { _ in diff }
      $0[DocumentClient.self] = DocumentRenderer.client
    }
    store.exhaustivity = .off
    await store.send(.commandPressed(.selectLines))
    #expect(store.state.visualStart == 1)
    await store.send(.commandPressed(.up))
    await store.send(.commandPressed(.comment))
    #expect(store.state.review?.inlineStartLine == "1")
    #expect(store.state.review?.inlineLine == "2")
    #expect(store.state.review?.inlineSide == .right)
    #expect(store.state.review?.inlineAnchorLocked == true)
    #expect(store.state.visualStart == nil)
    await store.send(.review(.inlineBodyChanged("Preserve this draft.")))
    await store.send(.review(.addInlineButtonPressed))
    await store.send(.review(.previewButtonPressed))
    #expect(store.state.review?.isConfirming == true)
    await store.send(.reviewDismissed)
    await store.receive(\.contentResponse)
    await store.finish()
    await store.send(.commandPressed(.comment))
    #expect(store.state.review?.isEditingInline == true)
    #expect(store.state.review?.isConfirming == false)
    #expect(store.state.review?.comments.first?.body == "Preserve this draft.")
    await store.send(.review(.cancelInlineButtonPressed))
    await store.send(.review(.previewButtonPressed))
    #expect(store.state.review?.isConfirming == true)
    await store.send(.reviewDismissed)
    await store.receive(\.contentResponse)
    await store.finish()
    await store.send(.commandPressed(.review))
    #expect(store.state.review?.isEditingInline == false)
    #expect(store.state.review?.isConfirming == false)
    #expect(store.state.review?.comments.first?.body == "Preserve this draft.")
  }

  @Test func `presets survive reopening and stay repository scoped`() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("tatara-presets-\(UUID())/state.sqlite")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let one = try RepositoryID("owner/one"), two = try RepositoryID("owner/two")
    let store = try await FilterPresetStore.open(at: url)
    let preset = FilterPreset(id: "test", name: "My reviews", query: "is:open review-requested:@me")
    try await store.client.save(one, preset)
    let reopened = try await FilterPresetStore.open(at: url)
    #expect(try await reopened.client.load(one) == [preset])
    #expect(try await reopened.client.load(two).isEmpty)
    try await reopened.client.delete(two, preset.id)
    #expect(try await reopened.client.load(one) == [preset])
    try await reopened.client.delete(one, preset.id)
    #expect(try await reopened.client.load(one).isEmpty)
  }

  @Test func `remote search preserves merged pull request state`() async throws {
    let payload = #"{"total_count":1,"incomplete_results":false,"items":[{"number":1,"title":"Merged","user":{"login":"author"},"html_url":"https://github.com/owner/repo/pull/1","state":"closed","labels":[],"pull_request":{"merged_at":"2026-09-07T00:00:00Z"}}]}"#
    let adapter = GitHubAdapter(runner: .init { _, arguments, _ in
      if arguments.contains("graphql") {
        return try .init(output: GitHubTests.summaryData([1], state: "MERGED"))
      }
      return .init(output: Data(payload.utf8))
    })
    let page = try await adapter.search(RepositoryID("owner/repo"), .pullRequest, "is:merged", 1)
    #expect(page.items.first?.state == .merged)
  }

  @Test func `remote search rejects results from another repository`() async throws {
    let payload = #"{"total_count":1,"incomplete_results":false,"items":[{"number":1,"title":"Result","user":{"login":"author"},"body":"","html_url":"https://github.com/another/repo/pull/1","state":"open","labels":[]}]}"#
    let adapter = GitHubAdapter(runner: .init { executable, arguments, _ in
      #expect(executable == "gh")
      #expect(arguments.contains("q=repo:owner/repo is:pr is:open label:bug"))
      return .init(output: Data(payload.utf8))
    })
    do { _ = try await adapter.search(RepositoryID("owner/repo"), .pullRequest, "is:open label:bug", 1)
      Issue.record("Foreign search result was accepted.")
    } catch { #expect((error as? TataraError)?.code == .invalidResponse) }
  }

  @Test func `decoded file snapshots rebuild anchors without serializing derived state`() throws {
    let file = ChangedFile(path: "Source.swift", patch: "@@ -1,2 +1,2 @@\n-old\n+new\n context\n@@ -20 +20 @@\n-next\n+updated")
    let data = try JSONEncoder().encode(file)
    let decoded = try JSONDecoder().decode(ChangedFile.self, from: data)
    #expect(decoded == file)
    #expect(decoded.anchors.contains(range: 1 ... 2, side: .left))
    #expect(decoded.anchors.contains(range: 20 ... 20, side: .right))
    #expect(!decoded.anchors.contains(range: 2 ... 20, side: .right))
    #expect(!String(decoding: data, as: UTF8.self).contains("anchors"))
  }
}
