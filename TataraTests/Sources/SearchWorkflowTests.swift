// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import CustomDump
import Foundation
import Synchronization
import TataraCore
import TataraKit
import Testing
@testable import TataraTUI

private func unifiedFixture() -> ReviewDiff {
  .init(path: "Example.swift", language: "Swift", status: "changed", rows: [
    .init(
      left: .init(number: 1, spans: [.init(text: "struct Example {")]),
      right: .init(number: 1, spans: [.init(text: "struct Example {")]),
    ),
    .init(
      left: .init(number: 2, spans: [.init(text: "  let oldValue = 1", role: .removed, highlight: "keyword")]),
      right: .init(number: 2, spans: [.init(text: "  var newValue = 2", role: .added, highlight: "keyword")]),
    ),
    .init(left: .init(number: 3, spans: [.init(text: "  obsolete()", role: .removed)]), right: nil),
    .init(left: .init(number: 4, spans: [.init(text: "}")]), right: .init(number: 3, spans: [.init(text: "}")])),
  ], revision: .init(mergeBase: "base", head: "head"))
}

// MARK: - UnifiedDiffTests

@MainActor
struct UnifiedDiffTests {

  // MARK: Internal

  @Test
  func `unified movement visits removed and added rows and reviews the selected source side`() async throws {
    let initialState = try await state()
    let store = TestStore(initialState: initialState) { WorkspaceFeature() }
    await store.send(.commandPressed(.down)) { $0.diffCursor = 1
      $0.diffSide = .left
    }
    await store.send(.commandPressed(.down)) { $0.diffCursor = 2 }
    await store.send(.commandPressed(.down)) { $0.diffCursor = 3
      $0.diffSide = .right
    }
    await store.send(.commandPressed(.up)) { $0.diffCursor = 2
      $0.diffSide = .left
    }
    store.exhaustivity = .off
    await store.send(.commandPressed(.comment))
    #expect(store.state.review?.inlineSide == .left)
    #expect(store.state.review?.inlineLine == "3")
    #expect(store.state.review?.selectedFile?.path == "Example.swift")
    #expect(store.state.review?.inlineAnchorLocked == true)
    await store.finish()
  }

  @Test
  func `unified side switching keeps both sides visible without requesting another diff`() async throws {
    var state = try await state()
    state.diffCursor = 1
    state.diffSide = .left
    let store = TestStore(initialState: state) { WorkspaceFeature() }
    await store.send(.commandPressed(.right)) { $0.diffSide = .right
      $0.diffCursor = 3
    }
    #expect(store.state.document == state.document)
    await store.finish()
  }

  @Test
  func `resizing preserves a removed line cursor and viewport through both layouts`() async throws {
    var state = try await state()
    state.contentWidth = 120
    state.document = try await DocumentRenderer.prepareDiff(unifiedFixture(), 120)
    state.diffCursor = 2
    state.diffSide = .left
    state.scroll = 2
    let location = SourceLocation(path: "Example.swift", line: 3, side: .left)
    let store = TestStore(initialState: state) { WorkspaceFeature() } withDependencies: {
      $0[DocumentClient.self] = DocumentRenderer.client
      $0[DiffClient.self].render = { _ in unifiedFixture() }
    }
    store.exhaustivity = .off
    for width in [80, 140, 60] {
      await store.send(.viewportChanged(width: width, height: 2))
      await store.receive(\.contentResponse)
      await store.finish()
      let document = store.state.document
      #expect(document.location(at: store.state.diffCursor, side: store.state.diffSide) == location)
      #expect(document.location(at: store.state.scroll, side: .left) == location)
      #expect(document.isUnifiedDiff == (width < 100))
    }
  }

  // MARK: Private

  private func state() async throws -> WorkspaceFeature.State {
    let repository = try RepositoryID("owner/repo")
    let item = ForgeItem(
      id: .init(repository: repository, number: 1),
      kind: .pullRequest,
      title: "Unified review",
      author: "reviewer",
      url: URL(string: "https://github.com/owner/repo/pull/1")!,
    )
    var state = WorkspaceFeature.State(repository: repository)
    state.items = [item]
    state.selectedItemID = item.id
    state.selectedFilePath = "Example.swift"
    state.detail = .init(item: item, revision: unifiedFixture().revision, files: [
      .init(
        path: "Example.swift",
        patch: "@@ -1,4 +1,3 @@\n struct Example {\n-  let oldValue = 1\n-  obsolete()\n+  var newValue = 2\n }",
      )
    ])
    state.pane = .content
    state.tab = .diff
    state.contentWidth = 80
    state.contentHeight = 4
    state.document = try await DocumentRenderer.prepareDiff(unifiedFixture(), 80)
    return state
  }

}

// MARK: - SearchWorkflowTests

@MainActor
struct SearchWorkflowTests {

  // MARK: Internal

  @Test
  func `PR search keeps the loaded list and waits for confirmation before loading another PR`() async throws {
    var initial = try state()
    let second = ForgeItem(
      id: .init(repository: initial.repository, number: 2),
      kind: .pullRequest,
      title: "Fix needle",
      author: "other",
      url: try #require(URL(string: "https://github.com/owner/repo/pull/2")),
    )
    initial.items.append(second)
    initial.detailCache[second.id] = .init(item: second)
    let store = TestStore(initialState: initial) { WorkspaceFeature() } withDependencies: {
      $0[DocumentClient.self] = DocumentRenderer.client
    }
    store.exhaustivity = .off
    await store.send(.commandPressed(.search))
    await store.send(.keyPressed("n"))
    await store.receive(\.listSearchResponse)
    #expect(store.state.visibleItems == initial.items)
    #expect(store.state.selectedItemID == initial.selectedItemID)
    #expect(store.state.selectedItemIndex == 1)
    #expect(store.state.contentGeneration == initial.contentGeneration)
    await store.send(.keyPressed("esc"))
    #expect(store.state.selectedItemIndex == 0)
    #expect(store.state.selectedItemID == initial.selectedItemID)
    await store.send(.commandPressed(.search))
    await store.send(.keyPressed("2"))
    await store.receive(\.listSearchResponse)
    await store.send(.keyPressed("enter"))
    await store.receive(\.itemSelected)
    await store.finish()
    #expect(store.state.selectedItemID == second.id)
    #expect(store.state.visibleItems == initial.items)
    #expect(store.state.activeFilter.isEmpty)
  }

  @Test
  func `forge filters submit qualifiers without creating a local search`() async throws {
    var initial = try state()
    initial.filterEditor = .init(repository: initial.repository, kind: .pullRequest, query: "")
    let queries = Mutex<[String]>([])
    let store = TestStore(initialState: initial) { WorkspaceFeature() } withDependencies: {
      $0[ForgeClient.self].search = { _, _, query, _ in
        queries.withLock { $0.append(query) }
        return .init(items: [])
      }
      $0[DocumentClient.self] = DocumentRenderer.client
    }
    store.exhaustivity = .off
    await store.send(.filterEditor(.delegate(.apply("is:open label:bug author:@me"))))
    await store.receive(\.listResponse)
    await store.finish()
    #expect(queries.withLock { $0 } == ["is:open label:bug author:@me"])
    #expect(store.state.activeFilter == "is:open label:bug author:@me")
    #expect(store.state.searches[.items]?.isActive == false)
  }

  @Test(arguments: [FilesView.tree, .list])
  func `Files search preserves all rows finds hidden paths and wraps from the actual cursor`(_ view: FilesView) async throws {
    var initial = try state()
    initial.pane = .files
    initial.preferences.filesView = view
    initial.collapsedDirectories = ["Elsewhere"]
    let store = TestStore(initialState: initial) { WorkspaceFeature() } withDependencies: {
      $0[DiffClient.self].render = { request in .init(
        path: request.file.path,
        language: "Swift",
        status: "changed",
        rows: [],
        revision: request.revision,
      ) }
      $0[DocumentClient.self] = DocumentRenderer.client
    }
    store.exhaustivity = .off
    await store.send(.commandPressed(.search))
    await store.send(.keyPressed("C"))
    await store.receive(\.listSearchResponse)
    #expect(store.state.fileCursor?.path == "Elsewhere/C.swift")
    #expect(store.state.selectedFilePath == "Sources/A.swift")
    #expect(store.state.contentGeneration == initial.contentGeneration)
    #expect(store.state.visibleFiles == initial.visibleFiles)
    await store.send(.keyPressed("esc"))
    #expect(store.state.collapsedDirectories == initial.collapsedDirectories)
    #expect(store.state.fileCursor?.path == "Sources/A.swift")
    await store.send(.commandPressed(.search))
    for key in ["[", "A", "C", "]"] { await store.send(.keyPressed(key)) }
    await store.receive(\.listSearchResponse)
    await store.send(.keyPressed("enter"))
    await store.receive(\.fileSelected)
    await store.receive(\.contentResponse)
    await store.finish()
    #expect(store.state.selectedFilePath == "Elsewhere/C.swift")
    #expect(store.state.visibleFiles.count == 3)
    #expect(store.state.visibleFileRows.contains { $0.path == "Sources/B.swift" })
    await store.send(.commandPressed(.nextMatch))
    await store.receive(\.fileSelected)
    await store.receive(\.contentResponse)
    await store.finish()
    #expect(store.state.selectedFilePath == "Sources/A.swift")
    await store.send(.commandPressed(.previousMatch))
    await store.receive(\.fileSelected)
    await store.receive(\.contentResponse)
    await store.finish()
    #expect(store.state.selectedFilePath == "Elsewhere/C.swift")
    await store.send(.keyPressed("esc"))
    #expect(store.state.visibleFiles.count == 3)
  }

  @Test
  func `invalid incremental pattern stays editable and cancels without a workspace error`() async throws {
    var initial = try state()
    initial.pane = .files
    let store = TestStore(initialState: initial) { WorkspaceFeature() }
    store.exhaustivity = .off
    await store.send(.commandPressed(.search))
    await store.send(.keyPressed("["))
    await store.receive(\.listSearchResponse)
    #expect(store.state.listSearchError != nil)
    #expect(store.state.error == nil)
    #expect(store.state.isSearching)
    await store.send(.keyPressed("esc"))
    #expect(!store.state.isSearching)
    #expect(store.state.listSearchError == nil)
    #expect(store.state.visibleFileRows == initial.visibleFileRows)
  }

  @Test
  func `late local search results cannot move a cancelled search cursor`() async throws {
    var initial = try state()
    initial.pane = .files
    let store = TestStore(initialState: initial) { WorkspaceFeature() }
    store.exhaustivity = .off
    await store.send(.commandPressed(.search))
    let generation = store.state.listSearchGeneration
    await store.send(.keyPressed("esc"))
    await store.send(.listSearchResponse(
      scope: .files,
      generation: generation,
      .success(.init(ids: ["file:Elsewhere/C.swift"], rows: [2])),
    ))
    #expect(store.state.selectedFilePath == initial.selectedFilePath)
    #expect(store.state.listSearchResults[.files] == nil)
  }

  @Test
  func `content results read immutable source and retain old and new line identities`() async throws {
    let initial = try state()
    let reads = Mutex<[String: String]>([:])
    let detail = try #require(initial.detail)
    let store = TestStore(initialState: FileContentSearchFeature.State(
      detail: detail,
      keymap: initial.preferences.keymap,
    )) {
      FileContentSearchFeature()
    } withDependencies: {
      $0[ForgeClient.self].content = { _, revision, path in
        reads.withLock { $0[path] = revision }
        return Data((path == "Sources/B.swift" ? "no matching content" : "unchanged\nneedle2 😀\nend").utf8)
      }
    }
    store.exhaustivity = .off
    for key in "needle[0-9]" { await store.send(.keyPressed(String(key))) }
    #expect(reads.withLock { $0 }.isEmpty)
    await store.send(.keyPressed("enter"))
    await store.receive(\.response)
    await store.finish()
    #expect(store.state.results.map(\.location) == [
      .init(path: "Sources/A.swift", line: 2, side: .right),
      .init(path: "Elsewhere/C.swift", line: 2, side: .left),
    ])
    #expect(store.state.results.allSatisfy { $0.excerpt == "needle2 😀" })
    #expect(reads.withLock { $0 } == ["Sources/A.swift": "head", "Sources/B.swift": "head", "Elsewhere/C.swift": "base"])
  }

  @Test
  func `closing content results cancels reads without changing the file tree`() async throws {
    var initial = try state()
    initial.pane = .files
    initial.fileSearch = .init(detail: try #require(initial.detail), keymap: initial.preferences.keymap)
    initial.fileSearch?.query = "needle"
    let (started, didStart) = AsyncStream<Void>.makeStream()
    let (pending, finishPending) = AsyncStream<Void>.makeStream()
    defer { didStart.finish()
      finishPending.finish()
    }
    let cancelled = Mutex(false)
    let store = TestStore(initialState: initial) { WorkspaceFeature() } withDependencies: {
      $0[ForgeClient.self].content = { _, _, _ in
        try await withTaskCancellationHandler {
          didStart.yield(())
          for await _ in pending { }
          throw CancellationError()
        } onCancel: { cancelled.withLock { $0 = true } }
      }
    }
    store.exhaustivity = .off
    await store.send(.keyPressed("enter"))
    var iterator = started.makeAsyncIterator()
    _ = await iterator.next()
    await store.send(.keyPressed("esc"))
    await store.receive(\.fileSearch.delegate)
    await store.finish()
    #expect(cancelled.withLock { $0 })
    #expect(store.state.fileSearch == nil)
    #expect(store.state.visibleFileRows == initial.visibleFileRows)
    #expect(store.state.selectedFilePath == initial.selectedFilePath)
  }

  @Test
  func `content result opens its exact source side and line without filtering Files`() async throws {
    var initial = try state()
    initial.pane = .files
    let requests = Mutex<[DiffRequest]>([])
    let store = TestStore(initialState: initial) { WorkspaceFeature() } withDependencies: {
      $0[ForgeClient.self].content = { _, _, path in Data((path == "Sources/B.swift" ? "first\nneedle\nlast" : "other").utf8) }
      $0[DiffClient.self].render = { request in
        requests.withLock { $0.append(request) }
        return .init(path: request.file.path, language: "Swift", status: "changed", rows: [
          .init(left: nil, right: .init(number: 2, spans: [.init(text: "needle")]))
        ], revision: request.revision)
      }
      $0[DocumentClient.self] = DocumentRenderer.client
    }
    store.exhaustivity = .off
    await store.send(.commandPressed(.searchFileContents))
    for key in "needle" { await store.send(.keyPressed(String(key))) }
    await store.send(.keyPressed("enter"))
    await store.receive(\.fileSearch.response)
    #expect(store.state.selectedFilePath == initial.selectedFilePath)
    await store.send(.keyPressed("enter"))
    await store.receive(\.fileSearch.delegate)
    await store.receive(\.contentResponse)
    await store.finish()
    let expected = SourceLocation(path: "Sources/B.swift", line: 2, side: .right)
    #expect(requests.withLock { $0.last?.revealing } == expected)
    #expect(store.state.document.location(at: store.state.diffCursor, side: store.state.diffSide) == expected)
    #expect(store.state.visibleFiles == initial.visibleFiles)
    #expect(store.state.pane == .content)
  }

  @Test
  func `content results from an old head cannot open against a refreshed PR`() async throws {
    var initial = try state()
    let old = try #require(initial.detail)
    let hit = FileContentHit(location: .init(path: "Sources/A.swift", line: 1, side: .right), excerpt: "needle", ranges: [0..<6])
    initial.fileSearch = .init(detail: old, keymap: initial.preferences.keymap)
    initial.fileSearch?.results = [hit]
    initial.fileSearch?.isEditing = false
    initial.detail = .init(item: old.item, revision: .init(mergeBase: "base", head: "new-head"), files: old.files)
    let store = TestStore(initialState: initial) { WorkspaceFeature() }
    store.exhaustivity = .off
    await store.send(.fileSearch(.delegate(.open(hit))))
    #expect(store.state.fileSearch == nil)
    #expect(store.state.error?.code == .revisionChanged)
    #expect(store.state.contentGeneration == initial.contentGeneration)
  }

  @Test(arguments: ["Sources", "/"])
  func `folder diff keeps file anchors and attaches current comments without assigning outdated ones to lines`(
    directory: String
  ) async throws {
    var state = try state()
    let detail = try #require(state.detail)
    state.detail = .init(
      item: detail.item,
      revision: detail.revision,
      files: detail.files + [.init(path: "Root.swift")],
      comments: [
        .init(id: 1, author: "reviewer", body: "Current comment", anchor: .init(path: "Sources/B.swift", line: 1, side: .right)),
        .init(
          id: 2,
          author: "reviewer",
          body: "Old comment",
          anchor: .init(path: "Sources/A.swift", line: nil, side: .left, originalLine: 1),
        ),
      ],
    )
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
    await store.send(.fileRowSelected("directory:" + directory))
    await store.receive(\.contentResponse)
    await store.finish()
    let expectedPaths = directory == "/"
      ? ["Sources/A.swift", "Sources/B.swift", "Elsewhere/C.swift", "Root.swift"]
      : [
        "Sources/A.swift",
        "Sources/B.swift",
      ]
    expectNoDifference(renderedPaths.withLock { $0.sorted() }, expectedPaths.sorted())
    expectNoDifference(store.state.selectedDirectoryPath, directory)
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

  @Test
  func `combined diff reads overlap within a fixed bound and retain source file order`() async throws {
    var initial = try state()
    let detail = try #require(initial.detail)
    let files = (0 ..< 8).map { ChangedFile(path: "Batch/File\($0).swift") }
    initial.detail = .init(item: detail.item, revision: detail.revision, files: files)
    initial.pane = .files
    let activity = Mutex((active: 0, maximum: 0, completed: [String]()))
    let store = TestStore(initialState: initial) { WorkspaceFeature() } withDependencies: {
      $0[DiffClient.self].render = { request in
        activity.withLock { $0.active += 1
          $0.maximum = max($0.maximum, $0.active)
        }
        defer { activity.withLock { $0.active -= 1 } }
        let index = try #require(files.firstIndex { $0.path == request.file.path })
        // Simulate independent providers finishing out of order, not UI settling.
        try await Task.sleep(for: .milliseconds((8 - index) * 10))
        activity.withLock { $0.completed.append(request.file.path) }
        return ReviewDiff(path: request.file.path, language: "Swift", status: "changed", rows: [
          .init(left: nil, right: .init(number: 1, spans: [.init(text: request.file.path)]))
        ], revision: request.revision)
      }
      $0[DocumentClient.self] = DocumentRenderer.client
    }
    store.exhaustivity = .off
    await store.send(.fileRowSelected("directory:/"))
    await store.receive(\.contentResponse)
    await store.finish()
    let observed = activity.withLock { $0 }
    #expect(observed.maximum == 4)
    #expect(observed.active == 0)
    #expect(observed.completed != files.map(\.path))
    let diff = try #require(store.state.document.diff)
    let paths = diff.rows.filter { $0.left != nil || $0.right != nil }.compactMap(\.path)
    expectNoDifference(paths, files.map(\.path))
  }

  @Test
  func `search navigation moves the exact cursor even when both matches are visible`() async throws {
    var state = try state()
    state.pane = .content
    state.tab = .diff
    state.contentHeight = 20
    let diff = ReviewDiff(path: "Sources/A.swift", language: "Swift", status: "changed", rows: (1 ... 6).map { line in
      .init(left: nil, right: .init(number: line, spans: [.init(text: line == 2 || line == 5 ? "hit hit" : "other")]))
    }, revision: state.detail?.revision)
    state.document = try await DocumentRenderer.prepareDiff(diff, 80)
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

  @Test
  func `old revision drafts are not displayed as current comments and cannot be submitted`() async throws {
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
  func `pane cycles stay within the active screen`(_ pane: WorkspaceFeature.Pane) async throws {
    var state = try WorkspaceFeature.State(repository: RepositoryID("owner/repo"))
    state.pane = pane
    state.isSelectingItems = pane == .items
    let store = TestStore(initialState: state) { WorkspaceFeature() }
    store.exhaustivity = .off
    for key in ["h", "l", "1", "2", "3", "enter"] {
      await store.send(.keyPressed(key))
    }
    await store.finish()
    expectNoDifference(store.state.pane, pane)
    await store.send(.keyPressed("tab"))
    await store.receive(\.commandPressed)
    expectNoDifference(store.state.pane, pane == .content ? .files : .content)
    await store.send(.keyPressed("shift-tab"))
    await store.receive(\.commandPressed)
    expectNoDifference(store.state.pane, pane)
  }

  // MARK: Private

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

}

// MARK: - SearchProjectionTests

struct SearchProjectionTests {
  @Test
  func `unified comments stay directly below their actual old or new source row`() async throws {
    let old = SourceLocation(path: "A.swift", line: 1, side: .left)
    let new = SourceLocation(path: "A.swift", line: 1, side: .right)
    let source = ReviewDiff(path: "A.swift", language: "Swift", status: "changed", rows: [
      .init(
        left: .init(number: 1, spans: [.init(text: "old", role: .removed)]),
        right: .init(number: 1, spans: [.init(text: "new", role: .added)]),
      ),
      .init(left: nil, right: nil, annotation: [.init(text: "Left comment", role: .comment)], annotationLocation: old),
      .init(left: nil, right: nil, annotation: [.init(text: "Left body", role: .commentBody)], annotationLocation: old),
      .init(left: nil, right: nil, annotation: [.init(text: "Right comment", role: .comment)], annotationLocation: new),
    ])
    let document = try await DocumentRenderer.prepareDiff(source, 80)
    #expect(document.row(for: old) == 0)
    #expect(document.row(for: new) == 3)
    #expect(document.displayLines[1].map(\.text).joined() == "Left comment")
    #expect(document.displayLines[2].map(\.text).joined() == "Left body")
    #expect(document.displayLines[4].map(\.text).joined() == "Right comment")
    #expect(document.location(at: 1, side: .left) == nil)
    #expect(document.counterpartRow(at: 0, side: .right) == 3)
  }

  @Test(arguments: [40, 80, 99, 100, 140])
  func `every layout preserves deleted added and shared source identities`(_ width: Int) async throws {
    let source = unifiedFixture()
    let document = try await DocumentRenderer.prepareDiff(source, width)
    let text = document.displayLines.lazy.map { $0.map(\.text).joined() }.joined(separator: "\n")
    #expect(text.contains("oldValue") && text.contains("newValue") && text.contains("obsolete()"))
    for (side, count) in [(InlineComment.Side.left, 4), (.right, 3)] {
      for line in 1 ... count {
        let location = SourceLocation(path: source.path, line: line, side: side)
        let row = try #require(document.row(for: location))
        #expect(document.location(at: row, side: side) == location)
      }
    }
    let old = try await DocumentRenderer.search(document, "oldValue|obsolete")
    #expect(old.lines.count == 2 && old.sides.allSatisfy { $0 == .left })
    for (index, row) in old.lines.enumerated() {
      let range = try #require(old.ranges[index])
      let shown = document.displayLines[row].map(\.text).joined() as NSString
      #expect(["oldValue", "obsolete"].contains(shown.substring(with: NSRange(range))))
    }
    if width < 100 {
      #expect(document.diff?.rows.count == 5)
      #expect(try await DocumentRenderer.search(document, "struct").lines.count == 1)
      #expect(document.displayLines[1].map(\.text).joined().contains("-"))
      #expect(document.displayLines[3].map(\.text).joined().contains("+"))
    }
  }

  @Test
  func `unified annotation rows do not acquire anchors and retain combined file provenance`() async throws {
    let a = unifiedFixture()
    var rows = a.rows.map { ReviewDiffRow(left: $0.left, right: $0.right, path: "A.swift") }
    rows.append(.init(left: nil, right: nil, path: "A.swift", annotation: [.init(text: "Review note", role: .commentBody)]))
    rows += a.rows.map { ReviewDiffRow(left: $0.left, right: $0.right, path: "B.swift") }
    let document = try await DocumentRenderer.prepareDiff(
      .init(path: "Sources", language: "Swift", status: "changed", rows: rows),
      80,
    )
    let note = try #require(document.displayLines.firstIndex { $0.map(\.text).joined() == "Review note" })
    #expect(document.location(at: note, side: .left) == nil)
    #expect(document.location(at: note, side: .right) == nil)
    #expect(document.row(for: .init(path: "A.swift", line: 3, side: .left)) == 2)
    #expect(document.row(for: .init(path: "B.swift", line: 3, side: .left)) == 8)
  }

  @Test
  func `unified long line search projection keeps removed rows and original alignment`() async throws {
    let diff = ReviewDiff(path: "A.swift", language: "Swift", status: "changed", rows: [
      .init(
        left: .init(number: 7, spans: [.init(text: String(repeating: "한글 ", count: 100) + "oldNeedle", role: .removed)]),
        right: .init(number: 8, spans: [.init(text: "newValue", role: .added)]),
      )
    ])
    let document = try await DocumentRenderer.prepareDiff(diff, 80)
    let matches = try await DocumentRenderer.search(document, "oldNeedle")
    #expect(matches.ranges == [nil])
    #expect(matches.sides == [.left])
    let shown = try await DocumentRenderer.revealMatch(document, matches, 0, 80)
    #expect(shown.displayLines[0].map(\.text).joined().contains("oldNeedle"))
    #expect(shown.sourceDiff == diff)
    #expect(shown.diff?.rows.map { $0.left?.number } == document.diff?.rows.map { $0.left?.number })
    #expect(shown.diff?.rows.map { $0.right?.number } == document.diff?.rows.map { $0.right?.number })
    let wide = try await DocumentRenderer.prepareDiff(#require(shown.sourceDiff), 140)
    #expect(wide.diff?.rows.count == 1)
    #expect(wide.diff?.rows.first?.left?.number == 7 && wide.diff?.rows.first?.right?.number == 8)
  }

  @Test
  func `regex search is case sensitive and preserves Unicode offsets without matching line numbers`() async throws {
    let source = "\t한글 Hit hit1 hit22"
    let diff = ReviewDiff(path: "A.swift", language: "Swift", status: "changed", rows: [
      .init(left: nil, right: .init(number: 22, spans: [.init(text: source)]))
    ])
    let document = try await DocumentRenderer.prepareDiff(diff, 80)
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

  @Test
  func `offscreen search reveals long source text and preserves source identity`() async throws {
    let source = String(repeating: "한글 ", count: 500) + "needle"
    let diff = ReviewDiff(path: "A.swift", language: "Swift", status: "changed", rows: [
      .init(left: nil, right: .init(number: 7, spans: [.init(text: source)]))
    ])
    let document = try await DocumentRenderer.prepareDiff(diff, 80)
    let matches = try await DocumentRenderer.search(document, "needle")
    expectNoDifference(matches.ranges, [nil])
    let revealed = try await DocumentRenderer.revealMatch(document, matches, 0, 80)
    #expect(revealed.displayLines[0].map(\.text).joined().contains("needle"))
    let visible = try await DocumentRenderer.search(revealed, "needle")
    #expect(visible.ranges[0] != nil)
    expectNoDifference(revealed.location(at: 0, side: .right), .init(path: "A.swift", line: 7, side: .right))
    expectNoDifference(revealed.sourceDiff, document.sourceDiff)
    expectNoDifference(revealed.diff?.rows.first?.right, document.diff?.rows.first?.right)
  }

  @Test
  func `labels toggle quoted qualifiers without changing quoted body searches`() {
    let query = "is:open \"label:bug\" label:bug"
    expectNoDifference(LabelQuery.toggling("bug", in: query), "is:open \"label:bug\"")
    let label = "good \"first\" issue"
    let added = LabelQuery.toggling(label, in: "author:@me")
    #expect(LabelQuery.contains(label, in: added))
    expectNoDifference(LabelQuery.toggling(label, in: added), "author:@me")
  }

  @Test
  func `word search honors Unicode boundaries punctuation and source offsets`() async throws {
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
  @Test
  func `hash starts backward whole word search and n preserves that direction after manual motion`() async throws {
    var state = try state()
    state.pane = .content
    state.tab = .diff
    state.contentHeight = 20
    state.diffCursor = 3
    let texts = ["token", "tokenized", "token", "token", "token"]
    state.document = try await DocumentRenderer.prepareDiff(.init(
      path: "Sources/A.swift",
      language: "Swift",
      status: "changed",
      rows: texts.enumerated().map { .init(left: nil, right: .init(number: $0.offset + 1, spans: [.init(text: $0.element)])) },
      revision: state.detail?.revision,
    ), 80)
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

  @Test
  func `multi key motions resolve through the keymap and keep pane focus`() async throws {
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
    expectNoDifference(store.state.pane, .items)
    let overrides = try Keymap(overrides: ["searchWordBackward": ["g#"], "searchPartialWordBackward": ["#"]])
    expectNoDifference(overrides.command(for: "g#"), .searchWordBackward)
  }

  @Test
  func `viewport placement keeps source cursor and visual anchor`() async throws {
    var state = try state()
    state.pane = .content
    state.tab = .diff
    state.diffCursor = 30
    state.visualStart = 28
    state.contentHeight = 10
    state.document = try await DocumentRenderer.prepareDiff(.init(
      path: "Sources/A.swift",
      language: "Swift",
      status: "changed",
      rows: (1 ... 60).map { .init(left: nil, right: .init(number: $0, spans: [.init(text: "source")])) },
      revision: state.detail?.revision,
    ), 80)
    let store = TestStore(initialState: state) { WorkspaceFeature() }
    await store.send(.commandPressed(.cursorToTop)) { $0.scroll = 30 }
    await store.send(.commandPressed(.cursorToCenter)) { $0.scroll = 25 }
    await store.send(.commandPressed(.cursorToBottom)) { $0.scroll = 21 }
    expectNoDifference(store.state.diffCursor, 30)
    expectNoDifference(store.state.visualStart, 28)
  }
}
