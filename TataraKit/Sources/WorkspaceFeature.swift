// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import TataraCore

/// Capture values during selection; concatenate source text on the concurrent executor.
private struct ContentSource: Sendable {
  let detail: ItemDetail?
  let tab: WorkspaceFeature.ContentTab
  let strings: [String: String]

  @concurrent
  func rendered() async throws -> String {
    try Task.checkCancellation()
    func text(_ key: String) -> String {
      strings[key] ?? key
    }
    guard let detail else { return text("Select an item to begin.") }
    let item = detail.item
    let result: String
    switch tab {
    case .overview:
      let status = item.isDraft ? "Draft" : item.state == .open ? "Open" : item.state == .merged ? "Merged" : "Closed"
      var lines = ["#\(item.id.number) \(item.title)", "@\(item.author) · \(text(status))", item.url.absoluteString,
                   item.labels.joined(separator: " · ")]
      if case let .github(metadata) = detail.metadata {
        lines += ["\(metadata.headBranch) → \(metadata.baseBranch)", "GitHub · \(metadata.mergeableState)"]
      }
      if let revision = detail.revision {
        lines.append("\(revision.mergeBase.prefix(8))…\(revision.head.prefix(8))")
      }
      result = (lines + ["", item.body]).joined(separator: "\n")
    case .diff: result = text("Select a file to read its diff.")
    case .discussion:
      var comments: [String] = []
      for comment in detail.comments {
        try Task.checkCancellation()
        comments.append("@\(comment.author)\(comment.context.map { " · \($0)" } ?? "")\n\(comment.body)")
      }
      result = comments.isEmpty ? text("No comments yet.") : comments.joined(separator: "\n\n")
    case .checks:
      if case let .github(metadata) = detail.metadata {
        let lines = metadata.checks + metadata.reviews
        result = lines.isEmpty ? text("No checks reported.") : lines.joined(separator: "\n")
      } else {
        result = text("No checks reported.")
      }
    }
    try Task.checkCancellation()
    return result
  }
}

@Reducer
public struct WorkspaceFeature {
  public enum Pane: Int, CaseIterable, Sendable { case items, files, content }
  public enum ContentTab: Int, CaseIterable, Sendable { case overview, diff, discussion, checks }
  public enum SearchScope: Hashable, Sendable { case items, files, content, help }

  @ObservableState
  public struct State: Equatable {
    public var repository: RepositoryID
    public var preferences: Preferences
    public var strings: [String: String]
    public var kind = ItemKind.pullRequest
    public var items: [ForgeItem] = []
    public var selectedItemID: ItemID?
    public var selectedFilePath: String?
    public var fileCursorID: String?
    public var collapsedDirectories = Set<String>()
    public var detail: ItemDetail?
    @ObservationStateIgnored public var detailCache: [ItemID: ItemDetail] = [:]
    public var document = ReviewDocument()
    public var documentTitle = ""
    public var resetsScrollOnResponse = false
    public var diffCursor = 0
    public var diffSide = InlineComment.Side.right
    public var visualStart: Int?
    public var pane = Pane.items
    public var tab = ContentTab.overview
    public var scroll = 0
    public var contentWidth = 100
    public var contentHeight = 24
    public var helpHeight = 16
    public var helpScroll = 0
    public var isLoading = false
    public var isLoadingDetail = false
    public var isLoadingDiff = false
    public var isPreparingDocument = false
    public var isFinding = false
    public var nextPage: Int?
    public var error: TataraError?
    public var searches: [SearchScope: PaneSearch] = [:]
    public var showsHelp = false
    public var pendingG = false
    public var review: ReviewFeature.State?
    public var filterEditor: FilterFeature.State?
    public var activeFilter = ""
    public var reviewedFiles = Set<String>()
    public var drafts: [ItemID: ReviewFeature.State] = [:]
    public var listGeneration = 0
    public var detailGeneration = 0
    public var contentGeneration = 0
    public var searchGeneration = 0

    public init(repository: RepositoryID, preferences: Preferences = .init(), strings: [String: String] = [:]) {
      self.repository = repository
      self.preferences = preferences
      self.strings = strings
    }

    public func text(_ key: String) -> String {
      strings[key] ?? key
    }

    public var selectedItem: ForgeItem? {
      items.first { $0.id == selectedItemID }
    }

    public var selectedFile: ChangedFile? {
      detail?.files.first { $0.path == selectedFilePath }
    }

    fileprivate var contentTitle: String {
      guard let detail else { return "" }
      let section = switch tab {
      case .overview: "Overview"
      case .diff: "Diff"
      case .discussion: "Discussion"
      case .checks: "Checks"
      }
      var title = "#\(detail.item.id.number) · \(text(section))"
      if let revision = detail.revision {
        title += " · \(revision.head.prefix(8))"
      }
      if tab == .diff, let file = selectedFile {
        title += " · \(file.path)"
      }
      return title
    }

    public var searchScope: SearchScope {
      if showsHelp {
        return .help
      }
      switch pane { case .items: return .items
      case .files: return .files
      case .content: return .content }
    }

    public var activeSearch: PaneSearch {
      searches[searchScope] ?? .init()
    }

    public var isSearching: Bool {
      activeSearch.isEditing
    }

    public var visibleItems: [ForgeItem] {
      let query = searches[.items]?.query ?? ""
      return query.isEmpty ? items : items
        .filter { "#\($0.id.number) \($0.title) \($0.author)".localizedCaseInsensitiveContains(query) }
    }

    public var visibleFiles: [ChangedFile] {
      let files = detail?.files ?? []
      let query = searches[.files]?.query ?? ""
      return query.isEmpty ? files : files
        .filter { "\($0.path) \($0.previousPath ?? "")".localizedCaseInsensitiveContains(query) }
    }

    public var visibleFileRows: [FileTreeRow] {
      if preferences.filesView == .list {
        return visibleFiles.map { .init(path: $0.path, name: $0.path, depth: 0, isDirectory: false) }
      }
      return detail?.fileTree.visible(
        collapsed: collapsedDirectories,
        matching: searches[.files]?.query.isEmpty == false ? Set(visibleFiles.map(\.path)) : nil,
      ) ??
        []
    }

    public var fileCursor: FileTreeRow? {
      let id = fileCursorKey
      return visibleFileRows.first { $0.id == id }
    }

    public var fileCursorKey: String? {
      fileCursorID ?? selectedFilePath.map { "file:" + $0 }
    }

    public var visibleHelp: [KeyCommand] {
      let query = searches[.help]?.query ?? ""
      return KeyCommand.allCases.filter { command in
        query.isEmpty || "\(command.rawValue) \(command.titleKey) \(commandTitle(command)) \((preferences.keymap.bindings[command] ?? []).joined(separator: " "))"
          .localizedCaseInsensitiveContains(query)
      }
    }

    public var maxScroll: Int {
      max(0, document.lines.count - contentHeight)
    }

    public func commandTitle(_ command: KeyCommand) -> String {
      if pane == .files, preferences.filesView == .tree {
        if command == .left {
          return text("Collapse folder")
        }
        if command == .right {
          return text("Expand folder")
        }
      }
      if pane == .content, tab == .diff {
        if command == .left {
          return text("Left diff side")
        }
        if command == .right {
          return text("Right diff side")
        }
        if command == .refresh {
          return text("Review selected lines")
        }
      }
      return text(command.titleKey)
    }

    public var commandTitles: [KeyCommand: String] {
      Dictionary(uniqueKeysWithValues: KeyCommand.allCases.map { ($0, commandTitle($0)) })
    }

    public func reviewKey(for path: String) -> String? {
      guard let detail, let revision = detail.revision else { return nil }
      return "\(detail.item.id.repository)#\(detail.item.id.number)|\(revision.mergeBase)|\(revision.head)|\(path)"
    }
  }

  public enum Action {
    case appeared
    case keyPressed(String)
    case commandPressed(KeyCommand)
    case tabSelected(ContentTab)
    case viewportChanged(width: Int, height: Int)
    case helpViewportChanged(Int)
    case scrollbarMoved(SearchScope, offset: Int, pageSize: Int)
    case wheelScrolled(SearchScope, delta: Int)
    case itemSelected(ItemID)
    case detailDelayElapsed(generation: Int, ForgeItem)
    case fileSelected(String)
    case fileRowSelected(String)
    case fileRowActivated(String)
    case diffCursorSelected(row: Int, side: InlineComment.Side)
    case filtersOpened
    case filterEditor(FilterFeature.Action)
    case listResponse(generation: Int, append: Bool, Result<ItemPage, TataraError>)
    case detailResponse(generation: Int, Result<ItemDetail, TataraError>)
    case contentResponse(generation: Int, Result<ReviewDocument, TataraError>)
    case searchResponse(generation: Int, matches: [Int])
    case searchFailed(generation: Int, TataraError)
    case review(ReviewFeature.Action)
    case reviewDismissed
    case markReviewedPressed
  }

  enum CancelID { case list, detail, content, search }
  @Dependency(ForgeClient.self) var forge
  @Dependency(DiffClient.self) var difftastic
  @Dependency(DocumentClient.self) var documents
  @Dependency(\.continuousClock) var clock
  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .appeared: return loadList(&state)
      case .filtersOpened:
        state.visualStart = nil
        state.filterEditor = .init(repository: state.repository, kind: state.kind, query: state.activeFilter)
        return .send(.filterEditor(.appeared))
      case let .filterEditor(.delegate(.apply(query))):
        state.activeFilter = query
        state.filterEditor = nil
        state.searches[.items] = .init()
        return loadList(&state)
      case .filterEditor(.delegate(.close)): state.filterEditor = nil
        return .none
      case .filterEditor: return .none
      case let .diffCursorSelected(row, side):
        guard state.filterEditor == nil, state.review == nil, !state.showsHelp,
              !state.isPreparingDocument, let diff = state.document.diff, diff.rows.indices.contains(row),
              diff.rows[row].line(on: side) != nil else { return .none }
        state.pane = .content
        state.diffSide = side
        state.diffCursor = row
        state.visualStart = nil
        return .none
      case let .fileRowActivated(id):
        guard state.filterEditor == nil, state.review == nil, !state.showsHelp else { return .none }
        state.pane = .files
        guard let row = state.visibleFileRows.first(where: { $0.id == id }) else { return .none }
        state.fileCursorID = id
        if row.isDirectory {
          guard state.searches[.files]?.query.isEmpty != false else { return .none }
          if !state.collapsedDirectories.insert(row.path).inserted {
            state.collapsedDirectories.remove(row.path)
          }
          return .none
        }
        return .send(.fileSelected(row.path))
      case let .fileRowSelected(id):
        guard let row = state.visibleFileRows.first(where: { $0.id == id }) else { return .none }
        state.fileCursorID = id
        return row.isDirectory ? .none : .send(.fileSelected(row.path))
      case let .wheelScrolled(scope, delta):
        guard state.review == nil, state.filterEditor == nil, delta != 0, !state.showsHelp || scope == .help else { return .none }
        switch scope {
        case .content:
          state.scroll = min(state.maxScroll, max(0, state.scroll + delta))
          alignCursorToViewport(&state)
        case .help:
          guard state.showsHelp else { return .none }
          state.helpScroll = min(max(0, state.visibleHelp.count - state.helpHeight), max(0, state.helpScroll + delta))
        case .items:
          let items = state.visibleItems
          guard let index = items.firstIndex(where: { $0.id == state.selectedItemID }) else { return .none }
          let next = min(items.count - 1, max(0, index + delta))
          guard next != index else { return .none }
          return .send(.itemSelected(items[next].id))
        case .files:
          let files = state.visibleFileRows
          guard let index = files.firstIndex(where: { $0.id == state.fileCursorKey }) else { return .none }
          let next = min(files.count - 1, max(0, index + delta))
          guard next != index else { return .none }
          return .send(.fileRowSelected(files[next].id))
        }
        return .none
      case let .scrollbarMoved(scope, offset, pageSize):
        guard state.filterEditor == nil, state.review == nil, !state.showsHelp || scope == .help else { return .none }
        switch scope {
        case .content: state.pane = .content
          state.scroll = min(state.maxScroll, max(0, offset))
          alignCursorToViewport(&state)
        case .help: state.helpScroll = min(max(0, state.visibleHelp.count - state.helpHeight), max(0, offset))
        case .items:
          let items = state.visibleItems
          guard !items.isEmpty else { return .none }
          state.pane = .items
          return .send(.itemSelected(items[min(items.count - 1, max(0, offset) + max(1, pageSize) - 1)].id))
        case .files:
          let files = state.visibleFileRows
          guard !files.isEmpty else { return .none }
          state.pane = .files
          return .send(.fileRowSelected(files[min(files.count - 1, max(0, offset) + max(1, pageSize) - 1)].id))
        }
        return .none
      case let .tabSelected(tab):
        guard tab != state.tab else { return .none }
        state.tab = tab
        return loadContent(&state, resetScroll: true)
      case let .keyPressed(key):
        if key == "esc", !state.showsHelp, !state.isSearching, state.visualStart != nil {
          state.visualStart = nil
          return .none
        }
        if state.review != nil {
          return key == "esc" ? .send(.reviewDismissed) : .none
        }
        if state.isSearching {
          let scope = state.searchScope
          switch key {
          case "esc": return clearSearch(&state, scope)
          case "enter":
            state.searches[scope, default: .init()].isEditing = false
            switch scope {
            case .items:
              if let first = state.visibleItems.first {
                return .send(.itemSelected(first.id))
              }
            case .files:
              if let first = state.visibleFiles.first {
                return .send(.fileSelected(first.path))
              }
            case .content: return findMatches(&state)
            case .help: state.helpScroll = 0
            }
          case "backspace":
            if !state.searches[scope, default: .init()].query.isEmpty {
              state.searches[scope]?.query.removeLast()
            }
          case "space": state.searches[scope, default: .init()].query += " "
          default:
            if key.count == 1 {
              state.searches[scope, default: .init()].query += key
            }
          }
          if scope == .help {
            state.helpScroll = 0
          }
          return scope == .content ? findMatches(&state) : .none
        }
        if key == "esc", state.activeSearch.isActive {
          return clearSearch(&state, state.searchScope)
        }
        if key == "g", !state.pendingG {
          state.pendingG = true
          return .none
        }
        let combined = state.pendingG && key == "g" ? "gg" : key
        state.pendingG = false
        if let command = state.preferences.keymap.command(for: combined) {
          return .send(.commandPressed(command))
        }
        return .none
      case let .commandPressed(command):
        if !state.showsHelp, state.pane == .content, state.tab == .diff, state.document.diff != nil {
          if command == .comment || command == .refresh {
            return reviewAtCursor(&state)
          }
          if command == .selectLines {
            guard !state.isPreparingDocument, let rows = state.document.diff?.rows, rows.indices.contains(state.diffCursor),
                  rows[state.diffCursor].line(on: state.diffSide) != nil else { return .none }
            state.visualStart = state.visualStart == nil ? state.diffCursor : nil
            return .none
          }
          if command == .left || command == .right {
            let side: InlineComment.Side = command == .left ? .left : .right
            guard let row = nearestDiffRow(state, to: state.diffCursor, side: side) else { return .none }
            state.diffSide = side
            state.diffCursor = row
            state.visualStart = nil
            return state.contentWidth < 100 ? loadContent(&state) : .none
          }
        }
        if !state.showsHelp, state.pane == .files, state.preferences.filesView == .tree,
           let row = state.fileCursor
        {
          if command == .open, row.isDirectory {
            return .send(.fileRowActivated(row.id))
          }
          if command == .left {
            if row.isDirectory, state.searches[.files]?.query.isEmpty != false,
               !state.collapsedDirectories.contains(row.path)
            {
              state.collapsedDirectories.insert(row.path)
              return .none
            }
            if let parent = row.parent {
              state.fileCursorID = parent
            }
            return .none
          }
          if command == .right, row.isDirectory {
            if state.collapsedDirectories.remove(row.path) == nil,
               let index = state.visibleFileRows.firstIndex(where: { $0.id == row.id }),
               state.visibleFileRows.indices.contains(index + 1)
            {
              return .send(.fileRowSelected(state.visibleFileRows[index + 1].id))
            }
            return .none
          }
        }
        if state.showsHelp {
          let maximum = max(0, state.visibleHelp.count - state.helpHeight)
          switch command {
          case .search: state.searches[.help, default: .init()].isEditing = true
          case .back:
            if state.activeSearch.isActive {
              return clearSearch(&state, .help)
            }
            state.showsHelp = false
            state.helpScroll = 0
          case .help, .quit: state.showsHelp = false
            state.helpScroll = 0
          case .down, .nextMatch: state.helpScroll = min(maximum, state.helpScroll + 1)
          case .up, .previousMatch: state.helpScroll = max(0, state.helpScroll - 1)
          case .halfPageDown, .contentHalfPageDown: state.helpScroll = min(
              maximum,
              state.helpScroll + max(1, state.helpHeight / 2),
            )
          case .halfPageUp, .contentHalfPageUp: state.helpScroll = max(0, state.helpScroll - max(1, state.helpHeight / 2))
          case .first: state.helpScroll = 0
          case .last: state.helpScroll = maximum
          default: break
          }
          return .none
        }
        switch command {
        case .filters: return .send(.filtersOpened)
        case .selectLines: return .none
        case .previousTab, .nextTab:
          return .send(.tabSelected(ContentTab(rawValue: (state.tab.rawValue + (command == .nextTab ? 1 : 3)) % 4) ?? .overview))
        case .itemsPane: state.pane = .items
        case .filesPane: state.pane = .files
        case .contentPane: state.pane = .content
          alignCursorToViewport(&state)
        case .left, .previousPane: state.pane = Pane(rawValue: (state.pane.rawValue + 2) % 3) ?? .items
          state.visualStart = nil
          alignCursorToViewport(&state)
        case .right, .nextPane: state.pane = Pane(rawValue: (state.pane.rawValue + 1) % 3) ?? .items
          state.visualStart = nil
          alignCursorToViewport(&state)
        case .help: state.showsHelp = true
          state.helpScroll = 0
        case .search: state.visualStart = nil
          state.searches[state.searchScope, default: .init()].isEditing = true
        case .refresh: return loadList(&state, invalidateCache: true)
        case .loadMore:
          if let page = state.nextPage, !state.isLoading {
            return loadList(&state, page: page)
          }
        case .toggleKind:
          state.kind = state.kind == .pullRequest ? .issue : .pullRequest
          state.items = []
          state.selectedItemID = nil
          state.searches = [:]
          return loadList(&state)
        case .open:
          if state.pane == .items {
            state.pane = state.kind == .pullRequest ? .files : .content
          } else if state.pane == .files {
            state.pane = .content
            alignCursorToViewport(&state)
            return .send(.tabSelected(.diff))
          }
        case .back:
          if state.activeSearch.isActive {
            return clearSearch(&state, state.searchScope)
          }
          state.pane = .items
          state.error = nil
        case .theme:
          state.preferences.theme = state.preferences.theme.next
          return state.tab == .diff ? loadContent(&state) : .none
        case .review, .comment:
          if command == .comment, state.pane == .files, state.fileCursor?.isDirectory == true {
            return .none
          }
          guard let detail = state.detail, !state.isLoadingDetail, !state.isPreparingDocument, detail.item.state == .open,
                !detail.item.isDraft else { return .none }
          state.review = state.drafts[detail.item.id] ?? .init(
            item: detail.item,
            expectedHead: detail.revision?.head,
            expectedMergeBase: detail.revision?.mergeBase,
          )
          let file = state.selectedFile
          state.review?.selectedFile = file
          state.review?.inlineAnchorLocked = false
          state.review?.latestHead = detail.revision?.head
          state.review?.latestMergeBase = detail.revision?.mergeBase
          let stale = state.review?.expectedHead != detail.revision?.head
          if stale {
            state.review?.error = .init(.revisionChanged)
          }
          state.review?.isEditingInline = !stale && command == .comment && detail.item.kind == .pullRequest && file?.patch != nil
        case .contentHalfPageDown, .contentHalfPageUp:
          let delta = max(1, state.contentHeight / 2) * (command == .contentHalfPageDown ? 1 : -1)
          state.scroll = min(state.maxScroll, max(0, state.scroll + delta))
          alignCursorToViewport(&state)
        case .down, .up, .first, .last, .halfPageDown, .halfPageUp, .nextMatch, .previousMatch:
          return move(&state, command)
        case .markReviewed: return .send(.markReviewedPressed)
        case .quit, .openBrowser: break
        }
        return .none
      case let .itemSelected(id):
        guard let item = state.items.first(where: { $0.id == id }) else { return .none }
        if id == state.selectedItemID, state.detail != nil, !state.isLoadingDetail {
          return .none
        }
        state.selectedItemID = id
        state.selectedFilePath = nil
        state.fileCursorID = nil
        state.collapsedDirectories = []
        state.error = nil
        state.detailGeneration += 1
        state.detail = state.detailCache[id] ?? ItemDetail(item: item)
        state.isLoadingDetail = state.detailCache[id] == nil
        state.selectedFilePath = state.visibleFiles.first?.path
        state.fileCursorID = state.selectedFilePath.map { "file:" + $0 }
        let contentEffect = loadContent(&state, resetScroll: true)
        guard state.isLoadingDetail else { return .merge(.cancel(id: CancelID.detail), contentEffect) }
        let generation = state.detailGeneration
        return .merge(contentEffect, replacing(.detail, with: .run(priority: .utility) { [clock] send in
          do {
            try await clock.sleep(for: .milliseconds(120))
            await send(.detailDelayElapsed(generation: generation, item))
          } catch is CancellationError {}
          catch {
            if !Task.isCancelled {
              await send(.detailResponse(generation: generation, .failure(.wrapping(error))))
            }
          }
        }))
      case let .detailDelayElapsed(generation, item):
        guard generation == state.detailGeneration, item.id == state.selectedItemID else { return .none }
        return replacing(.detail, with: .run(priority: .utility) { [forge] send in
          do {
            let detail = try await forge.detail(item)
            try Task.checkCancellation()
            await send(.detailResponse(generation: generation, .success(detail)))
          } catch is CancellationError {}
          catch {
            if !Task.isCancelled {
              await send(.detailResponse(generation: generation, .failure(.wrapping(error))))
            }
          }
        })
      case let .fileSelected(path):
        guard state.detail?.files.contains(where: { $0.path == path }) == true else { return .none }
        if path == state.selectedFilePath, state.tab == .diff, state.error == nil,
           state.isPreparingDocument || state.documentTitle == state.contentTitle
        {
          return .none
        }
        state.selectedFilePath = path
        state.fileCursorID = "file:" + path
        state.error = nil
        state.tab = .diff
        return loadContent(&state, resetScroll: true)
      case let .listResponse(generation, append, result):
        guard generation == state.listGeneration else { return .none }
        state.isLoading = false
        switch result {
        case let .failure(error): state.error = error
          return .none
        case let .success(page):
          let ids = Set(state.items.map(\.id))
          state.items = append ? state.items + page.items.filter { !ids.contains($0.id) } : page.items
          state.nextPage = page.nextPage
          if append {
            return .none
          }
          if let id = state.selectedItemID, state.items.contains(where: { $0.id == id }) {
            return .send(.itemSelected(id))
          }
          if let first = state.visibleItems.first {
            return .send(.itemSelected(first.id))
          }
          state.selectedItemID = nil
          return loadContent(&state)
        }
      case let .detailResponse(generation, result):
        guard generation == state.detailGeneration else { return .none }
        state.isLoadingDetail = false
        switch result {
        case let .failure(error): state.error = error
          return .none
        case let .success(detail):
          state.detail = detail
          if state.detailCache.count >= 16 {
            state.detailCache.removeAll(keepingCapacity: true)
          }
          state.detailCache[detail.item.id] = detail
          state.selectedFilePath = state.visibleFiles.first?.path
          state.fileCursorID = state.selectedFilePath.map { "file:" + $0 }
          return loadContent(&state)
        }
      case let .contentResponse(generation, result):
        guard generation == state.contentGeneration else { return .none }
        state.isLoadingDiff = false
        state.isPreparingDocument = false
        switch result {
        case let .success(document):
          state.document = document
          state.documentTitle = state.contentTitle
          state.scroll = state.resetsScrollOnResponse ? 0 : min(state.scroll, state.maxScroll)
          state.resetsScrollOnResponse = false
          if let diff = document.diff, !diff.rows.isEmpty {
            let desired = state.scroll
            if let row = nearestDiffRow(state, to: desired, side: state.diffSide) {
              state.diffCursor = row
            } else {
              state.diffSide = state.diffSide == .left ? .right : .left
              state.diffCursor = nearestDiffRow(state, to: desired, side: state.diffSide) ?? 0
            }
          }
          return findMatches(&state)
        case let .failure(error): state.error = error
        }
        return .none
      case let .searchResponse(generation, matches):
        guard generation == state.searchGeneration else { return .none }
        state.isFinding = false
        state.searches[.content, default: .init()].matches = matches
        state.searches[.content, default: .init()].selection = 0
        if let first = matches.first {
          state.scroll = min(state.maxScroll, first)
          alignCursorToViewport(&state)
        }
        return .none
      case let .searchFailed(generation, error):
        guard generation == state.searchGeneration else { return .none }
        state.isFinding = false
        state.error = error
        return .none
      case let .viewportChanged(width, height):
        let changed = max(1, width) != state.contentWidth
        state.contentWidth = max(1, width)
        state.contentHeight = max(1, height)
        state.scroll = min(state.scroll, state.maxScroll)
        return changed ? loadContent(&state) : .none
      case let .helpViewportChanged(height):
        state.helpHeight = max(1, height)
        state.helpScroll = min(state.helpScroll, max(0, state.visibleHelp.count - state.helpHeight))
        return .none
      case .review(.delegate(.submitted)):
        if let id = state.review?.item.id {
          state.drafts[id] = nil
          state.detailCache[id] = nil
        }
        state.review = nil
        state.detail = nil
        if let id = state.selectedItemID {
          return .send(.itemSelected(id))
        }
        return .none
      case .review(.delegate(.dismissed)): return .send(.reviewDismissed)
      case .review: return .none
      case .reviewDismissed:
        guard let review = state.review, !review.isSubmitting else { return .none }
        state.drafts[review.item.id] = review
        state.review = nil
        return .none
      case .markReviewedPressed:
        guard state.pane != .files || state.fileCursor?.isDirectory != true else { return .none }
        guard let path = state.selectedFilePath, let key = state.reviewKey(for: path) else { return .none }
        if !state.reviewedFiles.insert(key).inserted {
          state.reviewedFiles.remove(key)
        }
        return .none
      }
    }
    .ifLet(\.review, action: \.review) { ReviewFeature() }
    .ifLet(\.filterEditor, action: \.filterEditor) { FilterFeature() }
  }

  private func clearSearch(_ state: inout State, _ scope: SearchScope) -> Effect<Action> {
    state.searches[scope] = .init()
    state.pendingG = false
    if scope == .help {
      state.helpScroll = 0
    }
    if scope == .files, let path = state.selectedFilePath {
      for row in state.detail?.fileTree.rows ?? [] where row.isDirectory && path.hasPrefix(row.path + "/") {
        state.collapsedDirectories.remove(row.path)
      }
    }
    if scope == .content {
      state.searchGeneration += 1
      state.isFinding = false
      return .cancel(id: CancelID.search)
    }
    return .none
  }

  private func findMatches(_ state: inout State) -> Effect<Action> {
    state.searchGeneration += 1
    state.searches[.content, default: .init()].matches = []
    let query = state.searches[.content]?.query ?? ""
    state.isFinding = !query.isEmpty
    guard !query.isEmpty else { return .cancel(id: CancelID.search) }
    let generation = state.searchGeneration
    let document = state.document
    return replacing(.search, with: .run(priority: .utility) { [documents, clock] send in
      do {
        try await clock.sleep(for: .milliseconds(60))
        let matches = try await documents.search(document, query)
        try Task.checkCancellation()
        await send(.searchResponse(generation: generation, matches: matches))
      } catch is CancellationError {}
      catch {
        if !Task.isCancelled {
          await send(.searchFailed(generation: generation, .wrapping(error)))
        }
      }
    })
  }

  private func loadList(_ state: inout State, page: Int = 1, invalidateCache: Bool = false) -> Effect<Action> {
    state.listGeneration += 1
    state.isLoading = true
    state.error = nil
    if page == 1 {
      state.detailGeneration += 1
      state.contentGeneration += 1
      state.searchGeneration += 1
      state.detail = nil
      state.document = .init()
      state.detailCache = [:]
      state.isLoadingDetail = false
      state.isLoadingDiff = false
      state.isPreparingDocument = false
      state.isFinding = false
      state.selectedFilePath = nil
    }
    let generation = state.listGeneration
    let repository = state.repository
    let kind = state.kind
    let query = state.activeFilter
    let effect: Effect<Action> = .run(priority: .utility) { [forge] send in
      do {
        if invalidateCache {
          try await forge.invalidate(repository)
        }
        let result: ItemPage = if query.isEmpty {
          try await forge.list(repository, kind, page)
        } else {
          try await forge.search(repository, kind, query, page)
        }
        try Task.checkCancellation()
        await send(.listResponse(generation: generation, append: page > 1, .success(result)))
      } catch is CancellationError {}
      catch {
        if !Task.isCancelled {
          await send(.listResponse(
            generation: generation,
            append: page > 1,
            .failure(.wrapping(error)),
          ))
        }
      }
    }
    let replacement = replacing(.list, with: effect)
    guard page == 1 else { return replacement }
    return .concatenate(
      .merge(.cancel(id: CancelID.detail), .cancel(id: CancelID.content), .cancel(id: CancelID.search)),
      replacement,
    )
  }

  private func loadContent(_ state: inout State, resetScroll: Bool = false) -> Effect<Action> {
    state.contentGeneration += 1
    state.searchGeneration += 1
    state.resetsScrollOnResponse = state.resetsScrollOnResponse || resetScroll
    state.visualStart = nil
    state.isLoadingDiff = false
    state.isPreparingDocument = true
    state.isFinding = false
    state.searches[.content, default: .init()].matches = []
    let generation = state.contentGeneration
    let width = state.contentWidth
    let side = state.diffSide
    let source = ContentSource(detail: state.detail, tab: state.tab, strings: state.strings)
    let request: DiffRequest?
    if state.tab == .diff, let revision = state.detail?.revision, let file = state.selectedFile {
      request = .init(repository: state.repository, revision: revision, file: file, width: width, theme: state.preferences.theme)
      state.isLoadingDiff = true
    } else {
      request = nil
    }
    return .concatenate(
      .cancel(id: CancelID.search),
      replacing(.content, with: .run(priority: .utility) { [documents, difftastic] send in
        do {
          let document: ReviewDocument
          if let request {
            let output = try await difftastic.render(request)
            document = try await documents.prepareDiff(output, width, side)
          } else {
            document = try await documents.prepare(source.rendered(), width)
          }
          try Task.checkCancellation()
          await send(.contentResponse(generation: generation, .success(document)))
        } catch is CancellationError {}
        catch {
          if !Task.isCancelled {
            await send(.contentResponse(generation: generation, .failure(.wrapping(error))))
          }
        }
      }),
    )
  }

  /// Cancel synchronously when subscribing, before scheduling the replacement.
  /// A late-starting older run must never cancel a newer generation's task.
  private func replacing(_ id: CancelID, with effect: Effect<Action>) -> Effect<Action> {
    .concatenate(.cancel(id: id), effect.cancellable(id: id))
  }

  private func move(_ state: inout State, _ command: KeyCommand) -> Effect<Action> {
    if state.pane == .content, state.tab == .diff, let diff = state.document.diff,
       !state.isPreparingDocument, command != .nextMatch, command != .previousMatch
    {
      guard !diff.rows.isEmpty else { return .none }
      let proposed: Int = switch command {
      case .first: 0
      case .last: max(0, diff.rows.count - 1)
      case .up: state.diffCursor - 1
      case .halfPageUp: state.diffCursor - max(1, state.contentHeight / 2)
      case .halfPageDown: state.diffCursor + max(1, state.contentHeight / 2)
      default: state.diffCursor + 1
      }
      let down = proposed >= state.diffCursor
      let start = max(0, min(proposed, diff.rows.count - 1))
      let indices = down ? Array(start ..< diff.rows.count) : Array((0 ... start).reversed())
      if let row = indices.first(where: { diff.rows[$0].line(on: state.diffSide) != nil }) {
        state.diffCursor = row
      }
      state.scroll = min(state.maxScroll, max(0, min(state.scroll, state.diffCursor)))
      if state.diffCursor >= state.scroll + state.contentHeight {
        state.scroll = min(
          state.maxScroll,
          state.diffCursor - state.contentHeight + 1,
        )
      }
      state.error = nil
      return .none
    }
    if state.pane == .content, command == .nextMatch || command == .previousMatch {
      guard let search = state.searches[.content], !search.matches.isEmpty else { return .none }
      let index = (search.selection + (command == .nextMatch ? 1 : search.matches.count - 1)) % search.matches.count
      state.searches[.content]?.selection = index
      state.scroll = min(state.maxScroll, search.matches[index])
      alignCursorToViewport(&state)
      return .none
    }
    let step = switch command {
    case .up, .previousMatch: -1
    case .halfPageUp: -max(1, state.contentHeight / 2)
    case .halfPageDown: max(1, state.contentHeight / 2)
    default: 1
    }
    func index(_ current: Int, _ count: Int) -> Int {
      if command == .first {
        return 0
      }
      if command == .last {
        return max(0, count - 1)
      }
      return min(max(0, count - 1), max(0, current + step))
    }
    switch state.pane {
    case .items:
      let items = state.visibleItems
      guard !items.isEmpty else { return .none }
      let next = index(items.firstIndex { $0.id == state.selectedItemID } ?? 0, items.count)
      if items[next].id != state.selectedItemID {
        return .send(.itemSelected(items[next].id))
      }
    case .files:
      let files = state.visibleFileRows
      guard !files.isEmpty else { return .none }
      let next = index(files.firstIndex { $0.id == state.fileCursorKey } ?? 0, files.count)
      if files[next].id != state.fileCursorKey {
        return .send(.fileRowSelected(files[next].id))
      }
    case .content: state.scroll = index(state.scroll, state.maxScroll + 1)
    }
    return .none
  }

  private func nearestDiffRow(_ state: State, to row: Int, side: InlineComment.Side) -> Int? {
    state.document.diff?.rows.indices.filter { state.document.diff?.rows[$0].line(on: side) != nil }
      .min { abs($0 - row) < abs($1 - row) }
  }

  private func alignCursorToViewport(_ state: inout State) {
    guard state.pane == .content, let rows = state.document.diff?.rows, !rows.isEmpty else { return }
    let visible = state.scroll ..< min(rows.count, state.scroll + state.contentHeight)
    guard !visible.contains(state.diffCursor) else { return }
    if let row = visible.first(where: { rows[$0].line(on: state.diffSide) != nil }) {
      state.diffCursor = row
    }
  }

  private func reviewAtCursor(_ state: inout State) -> Effect<Action> {
    guard !state.isPreparingDocument, !state.isLoadingDetail, let detail = state.detail,
          detail.item.state == .open, !detail.item.isDraft,
          let file = state.selectedFile, let diff = state.document.diff,
          diff.path == file.path, diff.revision == detail.revision,
          let rows = Optional(diff.rows),
          rows.indices.contains(state.diffCursor), rows.indices.contains(state.visualStart ?? state.diffCursor),
          let end = rows[state.diffCursor].line(on: state.diffSide)?.number,
          let start = rows[state.visualStart ?? state.diffCursor].line(on: state.diffSide)?.number else { return .none }
    let range = min(start, end) ... max(start, end)
    guard ReviewAnchor.contains(range: range, side: state.diffSide, patch: file.patch) else {
      state.error = .init(.invalidLine)
      return .none
    }
    state.review = state.drafts[detail.item.id] ?? .init(
      item: detail.item,
      expectedHead: detail.revision?.head,
      expectedMergeBase: detail.revision?.mergeBase,
    )
    state.review?.stashInlineDraft()
    state.review?.selectedFile = file
    state.review?.latestHead = detail.revision?.head
    state.review?.latestMergeBase = detail.revision?.mergeBase
    state.review?.inlineLine = String(range.upperBound)
    state.review?.inlineStartLine = range.lowerBound == range.upperBound ? "" : String(range.lowerBound)
    let selectedSide = state.diffSide
    state.review?.inlineSide = selectedSide
    state.review?.inlineAnchorLocked = true
    state.review?.restoreInlineDraft()
    state.review?.isEditingInline = true
    state.visualStart = nil
    return .none
  }
}
