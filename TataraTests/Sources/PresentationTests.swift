// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import CustomDump
import Foundation
import TataraCore
import TataraKit
import TataraSystem
import TermLoom
import TermLoomTextArea
import Testing

@MainActor
struct PresentationTests {
  @Test func `sidebar geometry honors preference and preserves usable content width`() {
    #expect(WorkspaceGeometry(size: .init(width: 176, height: 40)).sidebarWidth == 52)
    #expect(WorkspaceGeometry(size: .init(width: 176, height: 40), preferredSidebarWidth: 64).content.x == 64)
    #expect(WorkspaceGeometry(size: .init(width: 104, height: 40), preferredSidebarWidth: 64).content.width == 60)
    #expect(WorkspaceGeometry(size: .init(width: 80, height: 40), preferredSidebarWidth: 64).files.width == 80)
  }

  @Test func `rich metadata keeps two row items within the visible page`() async throws {
    var state = try WorkspaceFeature.State(repository: RepositoryID("owner/repo"))
    state.tab = .diff
    state.itemsHeight = 13
    let store = TestStore(initialState: state) { WorkspaceFeature() }
    await store.send(.commandPressed(.toggleDetails)) { $0.preferences.detailLevel = .rich }
    #expect(store.state.itemsPage == 6)
    #expect(store.state.itemRowHeight == 2)
    await store.send(.commandPressed(.toggleDetails)) { $0.preferences.detailLevel = .compact }
    #expect(store.state.itemsPage == 13)
  }

  @Test func `metadata preferences reject invalid density and accept rich mode`() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".toml")
    defer { try? FileManager.default.removeItem(at: url) }
    try "detail_level = \"rich\"\nsidebar_width = 64\n".write(to: url, atomically: true, encoding: .utf8)
    let preferences = try Configuration.load(path: url.path)
    #expect(preferences.detailLevel == .rich && preferences.sidebarWidth == 64)
    try "detail_level = \"extra\"\n".write(to: url, atomically: true, encoding: .utf8)
    #expect(throws: TataraError.self) { try Configuration.load(path: url.path) }
  }

  @Test func `terminal wheel parser preserves both axes modifiers and chunked input`() {
    let directions: [MouseEventKind] = [.scrollUp, .scrollDown, .scrollLeft, .scrollRight]
    for modifiers in [0, 4, 8, 16, 28] {
      var expectedModifiers: KeyModifiers = []
      if modifiers & 4 != 0 {
        expectedModifiers.insert(.shift)
      }
      if modifiers & 8 != 0 {
        expectedModifiers.insert(.option)
      }
      if modifiers & 16 != 0 {
        expectedModifiers.insert(.control)
      }
      let input = (0 ..< 4).map { "\u{1B}[<\(64 + modifiers + $0);10;25M" }.joined()
      let expected = directions.map {
        TerminalEvent.mouse(MouseEvent($0, at: .init(x: 9, y: 24), modifiers: expectedModifiers))
      }
      var burst = InputParser()
      expectNoDifference(burst.feed(Data(input.utf8)), expected)
      var fragmented = InputParser()
      expectNoDifference(input.utf8.flatMap { fragmented.feed(Data([$0])) }, expected)
    }
  }

  private func presentation(
    _ state: WorkspaceFeature.State,
    size: Size = .init(width: 160, height: 40),
    noColor: Bool = false,
  ) -> WorkspacePresentation {
    .init(
      store: Store(initialState: state) { WorkspaceFeature() },
      size: size,
      demo: false,
      fields: [:],
      editors: [:],
      editorTexts: [:],
      reviewScroll: 0,
      reviewPreview: nil,
      commentScroll: 0,
      failure: nil,
      noColor: noColor,
      ascii: false,
      cursorFollowsFocus: false,
      palette: Palette(state.preferences.theme, noColor: noColor),
    )
  }

  @Test(arguments: TataraCore.Theme.allCases)
  func `all flavors render semantic borders backgrounds selections and exact search spans`(_ theme: TataraCore.Theme) throws {
    var state = try WorkspaceFeature.State(repository: RepositoryID("owner/repo"), preferences: .init(theme: theme))
    state.pane = .content
    state.document = .init(lines: [[.init(text: "before hit after hit", role: .added)]])
    state.searches[.content] = .init()
    state.searches[.content]?.query = "hit"
    state.searches[.content]?.result = .init(lines: [0, 0], highlights: [0: [7 ..< 10, 17 ..< 20]], ranges: [7 ..< 10, 17 ..< 20])
    let view = presentation(state), screen = view.screen(), palette = Palette(theme)
    var frame = Frame(buffer: Buffer(area: Rect(size: view.size)))
    frame.render(screen)
    let content = view.geometry.content
    expectNoDifference(frame.buffer[.init(x: content.x, y: content.y)].style.foreground, palette.lavender)
    expectNoDifference(frame.buffer[.init(x: 0, y: 1)].style.foreground, palette.overlay0)
    expectNoDifference(frame.buffer[.init(x: content.x + 2, y: content.y + 6)].style.background, palette.base)
    expectNoDifference(frame.buffer[.init(x: content.x + 1, y: content.y + 2)].style.background, palette.base)
    expectNoDifference(frame.buffer[.init(x: content.x + 8, y: content.y + 2)].style.background, palette.activeSearch)
    expectNoDifference(frame.buffer[.init(x: content.x + 18, y: content.y + 2)].style.background, palette.search)
    expectNoDifference(palette.ansi(5), palette.pink)
    #expect(palette.ansi(9) != palette.ansi(1))
    expectNoDifference(palette.ansi(16), palette.peach)
    expectNoDifference(palette.ansi(17), palette.rosewater)
  }

  @Test func `inline review expands below its source and retains the surrounding workspace`() async throws {
    let repository = try RepositoryID("owner/repo")
    let item = try ForgeItem(
      id: .init(repository: repository, number: 1),
      kind: .pullRequest,
      title: "Visible PR",
      author: "reviewer",
      url: #require(URL(string: "https://github.com/owner/repo/pull/1")),
    )
    let file = ChangedFile(path: "Source.swift", patch: "@@ -1,3 +1,3 @@\n-a\n-b\n-c\n+x\n+y\n+z")
    var state = WorkspaceFeature.State(repository: repository)
    state.items = [item]
    state.selectedItemID = item.id
    state.selectedFilePath = file.path
    state.detail = .init(item: item, revision: .init(mergeBase: "base", head: "head"), files: [file])
    state.pane = .content
    state.tab = .diff
    state.contentHeight = 34
    state.diffCursor = 1
    state.document = try await DocumentRenderer.prepareDiff(.init(path: file.path, language: "Swift", status: "changed", rows: [
      .init(left: nil, right: .init(number: 1, spans: [.init(text: "context-before")])),
      .init(left: nil, right: .init(number: 2, spans: [.init(text: "selected-source")])),
      .init(left: nil, right: .init(number: 3, spans: [.init(text: "context-after")])),
    ], revision: state.detail?.revision), 114, .right)
    state.review = .init(item: item, expectedHead: "head", expectedMergeBase: "base")
    state.review?.selectedFile = file
    state.review?.isEditingInline = true
    state.review?.inlineAnchorLocked = true
    state.review?.inlineLine = "2"
    state.review?.inlineBody = "Keep the context visible."
    state.reviewLocation = .init(path: file.path, line: 2, side: .right)
    let view = presentation(state)
    var frame = Frame(buffer: Buffer(area: Rect(size: view.size)), environment: .init(focusedControl: "review-inline"))
    frame.render(view.screen())
    let lines = frame.buffer.lines()
    #expect(lines.contains { $0.contains("Visible PR") })
    let sourceRow = try #require(lines.firstIndex { $0.contains("selected-source") })
    let editor = try #require(frame.interactions.regions.first { $0.control.rawValue == "review-inline" })
    expectNoDifference(editor.area.y, sourceRow + 4)
    #expect(lines.prefix(sourceRow).contains { $0.contains("context-before") })
    #expect(lines.dropFirst(editor.area.bottom).contains { $0.contains("context-after") })
    #expect(lines.contains { $0.contains("Keep the context visible.") })
    #expect(frame.cursorPosition != nil)
  }

  @Test func `no color still distinguishes matched source text`() throws {
    var state = try WorkspaceFeature.State(repository: RepositoryID("owner/repo"))
    state.pane = .content
    state.document = .init(lines: [[.init(text: "hit")]])
    state.searches[.content] = .init()
    state.searches[.content]?.result = .init(lines: [0], highlights: [0: [0 ..< 3]], ranges: [0 ..< 3])
    let view = presentation(state, noColor: true)
    var frame = Frame(buffer: Buffer(area: Rect(size: view.size)))
    frame.render(view.screen())
    let cell = frame.buffer[.init(x: view.geometry.content.x + 1, y: view.geometry.content.y + 2)]
    expectNoDifference(cell.style.foreground, .reset)
    expectNoDifference(cell.style.background, .reset)
    #expect(cell.style.modifiers.contains(.underlined))
  }

  @Test(arguments: [16, 40])
  func `sidebar selection retains context above and below in both lists`(height: Int) throws {
    let repository = try RepositoryID("owner/repo")
    var state = WorkspaceFeature.State(repository: repository, preferences: .init(filesView: .list))
    state.items = (0 ..< 25).map { index in
      .init(
        id: .init(repository: repository, number: index + 1),
        kind: .pullRequest,
        title: "PR-\(index)",
        author: "reviewer",
        url: URL(string: "https://github.com/owner/repo/pull/\(index + 1)")!,
      )
    }
    state.selectedItemID = state.items[10].id
    let files = (0 ..< 25).map { ChangedFile(path: String(format: "File%02d.swift", $0)) }
    state.detail = .init(item: state.items[10], files: files)
    state.selectedFilePath = files[10].path
    for pane in [WorkspaceFeature.Pane.items, .files] {
      state.pane = pane
      let geometry = WorkspaceGeometry(size: .init(width: 160, height: height))
      state.itemsScroll = ScrollMetrics.selectionOffset(selected: 10, total: 25, page: geometry.items.height - 3)
      state.filesScroll = ScrollMetrics.selectionOffset(selected: 10, total: 25, page: geometry.files.height - 3)
      let view = presentation(state, size: .init(width: 160, height: height))
      var frame = Frame(buffer: Buffer(area: Rect(size: view.size)))
      frame.render(view.screen())
      let rect = pane == .items ? view.geometry.items : view.geometry.files
      let page = rect.height - 3
      let margin = min(2, (page - 1) / 2)
      let rows = (rect.y + 2 ..< rect.bottom - 1).map { String(frame.buffer.lines()[$0].prefix(rect.width)) }
      let selected = try #require(rows.firstIndex { $0.contains(pane == .items ? "PR-10" : "File10.swift") })
      #expect(selected >= margin)
      #expect(rows.count - selected - 1 >= margin)
      for distance in 1 ... max(1, margin) where margin > 0 {
        #expect(rows[selected - distance].contains(pane == .items ? "PR-\(10 - distance)" : String(
          format: "File%02d.swift",
          10 - distance,
        )))
        #expect(rows[selected + distance].contains(pane == .items ? "PR-\(10 + distance)" : String(
          format: "File%02d.swift",
          10 + distance,
        )))
      }
    }
  }
}
