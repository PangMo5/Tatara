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
  private var palette: Palette {
    Palette(store.preferences.theme)
  }

  var body: some View {
    GeometryReader { geometry in
      let width = geometry.size.width
      let height = geometry.size.height
      VStack(spacing: 0) {
        header
        if width < 60 || height < 16 {
          Text(l10n("Expand the terminal to at least 60 × 16.")).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let review = store.scope(state: \.review, action: \.review) {
          ReviewView(store: review, l10n: l10n, palette: palette)
        } else if store.showsHelp {
          help.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
          HStack(spacing: 0) {
            if width >= 100 {
              VStack(spacing: 0) {
                items(height: max(4, (height - 7) / 2))
                files(height: max(4, (height - 7) / 2))
              }.frame(width: min(44, width / 3))
              content(width: width - min(44, width / 3) - 4, height: height - 7)
            } else {
              switch store.pane {
              case .items: items(height: height - 7)
              case .files: files(height: height - 7)
              case .content: content(width: width - 4, height: height - 7)
              }
            }
          }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        footer
      }
      .foregroundStyle(palette.text)
      .background(palette.base)
    }
    .focusable(store.review == nil)
    .onAppear { store.send(.appeared) }
    .onKeyPress { press in
      let key = Self.keyName(press)
      if store.review != nil {
        if key == "esc" {
          store.send(.reviewDismissed)
          return .handled
        }
        return .ignored
      }
      if !store.isSearching, store.preferences.keymap.command(for: key) == .quit {
        quit()
        return .handled
      }
      if !store.isSearching, store.preferences.keymap.command(for: key) == .openBrowser, let url = store.selectedItem?.url,
         url.scheme == "https", url.host == store.repository.host
      {
        openLink(LinkDestination(url.absoluteString))
        return .handled
      }
      store.send(.keyPressed(key))
      return .handled
    }
  }

  private var header: some View {
    HStack {
      Text(" tatara ").bold().foregroundStyle(palette.base).background(palette.accent)
      Text(store.repository.description).lineLimit(1)
      Spacer()
      if demo {
        Text(l10n("DEMO · synthetic data")).foregroundStyle(palette.yellow)
      }
      Text("\(store.preferences.theme.rawValue) ").foregroundStyle(palette.muted)
    }.background(palette.mantle)
  }

  private func items(height: Int) -> some View {
    let visible = store.visibleItems
    let selected = visible.firstIndex { $0.id == store.selectedItemID } ?? 0
    let start = max(0, selected - max(1, height - 2) + 1)
    return VStack(alignment: .leading, spacing: 0) {
      Text("1 · \(l10n(store.kind == .pullRequest ? "Pull requests" : "Issues")) · \(visible.count)")
        .bold().foregroundStyle(store.pane == .items ? palette.accent : palette.muted)
      if store.isLoading {
        Text(l10n("Loading…")).foregroundStyle(palette.yellow)
      }
      if visible.isEmpty, !store.isLoading {
        Text(l10n("No open items.")).foregroundStyle(palette.muted)
      }
      ForEach(Array(visible.dropFirst(start).prefix(max(1, height - 2)))) { item in
        Text("\(item.id == store.selectedItemID ? "▸" : " ") #\(item.id.number) \(TerminalText.sanitize(item.title))")
          .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
          .foregroundStyle(item.isDraft ? palette.muted : palette.text)
          .background(item.id == store.selectedItemID ? palette.surface : palette.mantle)
      }
      Spacer(minLength: 0)
      if store.nextPage != nil {
        Text("L · \(l10n("Load more"))").foregroundStyle(palette.blue)
      }
    }.padding(1).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(palette.mantle).border(store.pane == .items ? palette.accent : palette.surface)
  }

  private func files(height: Int) -> some View {
    let files = store.detail?.files ?? []
    let selected = files.firstIndex { $0.path == store.selectedFilePath } ?? 0
    let start = max(0, selected - max(1, height - 2) + 1)
    return VStack(alignment: .leading, spacing: 0) {
      Text("2 · \(l10n("Files")) · \(files.count)").bold().foregroundStyle(store.pane == .files ? palette.accent : palette.muted)
      if store.isLoadingDetail {
        Text(l10n("Loading…")).foregroundStyle(palette.yellow)
      } else if files.isEmpty {
        Text(l10n("No changed files.")).foregroundStyle(palette.muted)
      }
      ForEach(Array(files.dropFirst(start).prefix(max(1, height - 2)))) { file in
        let reviewed = store.state.reviewKey(for: file.path).map(store.reviewedFiles.contains) ?? false
        Text("\(reviewed ? "✓" : " ") \(TerminalText.sanitize(file.path))")
          .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
          .foregroundStyle(reviewed ? palette.green : palette.text)
          .background(file.path == store.selectedFilePath ? palette.surface : palette.mantle)
      }
      Spacer(minLength: 0)
    }.padding(1).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(palette.mantle).border(store.pane == .files ? palette.accent : palette.surface)
  }

  private func content(width: Int, height: Int) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 2) {
        ForEach(WorkspaceFeature.ContentTab.allCases, id: \.rawValue) { tab in
          Text(l10n(Self.tabTitle(tab))).bold(tab == store.tab)
            .foregroundStyle(tab == store.tab ? palette.accent : palette.muted)
        }
        Spacer(minLength: 0)
        Text("[ ]").foregroundStyle(palette.muted)
      }.lineLimit(1)
      if let error = store.error {
        Text(l10n.error(error)).foregroundStyle(palette.red)
      } else if store.isLoadingDetail || store.isLoadingDiff {
        Text(l10n("Loading…")).foregroundStyle(palette.yellow)
      } else if store.tab == .diff, !store.diff.isEmpty {
        let lines = store.diffLines
        let offset = min(store.scroll, max(0, lines.count - max(1, height - 2)))
        ForEach(Array(lines.dropFirst(offset).prefix(max(1, height - 2)).enumerated()), id: \.offset) { _, spans in
          palette.styled(spans).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
        }
      } else {
        ScrollView(.vertical, position: SwiftTUI.Binding(
          get: { ScrollCellOffset(y: store.scroll) }, set: { store.send(.scrollPositionChanged($0.y)) },
        )) {
          Text(contentText).frame(maxWidth: .infinity, alignment: .leading)
            .background {
              GeometryReader { textGeometry in
                EmptyView().onChange(of: textGeometry.size.height, initial: true) {
                  store.send(.contentLineCountChanged(textGeometry.size.height))
                }
              }
            }
        }
      }
      Spacer(minLength: 0)
    }.padding(1).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .border(store.pane == .content ? palette.accent : palette.surface)
      .onChange(of: "\(width):\(height)", initial: true) { store.send(.viewportChanged(width: width, height: height)) }
  }

  private var contentText: String {
    guard let detail = store.detail else { return l10n("Select an item to begin.") }
    switch store.tab {
    case .overview:
      let item = detail.item
      let status = item.isDraft ? "Draft" : item.state == .open ? "Open" : item.state == .merged ? "Merged" : "Closed"
      var lines = [
        "#\(item.id.number) \(item.title)",
        "@\(item.author) · \(l10n(status))",
        item.url.absoluteString,
        item.labels.joined(separator: " · "),
      ]
      if case let .github(metadata) = detail.metadata {
        lines += [
          "\(metadata.headBranch) → \(metadata.baseBranch)",
          "GitHub · \(metadata.mergeableState)",
        ]
      }
      if let revision = detail.revision {
        lines.append("\(revision.mergeBase.prefix(8))…\(revision.head.prefix(8))")
      }
      lines += ["", item.body]
      return TerminalText.sanitize(lines.joined(separator: "\n"))
    case .diff: return l10n("Select a file to read its diff.")
    case .discussion:
      return detail.comments.isEmpty ? l10n("No comments yet.") : TerminalText.sanitize(detail.comments.map {
        "@\($0.author)\($0.context.map { " · \($0)" } ?? "")\n\($0.body)"
      }.joined(separator: "\n\n"))
    case .checks:
      if case let .github(metadata) = detail.metadata {
        let lines = metadata.checks + metadata.reviews
        return lines.isEmpty ? l10n("No checks reported.") : TerminalText.sanitize(lines.joined(separator: "\n"))
      }
      return l10n("No checks reported.")
    }
  }

  private var footer: some View {
    VStack(alignment: .leading, spacing: 0) {
      if store.isSearching {
        Text("/\(store.search)▏").foregroundStyle(palette.rosewater)
      }
      HStack(spacing: 2) {
        Text(
          "\(key(.down))/\(key(.up)) \(l10n("Move"))  \(key(.nextPane)) \(l10n("Focus pane"))  \(key(.search)) \(l10n("Search"))  \(key(.review)) \(l10n("Review"))",
        )
        Spacer(minLength: 0)
        Text("\(key(.help)) \(l10n("Help"))  \(key(.quit)) \(l10n("Quit")) ")
      }.lineLimit(1)
    }.foregroundStyle(palette.muted).background(palette.mantle)
  }

  private var help: some View {
    ScrollView(.vertical, position: SwiftTUI.Binding(
      get: { ScrollCellOffset(y: store.scroll) }, set: { store.send(.scrollPositionChanged($0.y)) },
    )) {
      VStack(alignment: .leading, spacing: 0) {
        Text(l10n("Help")).bold().foregroundStyle(palette.accent)
        ForEach(KeyCommand.allCases, id: \.rawValue) { command in
          HStack {
            Text((store.preferences.keymap.bindings[command] ?? []).joined(separator: " / "))
              .frame(width: 26, alignment: .leading).foregroundStyle(palette.blue)
            Text(l10n(commandTitle(command)))
          }
        }
        Text(l10n("Your draft stays here until you quit.")).foregroundStyle(palette.muted)
      }.padding(2)
    }
  }

  private func key(_ command: KeyCommand) -> String {
    store.preferences.keymap.bindings[command]?.first ?? ""
  }

  private func commandTitle(_ command: KeyCommand) -> String {
    switch command {
    case .down, .up, .left, .right, .nextMatch, .previousMatch: "Move"
    case .nextPane, .previousPane, .itemsPane, .filesPane, .contentPane: "Focus pane"
    case .first, .last: "First / last"
    case .halfPageDown, .halfPageUp: "Half page"
    case .open: "Open"
    case .back: "Back"
    case .refresh: "Refresh"
    case .search: "Search"
    case .toggleKind: "Switch PRs / issues"
    case .loadMore: "Load more"
    case .review: "Write your review"
    case .comment: "Comment"
    case .theme: "Theme"
    case .help: "Help"
    case .quit: "Quit"
    case .nextTab, .previousTab: "Overview"
    case .markReviewed: "Mark reviewed"
    case .openBrowser: "Open in browser"
    }
  }

  static func tabTitle(_ tab: WorkspaceFeature.ContentTab) -> String {
    switch tab { case .overview: "Overview"
    case .diff: "Diff"
    case .discussion: "Discussion"
    case .checks: "Checks" }
  }

  static func keyName(_ press: KeyPress) -> String {
    switch press.key {
    case let .character(value): press.modifiers.contains(.ctrl) ? "ctrl-\(value)" : String(value)
    case .return: "enter"
    case .escape: "esc"
    case .tab: press.modifiers.contains(.shift) ? "shift-tab" : "tab"
    case .arrowDown: "down"
    case .arrowUp: "up"
    case .arrowLeft: "left"
    case .arrowRight: "right"
    case .backspace: "backspace"
    case .home: "home"
    case .end: "end"
    case .pageDown: "page-down"
    case .pageUp: "page-up"
    case .space: "space"
    default: ""
    }
  }
}
