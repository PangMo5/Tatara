// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TataraCore
import TataraKit
import TermLoom

extension WorkspacePresentation {
  func searchText(_ text: String, ranges: [Range<Int>], color: Color, active: Bool = false) -> Text {
    let source = text as NSString
    var spans = [Span]()
    var offset = 0
    for range in ranges where range.lowerBound >= offset && range.upperBound <= source.length && !range.isEmpty {
      if range.lowerBound > offset {
        spans.append(Span(
          TerminalText.sanitize(source.substring(with: NSRange(location: offset, length: range.lowerBound - offset))),
          style: Style(foreground: color),
        ))
      }
      spans.append(Span(
        TerminalText.sanitize(source.substring(with: NSRange(range))),
        style: Style(
          foreground: palette.text,
          background: active
            ? palette.activeSearch
            : palette.search,
          modifiers: .bold,
        ),
      ))
      offset = range.upperBound
    }
    spans.append(Span(TerminalText.sanitize(source.substring(from: offset)), style: Style(foreground: color)))
    return Text([Line(spans)])
  }

  func fileSearchFooter(_ search: FileContentSearchFeature.State, in rect: Rect, into result: inout TerminalScreen) {
    let status = search.isLoading
      ? loadingLabel("Finding…")
      : search.error.map { l10n.error($0) } ?? "\(search.results.isEmpty ? 0 : search.selection + 1)/\(search.results.count)"
    result.text(
      " " + l10n("Search file contents") + " · #\(search.detail.item.id.number) · " + status,
      in: Rect(x: rect.x, y: rect.y, width: rect.width, height: 1),
      color: search.error == nil
        ? palette.accent
        : palette.red,
      bold: true,
    )
    let hints = search.isEditing
      ? "Enter · \(l10n("Search"))  Esc · \(l10n("Normal mode"))"
      : "\(key(.down))/\(key(.up))  \(key(.nextMatch))/\(key(.previousMatch)) · \(l10n("Move"))  \(key(.open)) · \(l10n("Open match"))  \(key(.search))/i · \(l10n("Search"))  Esc · \(l10n("Close"))"
    result.text(" " + hints, in: Rect(x: rect.x, y: rect.y + 1, width: rect.width, height: 1), color: palette.muted)
  }

  func fileSearchScreen(_ search: FileContentSearchFeature.State, into result: inout TerminalScreen) {
    guard size.width >= 60, size.height >= 16 else { return }
    let width = min(120, size.width - 4)
    let slots = search.isEditing || search.isLoading ? 3 : max(1, min(8, search.results.count))
    let height = min(7 + slots * 2, size.height - 4)
    let rect = Rect(x: (size.width - width) / 2, y: size.height - height - 2, width: width, height: height)
    pane(rect, title: l10n("Search file contents") + " · #\(search.detail.item.id.number)", selected: true, into: &result)
    result.text(
      "/" + search.query + (search.isEditing ? "▏" : ""),
      in: Rect(x: rect.x + 2, y: rect.y + 2, width: width - 4, height: 1),
      color: palette.yellow,
    )
    let status = search.error.map { l10n.error($0) } ?? (search.isLoading
      ? loadingLabel("Finding…")
      : search.results.isEmpty ? l10n("No matches.") : "\(search.selection + 1)/\(search.results.count)")
    result.text(
      status,
      in: Rect(x: rect.x + 2, y: rect.y + 3, width: width - 4, height: 1),
      color: search.error == nil
        ? palette.muted
        : palette.red,
    )
    let count = max(1, (height - 7) / 2)
    let start = min(max(0, search.results.count - count), max(0, search.selection - count / 2))
    for (index, hit) in search.results.dropFirst(start).prefix(count).enumerated() {
      let y = rect.y + 4 + index * 2
      let selected = start + index == search.selection
      if selected {
        result.operations.append(.fill(
          Rect(x: rect.x + 1, y: y, width: width - 2, height: 2),
          palette.sidebarSelection,
        ))
      }
      result.text(
        (selected ? (ascii ? "> " : "▸ ") : "  ") + hit.location.path + ":\(hit.location.line) · " + hit.location.side.rawValue,
        in: Rect(x: rect.x + 2, y: y, width: width - 4, height: 1),
        color: selected ? palette.lavender : palette.text,
        bold: selected,
      )
      result.operations.append(.text(
        Rect(x: rect.x + 4, y: y + 1, width: width - 6, height: 1),
        searchText(hit.excerpt, ranges: hit.ranges, color: palette.muted, active: selected),
      ))
    }
    let hints = search.isEditing
      ? "Enter · \(l10n("Search"))  Esc · \(l10n("Normal mode"))"
      : "\(key(.down))/\(key(.up)) · \(l10n("Move"))  \(key(.open)) · \(l10n("Open match"))  \(key(.search))/i · \(l10n("Search"))  Esc · \(l10n("Close"))"
    result.text(hints, in: Rect(x: rect.x + 2, y: rect.bottom - 2, width: width - 4, height: 1), color: palette.muted)
  }
}
