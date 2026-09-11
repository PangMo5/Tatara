// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import CustomDump
import Foundation
import Synchronization
import TataraCore
import TataraKit
import Testing

@MainActor
struct SearchWorkflowTests {
  private func state() throws -> WorkspaceFeature.State {
    let repository = try RepositoryID("owner/repo")
    let item = ForgeItem(
      id: .init(repository: repository, number: 1),
      kind: .pullRequest,
      title: "Navigation",
      author: "author",
      url: URL(string: "https://github.com/owner/repo/pull/1")!,
    )
    var state = WorkspaceFeature.State(repository: repository)
    state.items = [item]
    state.selectedItemID = item.id
    state.detail = .init(item: item, revision: .init(mergeBase: "base", head: "head"), files: [
      .init(path: "Sources/A.swift", patch: "@@ -1,2 +1,2 @@\n-a\n-b\n+c\n+d"),
      .init(path: "Sources/B.swift", patch: "@@ -1,2 +1,2 @@\n-a\n-b\n+c\n+d"),
      .init(path: "Elsewhere/C.swift", status: "removed", patch: "@@ -1 +0,0 @@\n-old"),
    ])
    state.selectedFilePath = "Sources/A.swift"
    return state
  }

  @Test func `PR slash search sends GitHub qualifiers only after Enter`() async throws {
    let calls = Mutex<[String]>([])
    let state = try state()
    let store = TestStore(initialState: state) { WorkspaceFeature() } withDependencies: {
      $0[ForgeClient.self].search = { _, kind, query, page in
        expectNoDifference(kind, .pullRequest)
        expectNoDifference(page, 1)
        calls.withLock { $0.append(query) }
        return .init(items: [])
      }
      $0[DocumentClient.self] = DocumentRenderer.client
    }
    store.exhaustivity = .off
    await store.send(.commandPressed(.search))
    for character in "is:open label:\"good first issue\" author:@me" {
      await store.send(.keyPressed(String(character)))
    }
    expectNoDifference(calls.withLock { $0 }, [])
    expectNoDifference(store.state.visibleItems, state.items)
    await store.send(.keyPressed("enter"))
    await store.receive(\.listResponse)
    await store.finish()
    expectNoDifference(calls.withLock { $0 }, ["is:open label:\"good first issue\" author:@me"])
    #expect(store.state.visibleItems.isEmpty)
    expectNoDifference(store.state.pane, .items)
  }

  @Test func `Files search reads immutable content including unchanged context and deleted files`() async throws {
    var state = try state()
    state.pane = .files
    state.searches[.files] = .init()
    state.searches[.files]?.query = "needle[0-9]"
    state.searches[.files]?.isEditing = true
    let reads = Mutex<[String: String]>([:])
    let store = TestStore(initialState: state) { WorkspaceFeature() } withDependencies: {
      $0[ForgeClient.self].content = { _, revision, path in
        reads.withLock { $0[path] = revision }
        return Data((path == "Sources/B.swift" ? "no matching content" : "unchanged\nneedle2\nend").utf8)
      }
      $0[DiffClient.self].render = { request in .init(
        path: request.file.path,
        language: "Swift",
        status: "changed",
        rows: [.init(left: nil, right: .init(number: 1, spans: [.init(text: "c")]))],
        revision: request.revision,
      ) }
      $0[DocumentClient.self] = DocumentRenderer.client
    }
    store.exhaustivity = .off
    await store.send(.keyPressed("enter"))
    await store.receive(\.fileSearchResponse)
    await store.finish()
    expectNoDifference(store.state.fileMatches, ["Sources/A.swift": [2], "Elsewhere/C.swift": [2]])
    expectNoDifference(reads.withLock { $0 }, ["Sources/A.swift": "head", "Sources/B.swift": "head", "Elsewhere/C.swift": "base"])
    expectNoDifference(store.state.visibleFiles.map(\.path), ["Sources/A.swift", "Elsewhere/C.swift"])
    #expect(store.state.visibleFileRows.contains { $0.path == "Sources" && $0.isDirectory })
    await store.send(.keyPressed("esc"))
    expectNoDifference(store.state.visibleFiles.count, 3)
  }

  @Test func `clearing Files search cancels reads and rejects stale responses`() async throws {
    var state = try state()
    state.pane = .files
    state.searches[.files] = .init()
    state.searches[.files]?.query = "needle"
    state.searches[.files]?.isEditing = true
    let (started, didStart) = AsyncStream<Void>.makeStream()
    let (pending, finishPending) = AsyncStream<Void>.makeStream()
    defer { didStart.finish()
      finishPending.finish()
    }
    let cancelled = Mutex(false)
    let store = TestStore(initialState: state) { WorkspaceFeature() } withDependencies: {
      $0[ForgeClient.self].content = { _, _, _ in
        try await withTaskCancellationHandler {
          didStart.yield(())
          for await _ in pending {}
          throw CancellationError()
        } onCancel: { cancelled.withLock { $0 = true } }
      }
    }
    store.exhaustivity = .off
    await store.send(.keyPressed("enter"))
    var iterator = started.makeAsyncIterator()
    _ = await iterator.next()
    await store.send(.keyPressed("esc"))
    await store.finish()
    #expect(cancelled.withLock { $0 })
    await store.send(.fileSearchResponse(generation: 1, .success(["Sources/B.swift": [9]])))
    #expect(store.state.fileMatches == nil)
    #expect(!store.state.isSearchingFiles)
  }

  @Test func `folder diff keeps file anchors and attaches current comments without assigning outdated ones to lines`(
  ) async throws {
    var state = try state()
    let detail = try #require(state.detail)
    state.detail = .init(item: detail.item, revision: detail.revision, files: detail.files, comments: [
      .init(id: 1, author: "reviewer", body: "Current comment", anchor: .init(path: "Sources/B.swift", line: 1, side: .right)),
      .init(
        id: 2,
        author: "reviewer",
        body: "Old comment",
        anchor: .init(path: "Sources/A.swift", line: nil, side: .left, originalLine: 1),
      ),
    ])
    state.pane = .files
    let renderedPaths = Mutex<[String]>([])
    let store = TestStore(initialState: state) { WorkspaceFeature() } withDependencies: {
      $0[DiffClient.self].render = { request in
        renderedPaths.withLock { $0.append(request.file.path) }
        return .init(path: request.file.path, language: "Swift", status: "changed", rows: (1 ... 2).map { line in
          .init(left: .init(number: line, spans: [.init(text: "old")]), right: .init(number: line, spans: [.init(text: "new")]))
        }, revision: request.revision)
      }
      $0[DocumentClient.self] = DocumentRenderer.client
    }
    store.exhaustivity = .off
    await store.send(.fileRowSelected("directory:Sources"))
    await store.receive(\.contentResponse)
    await store.finish()
    expectNoDifference(renderedPaths.withLock { $0 }, ["Sources/A.swift", "Sources/B.swift"])
    expectNoDifference(store.state.selectedDirectoryPath, "Sources")
    #expect(store.state.selectedFilePath == nil)
    let document = store.state.document
    let location = SourceLocation(path: "Sources/B.swift", line: 1, side: .right)
    let row = try #require(document.row(for: location))
    let nextSource = try #require(document.row(for: .init(path: "Sources/B.swift", line: 2, side: .right)))
    let commentRows = (row + 1) ..< nextSource
    #expect(commentRows.contains { document.displayLines[$0].map(\.text).joined().contains("@reviewer") })
    #expect(commentRows.contains { document.displayLines[$0].map(\.text).joined().contains("Current comment") })
    #expect(document.displayLines.contains { $0.map(\.text).joined().contains("Outdated") })
    #expect(commentRows.allSatisfy { document.location(at: $0, side: .right) == nil })
    await store.send(.diffCursorSelected(row: row, side: .right))
    await store.send(.commandPressed(.comment))
    expectNoDifference(store.state.review?.selectedFile?.path, "Sources/B.swift")
    expectNoDifference(store.state.review?.inlineLine, "1")
    expectNoDifference(store.state.reviewLocation, location)
    #expect(store.state.review?.inlineAnchorLocked == true)
    await store.send(.review(.inlineBodyChanged("Draft under B")))
    await store.send(.review(.addInlineButtonPressed))
    await store.send(.reviewDismissed)
    await store.receive(\.contentResponse)
    await store.finish()
    expectNoDifference(store.state.document.location(at: store.state.diffCursor, side: .right), location)
    #expect(store.state.document.displayLines.contains { $0.map(\.text).joined().contains("Draft under B") })
    await store.send(.commandPressed(.selectLines))
    await store.send(.commandPressed(.up))
    await store.send(.commandPressed(.comment))
    #expect(store.state.review == nil)
    expectNoDifference(store.state.error?.code, .invalidLine)
  }

  @Test func `search navigation moves the exact cursor even when both matches are visible`() async throws {
    var state = try state()
    state.pane = .content
    state.tab = .diff
    state.contentHeight = 20
    let diff = ReviewDiff(path: "Sources/A.swift", language: "Swift", status: "changed", rows: (1 ... 6).map { line in
      .init(left: nil, right: .init(number: line, spans: [.init(text: line == 2 || line == 5 ? "hit hit" : "other")]))
    }, revision: state.detail?.revision)
    state.document = try await DocumentRenderer.prepareDiff(diff, 80, .right)
    state.searches[.content] = .init()
    state.searches[.content]?.query = "hit"
    let matches = try await DocumentRenderer.search(state.document, "hit")
    state.searches[.content]?.result = matches
    state.diffCursor = 1
    let store = TestStore(initialState: state) { WorkspaceFeature() }
    await store.send(.commandPressed(.nextMatch)) { $0.searches[.content]?.selection = 1 }
    await store.send(.commandPressed(.nextMatch)) { $0.searches[.content]?.selection = 2
      $0.diffCursor = 4
    }
    await store.send(.commandPressed(.previousMatch)) { $0.searches[.content]?.selection = 1
      $0.diffCursor = 1
    }
    expectNoDifference(store.state.scroll, 0)
  }

  @Test func `old revision drafts are not displayed as current comments and cannot be submitted`() async throws {
    var state = try state()
    let item = try #require(state.selectedItem)
    var draft = ReviewFeature.State(item: item, expectedHead: "old-head", expectedMergeBase: "base")
    draft.comments = [.init(path: "Sources/A.swift", line: 1, side: .right, body: "Stale draft")]
    state.drafts[item.id] = draft
    state.pane = .content
    let store = TestStore(initialState: state) { WorkspaceFeature() } withDependencies: {
      $0[DiffClient.self].render = { request in .init(
        path: request.file.path,
        language: "Swift",
        status: "changed",
        rows: [.init(left: nil, right: .init(number: 1, spans: [.init(text: "Current source")]))],
        revision: request.revision,
      ) }
      $0[DocumentClient.self] = DocumentRenderer.client
    }
    store.exhaustivity = .off
    await store.send(.fileSelected("Sources/A.swift"))
    await store.receive(\.contentResponse)
    await store.finish()
    #expect(!store.state.document.displayLines.contains { $0.map(\.text).joined().contains("Stale draft") })
    await store.send(.commandPressed(.comment))
    #expect(store.state.review?.revisionChanged == true)
    await store.send(.review(.inlineBodyChanged("New draft")))
    await store.send(.review(.addInlineButtonPressed))
    expectNoDifference(store.state.review?.comments.count, 1)
    expectNoDifference(store.state.review?.error?.code, .revisionChanged)
    await store.send(.review(.previewButtonPressed))
    #expect(store.state.review?.isConfirming == false)
    await store.send(.review(.submitButtonPressed))
    #expect(store.state.review?.isSubmitting == false)
  }

  @Test(arguments: WorkspaceFeature.Pane.allCases)
  func `only Tab and Shift Tab change keyboard pane focus`(_ pane: WorkspaceFeature.Pane) async throws {
    var state = try WorkspaceFeature.State(repository: RepositoryID("owner/repo"))
    state.pane = pane
    let store = TestStore(initialState: state) { WorkspaceFeature() }
    store.exhaustivity = .off
    for key in ["h", "l", "1", "2", "3", "enter", "esc"] {
      await store.send(.keyPressed(key))
    }
    await store.finish()
    expectNoDifference(store.state.pane, pane)
    await store.send(.keyPressed("tab"))
    await store.receive(\.commandPressed)
    expectNoDifference(store.state.pane.rawValue, (pane.rawValue + 1) % 3)
    await store.send(.keyPressed("shift-tab"))
    await store.receive(\.commandPressed)
    expectNoDifference(store.state.pane, pane)
  }
}

struct SearchProjectionTests {
  @Test func `regex search is case sensitive and preserves Unicode offsets without matching line numbers`() async throws {
    let source = "\t한글 Hit hit1 hit22"
    let diff = ReviewDiff(path: "A.swift", language: "Swift", status: "changed", rows: [
      .init(left: nil, right: .init(number: 22, spans: [.init(text: source)])),
    ])
    let document = try await DocumentRenderer.prepareDiff(diff, 80, .right)
    let matches = try await DocumentRenderer.search(document, "hit[0-9]+")
    expectNoDifference(matches.lines, [0, 0])
    expectNoDifference(matches.sourceRanges, [8 ..< 12, 13 ..< 18])
    let displayed = document.displayLines[0].map(\.text).joined() as NSString
    expectNoDifference(matches.ranges.compactMap { $0.map { displayed.substring(with: NSRange($0)) } }, ["hit1", "hit22"])
    let number = try await DocumentRenderer.search(document, "22")
    expectNoDifference(number.lines, [0])
    expectNoDifference(number.highlights[0]?.count, 1)
    let insensitive = try await DocumentRenderer.search(document, "(?i)hit")
    expectNoDifference(insensitive.lines.count, 3)
    await #expect(throws: TataraError.self) { try await DocumentRenderer.search(document, "[") }
  }

  @Test func `offscreen search reveals long source text and preserves source identity`() async throws {
    let source = String(repeating: "한글 ", count: 500) + "needle"
    let diff = ReviewDiff(path: "A.swift", language: "Swift", status: "changed", rows: [
      .init(left: nil, right: .init(number: 7, spans: [.init(text: source)])),
    ])
    let document = try await DocumentRenderer.prepareDiff(diff, 80, .right)
    let matches = try await DocumentRenderer.search(document, "needle")
    expectNoDifference(matches.ranges, [nil])
    let revealed = try await DocumentRenderer.revealMatch(document, matches, 0, 80)
    #expect(revealed.displayLines[0].map(\.text).joined().contains("needle"))
    let visible = try await DocumentRenderer.search(revealed, "needle")
    #expect(visible.ranges[0] != nil)
    expectNoDifference(revealed.location(at: 0, side: .right), .init(path: "A.swift", line: 7, side: .right))
    expectNoDifference(revealed.diff, document.diff)
  }

  @Test func `labels toggle quoted qualifiers without changing quoted body searches`() {
    let query = "is:open \"label:bug\" label:bug"
    expectNoDifference(LabelQuery.toggling("bug", in: query), "is:open \"label:bug\"")
    let label = "good \"first\" issue"
    let added = LabelQuery.toggling(label, in: "author:@me")
    #expect(LabelQuery.contains(label, in: added))
    expectNoDifference(LabelQuery.toggling(label, in: added), "author:@me")
  }

  @Test func `word search honors Unicode boundaries punctuation and source offsets`() async throws {
    let spans: [DiffSpan] = [.init(text: "  한글 value value_name")]
    let first = try #require(try await SearchPattern.word(in: spans, column: 0, whole: true))
    expectNoDifference(first.range, 2 ..< 4)
    try expectNoDifference(SearchPattern(first.pattern).ranges(in: "한글 한글자"), [0 ..< 2])
    let word = try #require(try await SearchPattern.word(in: spans, column: 7, whole: true))
    expectNoDifference(word.range, 5 ..< 10)
    try expectNoDifference(SearchPattern(word.pattern).ranges(in: "value value_name"), [0 ..< 5])
    let partial = try #require(try await SearchPattern.word(in: spans, column: 7, whole: false))
    try expectNoDifference(SearchPattern(partial.pattern).ranges(in: "value value_name"), [0 ..< 5, 6 ..< 11])
    let punctuation = try #require(try await SearchPattern.word(in: [.init(text: " []")], column: 0, whole: true))
    try expectNoDifference(SearchPattern(punctuation.pattern).ranges(in: "[] [x]"), [0 ..< 2])
    #expect(try await SearchPattern.word(in: [.init(text: "  ")], column: 0, whole: true) == nil)
  }
}

extension SearchWorkflowTests {
  @Test func `hash starts backward whole word search and n preserves that direction after manual motion`() async throws {
    var state = try state()
    state.pane = .content
    state.tab = .diff
    state.contentHeight = 20
    state.diffCursor = 3
    let texts = ["token", "tokenized", "token", "token", "token"]
    state.document = try await DocumentRenderer.prepareDiff(.init(
      path: "Sources/A.swift", language: "Swift", status: "changed",
      rows: texts.enumerated().map { .init(left: nil, right: .init(number: $0.offset + 1, spans: [.init(text: $0.element)])) },
      revision: state.detail?.revision,
    ), 80, .right)
    let word = try #require(try await SearchPattern.word(in: [.init(text: "token")], column: 0, whole: true))
    let matches = try await DocumentRenderer.search(state.document, word.pattern)
    let store = TestStore(initialState: state) { WorkspaceFeature() } withDependencies: {
      $0[DocumentClient.self] = DocumentRenderer.client
    }
    await store.send(.commandPressed(.searchWordBackward)) { $0.searchGeneration = 1
      $0.isFinding = true
    }
    await store.receive(\.wordSearchResponse) {
      $0.searchGeneration = 2
      $0.searches[.content] = .init()
      $0.searches[.content]?.query = word.pattern
      $0.searches[.content]?.origin = 3
      $0.searches[.content]?.originSide = .right
      $0.searches[.content]?.originColumn = 0
      $0.searches[.content]?.direction = -1
    }
    await store.receive(\.searchResponse) {
      $0.isFinding = false
      $0.searches[.content]?.result = matches
      $0.searches[.content]?.selection = 1
      $0.diffCursor = 2
    }
    await store.send(.commandPressed(.nextMatch)) { $0.searches[.content]?.selection = 0
      $0.diffCursor = 0
    }
    await store.send(.commandPressed(.previousMatch)) { $0.searches[.content]?.selection = 1
      $0.diffCursor = 2
    }
    await store.send(.commandPressed(.down)) { $0.diffCursor = 3 }
    await store.send(.commandPressed(.nextMatch)) { $0.diffCursor = 2 }
    await store.send(.commandPressed(.search)) {
      $0.searchGeneration = 3
      $0.searches[.content]?.direction = 1
      $0.searches[.content]?.originSide = nil
      $0.searches[.content]?.originColumn = nil
      $0.searches[.content]?.origin = 2
      $0.searches[.content]?.isEditing = true
    }
    await store.send(.wordSearchResponse(generation: 2, row: 2, side: .right, column: 0, direction: -1, word))
  }

  @Test func `multi key motions resolve through the keymap and keep pane focus`() async throws {
    let initial = try state()
    let store = TestStore(initialState: initial) { WorkspaceFeature() }
    await store.send(.keyPressed("g")) { $0.pendingPrefix = "g" }
    await store.send(.keyPressed("#")) { $0.pendingPrefix = nil }
    await store.receive(\.commandPressed)
    await store.send(.keyPressed("z")) { $0.pendingPrefix = "z" }
    await store.send(.keyPressed("z")) { $0.pendingPrefix = nil }
    await store.receive(\.commandPressed)
    await store.send(.keyPressed("z")) { $0.pendingPrefix = "z" }
    await store.send(.keyPressed("esc")) { $0.pendingPrefix = nil }
    await store.receive(\.commandPressed)
    expectNoDifference(store.state.pane, .items)
    let overrides = try Keymap(overrides: ["searchWordBackward": ["g#"], "searchPartialWordBackward": ["#"]])
    expectNoDifference(overrides.command(for: "g#"), .searchWordBackward)
  }

  @Test func `viewport placement keeps source cursor and visual anchor`() async throws {
    var state = try state()
    state.pane = .content
    state.tab = .diff
    state.diffCursor = 30
    state.visualStart = 28
    state.contentHeight = 10
    state.document = try await DocumentRenderer.prepareDiff(.init(
      path: "Sources/A.swift", language: "Swift", status: "changed",
      rows: (1 ... 60).map { .init(left: nil, right: .init(number: $0, spans: [.init(text: "source")])) },
      revision: state.detail?.revision,
    ), 80, .right)
    let store = TestStore(initialState: state) { WorkspaceFeature() }
    await store.send(.commandPressed(.cursorToTop)) { $0.scroll = 30 }
    await store.send(.commandPressed(.cursorToCenter)) { $0.scroll = 25 }
    await store.send(.commandPressed(.cursorToBottom)) { $0.scroll = 21 }
    expectNoDifference(store.state.diffCursor, 30)
    expectNoDifference(store.state.visualStart, 28)
  }
}
