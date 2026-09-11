// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import Foundation
import TataraCore

/// Capture values during selection; concatenate source text on the concurrent executor.
private struct ContentSource: Sendable {
  let detail: ItemDetail?
  let tab: WorkspaceFeature.ContentTab
  let strings: [String: String]
  var drafts: [InlineComment] = []
  var detailLevel: DetailLevel = .compact

  @concurrent
  func document(width: Int, documents: DocumentClient) async throws -> ReviewDocument {
    try Task.checkCancellation()
    func text(_ key: String) -> String {
      strings[key] ?? key
    }
    guard let detail else { return try await documents.prepare(text("Select an item to begin."), width) }
    let item = detail.item
    let result: String
    switch tab {
    case .overview:
      let status = item.isDraft ? "Draft" : item.state == .open ? "Open" : item.state == .merged ? "Merged" : "Closed"
      var lines = ["# \(item.title)", "#\(item.id.number) · @\(item.author) · \(text(status))", ""]
      if let info = item.github {
        if item.kind == .pullRequest {
          lines.append("**\(text("Review"))**  \(text(info.reviewTitleKey))   ·   **CI**  \(text(info.checksTitleKey))")
        }
        if let count = info.commentCount {
          lines.append("**\(text("Comments"))**  \(count)")
        }
        if let head = info.headBranch, let base = info.baseBranch {
          lines.append("`\(head)` → `\(base)`")
        }
        if let additions = info.additions, let deletions = info.deletions {
          lines
            .append(
              "+\(additions) −\(deletions)   ·   \(info.changedFiles.map(String.init) ?? "–") \(text("Files"))   ·   \(info.commits.map(String.init) ?? "–") \(text("Commits"))",
            )
        }
        if detailLevel == .rich {
          let fields: [(String, String?)] = [
            ("Assignees", info.assignees.isEmpty ? nil : info.assignees.map { "@" + $0 }.joined(separator: ", ")),
            (
              "Requested reviewers",
              (info.requestedReviewers.map { "@" + $0 } + info.requestedTeams.map { "team:" + $0 }).isEmpty ? nil :
                (info.requestedReviewers.map { "@" + $0 } + info.requestedTeams.map { "team:" + $0 }).joined(separator: ", "),
            ),
            ("Milestone", info.milestone), ("Created", info.createdAt), ("Updated", info.updatedAt),
            ("Closed", info.closedAt), ("Merged", info.mergedAt),
          ]
          lines.append("")
          for (key, value) in fields {
            if let value {
              lines.append("**\(text(key))**  \(value)")
            }
          }
        }
      }
      if !item.labels.isEmpty {
        lines.append("**\(text("Labels"))**  " + item.labels.joined(separator: " · "))
      }
      if case let .github(metadata) = detail.metadata, detailLevel == .rich {
        lines.append("**GitHub**  \(metadata.mergeableState)")
      }
      if let revision = detail.revision, detailLevel == .rich {
        lines.append("`\(revision.mergeBase.prefix(8))…\(revision.head.prefix(8))`")
      }
      lines += ["", item.url.absoluteString, "", item.body]
      let overview = try await documents.prepareComment(lines.joined(separator: "\n"), max(1, min(110, width - 6)))
      return try ReviewDocument(
        lines: overview.displayLines.map { [.init(text: "   ", role: .commentBody)] + $0 },
        checkingCancellation: Task.checkCancellation,
      )
    case .diff: result = text("Select a file to read its diff.")
    case .discussion:
      var lines: [[DiffSpan]] = []
      for comment in detail.comments {
        try Task.checkCancellation()
        lines += try await commentLines(
          comment,
          heading: "@\(comment.author)\(comment.context.map { " · \($0)" } ?? "")",
          width: width,
          documents: documents,
        )
      }
      return lines.isEmpty ? try await documents.prepare(text("No comments yet."), width) : try ReviewDocument(
        lines: lines,
        checkingCancellation: Task.checkCancellation,
      )
    case .checks:
      if case let .github(metadata) = detail.metadata {
        let lines = metadata.checks + metadata.reviews
        result = lines.isEmpty ? text("No checks reported.") : lines.joined(separator: "\n")
      } else {
        result = text("No checks reported.")
      }
    }
    try Task.checkCancellation()
    return try await documents.prepare(result, width)
  }

  @concurrent
  private func commentLines(
    _ comment: DiscussionComment,
    heading: String,
    width: Int,
    documents: DocumentClient,
  ) async throws -> [[DiffSpan]] {
    let body = try await documents.prepareComment(comment.body, max(1, min(110, width - 6)))
    let padding: [DiffSpan] = [.init(text: "   ", role: .commentBody)]
    return [[.init(text: "", role: .commentGap)], [.init(text: "   " + heading, bold: true, role: .comment)], padding]
      + body.displayLines.map { padding + $0 }
      + [padding, [.init(text: "", role: .commentGap)]]
  }

  @concurrent
  func diffDocument(
    filePath: String?,
    directory: String?,
    width: Int,
    side: InlineComment.Side,
    theme: Theme,
    documents: DocumentClient,
    difftastic: DiffClient,
  ) async throws -> ReviewDocument? {
    guard tab == .diff, let detail, let revision = detail.revision else { return nil }
    let files = directory.map { directory in detail.files.filter { $0.path.hasPrefix(directory + "/") } }
      ?? filePath.flatMap { detail.file(at: $0).map { [$0] } } ?? []
    guard !files.isEmpty else { return nil }
    let comments = Dictionary(grouping: detail.comments.filter { $0.anchor != nil }, by: { $0.anchor!.path })
    let draftGroups = Dictionary(grouping: drafts, by: \.path)
    var rows: [ReviewDiffRow] = [], identities: [String] = []
    var hasCacheIdentity = true
    for file in files {
      try Task.checkCancellation()
      let diff = try await difftastic.render(.init(
        repository: detail.item.id.repository,
        revision: revision,
        file: file,
        width: width,
        theme: theme,
      ))
      let remote = comments[file.path] ?? [], local = draftGroups[file.path] ?? []
      if directory == nil, remote.isEmpty, local.isEmpty {
        return try await documents.prepareDiff(diff, width, side)
      }
      hasCacheIdentity = hasCacheIdentity && diff.cacheIdentity != nil
      identities.append(diff.cacheIdentity ?? "\(revision.mergeBase):\(revision.head):\(file.path)")
      var attached: [Int: [DiscussionComment]] = [:], detached: [DiscussionComment] = []
      var positions: [String: Int] = [:]
      for (index, row) in diff.rows.enumerated() {
        for side in InlineComment.Side.allCases {
          if let line = row.line(on: side) {
            positions["\(side.rawValue):\(line.number)"] = index
          }
        }
      }
      for comment in remote {
        guard let anchor = comment.anchor else { continue }
        if let line = anchor.line, let side = anchor.side, let index = positions["\(side.rawValue):\(line)"] {
          attached[index, default: []].append(comment)
        } else {
          detached.append(comment)
        }
      }
      for (index, draft) in local.enumerated() {
        let comment = DiscussionComment(
          id: -index - 1,
          author: strings["Draft"] ?? "Draft",
          body: draft.body,
          anchor: .init(
            path: draft.path,
            line: draft.line,
            side: draft.side,
            startLine: draft.startLine,
          ),
        )
        if let index = positions["\(draft.side.rawValue):\(draft.line)"] {
          attached[index, default: []].append(comment)
        } else {
          detached.append(comment)
        }
      }
      let pathTitle = file.previousPath.map { "\($0) -> \(file.path)" } ?? file.path
      rows.append(.init(left: nil, right: nil, path: file.path, annotation: [.init(text: pathTitle, role: .filePath)]))
      func appendComment(_ comment: DiscussionComment) async throws {
        let anchor = comment.anchor!
        let location = anchor.line ?? anchor.originalLine
        let range = anchor.startLine.map { "\($0)–" } ?? ""
        let status = anchor.line == nil && anchor.subjectType != "file" ? " · \(strings["Outdated"] ?? "Outdated")" : ""
        let coordinate = anchor.subjectType == "file" ? file.path : "\(anchor.side?.rawValue ?? "–"):\(range)\(location.map(String.init) ?? "–")"
        let heading = "@\(comment.author) · \(coordinate)\(status)"
        for spans in try await commentLines(comment, heading: heading, width: width, documents: documents) {
          rows.append(.init(left: nil, right: nil, path: file.path, annotation: spans))
        }
        identities.append("\(comment.id):\(anchor):\(comment.body)")
      }
      for comment in detached {
        try await appendComment(comment)
      }
      if diff.rows.isEmpty {
        rows.append(.init(
          left: nil,
          right: nil,
          path: file.path,
          annotation: [.init(text: "\(diff.language) · \(diff.status)", role: .metadata)],
        ))
      }
      for (index, row) in diff.rows.enumerated() {
        rows.append(.init(left: row.left, right: row.right, path: file.path, annotation: row.annotation))
        for comment in attached[index] ?? [] {
          try await appendComment(comment)
        }
      }
    }
    try Task.checkCancellation()
    let combined = ReviewDiff(
      path: directory ?? files[0].path,
      language: "",
      status: "changed",
      rows: rows,
      revision: revision,
      cacheIdentity: hasCacheIdentity ? "annotated-v1:" + identities.joined(separator: "\u{0}") : nil,
    )
    return try await documents.prepareDiff(combined, width, side)
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
    public var preferences: Preferences {
      didSet {
        if preferences.filesView != oldValue.filesView {
          rebuildFileRows()
        }
      }
    }

    public var strings: [String: String]
    public var kind = ItemKind.pullRequest
    public var items: [ForgeItem] = [] {
      didSet {
        itemIndices = Dictionary(items.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        rebuildItems()
      }
    }

    public var selectedItemID: ItemID?
    public var selectedDirectoryPath: String?
    public var selectedFilePath: String?
    public var fileCursorID: String?
    public var collapsedDirectories = Set<String>() {
      didSet {
        if collapsedDirectories != oldValue {
          rebuildFileRows()
        }
      }
    }

    public var detail: ItemDetail? {
      didSet { rebuildFiles() }
    }

    @ObservationStateIgnored public var detailCache: [ItemID: ItemDetail] = [:]
    @ObservationStateIgnored var detailAccess: [ItemID: Int] = [:]
    @ObservationStateIgnored var cacheAccess = 0
    public var document = ReviewDocument()
    public var documentTitle = ""
    public var resetsScrollOnResponse = false
    public var pendingCursorLocation: SourceLocation?
    public var pendingViewportLocation: SourceLocation?
    public var pendingViewportOffset = 0
    public var diffCursor = 0
    public var diffSide = InlineComment.Side.right
    public var visualStart: Int?
    public var pane = Pane.items
    public var tab = ContentTab.overview
    public var scroll = 0
    public var itemsScroll = 0
    public var filesScroll = 0
    public var itemsHeight = 12
    public var itemRowHeight: Int {
      preferences.detailLevel == .rich ? 2 : 1
    }

    public var itemsPage: Int {
      max(1, itemsHeight / itemRowHeight)
    }

    public var filesHeight = 12
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
    public var fileMatches: [String: [Int]]? {
      didSet { rebuildFiles() }
    }

    public var fileSearchGeneration = 0
    public var isSearchingFiles = false

    public var showsHelp = false
    public var pendingPrefix: String?
    public var reviewLocation: SourceLocation?
    public var reviewRow: Int? {
      reviewLocation.flatMap { document.row(for: $0) }
    }

    public var reviewPanelHeight: Int {
      min(18, max(9, contentHeight * 2 / 3))
    }

    public var review: ReviewFeature.State?
    public var filterEditor: FilterFeature.State?
    public var activeFilter = ""
    public var reviewedFiles = Set<String>()
    public var drafts: [ItemID: ReviewFeature.State] = [:]
    public var listGeneration = 0
    public var detailGeneration = 0
    public var documentGeneration = 0
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
      selectedItemID.flatMap { item(for: $0) }
    }

    public var selectedFile: ChangedFile? {
      selectedFilePath.flatMap { detail?.file(at: $0) }
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
      if tab == .diff, let path = selectedDirectoryPath ?? selectedFilePath {
        title += " · \(path)"
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

    private var itemIndices: [ItemID: Int] = [:]
    private var visibleItemIndices: [ItemID: Int] = [:]
    private var visibleFileIndices: [String: Int] = [:]
    public var selectedItemIndex: Int? {
      selectedItemID.flatMap { visibleItemIndices[$0] }
    }

    public var fileCursorIndex: Int? {
      fileCursorKey.flatMap { visibleFileIndices[$0] }
    }

    fileprivate func item(for id: ItemID) -> ForgeItem? {
      itemIndices[id].map { items[$0] }
    }

    fileprivate func fileRow(for id: String) -> FileTreeRow? {
      visibleFileIndices[id].map { visibleFileRows[$0] }
    }

    public private(set) var visibleItems: [ForgeItem] = []
    public private(set) var visibleFiles: [ChangedFile] = []
    public private(set) var visibleFileRows: [FileTreeRow] = []

    private mutating func rebuildItems() {
      visibleItems = items
      visibleItemIndices = Dictionary(
        visibleItems.enumerated().map { ($0.element.id, $0.offset) },
        uniquingKeysWith: { first, _ in first },
      )
    }

    private mutating func rebuildFiles() {
      let files = detail?.files ?? []
      visibleFiles = fileMatches.map { matches in files.filter { matches[$0.path] != nil } } ?? files
      rebuildFileRows()
    }

    private mutating func rebuildFileRows() {
      if preferences.filesView == .list {
        visibleFileRows = visibleFiles.map { .init(path: $0.path, name: $0.path, depth: 0, isDirectory: false) }
      } else {
        visibleFileRows = detail?.fileTree.visible(
          collapsed: collapsedDirectories,
          matching: fileMatches.map { Set($0.keys) },
        ) ?? []
      }
      visibleFileIndices = Dictionary(
        visibleFileRows.enumerated().map { ($0.element.id, $0.offset) },
        uniquingKeysWith: { first, _ in first },
      )
    }

    public var fileCursor: FileTreeRow? {
      fileCursorKey.flatMap { fileRow(for: $0) }
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

    public var isDocumentCurrent: Bool {
      // Pending requests share the same preview state; avoid observing their changing tokens.
      !isPreparingDocument && documentGeneration == contentGeneration
    }

    public var maxScroll: Int {
      max(0, document.lines.count + (reviewLocation == nil ? 0 : reviewPanelHeight) - contentHeight)
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
    case sidebarViewportChanged(items: Int, files: Int)
    case scrollbarMoved(SearchScope, offset: Int)
    case wheelScrolled(SearchScope, delta: Int)
    case itemSelected(ItemID)
    case fileSelected(String)
    case fileRowSelected(String)
    case fileRowActivated(String)
    case diffCursorSelected(row: Int, side: InlineComment.Side)
    case filtersOpened
    case filterEditor(FilterFeature.Action)
    case listResponse(generation: Int, append: Bool, Result<ItemPage, TataraError>)
    case detailResponse(generation: Int, Result<ItemDetail, TataraError>)
    case contentResponse(generation: Int, Result<ReviewDocument, TataraError>)
    case fileSearchResponse(generation: Int, Result<[String: [Int]], TataraError>)
    case searchResponse(generation: Int, matches: SearchMatches)
    case wordSearchResponse(
      generation: Int,
      row: Int,
      side: InlineComment.Side,
      column: Int,
      direction: Int,
      SearchPattern.WordQuery?,
    )
    case searchProjectionResponse(generation: Int, selection: Int, Result<(ReviewDocument, SearchMatches), TataraError>)
    case searchFailed(generation: Int, TataraError)
    case review(ReviewFeature.Action)
    case reviewDismissed
    case markReviewedPressed
  }

  enum CancelID { case list, detail, content, search, filesSearch }
  @Dependency(ForgeClient.self) var forge
  @Dependency(DiffClient.self) var difftastic
  @Dependency(DocumentClient.self) var documents
  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      let previousItem = state.selectedItemID, previousItemIndex = state.selectedItemIndex
      let previousFile = state.fileCursorKey, previousFileIndex = state.fileCursorIndex
      let revealsItems: Bool
      let revealsFiles: Bool
      switch action {
      case .itemSelected: revealsItems = true
        revealsFiles = false
      case .fileSelected, .fileRowSelected, .fileRowActivated: revealsItems = false
        revealsFiles = true
      default: revealsItems = false
        revealsFiles = false
      }
      defer {
        // Manual scrolling owns the viewport. Reveal only explicit selection changes.
        if revealsItems || previousItem != state.selectedItemID || previousItemIndex != state.selectedItemIndex {
          state.itemsScroll = ScrollMetrics.selectionOffset(
            selected: state.selectedItemIndex ?? 0,
            total: state.visibleItems.count,
            page: state.itemsPage,
            previous: state.itemsScroll,
          )
        } else {
          state.itemsScroll = min(max(0, state.visibleItems.count - state.itemsPage), max(0, state.itemsScroll))
        }
        if revealsFiles || previousFile != state.fileCursorKey || previousFileIndex != state.fileCursorIndex {
          state.filesScroll = ScrollMetrics.selectionOffset(
            selected: state.fileCursorIndex ?? 0,
            total: state.visibleFileRows.count,
            page: state.filesHeight,
            previous: state.filesScroll,
          )
        } else {
          state.filesScroll = min(max(0, state.visibleFileRows.count - state.filesHeight), max(0, state.filesScroll))
        }
      }
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
        state.searches[.items]?.query = query
        return loadList(&state)
      case .filterEditor(.delegate(.close)): state.filterEditor = nil
        return .none
      case .filterEditor: return .none
      case let .diffCursorSelected(row, side):
        guard state.filterEditor == nil, state.review == nil, !state.showsHelp,
              state.isDocumentCurrent, let diff = state.document.diff, diff.rows.indices.contains(row),
              diff.rows[row].line(on: side) != nil else { return .none }
        state.pane = .content
        state.diffSide = side
        state.diffCursor = row
        state.visualStart = nil
        return .none
      case let .fileRowActivated(id):
        guard state.filterEditor == nil, state.review == nil, !state.showsHelp else { return .none }
        state.pane = .files
        guard let row = state.fileRow(for: id) else { return .none }
        state.fileCursorID = id
        if row.isDirectory {
          guard state.fileMatches == nil else { return .send(.fileRowSelected(id)) }
          if !state.collapsedDirectories.insert(row.path).inserted {
            state.collapsedDirectories.remove(row.path)
          }
          return .send(.fileRowSelected(id))
        }
        return .send(.fileSelected(row.path))
      case let .fileRowSelected(id):
        guard let row = state.fileRow(for: id) else { return .none }
        state.fileCursorID = id
        if row.isDirectory {
          if state.selectedDirectoryPath == row.path, state.tab == .diff, state.error == nil {
            return .none
          }
          state.selectedDirectoryPath = row.path
          state.selectedFilePath = nil
          state.tab = .diff
          state.error = nil
          return loadContent(&state, resetScroll: true)
        }
        return .send(.fileSelected(row.path))
      case let .wheelScrolled(scope, delta):
        guard state.review == nil, state.filterEditor == nil, delta != 0, !state.showsHelp || scope == .help else { return .none }
        switch scope {
        case .content: state.scroll = min(state.maxScroll, max(0, state.scroll + delta))
        case .help:
          guard state.showsHelp else { return .none }
          state.helpScroll = min(max(0, state.visibleHelp.count - state.helpHeight), max(0, state.helpScroll + delta))
        case .items: state.itemsScroll = min(
            max(0, state.visibleItems.count - state.itemsPage),
            max(0, state.itemsScroll + delta),
          )
        case .files: state.filesScroll = min(
            max(0, state.visibleFileRows.count - state.filesHeight),
            max(0, state.filesScroll + delta),
          )
        }
        return .none
      case let .scrollbarMoved(scope, offset):
        guard state.filterEditor == nil, state.review == nil, !state.showsHelp || scope == .help else { return .none }
        switch scope {
        case .content: state.scroll = min(state.maxScroll, max(0, offset))
        case .help: state.helpScroll = min(max(0, state.visibleHelp.count - state.helpHeight), max(0, offset))
        case .items: state.itemsScroll = min(max(0, state.visibleItems.count - state.itemsPage), max(0, offset))
        case .files: state.filesScroll = min(max(0, state.visibleFileRows.count - state.filesHeight), max(0, offset))
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
              state.activeFilter = state.searches[.items]?.query.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
              return loadList(&state)
            case .files: return findFiles(&state)
            case .content: return .none
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
        if key == "g" || key == "z", state.pendingPrefix == nil {
          state.pendingPrefix = key
          return .none
        }
        let combined = state.pendingPrefix.map { $0 + key } ?? key
        state.pendingPrefix = nil
        if combined != key, state.preferences.keymap.command(for: combined) == nil {
          if let command = state.preferences.keymap.command(for: key) {
            return .send(.commandPressed(command))
          }
          return .none
        }
        if let command = state.preferences.keymap.command(for: combined) {
          return .send(.commandPressed(command))
        }
        return .none
      case let .commandPressed(command):
        if !state.showsHelp, state.pane == .content, state.tab == .diff, state.document.diff != nil {
          if command == .comment || command == .refresh && state.isDocumentCurrent || command == .review && state
            .visualStart != nil
          {
            return reviewAtCursor(&state)
          }
          if command == .selectLines {
            guard state.isDocumentCurrent, let rows = state.document.diff?.rows, rows.indices.contains(state.diffCursor),
                  rows[state.diffCursor].line(on: state.diffSide) != nil else { return .none }
            state.visualStart = state.visualStart == nil ? state.diffCursor : nil
            return .none
          }
          if command == .left || command == .right {
            guard state.isDocumentCurrent else { return .none }
            let side: InlineComment.Side = command == .left ? .left : .right
            guard side != state.diffSide else { return .none }
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
              return .send(.fileRowSelected(parent))
            }
            return .none
          }
          if command == .right, row.isDirectory {
            if state.collapsedDirectories.remove(row.path) == nil,
               let index = state.fileCursorIndex,
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
        case .searchWordForward, .searchWordBackward, .searchPartialWordForward, .searchPartialWordBackward:
          return findWord(&state, command)
        case .cursorToTop, .cursorToCenter, .cursorToBottom:
          guard state.pane == .content, state.tab == .diff, state.isDocumentCurrent else { return .none }
          let offset = command == .cursorToTop ? 0 : command == .cursorToCenter ? state.contentHeight / 2 : state
            .contentHeight - 1
          state.scroll = min(state.maxScroll, max(0, state.diffCursor - offset))
          return .none
        case .filters: return .send(.filtersOpened)
        case .selectLines: return .none
        case .previousTab, .nextTab:
          return .send(.tabSelected(ContentTab(rawValue: (state.tab.rawValue + (command == .nextTab ? 1 : 3)) % 4) ?? .overview))
        case .left, .right: return .none
        case .previousPane: state.pane = Pane(rawValue: (state.pane.rawValue + 2) % 3) ?? .items
          state.visualStart = nil
        case .nextPane: state.pane = Pane(rawValue: (state.pane.rawValue + 1) % 3) ?? .items
          state.visualStart = nil
        case .help: state.showsHelp = true
          state.helpScroll = 0
        case .search: state.visualStart = nil
          state.searches[state.searchScope, default: .init()].direction = 1
          state.searches[state.searchScope, default: .init()].originSide = nil
          state.searches[state.searchScope, default: .init()].originColumn = nil
          if state.searchScope == .items {
            state.searches[.items, default: .init()].query = state.activeFilter
          }
          state.searches[state.searchScope, default: .init()].origin = state.diffCursor
          state.searches[state.searchScope, default: .init()].isEditing = true
          if state.searchScope == .content {
            state.searchGeneration += 1
            state.isFinding = false
            return .cancel(id: CancelID.search)
          }
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
          if state.pane == .items, state.selectedItem != nil {
            state.pane = state.kind == .pullRequest ? .files : .content
          } else if state.pane == .files, let row = state.fileCursor, !row.isDirectory {
            state.pane = .content
            return .send(.fileSelected(row.path))
          }
        case .back:
          if state.activeSearch.isActive {
            return clearSearch(&state, state.searchScope)
          }
          state.error = nil
        case .toggleDetails:
          state.preferences.detailLevel = state.preferences.detailLevel == .compact ? .rich : .compact
          if state.tab == .overview {
            return loadContent(&state)
          }
          return .none
        case .theme:
          state.preferences.theme = state.preferences.theme.next
          return .none
        case .review, .comment:
          if command == .comment, state.pane == .files, state.fileCursor?.isDirectory == true {
            return .none
          }
          guard let detail = state.detail, !state.isLoadingDetail, state.isDocumentCurrent, detail.item.state == .open,
                !detail.item.isDraft else { return .none }
          state.review = state.drafts[detail.item.id] ?? .init(
            item: detail.item,
            expectedHead: detail.revision?.head,
            expectedMergeBase: detail.revision?.mergeBase,
          )
          state.review?.isConfirming = false
          state.reviewLocation = state.pane == .content && state.tab == .diff ? state.document.location(
            at: state.diffCursor,
            side: state.diffSide,
          ) : nil
          revealReview(&state)
          let file = state.reviewLocation.flatMap { detail.file(at: $0.path) } ?? state.selectedFile
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
        guard let item = state.item(for: id) else { return .none }
        if id == state.selectedItemID, state.detail != nil, state.error == nil {
          return .none
        }
        state.selectedItemID = id
        state.fileSearchGeneration += 1
        state.fileMatches = nil
        state.isSearchingFiles = false
        state.searches[.files] = .init()
        state.selectedDirectoryPath = nil
        state.selectedFilePath = nil
        state.fileCursorID = nil
        state.collapsedDirectories = []
        state.error = nil
        state.detailGeneration += 1
        if state.detailCache[id] != nil {
          state.cacheAccess += 1
          state.detailAccess[id] = state.cacheAccess
        }
        state.detail = state.detailCache[id] ?? ItemDetail(item: item)
        state.isLoadingDetail = state.detailCache[id] == nil
        state.selectedFilePath = state.visibleFiles.first?.path
        state.fileCursorID = state.selectedFilePath.map { "file:" + $0 }
        let contentEffect: Effect<Action> = .merge(.cancel(id: CancelID.filesSearch), loadContent(&state, resetScroll: true))
        guard state.isLoadingDetail else { return .merge(.cancel(id: CancelID.detail), contentEffect) }
        let generation = state.detailGeneration
        return .merge(contentEffect, replacing(.detail, with: .run(priority: .utility) { [forge] send in
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
        }))
      case let .fileSelected(path):
        guard state.detail?.file(at: path) != nil else { return .none }
        if path == state.selectedFilePath, state.tab == .diff, state.error == nil,
           state.isPreparingDocument || state.isDocumentCurrent && state.documentTitle == state.contentTitle
        {
          return .none
        }
        state.selectedDirectoryPath = nil
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
          retainDetail(detail, in: &state)
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
          state.documentGeneration = generation
          state.documentTitle = state.contentTitle
          let restoredTop = state.pendingViewportLocation.flatMap { document.row(for: $0) }
            .map { $0 + state.pendingViewportOffset }
          state.scroll = state.resetsScrollOnResponse ? 0 : min(state.maxScroll, max(0, restoredTop ?? state.scroll))
          let restoredCursor = state.resetsScrollOnResponse ? nil : state.pendingCursorLocation.flatMap { document.row(for: $0) }
          state.resetsScrollOnResponse = false
          state.pendingCursorLocation = nil
          state.pendingViewportLocation = nil
          state.pendingViewportOffset = 0
          if let diff = document.diff, !diff.rows.isEmpty {
            let desired = state.scroll
            if let restoredCursor {
              state.diffCursor = restoredCursor
            } else if let row = nearestDiffRow(state, to: desired, side: state.diffSide) {
              state.diffCursor = row
            } else {
              state.diffSide = state.diffSide == .left ? .right : .left
              state.diffCursor = nearestDiffRow(state, to: desired, side: state.diffSide) ?? 0
            }
          }
          revealReview(&state)
          return findMatches(&state)
        case let .failure(error): state.error = error
        }
        return .none
      case let .fileSearchResponse(generation, result):
        guard generation == state.fileSearchGeneration else { return .none }
        state.isSearchingFiles = false
        switch result {
        case let .success(matches):
          state.fileMatches = matches
          if let first = state.visibleFiles.first {
            return .send(.fileSelected(first.path))
          }
        case let .failure(error): state.error = error
        }
        return .none
      case let .wordSearchResponse(generation, row, side, column, direction, word):
        guard generation == state.searchGeneration else { return .none }
        state.isFinding = false
        guard state.isDocumentCurrent, state.pane == .content, state.tab == .diff, !state.isSearching,
              !state.showsHelp, state.review == nil,
              state.diffCursor == row, state.diffSide == side, searchColumn(state) == column else { return .none }
        guard let word else { state.error = .init(
          .invalidResponse,
          detail: state.strings["No word at cursor."] ?? "No word at cursor.",
        )
        return .none
        }
        state.searches[.content, default: .init()].query = word.pattern
        state.searches[.content, default: .init()].isEditing = false
        state.searches[.content, default: .init()].origin = row
        state.searches[.content, default: .init()].originSide = side
        state.searches[.content, default: .init()].originColumn = word.range.lowerBound
        state.searches[.content, default: .init()].direction = direction
        return findMatches(&state)
      case let .searchResponse(generation, matches):
        guard generation == state.searchGeneration, state.isDocumentCurrent else { return .none }
        state.isFinding = false
        state.searches[.content, default: .init()].result = matches
        let origin = state.searches[.content]?.origin ?? 0
        let search = state.searches[.content] ?? .init()
        let index = search.originColumn.map {
          matchIndex(matches, row: origin, side: search.originSide ?? .right, column: $0, direction: search.direction)
        } ?? (matches.lines.firstIndex { $0 >= origin } ?? 0)
        state.searches[.content, default: .init()].selection = index
        if matches.lines.indices.contains(index) {
          state.scroll = min(state.maxScroll, matches.lines[index])
          focusMatch(&state, index: index)
        }
        return revealMatch(&state)
      case let .searchProjectionResponse(generation, selection, result):
        guard generation == state.searchGeneration else { return .none }
        state.isFinding = false
        guard state.isDocumentCurrent, state.pane == .content,
              state.searches[.content]?.selection == selection,
              state.searches[.content]?.matches.indices.contains(selection) == true,
              state.searches[.content]?.matches[selection] == state.diffCursor else { return .none }
        switch result {
        case let .success((document, matches)):
          state.document = document
          state.searches[.content]?.result = matches
        case let .failure(error): state.error = error
        }
        return .none
      case let .searchFailed(generation, error):
        guard generation == state.searchGeneration, state.isDocumentCurrent else { return .none }
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
      case let .sidebarViewportChanged(items, files):
        state.itemsHeight = max(1, items)
        state.filesHeight = max(1, files)
        return .none
      case .review(.delegate(.submitted)):
        if let id = state.review?.item.id {
          state.drafts[id] = nil
          state.detailCache[id] = nil
          state.detailAccess[id] = nil
        }
        state.review = nil
        state.reviewLocation = nil
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
        state.reviewLocation = nil
        return state.tab == .diff && !review.comments.isEmpty ? loadContent(&state) : .none
      case .markReviewedPressed:
        guard state.pane != .files || state.fileCursor?.isDirectory != true else { return .none }
        let currentPath = state.pane == .content ? state.document.location(at: state.diffCursor, side: state.diffSide)?.path : nil
        guard let path = currentPath ?? state.selectedFilePath, let key = state.reviewKey(for: path) else { return .none }
        if !state.reviewedFiles.insert(key).inserted {
          state.reviewedFiles.remove(key)
        }
        return .none
      }
    }
    .ifLet(\.review, action: \.review) { ReviewFeature() }
    .ifLet(\.filterEditor, action: \.filterEditor) { FilterFeature() }
  }

  private func retainDetail(_ detail: ItemDetail, in state: inout State) {
    let id = detail.item.id
    state.detailCache[id] = nil
    state.detailAccess[id] = nil
    let limit = 64 * 1024 * 1024
    guard detail.estimatedByteCount <= limit else { return }
    var bytes = state.detailCache.values.reduce(0) { $0 + $1.estimatedByteCount }
    while state.detailCache.count >= 16 || bytes + detail.estimatedByteCount > limit {
      guard let oldest = state.detailCache.keys.min(by: {
        (state.detailAccess[$0] ?? 0) < (state.detailAccess[$1] ?? 0)
      }), let removed = state.detailCache.removeValue(forKey: oldest) else { break }
      bytes -= removed.estimatedByteCount
      state.detailAccess[oldest] = nil
    }
    state.cacheAccess += 1
    state.detailAccess[id] = state.cacheAccess
    state.detailCache[id] = detail
  }

  private func clearSearch(_ state: inout State, _ scope: SearchScope) -> Effect<Action> {
    state.searches[scope] = .init()
    state.pendingPrefix = nil
    if scope == .help {
      state.helpScroll = 0
    }
    if scope == .items {
      guard !state.activeFilter.isEmpty else { return .none }
      state.activeFilter = ""
      return loadList(&state)
    }
    if scope == .files {
      state.fileSearchGeneration += 1
      state.fileMatches = nil
      state.isSearchingFiles = false
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
    return scope == .files ? .cancel(id: CancelID.filesSearch) : .none
  }

  private func searchColumn(_ state: State) -> Int {
    guard let search = state.searches[.content], search.result.lines.indices.contains(search.selection),
          search.result.lines[search.selection] == state.diffCursor,
          search.result.sides.indices.contains(search.selection), search.result.sides[search.selection] == state.diffSide,
          search.result.sourceRanges.indices.contains(search.selection) else { return 0 }
    return search.result.sourceRanges[search.selection]?.lowerBound ?? 0
  }

  /// Ordered source positions make repeated searches logarithmic in the match count.
  private func matchIndex(_ matches: SearchMatches, row: Int, side: InlineComment.Side, column: Int, direction: Int) -> Int {
    func comparison(_ index: Int) -> Int {
      if matches.lines[index] != row {
        return matches.lines[index] < row ? -1 : 1
      }
      let candidateSide = matches.sides.indices.contains(index) ? matches.sides[index] : nil
      let rank = candidateSide == nil ? -1 : candidateSide == .left ? 0 : 1
      let targetRank = side == .left ? 0 : 1
      if rank != targetRank {
        return rank < targetRank ? -1 : 1
      }
      let offset = matches.sourceRanges.indices.contains(index) ? matches.sourceRanges[index]?.lowerBound ?? 0 : 0
      return offset == column ? 0 : offset < column ? -1 : 1
    }
    var lower = 0, upper = matches.lines.count
    while lower < upper {
      let middle = lower + (upper - lower) / 2
      let order = comparison(middle)
      if order < 0 || direction > 0 && order == 0 {
        lower = middle + 1
      } else {
        upper = middle
      }
    }
    if direction > 0 {
      return lower < matches.lines.count ? lower : 0
    }
    return lower > 0 ? lower - 1 : max(0, matches.lines.count - 1)
  }

  private func findWord(_ state: inout State, _ command: KeyCommand) -> Effect<Action> {
    guard state.pane == .content, state.tab == .diff, state.isDocumentCurrent,
          let diff = state.document.diff, diff.rows.indices.contains(state.diffCursor),
          let line = diff.rows[state.diffCursor].line(on: state.diffSide) else { return .none }
    state.visualStart = nil
    state.searchGeneration += 1
    state.isFinding = true
    state.error = nil
    let generation = state.searchGeneration, row = state.diffCursor, side = state.diffSide, column = searchColumn(state)
    let direction = command == .searchWordBackward || command == .searchPartialWordBackward ? -1 : 1
    let whole = command == .searchWordForward || command == .searchWordBackward
    return replacing(.search, with: .run(priority: .utility) { send in
      do {
        let word = try await SearchPattern.word(in: line.spans, column: column, whole: whole)
        try Task.checkCancellation()
        await send(.wordSearchResponse(generation: generation, row: row, side: side, column: column, direction: direction, word))
      } catch is CancellationError {} catch {
        if !Task.isCancelled {
          await send(.searchFailed(generation: generation, .wrapping(error)))
        }
      }
    })
  }

  private func focusMatch(_ state: inout State, index: Int) {
    guard let result = state.searches[.content]?.result, result.lines.indices.contains(index) else { return }
    let row = result.lines[index]
    guard state.document.diff?.rows.indices.contains(row) == true else { return }
    state.diffCursor = row
    if result.sides.indices.contains(index), let side = result.sides[index] {
      state.diffSide = side
    }
  }

  private func revealMatch(_ state: inout State) -> Effect<Action> {
    guard let search = state.searches[.content], search.result.ranges.indices.contains(search.selection),
          search.result.ranges[search.selection] == nil, search.result.sourceRanges.indices.contains(search.selection),
          search.result.sourceRanges[search.selection] != nil else { return .none }
    state.searchGeneration += 1
    state.isFinding = true
    let generation = state.searchGeneration, document = state.document, width = state.contentWidth
    return replacing(.search, with: .run(priority: .utility) { [documents] send in
      do {
        let visible = try await documents.revealMatch(document, search.result, search.selection, width)
        let matches = try await documents.search(visible, search.query)
        try Task.checkCancellation()
        await send(.searchProjectionResponse(generation: generation, selection: search.selection, .success((visible, matches))))
      } catch is CancellationError {} catch {
        if !Task.isCancelled {
          await send(.searchProjectionResponse(
            generation: generation,
            selection: search.selection,
            .failure(.wrapping(error)),
          ))
        }
      }
    })
  }

  private func findFiles(_ state: inout State) -> Effect<Action> {
    let query = state.searches[.files]?.query ?? ""
    guard !query.isEmpty else { return clearSearch(&state, .files) }
    guard let detail = state.detail, let revision = detail.revision else { return .none }
    state.fileSearchGeneration += 1
    let generation = state.fileSearchGeneration
    state.isSearchingFiles = true
    state.fileMatches = [:]
    state.error = nil
    return replacing(.filesSearch, with: .run(priority: .utility) { [forge] send in
      do {
        let result = try await Self.searchFiles(detail, revision: revision, query: query, forge: forge)
        try Task.checkCancellation()
        await send(.fileSearchResponse(generation: generation, .success(result)))
      } catch is CancellationError {} catch {
        if !Task.isCancelled {
          await send(.fileSearchResponse(generation: generation, .failure(.wrapping(error))))
        }
      }
    })
  }

  @concurrent
  private static func searchFiles(
    _ detail: ItemDetail,
    revision: PullRequestRevision,
    query: String,
    forge: ForgeClient,
  ) async throws -> [String: [Int]] {
    let pattern = try SearchPattern(query)
    return try await withThrowingTaskGroup(of: (String, [Int]).self) { group in
      var files = detail.files.makeIterator(), result: [String: [Int]] = [:]
      func enqueue(_ file: ChangedFile) {
        group.addTask {
          try Task.checkCancellation()
          let deleted = file.status == "removed"
          let data = try await forge.content(detail.item.id.repository, deleted ? revision.mergeBase : revision.head, file.path)
          guard data.count <= 32 * 1024 * 1024 else { throw TataraError(
            .invalidResponse,
            detail: "File exceeds the 32 MiB search limit: \(file.path)",
          ) }
          // Binary files have no text lines to match.
          guard !data.contains(0), let source = String(data: data, encoding: .utf8) else { return (file.path, []) }
          var lines: [Int] = []
          for (index, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            try Task.checkCancellation()
            if try pattern.contains(in: String(line)) {
              lines.append(index + 1)
            }
          }
          return (file.path, lines)
        }
      }
      for _ in 0 ..< 4 {
        if let file = files.next() {
          enqueue(file)
        }
      }
      while let (path, lines) = try await group.next() {
        if !lines.isEmpty {
          result[path] = lines
        }
        if let file = files.next() {
          enqueue(file)
        }
      }
      return result
    }
  }

  private func findMatches(_ state: inout State) -> Effect<Action> {
    state.searchGeneration += 1
    clearContentMatches(&state)
    let query = state.searches[.content]?.query ?? ""
    state.isFinding = !query.isEmpty && state.isDocumentCurrent
    guard state.isFinding else { return .cancel(id: CancelID.search) }
    state.error = nil
    let generation = state.searchGeneration
    let document = state.document
    return replacing(.search, with: .run(priority: .utility) { [documents] send in
      do {
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
      state.detailAccess = [:]
      state.cacheAccess = 0
      state.isLoadingDetail = false
      state.isLoadingDiff = false
      state.isPreparingDocument = false
      state.isFinding = false
      state.selectedDirectoryPath = nil
      state.selectedFilePath = nil
      state.fileSearchGeneration += 1
      state.fileMatches = nil
      state.isSearchingFiles = false
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
      .merge(
        .cancel(id: CancelID.detail),
        .cancel(id: CancelID.content),
        .cancel(id: CancelID.search),
        .cancel(id: CancelID.filesSearch),
      ),
      replacement,
    )
  }

  private func loadContent(_ state: inout State, resetScroll: Bool = false) -> Effect<Action> {
    if resetScroll {
      state.pendingCursorLocation = nil
      state.pendingViewportLocation = nil
      state.pendingViewportOffset = 0
    } else if state.isDocumentCurrent {
      state.pendingCursorLocation = state.document.location(at: state.diffCursor, side: state.diffSide)
      if let row = state.document.diffRow(at: state.scroll, side: state.diffSide) {
        state.pendingViewportLocation = state.document.location(at: row, side: state.diffSide)
        state.pendingViewportOffset = state.scroll - row
      }
    }
    state.contentGeneration += 1
    state.searchGeneration += 1
    state.resetsScrollOnResponse = state.resetsScrollOnResponse || resetScroll
    state.visualStart = nil
    state.isPreparingDocument = true
    state.isFinding = false
    clearContentMatches(&state)
    let generation = state.contentGeneration
    let width = state.contentWidth
    let side = state.diffSide
    let draft = state.selectedItemID.flatMap { state.drafts[$0] }
    let currentDraft = draft?.expectedHead == state.detail?.revision?.head && draft?.expectedMergeBase == state.detail?.revision?
      .mergeBase
    let source = ContentSource(
      detail: state.detail,
      tab: state.tab,
      strings: state.strings,
      drafts: currentDraft ? draft?.comments ?? [] : [],
      detailLevel: state.preferences.detailLevel,
    )
    let filePath = state.selectedFilePath, directory = state.selectedDirectoryPath, theme = state.preferences.theme
    state.isLoadingDiff = state.tab == .diff && state.detail?.revision != nil && (filePath != nil || directory != nil)
    return .concatenate(
      .cancel(id: CancelID.search),
      replacing(.content, with: .run(priority: .utility) { [documents, difftastic] send in
        do {
          let document: ReviewDocument = if let diff = try await source.diffDocument(
            filePath: filePath,
            directory: directory,
            width: width,
            side: side,
            theme: theme,
            documents: documents,
            difftastic: difftastic,
          ) {
            diff
          } else {
            try await source.document(width: width, documents: documents)
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

  private func clearContentMatches(_ state: inout State) {
    // A dictionary mutation notifies search readers even when its nested value stays empty.
    guard state.searches[.content]?.matches.isEmpty == false else { return }
    state.searches[.content]?.matches = []
  }

  /// Cancel synchronously when subscribing, before scheduling the replacement.
  /// A late-starting older run must never cancel a newer generation's task.
  private func replacing(_ id: CancelID, with effect: Effect<Action>) -> Effect<Action> {
    .concatenate(.cancel(id: id), effect.cancellable(id: id))
  }

  private func move(_ state: inout State, _ command: KeyCommand) -> Effect<Action> {
    if state.pane == .content, state.tab == .diff, let diff = state.document.diff,
       state.isDocumentCurrent, command != .nextMatch, command != .previousMatch
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
      if let row = state.document.diffRow(at: start, side: state.diffSide, direction: down ? 1 : -1) {
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
      let direction = command == .nextMatch ? search.direction : -search.direction
      let index = state.tab == .diff && state.document.diff != nil
        ? matchIndex(
          search.result,
          row: state.diffCursor,
          side: state.diffSide,
          column: searchColumn(state),
          direction: direction,
        )
        : (search.selection + direction + search.matches.count) % search.matches.count
      state.searches[.content]?.selection = index
      state.scroll = min(state.maxScroll, search.matches[index])
      focusMatch(&state, index: index)
      return revealMatch(&state)
    }
    let step = switch command {
    case .up, .previousMatch: -1
    case .halfPageUp: -max(
        1,
        (state.pane == .items ? state.itemsPage : state.pane == .files ? state.filesHeight : state.contentHeight) / 2,
      )
    case .halfPageDown: max(
        1,
        (state.pane == .items ? state.itemsPage : state.pane == .files ? state.filesHeight : state.contentHeight) / 2,
      )
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
      let next = index(state.selectedItemIndex ?? 0, items.count)
      if items[next].id != state.selectedItemID {
        return .send(.itemSelected(items[next].id))
      }
      state.itemsScroll = ScrollMetrics.selectionOffset(
        selected: next,
        total: items.count,
        page: state.itemsPage,
        previous: state.itemsScroll,
      )
    case .files:
      let files = state.visibleFileRows
      guard !files.isEmpty else { return .none }
      let next = index(state.fileCursorIndex ?? 0, files.count)
      if files[next].id != state.fileCursorKey {
        return .send(.fileRowSelected(files[next].id))
      }
      state.filesScroll = ScrollMetrics.selectionOffset(
        selected: next,
        total: files.count,
        page: state.filesHeight,
        previous: state.filesScroll,
      )
    case .content: state.scroll = index(state.scroll, state.maxScroll + 1)
    }
    return .none
  }

  private func nearestDiffRow(_ state: State, to row: Int, side: InlineComment.Side) -> Int? {
    state.document.diffRow(at: row, side: side)
  }

  private func alignCursorToViewport(_ state: inout State) {
    guard state.isDocumentCurrent, state.pane == .content, let rows = state.document.diff?.rows, !rows.isEmpty else { return }
    let visible = state.scroll ..< min(rows.count, state.scroll + state.contentHeight)
    guard !visible.contains(state.diffCursor) else { return }
    if let row = visible.first(where: { rows[$0].line(on: state.diffSide) != nil }) {
      state.diffCursor = row
    }
  }

  private func revealReview(_ state: inout State) {
    guard let row = state.reviewRow else { return }
    let contextRows = max(1, state.contentHeight - state.reviewPanelHeight)
    if row < state.scroll {
      state.scroll = row
    }
    if row >= state.scroll + contextRows {
      state.scroll = max(0, row - contextRows + 1)
    }
  }

  private func reviewAtCursor(_ state: inout State) -> Effect<Action> {
    guard state.isDocumentCurrent, !state.isLoadingDetail, let detail = state.detail,
          detail.item.state == .open, !detail.item.isDraft,
          let diff = state.document.diff, diff.revision == detail.revision,
          let rows = Optional(diff.rows),
          rows.indices.contains(state.diffCursor), rows.indices.contains(state.visualStart ?? state.diffCursor),
          let file = detail.file(at: rows[state.diffCursor].path ?? diff.path),
          let end = rows[state.diffCursor].line(on: state.diffSide)?.number,
          let start = rows[state.visualStart ?? state.diffCursor].line(on: state.diffSide)?.number else { return .none }
    guard (rows[state.visualStart ?? state.diffCursor].path ?? diff.path) == file.path else {
      state.error = .init(.invalidLine)
      return .none
    }
    let range = min(start, end) ... max(start, end)
    guard file.anchors.contains(range: range, side: state.diffSide) else {
      state.error = .init(.invalidLine)
      return .none
    }
    state.review = state.drafts[detail.item.id] ?? .init(
      item: detail.item,
      expectedHead: detail.revision?.head,
      expectedMergeBase: detail.revision?.mergeBase,
    )
    state.review?.isConfirming = false
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
    state.reviewLocation = state.document.location(
      at: max(state.diffCursor, state.visualStart ?? state.diffCursor),
      side: state.diffSide,
    )
    revealReview(&state)
    state.visualStart = nil
    return .none
  }
}
