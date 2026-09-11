// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import TataraCore
import TataraKit
import TermLoom
import TermLoomTextArea

@MainActor
struct WorkspacePresentation {
  let store: StoreOf<WorkspaceFeature>
  let size: Size
  let demo: Bool
  let fields: [String: TextFieldState]
  let editors: [String: TextAreaState]
  let editorTexts: [String: String]
  let reviewScroll: Int
  let reviewPreview: ReviewDocument?
  let commentScroll: Int
  let failure: String?
  let noColor: Bool
  let ascii: Bool
  let cursorFollowsFocus: Bool
  let palette: Palette

  var l10n: Localization {
    Localization(language: store.preferences.language)
  }

  var geometry: WorkspaceGeometry {
    WorkspaceGeometry(size: size, preferredSidebarWidth: store.preferences.sidebarWidth)
  }

  func screen() -> TerminalScreen {
    var result = TerminalScreen(ascii: ascii)
    result.operations.append(.fill(Rect(size: size), palette.base))
    result.operations.append(.fill(Rect(x: 0, y: 0, width: size.width, height: 1), palette.mantle))
    result.text(
      " tatara · \(store.repository)",
      in: Rect(x: 0, y: 0, width: size.width, height: 1),
      color: palette.text,
      bold: true,
    )
    let suffix = (demo ? l10n("DEMO · synthetic data") + " · " : "") + store.preferences.theme.rawValue
    result.text(
      suffix,
      in: Rect(x: max(0, size.width - TerminalWidth.of(suffix) - 1), y: 0, width: TerminalWidth.of(suffix), height: 1),
      color: palette.muted,
    )
    if size.width < 60 || size.height < 16 {
      result.text(l10n("Expand the terminal to at least 60 × 16."), in: geometry.body, color: palette.text)
    } else if let review = store.review, store.reviewLocation == nil {
      reviewScreen(review, into: &result)
    } else {
      if size.width >= 100 || store.pane == .items {
        items(into: &result)
      }
      if size.width >= 100 || store.pane == .files {
        files(into: &result)
      }
      if size.width >= 100 || store.pane == .content {
        content(into: &result)
      }
    }
    if let filter = store.filterEditor {
      filterScreen(filter, into: &result)
    } else if store.showsHelp {
      help(into: &result)
    }
    footer(into: &result)
    if let failure {
      result.text(failure, in: Rect(x: 1, y: size.height - 1, width: size.width - 2, height: 1), color: palette.red)
    }
    if cursorFollowsFocus, store.review == nil, store.filterEditor == nil {
      let rect = store.pane == .items ? geometry.items : store.pane == .files ? geometry.files : geometry.content
      result.cursor = Position(x: rect.x + 1, y: rect.y + 1)
    }
    return result
  }

  func pane(_ rect: Rect, title: String, selected: Bool, into result: inout TerminalScreen) {
    result.operations.append(.fill(rect, palette.mantle))
    result.operations.append(.border(rect, selected ? palette.lavender : palette.overlay0, palette.mantle))
    result.text(
      title,
      in: Rect(x: rect.x + 1, y: rect.y + 1, width: rect.width - 2, height: 1),
      color: palette.text,
      bold: true,
    )
  }

  func items(into result: inout TerminalScreen) {
    let rect = geometry.items, visible = store.visibleItems, count = max(1, (rect.height - 3) / store.itemRowHeight)
    let selected = store.selectedItemIndex ?? 0
    let start = min(max(0, visible.count - count), max(0, store.itemsScroll))
    pane(
      rect,
      title: "\(l10n(store.kind == .pullRequest ? "Pull requests" : "Issues")) · \(visible.count)/\(store.items.count)",
      selected: store.pane == .items,
      into: &result,
    )
    for (index, item) in visible.dropFirst(start).prefix(count).enumerated() {
      let row = Rect(
        x: rect.x + 1,
        y: rect.y + 2 + index * store.itemRowHeight,
        width: rect.width - 2,
        height: store.itemRowHeight,
      )
      let selected = index + start == selected
      if selected {
        result.operations.append(.fill(row, palette.sidebarSelection))
      }
      let current = store.detail.flatMap { $0.item.id == item.id ? $0.item : nil } ?? item
      let status = current.isDraft ? (ascii ? "D" : "◌") : current.state == .merged ? (ascii ? "M" : "◆") : current
        .state == .closed ? (ascii ? "X" : "×") : (ascii ? "O" : "○")
      let color = current.isDraft ? palette.muted : current.state == .merged ? palette.mauve : current.state == .closed ? palette
        .red : palette.green
      result.text(
        selected ? (ascii ? ">" : "▸") : " ",
        in: Rect(x: row.x, y: row.y, width: 1, height: 1),
        color: palette.lavender,
      )
      result.text(status, in: Rect(x: row.x + 1, y: row.y, width: 1, height: 1), color: color)
      let badges = itemBadges(current)
      let badgeWidth = min(row.width / 3, TerminalWidth.of(badges))
      result.text(
        "#\(item.id.number) \(item.title)",
        in: Rect(x: row.x + 3, y: row.y, width: max(1, row.width - badgeWidth - 4), height: 1),
        color: current.isDraft ? palette.muted : palette.text,
      )
      let failed = current.github?.checksState == .failure || current.github?.checksState == .error || current.github?
        .reviewDecision == .changesRequested
      let pending = current.github?.checksState == .pending || current.github?.checksState == .expected || current.github?
        .reviewDecision == .reviewRequired
      result.text(
        badges,
        in: Rect(x: row.right - badgeWidth, y: row.y, width: badgeWidth, height: 1),
        color: failed ? palette.red : pending ? palette.yellow : palette.green,
      )
      if store.itemRowHeight == 2 {
        var info = ["@" + current.author]
        if let date = current.github?.updatedAt {
          info.append(String(date.prefix(10)))
        }
        info += current.labels
        result.text(
          info.joined(separator: " · "),
          in: Rect(x: row.x + 3, y: row.y + 1, width: row.width - 4, height: 1),
          color: palette.muted,
        )
      }
    }
    if visible.isEmpty {
      result.text(
        l10n(store.isLoading ? "Loading…" : store.activeSearch.query.isEmpty ? "No open items." : "No matches."),
        in: Rect(x: rect.x + 1, y: rect.y + 2, width: rect.width - 2, height: 1),
        color: palette.muted,
      )
    }
    result.scrollbar(rect, total: visible.count, page: count, offset: start, palette: palette)
  }

  func itemBadges(_ item: ForgeItem) -> String {
    guard let info = item.github else { return "" }
    var badges: [String] = []
    if let checks = info.checksState {
      badges
        .append("CI" +
          (checks == .success ? (ascii ? "+" : "✓") : checks == .failure || checks == .error ? "!" : (ascii ? "~" : "·")))
    }
    if let review = info.reviewDecision {
      badges.append("R" + (review == .approved ? (ascii ? "+" : "✓") : review == .changesRequested ? "!" : "?"))
    }
    if let count = info.commentCount, count > 0 {
      badges.append("c\(count)")
    }
    return badges.joined(separator: " ")
  }

  func files(into result: inout TerminalScreen) {
    let rect = geometry.files, visible = store.visibleFileRows, count = max(1, rect.height - 3)
    let selected = store.fileCursorIndex ?? 0
    let start = min(max(0, visible.count - count), max(0, store.filesScroll))
    let reviewPrefix = store.detail
      .flatMap { detail in
        detail.revision.map { "\(detail.item.id.repository)#\(detail.item.id.number)|\($0.mergeBase)|\($0.head)|" }
      }
    pane(
      rect,
      title: "\(l10n("Files")) · \(store.visibleFiles.count)/\(store.detail?.files.count ?? 0)",
      selected: store.pane == .files,
      into: &result,
    )
    for (index, file) in visible.dropFirst(start).prefix(count).enumerated() {
      let row = Rect(x: rect.x + 1, y: rect.y + 2 + index, width: rect.width - 2, height: 1)
      if index + start == selected {
        result.operations.append(.fill(row, palette.sidebarSelection))
      }
      let reviewed = !file.isDirectory && (reviewPrefix.map { store.reviewedFiles.contains($0 + file.path) } ?? false)
      let collapsed = store.searches[.files]?.query.isEmpty != false && store.collapsedDirectories.contains(file.path)
      let prefix = String(repeating: "  ", count: file.depth) +
        (file.isDirectory ? (collapsed ? (ascii ? "> " : "▸ ") : (ascii ? "v " : "▾ ")) : "  ")
      let match = store.fileMatches?[file.path].flatMap { $0.first.map { ":\($0)" } } ?? ""
      result.text(
        "\(noColor && index + start == selected ? ">" : reviewed ? (ascii ? "x" : "✓") : " ") \(prefix)\(file.name)\(match)",
        in: row,
        color: file.isDirectory ? palette.blue : reviewed ? palette.green : palette.text,
      )
    }
    if visible.isEmpty {
      result.text(
        l10n(store.isLoadingDetail || store.isSearchingFiles ? "Loading…" : store
          .fileMatches != nil ? "No matches." : "No changed files."),
        in: Rect(x: rect.x + 1, y: rect.y + 2, width: rect.width - 2, height: 1),
        color: palette.muted,
      )
    }
    result.scrollbar(rect, total: visible.count, page: count, offset: start, palette: palette)
  }

  func content(into result: inout TerminalScreen) {
    let rect = geometry.content, count = max(1, rect.height - 3)
    let offset = store.scroll
    let panelRow = store.review == nil ? nil : store.reviewRow
    let panelHeight = panelRow == nil ? 0 : store.reviewPanelHeight
    pane(
      rect,
      title: "",
      selected: store.pane == .content,
      into: &result,
    )
    result.operations.append(.fill(Rect(x: rect.x + 1, y: rect.y + 2, width: rect.width - 2, height: count), palette.base))
    var header: [Span] = []
    for tab in WorkspaceFeature.ContentTab.allCases {
      header.append(Span(
        " " + l10n(Self.tabTitle(tab)) + " ",
        style: Style(
          foreground: tab == store.tab ? palette.base : palette.muted,
          background: tab == store.tab ? palette.lavender : palette.mantle,
          modifiers: tab == store.tab ? .bold : [],
        ),
      ))
      header.append(Span(" ", style: Style(background: palette.mantle)))
    }
    header.append(Span(TerminalText.sanitize(store.documentTitle), style: Style(foreground: palette.muted)))
    result.operations.append(.text(Rect(x: rect.x + 1, y: rect.y + 1, width: rect.width - 2, height: 1), Text([Line(header)])))
    for (index, spans) in store.document.displayLines.dropFirst(offset).prefix(count).enumerated() {
      let selected = store.visualStart
        .map { (min($0, store.diffCursor) ... max($0, store.diffCursor)).contains(offset + index) } ?? false
      let row = offset + index
      let y = rect.y + 2 + index + (panelRow.map { row > $0 ? panelHeight : 0 } ?? 0)
      guard y < rect.bottom - 1 else { break }
      let line = highlightedLine(spans, row: row, selected: selected)
      let comment = spans.first?.role?.isComment == true
      if comment {
        result.operations.append(.fill(Rect(x: rect.x + 1, y: y, width: min(rect.width - 2, 116), height: 1), palette.mantle))
      }
      result.operations.append(.text(Rect(x: rect.x + 1, y: y, width: rect.width - 2, height: 1), Text([line])))
      if comment {
        result.text(ascii ? "|" : "│", in: Rect(x: rect.x + 1, y: y, width: 1, height: 1), color: palette.teal)
      }
    }
    if let review = store.review, let panelRow {
      inlineReview(
        review,
        rect: Rect(x: rect.x + 1, y: rect.y + 3 + panelRow - offset, width: rect.width - 2, height: panelHeight),
        into: &result,
      )
    }

    if store.document.lines.isEmpty || !store.isDocumentCurrent || store.isLoading || store.error != nil {
      let message = [
        store.error.map { l10n.error($0) } ?? activity,
        store.document.lines.isEmpty ? nil : l10n("Preview"),
        store.document.lines.isEmpty ? nil : store.documentTitle,
      ].compactMap(\.self).joined(separator: " · ")
      let row = Rect(x: rect.x + 1, y: rect.y + 2, width: rect.width - 2, height: store.error == nil ? 1 : min(count, 6))
      result.operations.append(.fill(row, palette.base))
      result.text(message, in: row, color: store.error == nil ? palette.yellow : palette.red)
    }
    if store.pane == .content, store.tab == .diff, store.isDocumentCurrent,
       let rows = store.document.diff?.rows, rows.indices.contains(store.diffCursor),
       rows[store.diffCursor].line(on: store.diffSide) != nil, store.diffCursor >= offset, store.diffCursor < offset + count
    {
      let x = rect.x + 1 + (rect.width - 2 >= 100 && store.diffSide == .right ? store.document.diffSideWidth + 3 : 0)
      result.text(
        ascii ? ">" : "▸",
        in: Rect(x: x, y: rect.y + 2 + store.diffCursor - offset, width: 1, height: 1),
        color: palette.rosewater,
      )
    }
    result.scrollbar(rect, total: store.document.lines.count + panelHeight, page: count, offset: offset, palette: palette)
  }

  /// Only split the visible text; regex matching and source projection stay on the worker.
  func highlightedLine(_ spans: [DiffSpan], row: Int, selected: Bool) -> Line {
    let search = store.searches[.content]
    let ranges = search?.result.highlights[row] ?? []
    let active: Range<Int>? = if let search, search.result.lines.indices.contains(search.selection),
                                 search.result.lines[search.selection] == row,
                                 search.result.ranges.indices.contains(search.selection)
    {
      search.result.ranges[search.selection]
    } else {
      nil
    }
    var output: [Span] = [], offset = 0
    for span in spans {
      let end = offset + span.text.utf16.count
      let overlaps = ranges.filter { $0.overlaps(offset ..< end) }
      let selected = selected && span.side == store.diffSide
      let normal = Style(
        foreground: palette.foreground(span),
        background: selected ? palette.selection : span.role == .commentCode ? palette.surface : span.role?
          .isComment == true ? palette.mantle : palette.base,
        modifiers: (span.bold ? Modifier.bold : [])
          .union(span.role == .commentEmphasis || span.role == .commentQuote ? .italic : [])
          .union(span.role == .commentLink ? .underlined : [])
          .union(span.role == .commentStrikethrough ? .crossedOut : [])
          .union(noColor && selected ? .reversed : []),
      )
      if overlaps.isEmpty {
        output.append(Span(span.text, style: normal))
      } else {
        var run = "", lastStyle: Style?
        for character in span.text {
          let length = character.utf16.count, range = offset ..< offset + length
          let matched = overlaps.contains { $0.overlaps(range) }
          let style = matched ? Style(
            foreground: palette.text,
            background: active?.overlaps(range) == true ? palette.activeSearch : palette.search,
            modifiers: noColor ? [.bold, .underlined] : .bold,
          ) : normal
          if let lastStyle, lastStyle != style {
            output.append(Span(run, style: lastStyle))
            run = ""
          }
          run.append(character)
          lastStyle = style
          offset += length
        }
        if let lastStyle {
          output.append(Span(run, style: lastStyle))
        }
      }
      offset = end
    }
    return Line(output)
  }

  func help(into result: inout TerminalScreen) {
    let rect = geometry.popup, rows = max(1, rect.height - 5)
    pane(rect, title: l10n("Help"), selected: true, into: &result)
    result.text(
      "/\(store.searches[.help]?.query ?? "")\(store.isSearching ? "▏" : "")",
      in: Rect(x: rect.x + 1, y: rect.y + 2, width: rect.width - 2, height: 1),
      color: palette.rosewater,
    )
    for (index, command) in store.visibleHelp.dropFirst(store.helpScroll).prefix(rows).enumerated() {
      let keyWidth = min(26, rect.width / 3)
      result.text(
        (store.preferences.keymap.bindings[command] ?? []).joined(separator: " / "),
        in: Rect(x: rect.x + 1, y: rect.y + 3 + index, width: keyWidth, height: 1),
        color: palette.blue,
      )
      result.text(
        store.commandTitles[command] ?? command.titleKey,
        in: Rect(x: rect.x + keyWidth + 2, y: rect.y + 3 + index, width: rect.width - keyWidth - 3, height: 1),
        color: palette.text,
      )
    }
    result.text(
      "/ · \(l10n("Search"))   Esc · \(l10n(store.activeSearch.isActive ? "Clear search" : "Close"))",
      in: Rect(x: rect.x + 1, y: rect.bottom - 2, width: rect.width - 2, height: 1),
      color: palette.muted,
    )
    result.scrollbar(rect, total: store.visibleHelp.count, page: rows, offset: store.helpScroll, palette: palette)
  }

  func footer(into result: inout TerminalScreen) {
    let rect = Rect(x: 0, y: max(0, size.height - 2), width: size.width, height: 2)
    result.operations.append(.fill(rect, palette.mantle))
    var label = " \(mode) · \(scope)"
    if store.pane == .content, store.tab == .diff, store.isDocumentCurrent, let rows = store.document.diff?.rows,
       rows.indices.contains(store.diffCursor), let end = rows[store.diffCursor].line(on: store.diffSide)?.number
    {
      let start = store.visualStart.flatMap { rows.indices.contains($0) ? rows[$0].line(on: store.diffSide)?.number : nil } ?? end
      label += "  \(store.diffSide.rawValue) · \(start == end ? String(end) : "\(min(start, end))–\(max(start, end))")"
    }
    if store.activeSearch.isActive {
      label += "  /\(store.activeSearch.query)\(store.isSearching ? "▏" : "")  \(searchCount)"
    } else if !store.activeFilter.isEmpty {
      label += "  \(store.activeFilter)"
    }
    let range = "\(store.document.lines.isEmpty ? 0 : store.scroll + 1)–\(min(store.document.lines.count, store.scroll + store.contentHeight))/\(store.document.lines.count) "
    let status = "\(activity)  \(range)", statusWidth = min(size.width / 2, TerminalWidth.of(status))
    result.text(
      label,
      in: Rect(x: 0, y: rect.y, width: max(0, size.width - statusWidth - 1), height: 1),
      color: palette.accent,
      bold: true,
    )
    result.text(
      status,
      in: Rect(x: size.width - statusWidth, y: rect.y, width: statusWidth, height: 1),
      color: store.error == nil ? palette.muted : palette.red,
    )
    let hints: String
    if store.isSearching {
      let title = store.searchScope == .items ? "GitHub search query" : store
        .searchScope == .files ? "File contents (regex)" : store.searchScope == .content ? "Find in diff (regex)" : "Search"
      hints = " \(l10n(title))  Enter · \(l10n("Search"))  Esc · \(l10n("Clear search"))"
    } else if store.activeSearch.isActive {
      hints = " Esc · \(l10n("Clear search"))  \(key(.nextMatch))/\(key(.previousMatch)) · \(l10n("Next match"))"
    } else {
      hints = " \(key(.down))/\(key(.up)) \(l10n("Move"))  \(key(.nextPane))/\(key(.previousPane)) \(l10n("Focus pane"))  \(key(.search)) \(l10n("Search"))  \(key(.filters)) \(l10n("Filters and presets"))  \(key(.toggleDetails)) \(l10n("Details"))"
    }

    result.text(
      hints + "  \(key(.help)) \(l10n("Help"))  \(store.pendingPrefix.map { $0 + "…" } ?? key(.quit) + " " + l10n("Quit"))",
      in: Rect(x: 0, y: rect.y + 1, width: size.width, height: 1),
      color: palette.muted,
    )
  }

  var mode: String {
    if store.filterEditor != nil {
      return l10n("Filters and presets")
    }
    if store.review != nil {
      return l10n("Review")
    }
    if store.visualStart != nil, store.pane == .content {
      return l10n("Visual")
    }
    if store.isSearching {
      return l10n("Search")
    }
    if store.activeSearch.isActive {
      return l10n(store.pane == .content && !store.showsHelp ? "Find" : "Filter")
    }
    return l10n("Normal")
  }

  var scope: String {
    switch store.searchScope { case .items: l10n(store.kind == .pullRequest ? "Pull requests" : "Issues")
    case .files: l10n("Files")
    case .content: l10n(Self.tabTitle(store.tab))
    case .help: l10n("Help") }
  }

  var searchCount: String {
    switch store.searchScope {
    case .items: "\(store.visibleItems.count)/\(store.items.count)"
    case .files: "\(store.visibleFiles.count)/\(store.detail?.files.count ?? 0)"
    case .help: "\(store.visibleHelp.count)/\(KeyCommand.allCases.count)"
    case .content: store.isFinding ? l10n("Finding…") : !store.isDocumentCurrent ? l10n("Preview") : store.activeSearch.matches
      .isEmpty ? l10n("No matches.") : "\(store.activeSearch.selection + 1)/\(store.activeSearch.matches.count)"
    }
  }

  var activity: String {
    if store.review?.isSubmitting == true {
      return l10n("Submitting…")
    }
    if store.error != nil || store.review?.error != nil {
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
    if store.isFinding || store.isSearchingFiles {
      return l10n("Finding…")
    }
    if !store.isDocumentCurrent {
      return l10n("Preview")
    }
    return store.nextPage != nil ? "\(key(.loadMore)) · \(l10n("Load more"))" : l10n("Ready")
  }

  func key(_ command: KeyCommand) -> String {
    store.preferences.keymap.bindings[command]?.first ?? ""
  }

  static func tabTitle(_ tab: WorkspaceFeature.ContentTab) -> String {
    switch tab { case .overview: "Overview"
    case .diff: "Diff"
    case .discussion: "Discussion"
    case .checks: "Checks" }
  }
}
