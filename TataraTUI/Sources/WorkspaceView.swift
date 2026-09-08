// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import Foundation
import SwiftTUI
import TataraCore
import TataraKit

struct WorkspaceView: View {
  let store: StoreOf<WorkspaceFeature>
  let l10n: Localization
  let demo: Bool
  @SwiftTUI.Environment(\.requestTermination) private var quit
  @SwiftTUI.Environment(\.openLinkAction) private var openLink

  var body: some View {
    GeometryReader { geometry in
      WorkspaceLayout(store: store, l10n: l10n, demo: demo, size: geometry.size)
    }
    .focusable(store.review == nil && store.filterEditor == nil)
    .onAppear { store.send(.appeared) }
    .onKeyPress { press in
      let key = Self.keyName(press)
      if store.filterEditor != nil {
        if key == "esc" {
          store.send(.filterEditor(.close))
          return .handled
        }
        return .ignored
      }
      if store.review != nil {
        if key == "esc" {
          store.send(.reviewDismissed)
          return .handled
        }
        return .ignored
      }
      if !store.isSearching, !store.showsHelp, store.preferences.keymap.command(for: key) == .quit {
        quit()
        return .handled
      }
      if !store.isSearching, !store.showsHelp, store.preferences.keymap.command(for: key) == .openBrowser,
         let url = store.selectedItem?.url, url.scheme == "https", url.host == store.repository.host
      {
        openLink(LinkDestination(url.absoluteString))
        return .handled
      }
      let started = NavigationTrace.destination == nil ? nil : ProcessInfo.processInfo.systemUptime
      store.send(.keyPressed(key))
      if let started {
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        Task(priority: .utility) { @concurrent in await NavigationTrace.shared.record(start: started, elapsed: elapsed) }
      }
      return .handled
    }
  }

  static func keyName(_ press: KeyPress) -> String {
    switch press.key {
    case let .character(value):
      if press.modifiers.contains(.ctrl) {
        return "ctrl-\(String(value).lowercased())"
      }
      return press.modifiers.contains(.shift) && value.isLetter ? String(value).uppercased() : String(value)
    case .return: return "enter"
    case .escape: return "esc"
    case .tab: return press.modifiers.contains(.shift) ? "shift-tab" : "tab"
    case .arrowDown: return "down"
    case .arrowUp: return "up"
    case .arrowLeft: return "left"
    case .arrowRight: return "right"
    case .backspace: return "backspace"
    case .home: return "home"
    case .end: return "end"
    case .pageDown: return "page-down"
    case .pageUp: return "page-up"
    case .space: return "space"
    default: return ""
    }
  }
}

private struct WorkspaceLayout: View {
  let store: StoreOf<WorkspaceFeature>
  let l10n: Localization
  let demo: Bool
  let size: CellSize
  private var palette: Palette {
    Palette(store.preferences.theme)
  }

  var body: some View {
    let width = size.width
    let height = size.height
    let bodyHeight = max(1, height - 3)
    let sidebarWidth = min(44, width / 3)
    let mainWidth = width >= 100 ? width - sidebarWidth : width
    VStack(spacing: 0) {
      WorkspaceHeader(store: store, l10n: l10n, demo: demo).frame(width: width, height: 1).clipped()
      Group {
        if width < 60 || height < 16 {
          Text(l10n("Expand the terminal to at least 60 × 16."))
        } else if let review = store.scope(state: \.review, action: \.review) {
          ReviewView(store: review, l10n: l10n, palette: palette)
        } else {
          HStack(spacing: 0) {
            if width >= 100 {
              VStack(spacing: 0) {
                ItemsPane(store: store, l10n: l10n, width: sidebarWidth, height: bodyHeight / 2)
                FilesPane(store: store, l10n: l10n, width: sidebarWidth, height: bodyHeight - bodyHeight / 2)
              }.frame(width: sidebarWidth, height: bodyHeight)
              ContentPane(store: store, l10n: l10n, width: mainWidth, height: bodyHeight)
            } else {
              switch store.pane {
              case .items: ItemsPane(store: store, l10n: l10n, width: width, height: bodyHeight)
              case .files: FilesPane(store: store, l10n: l10n, width: width, height: bodyHeight)
              case .content: ContentPane(store: store, l10n: l10n, width: width, height: bodyHeight)
              }
            }
          }
        }
      }
      .frame(width: width, height: bodyHeight, alignment: .topLeading).clipped()
      .overlay {
        if let filter = store.scope(state: \.filterEditor, action: \.filterEditor) {
          FilterView(store: filter, l10n: l10n, palette: palette)
            .frame(width: min(96, max(40, width - 8)), height: min(30, bodyHeight - 2))
            .background(palette.mantle).border(palette.accent)
        } else if store.showsHelp {
          HelpPopup(
            store: store,
            l10n: l10n,
            palette: palette,
            width: max(20, min(96, width - 8)),
            height: max(8, min(26, bodyHeight - 4)),
          )
        }
      }
      WorkspaceFooter(store: store, l10n: l10n).frame(width: width, height: 2, alignment: .leading).clipped()
    }
    .frame(width: width, height: height, alignment: .topLeading).clipped()
    .foregroundStyle(palette.text).background(palette.base)
    .onChange(of: "\(mainWidth):\(bodyHeight)", initial: true) {
      store.send(.viewportChanged(width: max(1, mainWidth - 2), height: max(1, bodyHeight - 3)))
    }
  }
}

private struct WorkspaceHeader: View {
  let store: StoreOf<WorkspaceFeature>
  let l10n: Localization
  private var palette: Palette {
    Palette(store.preferences.theme)
  }

  let demo: Bool
  var body: some View {
    HStack {
      Text(" tatara ").bold().foregroundStyle(palette.base).background(palette.accent)
      Text(store.repository.description).lineLimit(1)
      Spacer(minLength: 0)
      if demo {
        Text(l10n("DEMO · synthetic data")).foregroundStyle(palette.yellow)
      }
      Text("\(store.preferences.theme.rawValue) ").foregroundStyle(palette.muted)
    }.background(palette.mantle)
  }
}

private struct ItemsPane: View {
  let store: StoreOf<WorkspaceFeature>
  let l10n: Localization
  private var palette: Palette {
    Palette(store.preferences.theme)
  }

  let width: Int
  let height: Int
  var body: some View {
    let visible = store.visibleItems
    let selected = visible.firstIndex { $0.id == store.selectedItemID } ?? 0
    let rows = max(1, height - 3)
    let start = max(0, selected - rows + 1)
    let visibleCount = visible.count
    let displayRows = visible.dropFirst(start).prefix(rows).map { item in
      SidebarRow(
        id: String(item.id.number),
        text: "#\(item.id.number) \(TerminalText.sanitize(item.title))",
        selected: item.id == store.selectedItemID,
        muted: item.isDraft,
        reviewed: false,
      )
    }
    return VStack(alignment: .leading, spacing: 0) {
      Text("1 · \(l10n(store.kind == .pullRequest ? "Pull requests" : "Issues")) · \(visibleCount)/\(store.items.count)")
        .bold().foregroundStyle(store.pane == .items ? palette.accent : palette.muted).lineLimit(1).frame(height: 1)
        .background(store.pane == .items ? palette.surface : palette.mantle)
      if visibleCount == 0 {
        Text(l10n(store
            .isLoading ? "Loading…" : (store.searches[.items]?.query.isEmpty == false ? "No matches." : "No open items.")))
          .foregroundStyle(palette.muted).lineLimit(1).frame(height: 1)
      }
      ForEach(displayRows) { row in
        Text("\(row.selected ? "▸" : " ") \(row.text)")
          .lineLimit(1).frame(width: max(1, width - 2), height: 1, alignment: .leading)
          .foregroundStyle(row.muted ? palette.muted : palette.text)
          .background(row.selected ? palette.surface : palette.mantle)
      }
      Spacer(minLength: 0)
    }.frame(width: max(1, width - 2), height: max(1, height - 2), alignment: .topLeading)
      .padding(1).frame(width: width, height: height).clipped()
      .background(palette.mantle).border(store.pane == .items ? palette.accent : palette.surface)
      .overlay(alignment: .trailing) {
        ScrollIndicator(
          metrics: .init(total: visibleCount, page: rows, offset: start, track: max(1, height - 2)),
          palette: palette,
        ) {
          store.send(.scrollbarMoved(.items, offset: $0, pageSize: rows))
        }
      }
      .onScrollWheel { event in
        store.send(.wheelScrolled(.items, delta: event.deltaY))
        return .handled
      }
  }
}

private struct FilesPane: View {
  let store: StoreOf<WorkspaceFeature>
  let l10n: Localization
  private var palette: Palette {
    Palette(store.preferences.theme)
  }

  let width: Int
  let height: Int
  var body: some View {
    let visible = store.visibleFileRows
    let selected = visible.firstIndex { $0.id == store.fileCursorKey } ?? 0
    let rows = max(1, height - 3)
    let start = max(0, selected - rows + 1)
    let reviewPrefix = store.detail.flatMap { detail in detail.revision.map {
      "\(detail.item.id.repository)#\(detail.item.id.number)|\($0.mergeBase)|\($0.head)|"
    }}
    let visibleCount = visible.count
    let displayRows = visible.dropFirst(start).prefix(rows).map { file in
      SidebarRow(
        id: file.id,
        text: String(repeating: "  ", count: file.depth) +
          (file
            .isDirectory ?
            (store.searches[.files]?.query.isEmpty != false && store.collapsedDirectories.contains(file.path) ? "▸ " : "▾ ") :
            "  ") + TerminalText
          .sanitize(file.name),
        selected: file.id == store.fileCursorKey,
        muted: file.isDirectory,
        reviewed: !file.isDirectory && (reviewPrefix.map { store.reviewedFiles.contains($0 + file.path) } ?? false),
      )
    }
    return VStack(alignment: .leading, spacing: 0) {
      Text("2 · \(l10n("Files")) · \(store.visibleFiles.count)/\(store.detail?.files.count ?? 0)")
        .bold().foregroundStyle(store.pane == .files ? palette.accent : palette.muted).lineLimit(1).frame(height: 1)
        .background(store.pane == .files ? palette.surface : palette.mantle)
      if visibleCount == 0 {
        Text(l10n(store
            .isLoadingDetail ? "Loading…" :
            (store.searches[.files]?.query.isEmpty == false ? "No matches." : "No changed files.")))
          .foregroundStyle(palette.muted).lineLimit(1).frame(height: 1)
      }
      ForEach(displayRows) { row in
        Text("\(row.reviewed ? "✓" : " ") \(row.text)")
          .lineLimit(1).frame(width: max(1, width - 2), height: 1, alignment: .leading)
          .foregroundStyle(row.muted ? palette.blue : row.reviewed ? palette.green : palette.text)
          .background(row.selected ? palette.surface : palette.mantle)
          .onTapGesture { store.send(.fileRowActivated(row.id)) }
      }
      Spacer(minLength: 0)
    }.frame(width: max(1, width - 2), height: max(1, height - 2), alignment: .topLeading)
      .padding(1).frame(width: width, height: height).clipped()
      .background(palette.mantle).border(store.pane == .files ? palette.accent : palette.surface)
      .overlay(alignment: .trailing) {
        ScrollIndicator(
          metrics: .init(total: visibleCount, page: rows, offset: start, track: max(1, height - 2)),
          palette: palette,
        ) {
          store.send(.scrollbarMoved(.files, offset: $0, pageSize: rows))
        }
      }
      .onScrollWheel { event in
        store.send(.wheelScrolled(.files, delta: event.deltaY))
        return .handled
      }
  }
}

private struct ContentPane: View {
  let store: StoreOf<WorkspaceFeature>
  let l10n: Localization
  private var palette: Palette {
    Palette(store.preferences.theme)
  }

  let width: Int
  let height: Int
  var body: some View {
    let count = max(1, height - 3)
    let offset = min(store.scroll, max(0, store.document.lines.count - count))
    let matches = store.searches[.content]?.matchingLines ?? []
    return VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 2) {
        Text("3 ·").bold().foregroundStyle(store.pane == .content ? palette.accent : palette.muted)
        ForEach(WorkspaceFeature.ContentTab.allCases, id: \.rawValue) { tab in
          Text(l10n(Self.tabTitle(tab))).bold(tab == store.tab).foregroundStyle(tab == store.tab ? palette.accent : palette.muted)
        }
        if store.tab == .diff, let diff = store.document.diff {
          Text(TerminalText.sanitize((diff.previousPath.map { $0 + " → " } ?? "") + diff.path))
            .foregroundStyle(palette.muted).lineLimit(1)
        }
        Spacer(minLength: 0)
        Text("\(key(.previousTab)) \(key(.nextTab))").foregroundStyle(palette.muted)
      }.lineLimit(1).frame(height: 1)
        .background(store.pane == .content ? palette.surface : palette.base)
      if let error = store.error, store.document.lines.isEmpty {
        Text(l10n.error(error)).foregroundStyle(palette.red).lineLimit(3).frame(height: 3)
      } else if store.document.lines.isEmpty, store.isLoadingDiff || store.isPreparingDocument {
        Text(l10n(store.isLoadingDiff ? "Loading diff…" : "Preparing text…")).foregroundStyle(palette.yellow).lineLimit(1)
          .frame(height: 1)
      } else {
        DocumentViewport(
          lines: Array(store.document.displayLines.dropFirst(offset).prefix(count)),
          matches: Set((0 ..< min(count, store.document.lines.count - offset)).filter { matches.contains(offset + $0) }),
          theme: store.preferences.theme,
          width: max(1, width - 2),
          height: count,
          selectedRows: Set((offset ..< min(store.document.lines.count, offset + count)).filter {
            guard let start = store.visualStart else { return false }
            return (min(start, store.diffCursor) ... max(start, store.diffCursor)).contains($0)
          }.map { $0 - offset }),
          selectedSide: store.diffSide,
        )
        .overlay(alignment: .topLeading) {
          if store.isPreparingDocument || store.isLoading || store.error != nil {
            Text(
              "\(store.error.map(l10n.error) ?? l10n(store.isLoading ? "Loading…" : store.isLoadingDiff ? "Loading diff…" : "Preparing text…")) · \(l10n("Preview")) · \(TerminalText.sanitize(store.documentTitle))",
            )
            .foregroundStyle(store.error == nil ? palette.yellow : palette.red)
            .lineLimit(store.error == nil ? 1 : 3).frame(
              width: max(1, width - 2),
              height: store.error == nil ? 1 : 3,
              alignment: .leading,
            )
            .background(palette.base).clipped()
          }
        }
        .overlay(alignment: .topLeading) {
          if store.pane == .content, store.tab == .diff, !store.isPreparingDocument,
             let diff = store.document.diff, diff.rows.indices.contains(store.diffCursor),
             diff.rows[store.diffCursor].line(on: store.diffSide) != nil,
             store.diffCursor >= offset, store.diffCursor < offset + count
          {
            Text("▸").foregroundStyle(palette.base).background(palette.accent)
              .frame(width: 1, height: 1)
              .offset(
                x: width - 2 >= 100 && store.diffSide == .right ? store.document.diffSideWidth + 3 : 0,
                y: store.diffCursor - offset,
              )
          }
        }
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
          guard store.document.diff != nil else { return }
          let side: InlineComment.Side = width - 2 < 100 ? store.diffSide : Int(value.location.x) < store.document
            .diffSideWidth ? .left : .right
          store.send(.diffCursorSelected(row: offset + Int(value.location.y), side: side))
        })
      }
      Spacer(minLength: 0)
    }.frame(width: max(1, width - 2), height: max(1, height - 2), alignment: .topLeading)
      .padding(1).frame(width: width, height: height).clipped()
      .border(store.pane == .content ? palette.accent : palette.surface)
      .overlay(alignment: .trailing) {
        ScrollIndicator(
          metrics: .init(total: store.document.lines.count, page: count, offset: offset, track: max(1, height - 2)),
          palette: palette,
        ) {
          store.send(.scrollbarMoved(.content, offset: $0, pageSize: count))
        }
      }
      .onScrollWheel { event in
        store.send(.wheelScrolled(.content, delta: event.deltaY))
        return .handled
      }
  }

  private func key(_ command: KeyCommand) -> String {
    store.preferences.keymap.bindings[command]?.first ?? ""
  }

  static func tabTitle(_ tab: WorkspaceFeature.ContentTab) -> String {
    switch tab { case .overview: "Overview"
    case .diff: "Diff"
    case .discussion: "Discussion"
    case .checks: "Checks" }
  }
}

private struct WorkspaceFooter: View {
  let store: StoreOf<WorkspaceFeature>
  let l10n: Localization
  private var palette: Palette {
    Palette(store.preferences.theme)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 2) {
        Text(" \(modeLabel) · \(scopeLabel)").bold().foregroundStyle(palette.accent)
        if let cursorLabel {
          Text(cursorLabel).foregroundStyle(palette.accent)
        }
        if !store.activeFilter
          .isEmpty
        {
          Text(TerminalText.sanitize(store.activeFilter)).foregroundStyle(palette.yellow).lineLimit(1)
        }
        if store.activeSearch.isActive {
          Text("/\(store.activeSearch.query)\(store.isSearching ? "▏" : "")").foregroundStyle(palette.rosewater)
          Text(searchCount).foregroundStyle(palette.yellow)
        } else if let file = store.selectedFile, store.pane == .files {
          Text("+\(file.additions) −\(file.deletions)").foregroundStyle(palette.green)
        }
        Spacer(minLength: 0)
        Text(activity).foregroundStyle(store.error == nil ? palette.muted : palette.red)
        Text(
          "\(store.document.lines.isEmpty ? 0 : store.scroll + 1)–\(min(store.document.lines.count, store.scroll + store.contentHeight))/\(store.document.lines.count) ",
        )
        .foregroundStyle(palette.muted)
      }.lineLimit(1).frame(height: 1)
      HStack {
        if store.activeSearch.isActive {
          Text(" Esc · \(l10n("Clear search"))  \(key(.nextMatch))/\(key(.previousMatch)) · \(l10n("Next match"))")
        } else {
          Text(
            " \(key(.down))/\(key(.up)) \(l10n("Move"))  \(key(.nextPane)) \(l10n("Focus pane"))  \(key(.search)) \(l10n("Search"))  \(key(.contentHalfPageDown))/\(key(.contentHalfPageUp)) \(l10n("Content"))",
          )
        }
        Spacer(minLength: 0)
        Text(store.pendingG ? "g… " : "\(key(.help)) \(l10n("Help"))  \(key(.quit)) \(l10n("Quit")) ")
      }.foregroundStyle(palette.muted).lineLimit(1).frame(height: 1)
    }.background(palette.mantle)
  }

  private var modeLabel: String {
    if store.visualStart != nil, store.pane == .content {
      return l10n("Visual")
    }
    if store.filterEditor != nil {
      return l10n("Filters and presets")
    }
    if store.review != nil {
      return l10n("Review")
    }
    if store.isSearching {
      return l10n("Search")
    }
    if store.activeSearch.isActive {
      return l10n(store.pane == .content && !store.showsHelp ? "Find" : "Filter")
    }
    return l10n("Normal")
  }

  private var cursorLabel: String? {
    guard store.pane == .content, store.tab == .diff, !store.isPreparingDocument,
          let rows = store.document.diff?.rows, rows.indices.contains(store.diffCursor),
          let end = rows[store.diffCursor].line(on: store.diffSide)?.number else { return nil }
    let start = store.visualStart.flatMap { rows.indices.contains($0) ? rows[$0].line(on: store.diffSide)?.number : nil } ?? end
    return "\(store.diffSide.rawValue) · \(start == end ? String(end) : "\(min(start, end))–\(max(start, end))")"
  }

  private var scopeLabel: String {
    switch store.searchScope {
    case .items: l10n(store.kind == .pullRequest ? "Pull requests" : "Issues")
    case .files: l10n("Files")
    case .content: l10n(Self.tabTitle(store.tab))
    case .help: l10n("Help")
    }
  }

  private var searchCount: String {
    switch store.searchScope {
    case .items: "\(store.visibleItems.count)/\(store.items.count)"
    case .files: "\(store.visibleFiles.count)/\(store.detail?.files.count ?? 0)"
    case .help: "\(store.visibleHelp.count)/\(KeyCommand.allCases.count)"
    case .content:
      store.activeSearch.matches.isEmpty ? l10n("No matches.") : "\(store.activeSearch.selection + 1)/\(store.activeSearch.matches.count)"
    }
  }

  private var activity: String {
    if store.review?.isSubmitting == true {
      return l10n("Submitting…")
    }
    if store.review?.error != nil {
      return l10n("Error")
    }
    if store.error != nil {
      return l10n("Error")
    }
    if store.isLoading {
      return l10n("Loading…")
    }
    if store.isLoadingDiff {
      return l10n("Loading diff…")
    }
    if store.isLoadingDetail {
      return l10n("Loading details…")
    }
    if store.isPreparingDocument {
      return l10n("Preparing text…")
    }
    if store.isFinding {
      return l10n("Finding…")
    }
    if store.nextPage != nil {
      return "\(key(.loadMore)) · \(l10n("Load more"))"
    }
    return l10n("Ready")
  }

  private func key(_ command: KeyCommand) -> String {
    store.preferences.keymap.bindings[command]?.first ?? ""
  }

  static func tabTitle(_ tab: WorkspaceFeature.ContentTab) -> String {
    switch tab { case .overview: "Overview"
    case .diff: "Diff"
    case .discussion: "Discussion"
    case .checks: "Checks" }
  }
}

private struct HelpPopup: View {
  let store: StoreOf<WorkspaceFeature>
  let l10n: Localization
  let palette: Palette
  let width: Int
  let height: Int

  var body: some View {
    let rows = max(1, height - 5)
    let entries = store.visibleHelp
    let titles = store.commandTitles
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text(l10n("Help")).bold().foregroundStyle(palette.accent)
        Spacer(minLength: 0)
        Text("\(entries.count)/\(KeyCommand.allCases.count)").foregroundStyle(palette.muted)
      }.lineLimit(1).frame(height: 1)
      Text("/\(store.searches[.help]?.query ?? "")\(store.isSearching ? "▏" : "")")
        .foregroundStyle(palette.rosewater).lineLimit(1).frame(height: 1)
      if entries.isEmpty {
        Text(l10n("No matches.")).frame(height: 1)
      }
      ForEach(Array(entries.dropFirst(store.helpScroll).prefix(rows)), id: \.rawValue) { command in
        HStack(spacing: 1) {
          Text((store.preferences.keymap.bindings[command] ?? []).joined(separator: " / "))
            .foregroundStyle(palette.blue).frame(width: min(26, width / 3), height: 1, alignment: .leading)
          Text(titles[command] ?? command.titleKey).lineLimit(1)
          Spacer(minLength: 0)
        }.frame(height: 1)
      }
      Spacer(minLength: 0)
      Text("/ · \(l10n("Search"))   Esc · \(l10n(store.activeSearch.isActive ? "Clear search" : "Close"))")
        .foregroundStyle(palette.muted).lineLimit(1).frame(height: 1)
    }.frame(width: width - 2, height: height - 2, alignment: .topLeading).padding(1)
      .frame(width: width, height: height).clipped().background(palette.mantle).border(palette.accent)
      .overlay(alignment: .trailing) {
        ScrollIndicator(
          metrics: .init(total: entries.count, page: rows, offset: store.helpScroll, track: max(1, height - 2)),
          palette: palette,
        ) {
          store.send(.scrollbarMoved(.help, offset: $0, pageSize: rows))
        }
      }
      .onChange(of: rows, initial: true) { store.send(.helpViewportChanged(rows)) }
      .onScrollWheel { event in
        store.send(.wheelScrolled(.help, delta: event.deltaY))
        return .handled
      }
  }
}

/// Only presentation fields cross the renderer's view-diff boundary.
private struct SidebarRow: Identifiable, Equatable {
  let id: String
  let text: String
  let selected: Bool
  let muted: Bool
  let reviewed: Bool
}

/// A pure, bounded viewport keeps focus changes out of rich-text reconstruction.
private struct DocumentViewport: View, Equatable {
  let lines: [[DiffSpan]]
  let matches: Set<Int>
  let theme: TataraCore.Theme
  let width: Int
  let height: Int
  var selectedRows: Set<Int> = []
  var selectedSide = InlineComment.Side.right

  var body: some View {
    Palette(theme).viewport(
      lines,
      offset: 0,
      count: height,
      matches: matches,
      selectedRows: selectedRows,
      selectedSide: selectedSide,
    )
    .lineLimit(height)
    .fixedSize(horizontal: true, vertical: true)
    .frame(width: width, height: height, alignment: .topLeading)
    .clipped()
  }
}
