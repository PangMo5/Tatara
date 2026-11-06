// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import Foundation
import TataraCore

extension WorkspaceFeature {

  // MARK: Internal

  func listCursorRow(_ state: State, _ scope: SearchScope) -> Int {
    if scope == .items {
      return state.selectedItemIndex ?? 0
    }
    guard let id = state.fileCursorKey else { return 0 }
    if state.preferences.filesView == .tree {
      return state.detail?.fileTree.index(for: id) ?? 0
    }
    return state.fileCursorIndex ?? 0
  }

  func beginListSearch(_ state: inout State, _ scope: SearchScope) -> Effect<Action> {
    let origin = listCursorRow(state, scope)
    state.listSearchSession = .init(
      scope: scope,
      previous: state.searches[scope] ?? .init(),
      results: state.listSearchResults[scope],
      collapsed: state.collapsedDirectories,
      itemsScroll: state.itemsScroll,
      filesScroll: state.filesScroll,
    )
    var search = PaneSearch()
    search.isEditing = true
    search.origin = origin
    state.searches[scope] = search
    state.listSearchResults[scope] = nil
    state.listSearchPending = nil
    state.listSearchErrors[scope] = nil
    state.listSearchGeneration += 1
    return .cancel(id: CancelID.listSearch)
  }

  func cancelListSearch(_ state: inout State) -> Effect<Action> {
    guard let session = state.listSearchSession else { return .none }
    state.searches[session.scope] = session.previous
    state.listSearchResults[session.scope] = session.results
    state.collapsedDirectories = session.collapsed
    state.itemsScroll = session.itemsScroll
    state.filesScroll = session.filesScroll
    state.listSearchSession = nil
    state.listSearchGeneration += 1
    state.listSearchPending = nil
    state.listSearchErrors[session.scope] = nil
    return .cancel(id: CancelID.listSearch)
  }

  func findListMatches(_ state: inout State, _ scope: SearchScope, accept: Bool = false) -> Effect<Action> {
    state.listSearchGeneration += 1
    let generation = state.listSearchGeneration
    let query = state.searches[scope]?.query ?? ""
    state.listSearchErrors[scope] = nil
    state.listSearchResults[scope] = nil
    state.searches[scope]?.matches = []
    if let session = state.listSearchSession, scope == .files {
      state.collapsedDirectories = session.collapsed
    }
    state.listSearchPending = query.isEmpty ? nil : scope
    state.listSearchSession?.acceptWhenReady = accept
    guard !query.isEmpty else { return .cancel(id: CancelID.listSearch) }
    let items = state.visibleItems
    let detail = state.detail
    let view = state.preferences.filesView
    return .run(priority: .utility) { send in
      do {
        let result = try await Self.searchList(scope, items: items, detail: detail, view: view, query: query)
        try Task.checkCancellation()
        await send(.listSearchResponse(scope: scope, generation: generation, .success(result)))
      } catch is CancellationError {} catch {
        if !Task.isCancelled {
          await send(.listSearchResponse(scope: scope, generation: generation, .failure(.wrapping(error))))
        }
      }
    }.cancellable(id: CancelID.listSearch, cancelInFlight: true)
  }

  func finishListSearch(_ state: inout State, _ scope: SearchScope) -> Effect<Action> {
    if let session = state.listSearchSession {
      state.collapsedDirectories = session.collapsed
    }
    state.listSearchSession = nil
    state.searches[scope]?.isEditing = false
    guard
      let results = state.listSearchResults[scope],
      let selection = state.searches[scope]?.selection,
      results.ids.indices.contains(selection)
    else { return .none }
    return selectListMatch(&state, scope, results: results, index: selection)
  }

  func selectListMatch(_ state: inout State, _ scope: SearchScope, results: ListSearchResults, index: Int) -> Effect<Action> {
    if scope == .items {
      guard state.visibleItems.indices.contains(results.rows[index]) else { return .none }
      return .send(.itemSelected(state.visibleItems[results.rows[index]].id))
    }
    let id = results.ids[index]
    revealFileRow(&state, id)
    return .send(.fileRowSelected(id))
  }

  func revealFileRow(_ state: inout State, _ id: String) {
    guard state.preferences.filesView == .tree else { return }
    let path = String(id.dropFirst(id.hasPrefix("directory:") ? 10 : 5))
    var collapsed = state.collapsedDirectories
    collapsed.remove(FileTree.rootPath)
    var parent = (path as NSString).deletingLastPathComponent
    while !parent.isEmpty, parent != "." {
      collapsed.remove(parent)
      parent = (parent as NSString).deletingLastPathComponent
    }
    state.collapsedDirectories = collapsed
  }

  // MARK: Private

  @concurrent
  private static func searchList(
    _ scope: SearchScope,
    items: [ForgeItem],
    detail: ItemDetail?,
    view: FilesView,
    query: String,
  ) async throws -> ListSearchResults {
    let entries: [(id: String, fields: [String])] =
      if scope == .items {
        items.map { item in
          let info = [item.github?.headBranch, item.github?.baseBranch].compactMap { $0 }.joined(separator: " → ")
          return ("item:\(item.id.number)", ["#\(item.id.number) \(item.title)", "@\(item.author)", info])
        }
      } else if view == .list {
        (detail?.files ?? []).map { ("file:" + $0.path, [$0.path]) }
      } else {
        (detail?.fileTree.rows ?? []).map { ($0.id, [$0.name, $0.path]) }
      }
    return try await ListSearchResults.find(entries, query: query)
  }

}
