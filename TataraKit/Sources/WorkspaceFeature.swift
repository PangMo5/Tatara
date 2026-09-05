// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import TataraCore

@Reducer
public struct WorkspaceFeature {
  public enum Pane: Int, CaseIterable, Sendable { case items, files, content }
  public enum ContentTab: Int, CaseIterable, Sendable { case overview, diff, discussion, checks }

  @ObservableState
  public struct State: Equatable {
    public var repository: RepositoryID
    public var preferences: Preferences
    public var kind = ItemKind.pullRequest
    public var items: [ForgeItem] = []
    public var selectedItemID: ItemID?
    public var selectedFilePath: String?
    public var detail: ItemDetail?
    public var diff = ""
    public var diffLines: [[DiffSpan]] = []
    public var pane = Pane.items
    public var tab = ContentTab.overview
    public var scroll = 0
    public var contentWidth = 100
    public var contentHeight = 24
    public var contentLineCount = 0
    public var isLoading = false
    public var isLoadingDetail = false
    public var isLoadingDiff = false
    public var nextPage: Int?
    public var error: TataraError?
    public var search = ""
    public var isSearching = false
    public var showsHelp = false
    public var pendingG = false
    public var review: ReviewFeature.State?
    public var reviewedFiles = Set<String>()
    public var drafts: [ItemID: ReviewFeature.State] = [:]
    public var listGeneration = 0
    public var detailGeneration = 0
    public var diffGeneration = 0
    public init(repository: RepositoryID, preferences: Preferences = .init()) {
      self.repository = repository
      self.preferences = preferences
    }

    public var selectedItem: ForgeItem? {
      items.first { $0.id == selectedItemID }
    }

    public var selectedFile: ChangedFile? {
      detail?.files.first { $0.path == selectedFilePath }
    }

    public func reviewKey(for path: String) -> String? {
      guard let detail, let revision = detail.revision else { return nil }
      return "\(detail.item.id.repository)#\(detail.item.id.number)|\(revision.mergeBase)|\(revision.head)|\(path)"
    }

    public var visibleItems: [ForgeItem] {
      guard !search.isEmpty else { return items }
      return items.filter { "#\($0.id.number) \($0.title) \($0.author)".localizedCaseInsensitiveContains(search) }
    }
  }

  public enum Action {
    case appeared
    case keyPressed(String)
    case commandPressed(KeyCommand)
    case tabSelected(ContentTab)
    case viewportChanged(width: Int, height: Int)
    case contentLineCountChanged(Int)
    case scrollPositionChanged(Int)
    case itemSelected(ItemID)
    case fileSelected(String)
    case listResponse(generation: Int, append: Bool, Result<ItemPage, TataraError>)
    case detailResponse(generation: Int, Result<ItemDetail, TataraError>)
    case diffResponse(generation: Int, Result<String, TataraError>)
    case review(ReviewFeature.Action)
    case reviewDismissed
    case markReviewedPressed
  }

  enum CancelID { case list, detail, diff }
  @Dependency(ForgeClient.self) var forge
  @Dependency(DiffClient.self) var difftastic
  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .appeared:
        return loadList(&state)
      case let .keyPressed(key):
        if state.review != nil {
          return key == "esc" ? .send(.reviewDismissed) : .none
        }
        if state.isSearching {
          switch key {
          case "esc": state.isSearching = false
            state.search = ""
          case "enter":
            state.isSearching = false
            if let first = state.visibleItems.first {
              return .send(.itemSelected(first.id))
            }
          case "backspace": if !state.search.isEmpty {
              state.search.removeLast()
            }
          case "space": state.search += " "
          default: if key.count == 1 {
              state.search += key
            }
          }
          return .none
        }
        if key == "g" && !state.pendingG {
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
        if state.showsHelp {
          let maximum = max(0, KeyCommand.allCases.count + 7 - state.contentHeight)
          switch command {
          case .help, .back: state.showsHelp = false
            state.scroll = 0
          case .down: state.scroll = min(maximum, state.scroll + 1)
          case .up: state.scroll = max(0, state.scroll - 1)
          case .halfPageDown: state.scroll = min(maximum, state.scroll + max(1, state.contentHeight / 2))
          case .halfPageUp: state.scroll = max(0, state.scroll - max(1, state.contentHeight / 2))
          case .first: state.scroll = 0
          case .last: state.scroll = maximum
          default: break
          }
          return .none
        }
        switch command {
        case .previousTab, .nextTab:
          let index = (state.tab.rawValue + (command == .nextTab ? 1 : 3)) % 4
          return .send(.tabSelected(ContentTab(rawValue: index) ?? .overview))
        case .itemsPane: state.pane = .items
        case .filesPane: state.pane = .files
        case .contentPane: state.pane = .content
        case .markReviewed: return .send(.markReviewedPressed)
        case .openBrowser: break
        case .help: state.showsHelp = true
          state.scroll = 0
        case .search: state.isSearching = true
          state.pane = .items
        case .refresh: return loadList(&state)
        case .loadMore: if let page = state.nextPage, !state.isLoading {
            return loadList(&state, page: page)
          }
        case .toggleKind:
          state.kind = state.kind == .pullRequest ? .issue : .pullRequest
          state.search = ""
          state.selectedItemID = nil
          state.items = []
          return loadList(&state)
        case .left, .previousPane:
          state.pane = Pane(rawValue: (state.pane.rawValue + 2) % 3) ?? .items
        case .right, .nextPane:
          state.pane = Pane(rawValue: (state.pane.rawValue + 1) % 3) ?? .items
        case .open:
          if state.pane == .items {
            state.pane = state.kind == .pullRequest ? .files : .content
          } else if state.pane == .files {
            state.pane = .content
            return .send(.tabSelected(.diff))
          }
        case .back:
          if state.showsHelp {
            state.showsHelp = false
          } else {
            state.pane = .items
            state.tab = .overview
            state.scroll = 0
            state.error = nil
          }
        case .theme:
          state.preferences.theme = state.preferences.theme.next
          return loadDiff(&state)
        case .review, .comment:
          guard let detail = state.detail, detail.item.state == .open, !detail.item.isDraft else { return .none }
          if let draft = state.drafts[detail.item.id] {
            state.review = draft
          } else {
            state.review = .init(item: detail.item, expectedHead: detail.revision?.head)
          }
          let selectedFile = state.selectedFile
          state.review?.selectedFile = selectedFile
          state.review?.latestHead = detail.revision?.head
          let stale = state.review?.expectedHead != detail.revision?.head
          if stale {
            state.review?.error = .init(.revisionChanged)
          }
          state.review?.isEditingInline = !stale && command == .comment && detail.item.kind == .pullRequest && selectedFile?
            .patch != nil
        case .down, .up, .first, .last, .halfPageDown, .halfPageUp, .nextMatch, .previousMatch:
          return move(&state, command)
        case .quit: break // The scene restores terminal state when an unhandled quit key reaches it.
        }
        return .none
      case let .itemSelected(id):
        guard let item = state.items.first(where: { $0.id == id }) else { return .none }
        state.selectedItemID = id
        state.detail = nil
        state.diff = ""
        state.selectedFilePath = nil
        state.scroll = 0
        state.error = nil
        state.isLoadingDetail = true
        state.isLoadingDiff = false
        state.detailGeneration += 1
        state.diffGeneration += 1
        let generation = state.detailGeneration
        return .merge(.cancel(id: CancelID.diff), .run { [forge] send in
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
        }.cancellable(id: CancelID.detail, cancelInFlight: true))
      case let .fileSelected(path):
        guard state.detail?.files.contains(where: { $0.path == path }) == true else { return .none }
        state.selectedFilePath = path
        state.tab = .diff
        state.scroll = 0
        return loadDiff(&state)
      case let .listResponse(generation, append, result):
        guard generation == state.listGeneration else { return .none }
        state.isLoading = false
        switch result {
        case let .failure(error): state.error = error
          return .none
        case let .success(page):
          let existing = Set(state.items.map(\.id))
          if append {
            state.items += page.items.filter { !existing.contains($0.id) }
          } else {
            state.items = page.items
          }
          state.nextPage = page.nextPage
          if append {
            return .none
          }
          if let previous = state.selectedItemID,
             state.items.contains(where: { $0.id == previous })
          {
            return .send(.itemSelected(previous))
          }
          if let first = state.visibleItems.first {
            return .send(.itemSelected(first.id))
          }
          state.selectedItemID = nil
          return .none
        }
      case let .detailResponse(generation, result):
        guard generation == state.detailGeneration else { return .none }
        state.isLoadingDetail = false
        switch result {
        case let .failure(error): state.error = error
          return .none
        case let .success(detail):
          state.detail = detail
          state.selectedFilePath = detail.files.first?.path
          return state.tab == .diff ? loadDiff(&state) : .none
        }
      case let .diffResponse(generation, result):
        guard generation == state.diffGeneration else { return .none }
        state.isLoadingDiff = false
        switch result {
        case let .success(diff): state.diff = diff
          state.diffLines = StyledDiff.lines(diff)
        case let .failure(error): state.error = error
        }
        return .none
      case let .tabSelected(tab):
        state.tab = tab
        state.scroll = 0
        return tab == .diff ? loadDiff(&state) : .none
      case let .viewportChanged(width, height):
        let width = max(20, width)
        let changed = width != state.contentWidth
        state.contentWidth = width
        state.contentHeight = max(1, height)
        return changed && state.tab == .diff ? loadDiff(&state) : .none
      case let .contentLineCountChanged(count):
        state.contentLineCount = count
        state.scroll = min(state.scroll, max(0, count - max(1, state.contentHeight - 2)))
        return .none
      case let .scrollPositionChanged(offset):
        state.scroll = max(0, offset)
        return .none
      case .review(.delegate(.submitted)):
        if let id = state.review?.item.id {
          state.drafts[id] = nil
        }
        state.review = nil
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
        guard let path = state.selectedFilePath, let key = state.reviewKey(for: path) else { return .none }
        if !state.reviewedFiles.insert(key).inserted {
          state.reviewedFiles.remove(key)
        }
        return .none
      }
    }
    .ifLet(\.review, action: \.review) { ReviewFeature() }
  }

  private func loadList(_ state: inout State, page: Int = 1) -> Effect<Action> {
    state.listGeneration += 1
    state.isLoading = true
    state.error = nil
    if page == 1 {
      state.detailGeneration += 1
      state.diffGeneration += 1
      state.detail = nil
      state.diff = ""
      state.isLoadingDetail = false
      state.isLoadingDiff = false
      state.selectedFilePath = nil
    }
    let generation = state.listGeneration
    let repository = state.repository
    let kind = state.kind
    let effect: Effect<Action> = .run { [forge] send in
      do {
        let pageResult = try await forge.list(repository, kind, page)
        try Task.checkCancellation()
        await send(.listResponse(generation: generation, append: page > 1, .success(pageResult)))
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
    }.cancellable(id: CancelID.list, cancelInFlight: true)
    return page == 1 ? .merge(.cancel(id: CancelID.detail), .cancel(id: CancelID.diff), effect) : effect
  }

  private func loadDiff(_ state: inout State) -> Effect<Action> {
    state.diffGeneration += 1
    state.diff = ""
    state.diffLines = []
    state.isLoadingDiff = false
    guard let revision = state.detail?.revision, let file = state.selectedFile else { return .cancel(id: CancelID.diff) }
    state.isLoadingDiff = true
    state.error = nil
    let generation = state.diffGeneration
    let request = DiffRequest(
      repository: state.repository,
      revision: revision,
      file: file,
      width: state.contentWidth,
      theme: state.preferences.theme,
    )
    return .run { [difftastic] send in
      do {
        let output = try await difftastic.render(request)
        try Task.checkCancellation()
        await send(.diffResponse(generation: generation, .success(output)))
      } catch is CancellationError {}
      catch {
        if !Task.isCancelled {
          await send(.diffResponse(generation: generation, .failure(.wrapping(error))))
        }
      }
    }.cancellable(id: CancelID.diff, cancelInFlight: true)
  }

  private func move(_ state: inout State, _ command: KeyCommand) -> Effect<Action> {
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
      guard let files = state.detail?.files, !files.isEmpty else { return .none }
      let next = index(files.firstIndex { $0.path == state.selectedFilePath } ?? 0, files.count)
      if files[next].path != state.selectedFilePath {
        return .send(.fileSelected(files[next].path))
      }
    case .content:
      let count = state.tab == .diff ? state.diffLines.count : state.contentLineCount
      state.scroll = index(state.scroll, max(1, count - max(1, state.contentHeight - 2) + 1))
    }
    return .none
  }
}
