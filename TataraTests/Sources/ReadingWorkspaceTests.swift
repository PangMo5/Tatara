// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import Foundation
import Synchronization
import TataraCore
import TataraGitHub
import TataraKit
import TataraSystem
import TermLoom
import Testing

// MARK: - CommentWriteCalls

private final class CommentWriteCalls: Sendable {
  let values = Mutex<[(arguments: [String], input: String?)]>([])
}

// MARK: - ReadingWorkspaceTests

@MainActor
struct ReadingWorkspaceTests {

  // MARK: Internal

  @Test(arguments: [64, 160])
  func `wrapping preserves Unicode and source coordinates while searching complete lines`(_ width: Int) async throws {
    let source = diff()
    let document = try await DocumentRenderer.prepareDiff(source, DiffViewport(width: width, wrap: true))
    #expect(document.lines.count > source.rows.count)
    #expect(document.displayLines.allSatisfy { TerminalWidth.of($0.map(\.text).joined()) <= width })
    let location = SourceLocation(path: source.path, line: 10, side: .right)
    #expect(document.rows(for: location).count > 1)
    #expect(document.rows(for: location).allSatisfy { document.location(at: $0, side: .right) == location })
    let visible = document.rows(for: location).map { row in
      let spans = document.displayLines[row].filter { $0.side == .right }
      return spans.dropFirst().dropLast().map(\.text).joined()
    }.joined()
    #expect(visible == source.rows[0].right?.spans.map(\.text).joined().replacing("\t", with: "    "))
    let matches = try await DocumentRenderer.search(document, "needle boundary")
    #expect(matches.lines.count == 1)
    #expect(matches.lines[0] > 0)
    #expect(matches.ranges[0] != nil)
    #expect(document.location(at: matches.lines[0], side: .right) == location)
    let narrow = try await DocumentRenderer.prepareDiff(source, DiffViewport(width: width, wrap: false))
    #expect(narrow.maximumHorizontalOffset > 0)
    let offscreen = try await DocumentRenderer.search(narrow, "needle")
    #expect(offscreen.ranges.count == 1)
    #expect(offscreen.ranges[0] == nil)
    let revealed = try await DocumentRenderer.revealMatch(narrow, offscreen, 0, width)
    #expect(revealed.displayLines[0].map(\.text).joined().contains("needle"))
    #expect(revealed.location(at: 0, side: .right) == location)
  }

  @Test
  func `Vim source and display motions differ on wrapped lines`() async throws {
    var state = try WorkspaceFeature.State(repository: RepositoryID("owner/repo"))
    state.pane = .content
    state.tab = .diff
    state.document = try await DocumentRenderer.prepareDiff(diff(), DiffViewport(width: 64, wrap: true))
    let next = try #require(state.document.row(for: .init(path: "Source.swift", line: 11, side: .right)))
    let store = TestStore(initialState: state) { WorkspaceFeature() }
    store.exhaustivity = .off
    await store.send(.commandPressed(.down))
    #expect(store.state.diffCursor == next)
    await store.send(.commandPressed(.up))
    #expect(store.state.diffCursor == 0)
    await store.send(.commandPressed(.visualDown))
    #expect(store.state.diffCursor == 1)
    #expect(store.state.document.location(at: 1, side: .right)?.line == 10)
  }

  @Test
  func `paging content from Files moves the source cursor with the viewport`() async throws {
    var state = try WorkspaceFeature.State(repository: RepositoryID("owner/repo"))
    state.pane = .files
    state.tab = .diff
    state.contentHeight = 10
    let rows = (1 ... 50).map { ReviewDiffRow(left: nil, right: .init(number: $0, spans: [.init(text: "Line \($0)")])) }
    state.document = try await DocumentRenderer.prepareDiff(
      .init(path: "A.swift", language: "Swift", status: "changed", rows: rows),
      80,
    )
    state.diffCursor = 2
    let store = TestStore(initialState: state) { WorkspaceFeature() }
    store.exhaustivity = .off
    await store.send(.commandPressed(.contentPageDown))
    #expect(store.state.scroll == 8)
    #expect(store.state.diffCursor == 10)
    #expect(store.state.pane == .files)
    await store.send(.commandPressed(.contentPageUp))
    #expect(store.state.scroll == 0 && store.state.diffCursor == 2)
  }

  @Test
  func `manual horizontal scrolling refreshes search without moving the source cursor`() async throws {
    let diff = ReviewDiff(path: "A.swift", language: "Swift", status: "changed", rows: [
      .init(left: nil, right: .init(number: 1, spans: [.init(text: "needle " + String(repeating: "value ", count: 60))])),
      .init(left: nil, right: .init(number: 2, spans: [.init(text: "next line")])),
    ])
    var state = try WorkspaceFeature.State(repository: RepositoryID("owner/repo"), preferences: .init(wrap: false))
    state.pane = .content
    state.tab = .diff
    state.contentWidth = 80
    state.document = try await DocumentRenderer.prepareDiff(diff, 80)
    state.diffCursor = 1
    state.searches[.content] = .init()
    state.searches[.content]?.query = "needle"
    let matches = try await DocumentRenderer.search(state.document, "needle")
    state.searches[.content]?.result = matches
    let store = TestStore(initialState: state) { WorkspaceFeature() } withDependencies: {
      $0[DocumentClient.self] = DocumentRenderer.client
    }
    store.exhaustivity = .off
    await store.send(.horizontalScrolled(40))
    await store.receive(\.reflowResponse)
    await store.receive(\.contentResponse)
    await store.receive(\.searchRefreshed)
    await store.finish()
    #expect(store.state.document.horizontalOffset == 40)
    #expect(store.state.diffCursor == 1)
    #expect(store.state.scroll == 0)
    #expect(store.state.searches[.content]?.result.ranges == [nil])
  }

  @Test
  func `comment rows align to their source side without becoming review anchors`() async throws {
    let source = ReviewDiff(path: "A.swift", language: "Swift", status: "changed", rows: [
      .init(
        left: nil,
        right: nil,
        annotation: [.init(text: "left comment", role: .comment, commentKey: "review:1", commentSide: .left)],
      ),
      .init(
        left: nil,
        right: nil,
        annotation: [.init(text: "right comment", role: .comment, commentKey: "review:2", commentSide: .right)],
      ),
    ])
    let document = try await DocumentRenderer.prepareDiff(source, 160)
    #expect(document.displayLines[0].map(\.text).joined().hasPrefix("left"))
    #expect(document.displayLines[1].map(\.text).joined().hasPrefix(String(repeating: " ", count: document.diffSideWidth + 3)))
    #expect(document.commentKeys == ["review:1", "review:2"])
    #expect(document.location(at: 0, side: .left) == nil)
    #expect(document.location(at: 1, side: .right) == nil)
    #expect(try await DocumentRenderer.search(document, "right").lines == [1])
  }

  @Test
  func `a comment search changes the action target to the matching comment`() async throws {
    let item = try item()
    let first = DiscussionComment(id: 1, author: "author", body: "first", anchor: .init(path: "A.swift", line: 1, side: .left))
    let second = DiscussionComment(id: 2, author: "author", body: "second", anchor: .init(path: "A.swift", line: 2, side: .right))
    var state = WorkspaceFeature.State(repository: item.id.repository)
    state.items = [item]
    state.selectedItemID = item.id
    state.detail = .init(item: item, revision: .init(mergeBase: "base", head: "head"), comments: [first, second])
    state.pane = .content
    state.tab = .diff
    state.document = try await DocumentRenderer.prepareDiff(.init(path: "A.swift", language: "Swift", status: "changed", rows: [
      .init(left: nil, right: nil, annotation: [.init(text: "first", role: .commentBody, commentKey: first.key)]),
      .init(left: nil, right: nil, annotation: [.init(text: "second", role: .commentBody, commentKey: second.key)]),
    ]), 80)
    state.focusedCommentKey = first.key
    state.searches[.content] = .init()
    state.searches[.content]?.query = "second"
    let matches = try await DocumentRenderer.search(state.document, "second")
    let store = TestStore(initialState: state) { WorkspaceFeature() } withDependencies: {
      $0[ForgeClient.self].commentContext = { _, comment in .init(
        comment: comment,
        canReply: true,
        canEdit: false,
        canDelete: false,
        canReact: true,
      ) }
    }
    store.exhaustivity = .off
    await store.send(.searchResponse(generation: 0, matches: matches))
    #expect(store.state.focusedCommentKey == second.key)
    await store.send(.commandPressed(.comment))
    await store.finish()
    #expect(store.state.commentEditor?.target.id == second.id)
  }

  @Test
  func `picker Normal motions and Insert text never conflict`() async throws {
    let items = try (1 ... 50).map { try item($0) }
    var state = WorkspaceFeature.State(repository: items[0].id.repository)
    state.items = items
    state.selectedItemID = items[0].id
    state.helpHeight = 21
    state.document = try await DocumentRenderer.prepareDiff(diff(), 80)
    state.visualStart = 0
    let store = TestStore(initialState: state) { WorkspaceFeature() }
    store.exhaustivity = .off
    await store.send(.commandPressed(.pickItem))
    #expect(store.state.picker?.isEditing == false)
    for (key, selection) in [
      ("j", 1),
      ("k", 0),
      ("ctrl-d", 9),
      ("ctrl-u", 0),
      ("G", 49),
      ("g", 49),
      ("g", 0),
      ("ctrl-f", 16),
      ("ctrl-b", 0),
    ] {
      await store.send(.keyPressed(key))
      #expect(store.state.picker?.selection == selection)
      #expect(store.state.picker?.query == "")
      #expect(store.state.selectedItemID == items[0].id)
    }
    await store.send(.keyPressed("g"))
    await store.send(.keyPressed("esc"))
    #expect(store.state.picker != nil && store.state.picker?.pendingPrefix == nil)
    await store.send(.keyPressed("/"))
    for key in ["j", "k", "g"] {
      await store.send(.keyPressed(key))
      await store.receive(\.pickerMatches)
    }
    #expect(store.state.picker?.query == "jkg")
    await store.send(.keyPressed("esc"))
    #expect(store.state.picker?.isEditing == false)
    #expect(store.state.picker?.query == "jkg")
    await store.send(.keyPressed("i"))
    #expect(store.state.picker?.isEditing == true)
    await store.send(.keyPressed("esc"))
    await store.send(.keyPressed("esc"))
    #expect(store.state.picker == nil)
    #expect(store.state.visualStart == 0)
    await store.finish()
  }

  @Test
  func `picker navigation honors remaps and rejects previous dialog results`() async throws {
    let items = try (1 ... 4).map { try item($0) }
    var state = try WorkspaceFeature.State(
      repository: items[0].id.repository,
      preferences: .init(keymap: Keymap(overrides: ["down": ["J"], "up": ["K"]])),
    )
    state.items = items
    let store = TestStore(initialState: state) { WorkspaceFeature() }
    store.exhaustivity = .off
    await store.send(.commandPressed(.pickItem))
    let oldGeneration = try #require(store.state.picker?.generation)
    await store.send(.keyPressed("J"))
    #expect(store.state.picker?.selection == 1)
    await store.send(.keyPressed("K"))
    #expect(store.state.picker?.selection == 0)
    await store.send(.keyPressed("esc"))
    await store.send(.commandPressed(.pickItem))
    await store.send(.pickerMatches(generation: oldGeneration, [items[3]]))
    #expect(store.state.picker?.items == items)
  }

  @Test
  func `quick picker keeps the current selection until an item is accepted`() async throws {
    let first = try item()
    let second = try item(2)
    var state = WorkspaceFeature.State(repository: first.id.repository)
    state.items = [first, second]
    state.selectedItemID = first.id
    state.detail = .init(item: first)
    let store = TestStore(initialState: state) { WorkspaceFeature() } withDependencies: {
      $0[ForgeClient.self].detail = { .init(item: $0) }
      $0[DocumentClient.self] = DocumentRenderer.client
    }
    store.exhaustivity = .off
    await store.send(.commandPressed(.pickItem))
    await store.send(.keyPressed("/"))
    await store.send(.keyPressed("2"))
    await store.receive(\.pickerMatches)
    #expect(store.state.selectedItemID == first.id)
    #expect(store.state.picker?.items.map(\.id) == [second.id])
    await store.send(.keyPressed("enter"))
    await store.receive(\.itemSelected)
    await store.finish()
    #expect(store.state.selectedItemID == second.id)
    #expect(store.state.picker == nil && !store.state.isSelectingItems)
    #expect(store.state.pane == .files)
  }

  @Test
  func `comment mutations require a completed preview and submit exactly once`() async throws {
    let item = try item()
    let comment = DiscussionComment(id: 1, author: "author", body: "Original discussion")
    let writes = Mutex<[CommentMutation]>([])
    let (completion, complete) = AsyncStream<Void>.makeStream()
    let store = TestStore(initialState: CommentFeature.State(item: item, expectedHead: "head", target: comment)) {
      CommentFeature()
    } withDependencies: {
      $0[ForgeClient.self].commentContext = { _, comment in .init(
        comment: comment,
        canReply: true,
        canEdit: true,
        canDelete: true,
        canReact: true,
        viewer: "viewer",
      ) }
      $0[ForgeClient.self].mutateComment = { mutation in
        writes.withLock { $0.append(mutation) }
        for await _ in completion {
          break
        }
      }
      $0[DocumentClient.self] = DocumentRenderer.client
    }
    store.exhaustivity = .off
    await store.send(.appeared)
    await store.receive(\.contextResponse)
    await store.send(.bodyChanged("**Reply**"))
    await store.send(.confirmPressed)
    #expect(writes.withLock { $0.isEmpty })
    await store.send(.previewPressed(width: 80))
    await store.receive(\.previewResponse)
    #expect(store.state.isConfirming)
    #expect(store.state.preview?.searchableLines.joined().contains("@author") == true)
    await store.send(.confirmPressed)
    await store.send(.confirmPressed)
    complete.yield(())
    complete.finish()
    await store.receive(\.submissionResponse)
    await store.receive(\.delegate)
    await store.finish()
    #expect(writes.withLock { $0.count } == 1)
    #expect(writes.withLock { $0.first?.body } == "@author\n\n**Reply**")
  }

  @Test
  func `Markdown tables tasks references and quotes remain readable at narrow widths`() async throws {
    let markdown = """
      Reading notes
      ===
      - [x] Done
      - [ ] Pending
      >> **Nested quote**
      | Name | Meaning |
      | --- | --- |
      | `alpha` | a long explanation of this value |
      | beta | 한글 내용 |
      [Guide][docs]
      [docs]: https://example.com/guide
      """
    for width in [32, 80] {
      let document = try await CommentRenderer.prepare(markdown, width)
      let text = document.searchableLines.joined(separator: "\n")
      #expect(text.contains("☑ Done") && text.contains("☐ Pending"))
      #expect(text.contains("│ │ Nested quote"))
      #expect(text.contains("https://example.com/guide"))
      #expect(document.searchableLines.allSatisfy { TerminalWidth.of($0) <= width })
      #expect(document.lines.flatMap(\.self).contains { $0.bold && $0.text.contains("Reading notes") })
      #expect(text.replacing("\n", with: "").contains("alpha"))
    }
  }

  @Test(arguments: [CommentOperation.reply, .edit, .delete, .react, .resolve, .unresolve])
  func `GitHub comment operations use their native endpoints and never repeat writes`(_ operation: CommentOperation) async throws {
    let item = try item()
    let comment = DiscussionComment(
      id: 7,
      author: "author",
      body: "Existing",
      anchor: .init(path: "A.swift", line: 1, side: .right),
    )
    let writes = CommentWriteCalls()
    let runner = commentRunner(writes: writes, resolved: operation == .unresolve)
    let adapter = GitHubAdapter(runner: runner)
    let context = try await adapter.commentContext(item, comment)
    #expect(context.viewer == "viewer" && context.comment.nodeID == "node7")
    try await adapter.mutateComment(.init(
      item: item,
      expectedHead: "head",
      context: context,
      operation: operation,
      body: "New body",
    ))
    let calls = writes.values.withLock { $0 }
    #expect(calls.count == 1)
    let call = try #require(calls.first)
    switch operation {
    case .reply: #expect(call.arguments.contains("repos/owner/repo/pulls/1/comments/7/replies"))
    case .edit: #expect(call.arguments.contains("PATCH") && call.arguments.contains("repos/owner/repo/pulls/comments/7"))
    case .delete: #expect(call.arguments.contains("DELETE"))
    case .react: #expect(call.input?.contains("addReaction") == true)
    case .resolve: #expect(call.input?.contains("resolveReviewThread") == true)
    case .unresolve: #expect(call.input?.contains("unresolveReviewThread") == true)
    }
  }

  @Test(arguments: ["head", "body", "account", "permission", "owner", "author"])
  func `GitHub rejects stale comment ownership and permissions before any write`(_ change: String) async throws {
    let item = try item()
    let comment = DiscussionComment(
      id: 7,
      author: "author",
      body: "Existing",
      anchor: .init(path: "A.swift", line: 1, side: .right),
    )
    let writes = CommentWriteCalls()
    let original = try await GitHubAdapter(runner: commentRunner(writes: writes)).commentContext(item, comment)
    let changed = GitHubAdapter(runner: commentRunner(writes: writes, change: change))
    await #expect(throws: TataraError.self) {
      try await changed.mutateComment(.init(item: item, expectedHead: "head", context: original, operation: .edit, body: "Edit"))
    }
    #expect(writes.values.withLock { $0.isEmpty })
  }

  @Test
  func `a failed comment write has no automatic retry`() async throws {
    let item = try item()
    let comment = DiscussionComment(
      id: 7,
      author: "author",
      body: "Existing",
      anchor: .init(path: "A.swift", line: 1, side: .right),
    )
    let writes = CommentWriteCalls()
    let adapter = GitHubAdapter(runner: commentRunner(writes: writes, change: "failure"))
    let context = try await adapter.commentContext(item, comment)
    await #expect(throws: TataraError.self) {
      try await adapter.mutateComment(.init(item: item, expectedHead: "head", context: context, operation: .reply, body: "Reply"))
    }
    #expect(writes.values.withLock { $0.count } == 1)
  }

  // MARK: Private

  private func item(_ number: Int = 1) throws -> ForgeItem {
    try .init(
      id: .init(repository: RepositoryID("owner/repo"), number: number),
      kind: .pullRequest,
      title: "Review \(number)",
      author: "author",
      url: URL(string: "https://github.com/owner/repo/pull/\(number)")!,
    )
  }

  private func diff() -> ReviewDiff {
    .init(path: "Source.swift", language: "Swift", status: "changed", rows: [
      .init(
        left: nil,
        right: .init(
          number: 10,
          spans: [.init(text: "\t" + String(repeating: "한글👩🏽‍💻 abc ", count: 15) + "needle boundary", role: .added)],
        ),
      ),
      .init(left: nil, right: .init(number: 11, spans: [.init(text: "next source line", role: .added)])),
    ], revision: .init(mergeBase: "base", head: "head"))
  }

  private func commentRunner(writes: CommentWriteCalls, resolved: Bool = false, change: String = "") -> CommandRunner {
    CommandRunner { _, arguments, input in
      let query = input
        .flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }?["query"] as? String ?? ""
      if query.hasPrefix("mutation") || (arguments.contains("--method") && !arguments.contains("GET")) {
        writes.values.withLock { $0.append((arguments, input)) }
        if change == "failure" {
          return .init(error: "fixture failed", status: 500)
        }
        if !query.isEmpty {
          let operation = query.contains("unresolveReviewThread")
            ? "unresolveReviewThread"
            : query
              .contains("resolveReviewThread") ? "resolveReviewThread" : "addReaction"
          let object = operation == "addReaction" ? "\"subject\":{\"id\":\"node7\"}" : "\"thread\":{\"id\":\"thread1\"}"
          return .init(output: Data("{\"data\":{\"\(operation)\":{\(object)}}}".utf8))
        }
        return .init(output: Data("{}".utf8))
      }
      if query.contains("reviewThreads") {
        return .init(output: Data("""
          {"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"thread1","isResolved":\(resolved),"viewerCanResolve":true,"viewerCanUnresolve":true,"viewerCanReply":true,"comments":{"nodes":[{"id":"node7"}]}}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}
          """.utf8))
      }
      if !query.isEmpty {
        return .init(output: Data("""
          {"data":{"viewer":{"login":"\(change == "account" ? "other" : "viewer")"},"node":{"id":"node7","body":"\(change == "body" ? "Changed" : "Existing")","updatedAt":"today","url":"https://github.com/owner/repo/pull/1#discussion_r7","viewerCanUpdate":\(change != "permission"),"viewerDidAuthor":\(change != "author"),"viewerCanDelete":true,"viewerCanReact":true,"reactionGroups":[],"parent":{"number":\(change == "owner" ? 2 : 1),"locked":false,"viewerCanUpdate":true,"repository":{"nameWithOwner":"owner/repo"}}}}}
          """.utf8))
      }
      if arguments.contains("repos/owner/repo/pulls/comments/7") {
        return .init(
          output: Data(
            #"{"id":7,"node_id":"node7","user":{"login":"author"},"body":"Existing","path":"A.swift","line":1,"side":"RIGHT","updated_at":"today"}"#
              .utf8
          )
        )
      }
      if arguments.contains("repos/owner/repo/pulls/1") {
        return .init(output: Data("""
          {"number":1,"title":"Review","html_url":"https://github.com/owner/repo/pull/1","state":"open","labels":[],"draft":false,"merged":false,"base":{"sha":"base","ref":"main","label":"main"},"head":{"sha":"\(change == "head" ? "changed" : "head")","ref":"feature","label":"feature"},"changed_files":1}
          """.utf8))
      }
      throw TataraError(.invalidResponse, detail: "Unexpected fixture request: \(arguments)")
    }
  }

}
