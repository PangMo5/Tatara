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

  // MARK: Internal

  @Test
  func `sidebar geometry honors preference and preserves usable content width`() {
    #expect(WorkspaceGeometry(size: .init(width: 176, height: 40)).sidebarWidth == 52)
    #expect(WorkspaceGeometry(size: .init(width: 176, height: 40), preferredSidebarWidth: 64).content.x == 64)
    #expect(WorkspaceGeometry(size: .init(width: 104, height: 40), preferredSidebarWidth: 64).content.width == 60)
    #expect(WorkspaceGeometry(size: .init(width: 80, height: 40), preferredSidebarWidth: 64).files.width == 80)
  }

  @Test
  func `item selection always reserves three metadata rows`() throws {
    var state = try WorkspaceFeature.State(repository: RepositoryID("owner/repo"))
    state.itemsHeight = 13
    #expect(state.itemsPage == 4)
    #expect(state.itemRowHeight == 3)
  }

  @Test
  func `wrap preferences are explicit and validate configuration`() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".toml")
    defer { try? FileManager.default.removeItem(at: url) }
    try "wrap = false\nsidebar_width = 64\n".write(to: url, atomically: true, encoding: .utf8)
    let preferences = try Configuration.load(path: url.path)
    #expect(!preferences.wrap && preferences.sidebarWidth == 64)
    try "wrap = \"extra\"\n".replacing("\\", with: "").write(to: url, atomically: true, encoding: .utf8)
    #expect(throws: TataraError.self) { try Configuration.load(path: url.path) }
  }

  @Test
  func `terminal wheel parser preserves both axes modifiers and chunked input`() {
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

  @Test(arguments: TataraCore.Theme.allCases)
  func `all flavors render semantic borders backgrounds selections and exact search spans`(_ theme: TataraCore.Theme) throws {
    var state = try WorkspaceFeature.State(repository: RepositoryID("owner/repo"), preferences: .init(theme: theme))
    state.pane = .content
    state.document = .init(lines: [[.init(text: "before hit after hit", role: .added)]])
    state.searches[.content] = .init()
    state.searches[.content]?.query = "hit"
    state.searches[.content]?.result = .init(lines: [0, 0], highlights: [0: [7 ..< 10, 17 ..< 20]], ranges: [7 ..< 10, 17 ..< 20])
    let view = presentation(state)
    let screen = view.screen()
    let palette = Palette(theme)
    var frame = Frame(buffer: Buffer(area: Rect(size: view.size)))
    frame.render(screen)
    let content = view.geometry.content
    expectNoDifference(frame.buffer[.init(x: content.x, y: content.y)].style.foreground, palette.lavender)
    expectNoDifference(frame.buffer[.init(x: 0, y: 1)].style.foreground, palette.overlay0)
    expectNoDifference(frame.buffer[.init(x: content.x + 2, y: content.y + 6)].style.background, .reset)
    expectNoDifference(frame.buffer[.init(x: content.x + 1, y: content.y + 2)].style.background, .reset)
    for position in [Position(x: 0, y: 0), Position(x: 0, y: 1), Position(x: 2, y: 10), Position(x: 0, y: view.size.height - 2)] {
      expectNoDifference(frame.buffer[position].style.background, .reset)
    }
    expectNoDifference(frame.buffer[.init(x: content.x + 8, y: content.y + 2)].style.background, palette.activeSearch)
    expectNoDifference(frame.buffer[.init(x: content.x + 18, y: content.y + 2)].style.background, palette.search)
    expectNoDifference(palette.ansi(5), palette.pink)
    #expect(palette.ansi(9) != palette.ansi(1))
    expectNoDifference(palette.ansi(16), palette.peach)
    expectNoDifference(palette.ansi(17), palette.rosewater)
  }

  @Test
  func `inline review expands below its source and retains the surrounding workspace`() async throws {
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
    ], revision: state.detail?.revision), 114)
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

  @Test
  func `no color still distinguishes matched source text`() throws {
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

  @Test(arguments: TataraCore.Theme.allCases)
  func `difftastic JSON categories use directional ANSI colors and upstream token emphasis`(_ theme: TataraCore
    .Theme) async throws
  {
    var state = try WorkspaceFeature.State(repository: RepositoryID("owner/repo"), preferences: .init(theme: theme))
    state.pane = .content
    state.tab = .diff
    func buffer(_ line: Line) -> Buffer {
      var frame = Frame(buffer: Buffer(area: Rect(x: 0, y: 0, width: 80, height: 1)))
      frame.render(Text([line]))
      return frame.buffer
    }
    let removed: Color = theme == .latte ? .red : .lightRed
    let added: Color = theme == .latte ? .green : .lightGreen
    for category in ["keyword", "type", "delimiter", "string", "comment", "normal", "tree_sitter_error", "future_category"] {
      let json = """
        {"language":"Swift","status":"changed","aligned_lines":[[0,0]],"chunks":[[{"lhs":{"line_number":0,"changes":[{"start":0,"end":3,"content":"old","highlight":"\(category)"}]},"rhs":{"line_number":0,"changes":[{"start":0,"end":3,"content":"new","highlight":"\(category)"}]}}]]}
        """
      let diff = try ReviewDiff.decode(Data(json.utf8), before: "old value", after: "new value", path: "A.swift")
      state.document = try await DocumentRenderer.prepareDiff(diff, 80)
      let view = presentation(state)
      let palette = Palette(theme)
      let oldCells = buffer(view.highlightedLine(state.document.displayLines[0], row: 0, selected: false))
      let newCells = buffer(view.highlightedLine(state.document.displayLines[1], row: 1, selected: false))
      let x = state.document.diffPrefixWidth
      expectNoDifference(oldCells[.init(x: x, y: 0)].style.foreground, removed)
      expectNoDifference(newCells[.init(x: x, y: 0)].style.foreground, added)
      expectNoDifference(oldCells[.init(x: x - 2, y: 0)].style.foreground, removed)
      expectNoDifference(newCells[.init(x: x - 2, y: 0)].style.foreground, added)
      #expect(newCells[.init(x: x - 2, y: 0)].style.modifiers.contains(.bold))
      #expect(newCells[.init(x: x, y: 0)].style.modifiers.contains(.bold) == ["keyword", "type", "delimiter"].contains(category))
      #expect(newCells[.init(x: x, y: 0)].style.modifiers.contains(.italic) == (category == "comment"))
      #expect(!newCells[.init(x: x, y: 0)].style.modifiers.contains(.underlined))
      expectNoDifference(newCells[.init(x: x, y: 0)].style.background, .reset)
      expectNoDifference(newCells[.init(x: x + 4, y: 0)].style.foreground, .reset)
      let plain = buffer(presentation(state, noColor: true).highlightedLine(
        state.document.displayLines[1],
        row: 1,
        selected: false,
      ))
      expectNoDifference(plain[.init(x: x, y: 0)].style.foreground, .reset)
      expectNoDifference(plain[.init(x: x, y: 0)].style.modifiers, [])
      let matches = try await DocumentRenderer.search(state.document, "new")
      state.searches[.content] = .init()
      state.searches[.content]?.result = matches
      let searched = buffer(presentation(state).highlightedLine(state.document.displayLines[1], row: 1, selected: true))
      expectNoDifference(searched[.init(x: x, y: 0)].style.background, palette.activeSearch)
      expectNoDifference(searched[.init(x: x, y: 0)].style.foreground, palette.text)
      state.searches[.content] = .init()
    }
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
      state.isSelectingItems = pane == .items
      let geometry = WorkspaceGeometry(size: .init(width: 160, height: height), isSelectingItems: state.isSelectingItems)
      state.itemsScroll = ScrollMetrics.selectionOffset(
        selected: 10,
        total: 25,
        page: max(1, (geometry.items.height - 3) / state.itemRowHeight),
      )
      state.filesScroll = ScrollMetrics.selectionOffset(selected: 10, total: 25, page: geometry.files.height - 3)
      let view = presentation(state, size: .init(width: 160, height: height))
      var frame = Frame(buffer: Buffer(area: Rect(size: view.size)))
      frame.render(view.screen())
      let rect = pane == .items ? view.geometry.items : view.geometry.files
      let page = pane == .items ? max(1, (rect.height - 3) / state.itemRowHeight) : rect.height - 3
      let margin = min(2, (page - 1) / 2)
      let rows = stride(from: rect.y + 2, to: rect.bottom - 1, by: pane == .items ? state.itemRowHeight : 1)
        .map { String(frame.buffer.lines()[$0].prefix(rect.width)) }
      let selected = try #require(rows.firstIndex { $0.contains(pane == .items ? "PR-10" : "File10.swift") })
      #expect(selected >= margin)
      #expect(rows.count - selected - 1 >= margin)
      for distance in 1 ... max(1, margin) where margin > 0 {
        #expect(rows[selected - distance].contains(pane == .items
            ? "PR-\(10 - distance)"
            : String(
              format: "File%02d.swift",
              10 - distance,
            )))
        #expect(rows[selected + distance].contains(pane == .items
            ? "PR-\(10 + distance)"
            : String(
              format: "File%02d.swift",
              10 + distance,
            )))
      }
    }
  }

  @Test(arguments: [104, 176])
  func `file rows show status and exact counts with compact indentation and readable names`(_ columns: Int) throws {
    let repository = try RepositoryID("owner/repo")
    let item = try ForgeItem(
      id: .init(repository: repository, number: 1),
      kind: .pullRequest,
      title: "File changes",
      author: "reviewer",
      url: #require(URL(string: "https://github.com/owner/repo/pull/1")),
    )
    let files: [ChangedFile] = [
      .init(path: "Sources/Feature/AddedFile.swift", status: "added", additions: 120),
      .init(path: "Sources/Feature/DeletedFile.swift", status: "removed", deletions: 45),
      .init(
        path: "Sources/Feature/LongRenamedController.swift",
        previousPath: "Previous.swift",
        status: "renamed",
        additions: 7,
        deletions: 3,
      ),
      .init(path: "Sources/Feature/ModifiedFile.swift", additions: 12, deletions: 3),
      .init(path: "Sources/Feature/Zero.swift", status: "renamed"),
    ]
    var state = WorkspaceFeature.State(repository: repository)
    state.items = [item]
    state.selectedItemID = item.id
    let detail = ItemDetail(item: item, files: files, comments: [
      .init(id: 1, author: "reviewer", body: "PR discussion"),
      .init(id: 2, author: "reviewer", body: "Current line", anchor: .init(path: files[0].path, line: 1, side: .right)),
      .init(
        id: 3,
        author: "reviewer",
        body: "Outdated line",
        anchor: .init(path: files[0].path, line: nil, side: .right, originalLine: 2),
      ),
      .init(
        id: 4,
        author: "reviewer",
        body: "File comment",
        anchor: .init(path: files[0].path, line: nil, side: nil, subjectType: "file"),
      ),
    ])
    state.detail = try JSONDecoder().decode(ItemDetail.self, from: JSONEncoder().encode(detail))
    #expect(state.detail?.commentCount(at: files[0].path) == 3)
    #expect(state.detail?.commentCount(at: files[1].path) == 0)
    state.selectedFilePath = files[0].path
    state.pane = .files
    let view = presentation(state, size: .init(width: columns, height: 40))
    var screen = TerminalScreen()
    view.files(into: &screen)
    var frame = Frame(buffer: Buffer(area: Rect(size: view.size)))
    frame.render(screen)
    let content = frame.buffer.lines().map { String($0.prefix(view.geometry.files.width)) }
    for (symbol, suffix) in [("A", "c3 +120"), ("D", "−45"), ("R", "+7 −3"), ("M", "+12 −3")] {
      let row = try #require(content.firstIndex { $0.contains(suffix) })
      // Root and two folder levels consume three indentation columns before the status badge.
      #expect(frame.buffer[.init(x: view.geometry.files.x + 5, y: row)].symbol == symbol)
      #expect(content[row].contains(".swift"))
      #expect(content[row].trimmingCharacters(in: .whitespaces).hasSuffix(suffix + "│"))
    }
    #expect(!content.joined().contains("+0"))
    #expect(!content.joined().contains("−0"))
    #expect(!content.joined().contains("c0"))
    #expect(content.contains { $0.contains("Zero.swift") })
    var footer = TerminalScreen()
    view.footer(into: &footer)
    frame.render(footer)
    let status = frame.buffer.lines()[view.size.height - 2]
    #expect(status.contains("c3 +120"))
    #expect(!status.contains("−0"))
    #expect(view.compactFileName("日本語の長いファイル名.swift", width: 16).hasSuffix(".swift"))
    #expect(TerminalWidth.of(view.compactFileName("日本語の長いファイル名.swift", width: 16)) <= 16)
  }

  // MARK: Private

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

}
