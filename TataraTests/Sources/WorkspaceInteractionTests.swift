// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import Foundation
import TataraCore
import TataraKit
import Testing

@MainActor
struct WorkspaceInteractionTests {
  @Test func `selection keeps an identified preview until replacement and blocks premature reviews`() async throws {
    let first = try item(1), next = try item(2)
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
      $0[DocumentClient.self].prepare = { _, _ in
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
    #expect(store.state.document == replacement)
    #expect(store.state.documentTitle == "#2 · Overview")
    #expect(store.state.scroll == 0)
    #expect(!store.state.isPreparingDocument)
  }

  @Test func `wheel targets the hovered document without changing keyboard focus`() async throws {
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

  @Test func `help owns wheel input while presented`() async throws {
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

  @Test func `expired selection delay cannot start an API request`() async throws {
    let old = try item(1)
    let current = try item(2)
    var state = WorkspaceFeature.State(repository: current.id.repository)
    state.items = [old, current]
    state.selectedItemID = current.id
    state.detailGeneration = 5
    let store = TestStore(initialState: state) { WorkspaceFeature() }
    await store.send(.detailDelayElapsed(generation: 4, old))
  }

  @Test func `next match without A search does not scroll`() async throws {
    var state = try WorkspaceFeature.State(repository: RepositoryID("owner/repo"))
    state.pane = .content
    state.document = .init(lines: (0 ..< 100).map { [.init(text: "Line \($0)")] })
    let store = TestStore(initialState: state) { WorkspaceFeature() }
    await store.send(.commandPressed(.nextMatch))
    await store.send(.commandPressed(.previousMatch))
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

  @Test func `committed filter clears without leaving its pane`() async throws {
    var state = try WorkspaceFeature.State(repository: RepositoryID("owner/repo"))
    state.pane = .files
    state.tab = .diff
    state.scroll = 8
    state.searches[.items] = .init()
    state.searches[.items]?.query = "Example"
    state.searches[.files] = .init()
    state.searches[.files]?.query = "swift"
    let store = TestStore(initialState: state) { WorkspaceFeature() }
    await store.send(.keyPressed("esc")) { $0.searches[.files] = .init() }
    #expect(store.state.pane == .files)
    #expect(store.state.scroll == 8)
    #expect(store.state.searches[.items]?.query == "Example")
  }

  @Test func `search does not move focus to the pull request list`() async throws {
    var state = try WorkspaceFeature.State(repository: RepositoryID("owner/repo"))
    state.pane = .files
    let store = TestStore(initialState: state) { WorkspaceFeature() }
    await store.send(.commandPressed(.search)) { $0.searches[.files] = .init()
      $0.searches[.files]?.isEditing = true
    }
    await store.send(.keyPressed("s")) { $0.searches[.files]?.query = "s" }
    await store.send(.keyPressed("enter")) { $0.searches[.files]?.isEditing = false }
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
    await store.receive(\.commandPressed) { $0.scroll = 10 }
    await store.send(.keyPressed("ctrl-b"))
    await store.receive(\.commandPressed) { $0.scroll = 0 }
    await store.send(.commandPressed(.contentHalfPageUp))
    #expect(store.state.pane == pane)
    #expect(store.state.selectedItemID == item.id)
  }

  @Test func `help search matches localized labels and actual bindings`() async throws {
    var state = try WorkspaceFeature.State(
      repository: RepositoryID("owner/repo"),
      strings: ["Scroll main pane down": "메인 패널 아래로"],
    )
    state.pane = .files
    state.showsHelp = true
    state.searches[.help] = .init()
    state.searches[.help]?.query = "메인"
    #expect(state.visibleHelp == [.contentHalfPageDown])
    state.searches[.help]?.query = "ctrl-f"
    #expect(state.visibleHelp == [.contentHalfPageDown])
    let store = TestStore(initialState: state) { WorkspaceFeature() }
    await store.send(.keyPressed("esc")) { $0.searches[.help] = .init() }
    #expect(store.state.showsHelp)
    await store.send(.keyPressed("esc"))
    await store.receive(\.commandPressed) { $0.showsHelp = false }
    #expect(store.state.pane == .files)
  }

  @Test func `content search jumps between matches and rejects stale results`() async throws {
    let clock = TestClock()
    var state = try WorkspaceFeature.State(repository: RepositoryID("owner/repo"))
    state.pane = .content
    state.contentHeight = 5
    state.document = .init(lines: (0 ..< 30).map { [.init(text: "Line \($0)")] })
    state.searches[.content] = .init()
    state.searches[.content]?.isEditing = true
    let store = TestStore(initialState: state) { WorkspaceFeature() } withDependencies: {
      $0.continuousClock = clock
      $0[DocumentClient.self].search = { _, query in query == "L" ? [2, 20] : [] }
    }
    await store.send(.keyPressed("L")) {
      $0.searches[.content]?.query = "L"
      $0.searchGeneration = 1
      $0.isFinding = true
    }
    await clock.advance(by: .milliseconds(60))
    await store.receive(\.searchResponse) {
      $0.searches[.content]?.matches = [2, 20]
      $0.scroll = 2
      $0.isFinding = false
    }
    await store.send(.keyPressed("enter")) {
      $0.searches[.content]?.isEditing = false
      $0.searches[.content]?.matches = []
      $0.searchGeneration = 2
      $0.isFinding = true
    }
    await clock.advance(by: .milliseconds(60))
    await store.receive(\.searchResponse) { $0.searches[.content]?.matches = [2, 20]
      $0.isFinding = false
    }
    await store.send(.commandPressed(.nextMatch)) { $0.searches[.content]?.selection = 1
      $0.scroll = 20
    }
    await store.send(.keyPressed("esc")) { $0.searches[.content] = .init()
      $0.searchGeneration = 3
    }
    await store.send(.searchResponse(generation: 2, matches: [29]))
    #expect(store.state.scroll == 20)
  }

  private actor Requests {
    var ids: [ItemID] = []
    func record(_ id: ItemID) {
      ids.append(id)
    }
  }

  @Test func `rapid selection fetches only the settled item and reuses its detail`() async throws {
    let clock = TestClock()
    let calls = Requests()
    let items = try [item(1), item(2), item(3)]
    var state = WorkspaceFeature.State(repository: items[0].id.repository)
    state.items = items
    let store = TestStore(initialState: state) { WorkspaceFeature() } withDependencies: {
      $0.continuousClock = clock
      $0[ForgeClient.self].detail = { item in await calls.record(item.id)
        return .init(item: item)
      }
      $0[DocumentClient.self].prepare = { text, _ in .init(lines: [[.init(text: text)]]) }
    }
    store.exhaustivity = .off
    for item in items {
      await store.send(.itemSelected(item.id))
    }
    #expect(store.state.detail?.item == items[2]) // Overview is available before the network.
    await clock.advance(by: .milliseconds(120))
    await store.finish()
    #expect(await calls.ids == [items[2].id])
    await store.send(.itemSelected(items[0].id))
    await clock.advance(by: .milliseconds(120))
    await store.finish()
    await store.send(.itemSelected(items[2].id))
    await store.finish()
    #expect(await calls.ids == [items[2].id, items[0].id])
    #expect(!store.state.isLoadingDetail)
  }
}
