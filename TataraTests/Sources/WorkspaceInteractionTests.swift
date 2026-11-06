// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import Foundation
import Observation
import Synchronization
import TataraCore
import TataraKit
import Testing

@MainActor
struct WorkspaceInteractionTests {

  // MARK: Internal

  @Test
  func `enter opens the selected PR into files and the selected file into diff`() async throws {
    let item = try item()
    var state = WorkspaceFeature.State(repository: item.id.repository, preferences: .init(filesView: .list))
    state.items = [item]
    state.selectedItemID = item.id
    state.detail = .init(item: item, files: [.init(path: "A.swift")])
    state.selectedFilePath = "A.swift"
    state.tab = .diff
    state.isPreparingDocument = true
    let store = TestStore(initialState: state) { WorkspaceFeature() }
    await store.send(.keyPressed("enter"))
    await store.receive(\.commandPressed) { $0.pane = .files }
    await store.send(.keyPressed("enter"))
    await store.receive(\.commandPressed) { $0.pane = .content }
    await store.receive(\.fileSelected)
  }

  @Test
  func `sidebar scroll remains stationary until selection crosses either context margin`() {
    func offset(_ selected: Int, _ previous: Int, total: Int = 100, page: Int = 10) -> Int {
      ScrollMetrics.selectionOffset(selected: selected, total: total, page: page, previous: previous)
    }
    #expect(offset(20, 0) == 13)
    for selected in 15 ... 20 {
      #expect(offset(selected, 13) == 13)
    }
    #expect(offset(14, 13) == 12)
    #expect(offset(15, 12) == 12)
    #expect(offset(19, 12) == 12)
    #expect(offset(20, 12) == 13)
    #expect(offset(0, 13) == 0)
    #expect(offset(99, 0) == 90)
    #expect(offset(2, 90, total: 3) == 0)
    #expect(offset(20, 13, page: 5) == 18)
    #expect(offset(20, 13, page: 1) == 20)
  }

  @Test(arguments: [false, true])
  func `loading file selection does not invalidate unchanged content state`(hasSearchState: Bool) async throws {
    let item = try item()
    var state = WorkspaceFeature.State(repository: item.id.repository)
    state.items = [item]
    state.selectedItemID = item.id
    state.detail = .init(
      item: item,
      revision: .init(mergeBase: String(repeating: "a", count: 40), head: String(repeating: "b", count: 40)),
      files: [.init(path: "A.swift"), .init(path: "B.swift")],
    )
    state.selectedFilePath = "A.swift"
    state.pane = .files
    state.tab = .diff
    state.isLoadingDiff = true
    state.isPreparingDocument = true
    if hasSearchState {
      state.searches[.content] = .init()
    }
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    defer { continuation.finish() }
    // Exercise the live observation boundary used by the view, not a reducer snapshot.
    let store = Store(initialState: state) { WorkspaceFeature() } withDependencies: {
      $0[DiffClient.self].render = { _ in
        for await _ in stream { }
        throw CancellationError()
      }
    }
    let changes = Mutex(0)
    withObservationTracking {
      _ = store.state.isLoadingDiff
      _ = store.state.isDocumentCurrent
      _ = store.state.searches[.content]?.matchingLines
    } onChange: {
      changes.withLock { $0 += 1 }
    }

    let task = store.send(.fileSelected("B.swift"))

    #expect(store.state.selectedFilePath == "B.swift")
    #expect(store.state.isLoadingDiff)
    #expect(!store.state.isDocumentCurrent)
    #expect(changes.withLock { $0 } == 0)
    #expect((store.state.searches[.content] != nil) == hasSearchState)
    store.send(.contentResponse(generation: store.state.contentGeneration, .success(.init(lines: [[.init(text: "Ready")]]))))
    #expect(!store.state.isLoadingDiff)
    #expect(store.state.isDocumentCurrent)
    #expect(changes.withLock { $0 } == 1)
    task.cancel()
    await task.finish()
  }

  @Test
  func `selection keeps an identified preview until replacement and blocks premature reviews`() async throws {
    let first = try item(1)
    let next = try item(2)
    let original = ReviewDocument(lines: (0 ..< 50).map { [.init(text: "Old source \($0)")] })
    let replacement = ReviewDocument(lines: [[.init(text: "New source")]])
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    var state = WorkspaceFeature.State(repository: first.id.repository)
    state.items = [first, next]
    state.selectedItemID = first.id
    state.detail = .init(item: first)
    state.detailCache[next.id] = .init(item: next)
    state.document = original
    state.documentTitle = "#1 · Overview"
    state.scroll = 10
    let store = TestStore(initialState: state) { WorkspaceFeature() } withDependencies: {
      $0[DocumentClient.self].prepareComment = { _, _ in
        for await _ in stream {
          return replacement
        }
        throw CancellationError()
      }
    }
    store.exhaustivity = .off
    await store.send(.itemSelected(next.id))
    #expect(store.state.isPreparingDocument)
    #expect(store.state.document == original)
    #expect(store.state.documentTitle == "#1 · Overview")
    #expect(store.state.scroll == 10)
    await store.send(.commandPressed(.review))
    #expect(store.state.review == nil)
    await store.send(.contentResponse(generation: 0, .success(.init(lines: [[.init(text: "Stale")]]))))
    #expect(store.state.document == original)
    continuation.yield(())
    continuation.finish()
    await store.receive(\.contentResponse)
    await store.finish()
    #expect(store.state.document.lines == replacement.lines.map { [.init(text: "   ", role: .commentBody)] + $0 })
    #expect(store.state.documentTitle == "#2 · Overview")
    #expect(store.state.scroll == 0)
    #expect(!store.state.isPreparingDocument)
  }

  @Test
  func `wheel targets the hovered document without changing keyboard focus`() async throws {
    var state = try WorkspaceFeature.State(repository: RepositoryID("owner/repo"))
    state.pane = .files
    state.contentHeight = 10
    state.document = .init(lines: (0 ..< 100).map { [.init(text: "Line \($0)")] })
    let store = TestStore(initialState: state) { WorkspaceFeature() }
    await store.send(.wheelScrolled(.content, delta: 6)) { $0.scroll = 6 }
    await store.send(.wheelScrolled(.content, delta: 1000)) { $0.scroll = 90 }
    await store.send(.wheelScrolled(.content, delta: -1000)) { $0.scroll = 0 }
    #expect(store.state.pane == .files)
  }

  @Test
  func `manual scrolling preserves sidebar selection pane focus and diff source cursor`() async throws {
    let items = try (1 ... 50).map { try item($0) }
    let files = (0 ..< 50).map { ChangedFile(path: "File\($0).swift") }
    var state = WorkspaceFeature.State(repository: items[0].id.repository, preferences: .init(filesView: .list))
    state.items = items
    state.selectedItemID = items[0].id
    state.detail = .init(item: items[0], files: files)
    state.selectedFilePath = files[0].path
    state.fileCursorID = "file:" + files[0].path
    state.itemsHeight = 5
    state.filesHeight = 5
    state.contentHeight = 10
    state.pane = .content
    state.tab = .diff
    state.document = .init(
      lines: (0 ..< 100).map { [.init(text: "line \($0)")] },
      diff: .init(
        path: files[0].path,
        language: "Swift",
        status: "changed",
        rows:
        (0 ..< 100).map { .init(left: nil, right: .init(number: $0 + 1, spans: [.init(text: "line \($0)")])) },
      ),
      checkingCancellation: { },
    )
    state.diffCursor = 4
    state.visualStart = 2
    let store = TestStore(initialState: state) { WorkspaceFeature() }
    await store.send(.wheelScrolled(.items, delta: 3)) { $0.itemsScroll = 3 }
    await store.send(.wheelScrolled(.files, delta: 7)) { $0.filesScroll = 7 }
    await store.send(.scrollbarMoved(.items, offset: 40)) { $0.itemsScroll = 40 }
    await store.send(.scrollbarMoved(.files, offset: 1000)) { $0.filesScroll = 45 }
    await store.send(.wheelScrolled(.content, delta: 30)) { $0.scroll = 30 }
    await store.send(.scrollbarMoved(.content, offset: 60)) { $0.scroll = 60 }
    await store.send(.commandPressed(.theme)) { $0.preferences.theme = .latte }
    #expect(store.state.pane == .content && store.state.diffCursor == 4 && store.state.visualStart == 2)
    #expect(store.state.selectedItemID == items[0].id && store.state.selectedFilePath == files[0].path)
    #expect(store.state.itemsScroll == 40 && store.state.filesScroll == 45)
    await store.send(.commandPressed(.previousPane)) { $0.pane = .files
      $0.visualStart = nil
    }
    await store.send(.commandPressed(.nextPane)) { $0.pane = .content }
    #expect(store.state.diffCursor == 4 && store.state.scroll == 60)
    await store.send(.commandPressed(.down)) { $0.diffCursor = 5
      $0.scroll = 5
    }
  }

  @Test
  func `keyboard boundary motion reveals the selection after independent scrolling`() async throws {
    let items = try (1 ... 20).map { try item($0) }
    var state = WorkspaceFeature.State(repository: items[0].id.repository)
    state.items = items
    state.selectedItemID = items[0].id
    state.itemsHeight = 5
    state.itemsScroll = 12
    let store = TestStore(initialState: state) { WorkspaceFeature() }
    await store.send(.commandPressed(.first)) { $0.itemsScroll = 0 }
  }

  @Test
  func `help owns wheel input while presented`() async throws {
    var state = try WorkspaceFeature.State(repository: RepositoryID("owner/repo"))
    state.showsHelp = true
    state.helpHeight = 5
    state.contentHeight = 10
    state.document = .init(lines: (0 ..< 100).map { [.init(text: "Line \($0)")] })
    let store = TestStore(initialState: state) { WorkspaceFeature() }
    await store.send(.wheelScrolled(.content, delta: 6))
    await store.send(.wheelScrolled(.items, delta: 6))
    await store.send(.wheelScrolled(.help, delta: 3)) { $0.helpScroll = 3 }
    await store.send(.wheelScrolled(.help, delta: -100)) { $0.helpScroll = 0 }
  }

  @Test
  func `obsolete detail failure cannot replace current selection`() async throws {
    let old = try item(1)
    let current = try item(2)
    var state = WorkspaceFeature.State(repository: current.id.repository)
    state.items = [old, current]
    state.selectedItemID = current.id
    state.detailGeneration = 5
    let store = TestStore(initialState: state) { WorkspaceFeature() }
    await store.send(.detailResponse(generation: 4, .failure(.init(.timedOut))))
  }

  @Test
  func `next match without A search does not scroll`() async throws {
    var state = try WorkspaceFeature.State(repository: RepositoryID("owner/repo"))
    state.pane = .content
    state.document = .init(lines: (0 ..< 100).map { [.init(text: "Line \($0)")] })
    let store = TestStore(initialState: state) { WorkspaceFeature() }
    await store.send(.commandPressed(.nextMatch))
    await store.send(.commandPressed(.previousMatch))
  }

  @Test
  func `committed list search clears without leaving its pane`() async throws {
    var state = try WorkspaceFeature.State(repository: RepositoryID("owner/repo"))
    state.pane = .files
    state.tab = .diff
    state.scroll = 8
    state.searches[.items] = .init()
    state.searches[.items]?.query = "Example"
    state.searches[.files] = .init()
    state.searches[.files]?.query = "swift"
    let store = TestStore(initialState: state) { WorkspaceFeature() }
    await store.send(.keyPressed("esc")) { $0.searches[.files] = .init()
      $0.listSearchGeneration = 1
    }
    #expect(store.state.pane == .files)
    #expect(store.state.scroll == 8)
    #expect(store.state.searches[.items]?.query == "Example")
  }

  @Test
  func `search does not move focus to the pull request list`() async throws {
    var state = try WorkspaceFeature.State(repository: RepositoryID("owner/repo"))
    state.pane = .files
    let store = TestStore(initialState: state) { WorkspaceFeature() }
    store.exhaustivity = .off
    await store.send(.commandPressed(.search))
    await store.send(.keyPressed("s"))
    await store.receive(\.listSearchResponse)
    await store.send(.keyPressed("enter"))
    #expect(store.state.activeSearch.isActive)
    #expect(store.state.pane == .files)
  }

  @Test(arguments: [WorkspaceFeature.Pane.items, .files])
  func `remote paging uses main viewport and preserves selection`(_ pane: WorkspaceFeature.Pane) async throws {
    let item = try item()
    var state = WorkspaceFeature.State(repository: item.id.repository)
    state.pane = pane
    state.items = [item]
    state.selectedItemID = item.id
    state.document = .init(lines: (0 ..< 100).map { [.init(text: "Line \($0)")] })
    state.contentHeight = 20
    let store = TestStore(initialState: state) { WorkspaceFeature() }
    await store.send(.keyPressed("ctrl-f"))
    await store.receive(\.commandPressed) { $0.scroll = 18 }
    await store.send(.keyPressed("ctrl-b"))
    await store.receive(\.commandPressed) { $0.scroll = 0 }
    await store.send(.commandPressed(.contentPageUp))
    #expect(store.state.pane == pane)
    #expect(store.state.selectedItemID == item.id)
  }

  @Test
  func `help search matches localized labels and actual bindings`() async throws {
    var state = try WorkspaceFeature.State(
      repository: RepositoryID("owner/repo"),
      strings: ["Page down in content": "메인 패널 아래로"],
    )
    state.pane = .files
    state.showsHelp = true
    state.searches[.help] = .init()
    state.searches[.help]?.query = "메인"
    #expect(state.visibleHelp == [.contentPageDown])
    state.searches[.help]?.query = "ctrl-f"
    #expect(state.visibleHelp == [.contentPageDown])
    let store = TestStore(initialState: state) { WorkspaceFeature() }
    await store.send(.keyPressed("esc")) { $0.searches[.help] = .init() }
    #expect(store.state.showsHelp)
    await store.send(.keyPressed("esc"))
    await store.receive(\.commandPressed) { $0.showsHelp = false }
    #expect(store.state.pane == .files)
  }

  @Test
  func `content search jumps between matches and rejects stale results`() async throws {
    var state = try WorkspaceFeature.State(repository: RepositoryID("owner/repo"))
    state.pane = .content
    state.contentHeight = 5
    state.document = .init(lines: (0 ..< 30).map { [.init(text: "Line \($0)")] })
    state.searches[.content] = .init()
    state.searches[.content]?.isEditing = true
    let store = TestStore(initialState: state) { WorkspaceFeature() } withDependencies: {
      $0[DocumentClient.self].search = { _, query in query == "L" ? [2, 20] : [] }
    }
    await store.send(.keyPressed("L")) {
      $0.searches[.content]?.query = "L"
      $0.searchGeneration = 1
      $0.isFinding = true
    }
    await store.receive(\.searchResponse) {
      $0.searches[.content]?.matches = [2, 20]
      $0.scroll = 2
      $0.isFinding = false
    }
    await store.send(.keyPressed("enter")) { $0.searches[.content]?.isEditing = false }
    await store.send(.commandPressed(.nextMatch)) { $0.searches[.content]?.selection = 1
      $0.scroll = 20
    }
    await store.send(.keyPressed("esc")) { $0.searches[.content] = .init()
      $0.searchGeneration = 2
    }
    await store.send(.searchResponse(generation: 1, matches: [29]))
    #expect(store.state.scroll == 20)
  }

  @Test
  func `detail starts without a timer and a cached revisit does not fetch again`() async throws {
    let calls = Requests()
    let items = try [item(1), item(2)]
    var state = WorkspaceFeature.State(repository: items[0].id.repository)
    state.items = items
    let store = TestStore(initialState: state) { WorkspaceFeature() } withDependencies: {
      $0.continuousClock = TestClock()
      $0[ForgeClient.self].detail = { item in
        await calls.record(item.id)
        return .init(item: item)
      }
      $0[DocumentClient.self].prepareComment = { text, _ in .init(lines: [[.init(text: text)]]) }
    }
    store.exhaustivity = .off
    for item in items {
      await store.send(.itemSelected(item.id))
      await store.receive(\.detailResponse)
      await store.finish()
    }
    #expect(await calls.ids == items.map(\.id))
    await store.send(.itemSelected(items[0].id))
    await store.finish()
    #expect(await calls.ids == items.map(\.id))
    #expect(store.state.detail?.item == items[0])
    #expect(!store.state.isLoadingDetail)
  }

  @Test
  func `failed replacement remains a preview and cannot provide search or review anchors`() async throws {
    let item = try item()
    let file = ChangedFile(path: "File.swift", patch: "@@ -1 +1 @@\n-old\n+new")
    var state = WorkspaceFeature.State(repository: item.id.repository)
    state.items = [item]
    state.selectedItemID = item.id
    state.detail = .init(item: item, revision: .init(mergeBase: "base", head: "head"), files: [file])
    state.selectedFilePath = file.path
    state.pane = .content
    state.tab = .diff
    state.contentGeneration = 1
    state.isPreparingDocument = true
    state.document = .init(
      lines: [[.init(text: "old preview")]],
      diff: .init(path: file.path, language: "Swift", status: "changed", rows: [
        .init(left: nil, right: .init(number: 1, spans: [.init(text: "old preview")]))
      ], revision: state.detail?.revision),
      checkingCancellation: { },
    )
    let store = TestStore(initialState: state) { WorkspaceFeature() }
    store.exhaustivity = .off
    await store.send(.contentResponse(generation: 1, .failure(.init(.commandFailed))))
    #expect(!store.state.isDocumentCurrent)
    #expect(!store.state.isPreparingDocument)
    await store.send(.commandPressed(.selectLines))
    await store.send(.diffCursorSelected(row: 0, side: .right))
    await store.send(.commandPressed(.comment))
    await store.send(.commandPressed(.review))
    #expect(store.state.visualStart == nil)
    #expect(store.state.review == nil)
    await store.send(.commandPressed(.search))
    await store.send(.keyPressed("x"))
    #expect(!store.state.isFinding)
    #expect(store.state.document.lines[0][0].text == "old preview")
    await store.finish()
  }

  @Test
  func `theme changes reuse the prepared diff and preserve selection`() async throws {
    var state = try WorkspaceFeature.State(repository: RepositoryID("owner/repo"))
    state.tab = .diff
    state.scroll = 20
    state.visualStart = 21
    let store = TestStore(initialState: state) { WorkspaceFeature() }
    await store.send(.commandPressed(.theme)) { $0.preferences.theme = .latte }
    #expect(store.state.contentGeneration == 0)
    #expect(store.state.scroll == 20)
    #expect(store.state.visualStart == 21)
  }

  @Test
  func `sidebar projections preserve unmatched rows during search`() throws {
    let item = try item()
    var state = WorkspaceFeature.State(repository: item.id.repository)
    state.items = [item]
    state.detail = .init(item: item, files: [.init(path: "Sources/One.swift"), .init(path: "Tests/Two.swift")])
    #expect(state.visibleItems == [item])
    state.searches[.items] = .init()
    state.searches[.items]?.query = "absent"
    #expect(state.visibleItems == [item])
    state.searches[.items] = nil
    #expect(state.visibleItems == [item])
    state.collapsedDirectories = ["Sources"]
    #expect(!state.visibleFileRows.contains { $0.path == "Sources/One.swift" })
    state.searches[.files] = .init()
    state.searches[.files]?.query = "One"
    state.listSearchResults[.files] = .init(ids: ["file:Sources/One.swift"], rows: [2])
    #expect(state.visibleFileRows.map(\.path) == ["/", "Sources", "Tests", "Tests/Two.swift"])
    state.preferences.filesView = .list
    #expect(state.visibleFileRows.map(\.path) == ["Sources/One.swift", "Tests/Two.swift"])
    state.searches[.files] = nil
    state.listSearchResults[.files] = nil
    #expect(state.visibleFiles.count == 2)
    state.detail = nil
    #expect(state.visibleFileRows.isEmpty)
  }

  @Test
  func `an older preset read cannot finish a newer save`() async throws {
    let repository = try RepositoryID("owner/repo")
    var state = FilterFeature.State(repository: repository, kind: .pullRequest, query: "is:open")
    state.generation = 2
    state.isSaving = true
    let store = TestStore(initialState: state) { FilterFeature() }
    await store.send(.loaded(generation: 1, .success([])))
    await store.send(.loaded(generation: 1, .failure(.init(.commandFailed))))
    await store.send(.appeared)
    #expect(store.state.isSaving)
    await store.send(.loaded(generation: 2, .success([]))) { $0.isSaving = false }
  }

  @Test
  func `detail cache evicts an old entry without flushing recently viewed items`() async throws {
    let items = try (1 ... 17).map { try item($0) }
    var state = WorkspaceFeature.State(repository: items[0].id.repository)
    state.items = items
    let store = TestStore(initialState: state) { WorkspaceFeature() } withDependencies: {
      $0[ForgeClient.self].detail = { .init(item: $0) }
      $0[DocumentClient.self].prepareComment = { text, _ in .init(lines: [[.init(text: text)]]) }
    }
    store.exhaustivity = .off
    for item in items.prefix(16) {
      await store.send(.itemSelected(item.id))
      await store.receive(\.detailResponse)
      await store.finish()
    }
    await store.send(.itemSelected(items[0].id))
    await store.finish()
    await store.send(.itemSelected(items[16].id))
    await store.receive(\.detailResponse)
    await store.finish()
    #expect(store.state.detailCache.count == 16)
    #expect(store.state.detailCache[items[0].id] != nil)
    #expect(store.state.detailCache[items[1].id] == nil)
    #expect(store.state.detailCache[items[16].id] != nil)
  }

  // MARK: Private

  private actor Requests {
    var ids = [ItemID]()

    func record(_ id: ItemID) {
      ids.append(id)
    }
  }

  private func item(_ number: Int = 1) throws -> ForgeItem {
    try ForgeItem(
      id: .init(repository: RepositoryID("owner/repo"), number: number),
      kind: .pullRequest,
      title: "Example \(number)",
      author: "author",
      body: "Overview \(number)",
      url: #require(URL(string: "https://github.com/owner/repo/pull/\(number)")),
    )
  }

}
