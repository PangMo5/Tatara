// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CryptoKit
import Foundation
import TataraCore
import TermLoom

/// Markdown is prepared only for prose. Immutable diff source never enters this renderer.
enum CommentRenderer {

  // MARK: Internal

  @concurrent
  static func prepare(_ markdown: String, _ width: Int) async throws -> ReviewDocument {
    try Task.checkCancellation()
    let key = "markdown-v2:\(width):" + SHA256.hash(data: Data(markdown.utf8)).map { String(format: "%02x", $0) }.joined()
    if let result = await cache.value(for: key) {
      try Task.checkCancellation()
      return result
    }
    let clean = TerminalText.sanitize(markdown).replacing("\r\n", with: "\n").replacing(
      "\t",
      with: "    ",
    )
    let sourceLines = clean.components(separatedBy: "\n")
    var references = [String: String]()
    let referencePattern = try NSRegularExpression(pattern: #"^\s*\[(?!\^)([^\]]+)\]:\s*<?([^ >]+)>?.*$"#)
    var inReferenceFence = false
    for line in sourceLines {
      if
        line.trimmingCharacters(in: .whitespaces).hasPrefix("```") || line.trimmingCharacters(in: .whitespaces)
          .hasPrefix("~~~")
      {
        inReferenceFence.toggle()
      }
      if !inReferenceFence, let match = referencePattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
        let text = line as NSString
        references[text.substring(with: match.range(at: 1)).lowercased()] = text.substring(with: match.range(at: 2))
      }
    }
    var spans = [DiffSpan]()
    var fence: (Character, Int)?
    var skipped = 0
    for (index, line) in sourceLines.enumerated() {
      if skipped > 0 {
        skipped -= 1
        continue
      }
      if index % 64 == 0 {
        try Task.checkCancellation()
        await Task.yield()
      }
      if index > 0 {
        spans.append(.init(text: "\n", role: .commentBody))
      }
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      let marker = trimmed.first
      let markerCount = marker.map { character in trimmed.prefix { $0 == character }.count } ?? 0
      if let active = fence {
        if
          marker == active.0,
          markerCount >= active.1,
          trimmed.dropFirst(markerCount).trimmingCharacters(in: .whitespaces).isEmpty
        {
          fence = nil
        } else {
          spans.append(.init(text: line, role: .commentCode))
        }
        continue
      }
      if marker == "`" || marker == "~", markerCount >= 3 {
        fence = (marker!, markerCount)
        spans.append(.init(text: String(trimmed.dropFirst(markerCount)), role: .commentQuote))
        continue
      }
      if referencePattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
        continue
      }
      if index + 1 < sourceLines.count, line.contains("|"), isTableDivider(sourceLines[index + 1]) {
        var rows = [tableCells(line)]
        var next = index + 2
        while
          next < sourceLines.count,
          sourceLines[next].contains("|"),
          !sourceLines[next].trimmingCharacters(in: .whitespaces).isEmpty
        {
          rows.append(tableCells(sourceLines[next]))
          next += 1
        }
        let table = try await renderTable(rows, width: max(1, width))
        for (row, cells) in table.enumerated() {
          if row > 0 {
            spans.append(.init(text: "\n", role: .commentBody))
          }
          spans += cells
        }
        skipped = next - index - 1
        continue
      }
      let compact = trimmed.filter { !$0.isWhitespace }
      if compact.count >= 3, let first = compact.first, ["-", "*", "_"].contains(first), compact.allSatisfy({ $0 == first }) {
        spans.append(.init(text: String(repeating: "─", count: min(60, max(1, width))), role: .commentQuote))
        continue
      }
      let headingCount = line.prefix { $0 == "#" }.count
      let setext = index + 1 < sourceLines.count && !trimmed.isEmpty && sourceLines[index + 1].range(
        of: #"^\s*(={3,}|-{3,})\s*$"#,
        options: .regularExpression,
      ) != nil
      let heading = setext || (1 ... 6).contains(headingCount) && line.dropFirst(headingCount).first == " "
      if setext {
        skipped = 1
      }
      var source = heading && !setext ? String(line.dropFirst(headingCount + 1)) : line
      var quoteDepth = 0
      while source.hasPrefix(">") {
        source.removeFirst()
        if source.first == " " {
          source.removeFirst()
        }
        quoteDepth += 1
      }
      let quote = quoteDepth > 0
      if quote {
        spans.append(.init(text: String(repeating: "│ ", count: quoteDepth), role: .commentQuote))
      }
      let indent = source.prefix { $0 == " " }
      let body = source.dropFirst(indent.count)
      if body.hasPrefix("- [x] ") || body.hasPrefix("- [X] ") {
        source = indent + "☑ " + body.dropFirst(6)
      } else if body.hasPrefix("- [ ] ") {
        source = indent + "☐ " + body.dropFirst(6)
      } else if body.hasPrefix("- ") || body.hasPrefix("* ") || body.hasPrefix("+ ") {
        source = indent + "• " + body.dropFirst(2)
      }
      if ["<details>", "</details>"].contains(trimmed) {
        continue
      }
      source = source.replacing("<summary>", with: "▸ ").replacing("</summary>", with: "")
        .replacing("<br>", with: "\n").replacing("<br/>", with: "\n").replacing(
          "<br />",
          with: "\n",
        )
        .replacing("<kbd>", with: "`").replacing("</kbd>", with: "`")
      let referenceLinks = try NSRegularExpression(pattern: #"\[([^\]]+)\]\[([^\]]*)\]"#)
      for match in referenceLinks.matches(in: source, range: NSRange(source.startIndex..., in: source)).reversed() {
        let value = source as NSString
        let label = value.substring(with: match.range(at: 1))
        let name = value.substring(with: match.range(at: 2))
        if let url = references[(name.isEmpty ? label : name).lowercased()], let range = Range(match.range, in: source) {
          source.replaceSubrange(range, with: "[\(label)](\(url))")
        }
      }
      let parsed = try AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
      var lastLink: URL?
      var linkLabel = ""
      for run in parsed.runs {
        let intent = run.inlinePresentationIntent ?? []
        let link = run.link ?? run.imageURL
        let role: DiffRole = intent.contains(.code)
          ? .commentCode
          : link != nil
            ? .commentLink
            : intent.contains(.strikethrough)
              ? .commentStrikethrough
              : intent.contains(.emphasized)
                ? .commentEmphasis
                : quote ? .commentQuote : .commentBody
        if let previous = lastLink, link != previous {
          if linkLabel != previous.absoluteString {
            spans.append(.init(text: " (\(TerminalText.sanitize(previous.absoluteString)))", role: .commentLink))
          }
          linkLabel = ""
        }
        let label = (run.imageURL == nil ? "" : "▧ ") + String(parsed[run.range].characters)
        if link != nil {
          linkLabel += label
        }
        spans.append(.init(
          text: label,
          bold: heading || intent.contains(.stronglyEmphasized),
          role: role,
        ))
        lastLink = link
      }
      if let lastLink, linkLabel != lastLink.absoluteString {
        spans.append(.init(text: " (\(TerminalText.sanitize(lastLink.absoluteString)))", role: .commentLink))
      }
    }
    // Reuse word wrapping, then project its rows onto immutable styled UTF-16 runs.
    let source = spans.map(\.text).joined() as NSString
    let wrapped = try await DocumentRenderer.prepare(source as String, max(1, width))
    var bounds = [Range<Int>]()
    var length = 0
    for span in spans {
      bounds.append(length ..< length + span.text.utf16.count)
      length += span.text.utf16.count
    }
    var cursor = 0
    var styleIndex = 0
    var lines = [[DiffSpan]]()
    for (index, row) in wrapped.lines.enumerated() {
      if index % 128 == 0 {
        try Task.checkCancellation()
        await Task.yield()
      }
      let text = row.map(\.text).joined()
      if text.isEmpty {
        lines.append([.init(text: "", role: .commentBody)])
        continue
      }
      let range = source.range(of: text, options: .literal, range: NSRange(location: cursor, length: source.length - cursor))
      guard range.location != NSNotFound else { throw TataraError(
        .invalidResponse,
        detail: "Comment wrapping lost its text projection.",
      ) }
      let end = NSMaxRange(range)
      while styleIndex < bounds.count, bounds[styleIndex].upperBound <= range.location {
        styleIndex += 1
      }
      var projected = [DiffSpan]()
      var position = styleIndex
      while position < bounds.count, bounds[position].lowerBound < end {
        let lower = max(range.location, bounds[position].lowerBound)
        let upper = min(end, bounds[position].upperBound)
        if lower < upper {
          var span = spans[position]
          span.text = source.substring(with: NSRange(location: lower, length: upper - lower))
          projected.append(span)
        }
        position += 1
      }
      lines.append(projected)
      cursor = end
    }
    let result = try ReviewDocument(lines: lines, checkingCancellation: Task.checkCancellation)
    await cache.insert(result, for: key, cost: clean.utf8.count * 4 + lines.reduce(0) { $0 + 192 + $1.count * 96 })
    try Task.checkCancellation()
    return result
  }

  // MARK: Private

  private static let cache = PreparedDocumentCache(maximumCost: 8 * 1024 * 1024, maximumCount: 64)

  private static func tableCells(_ line: String) -> [String] {
    var cells = [String]()
    var cell = ""
    var escaped = false
    var code = false
    for character in line.trimmingCharacters(in: .whitespaces) {
      if escaped {
        cell.append(character)
        escaped = false
        continue
      }
      if character == "\\" {
        escaped = true
        cell.append(character)
        continue
      }
      if character == "`" {
        code.toggle()
      }
      if character == "|", !code {
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        cell = ""
      } else {
        cell.append(character)
      }
    }
    cells.append(cell.trimmingCharacters(in: .whitespaces))
    if cells.first == "" {
      cells.removeFirst()
    }
    if cells.last == "" {
      cells.removeLast()
    }
    return cells
  }

  private static func isTableDivider(_ line: String) -> Bool {
    let cells = tableCells(line)
    return !cells.isEmpty && cells.allSatisfy { $0.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil }
  }

  @concurrent
  private static func renderTable(_ rows: [[String]], width: Int) async throws -> [[DiffSpan]] {
    let count = rows.map(\.count).max() ?? 0
    guard count > 0 else { return [] }
    var result = [[DiffSpan]]()
    if width < count * 7 + 1 {
      if rows.count == 1 {
        return try await prepare(rows[0].joined(separator: " · "), width).displayLines
      }
      for row in rows.dropFirst() {
        for column in 0 ..< count {
          let label = rows[0].indices.contains(column) ? rows[0][column] : String(column + 1)
          let value = row.indices.contains(column) ? row[column] : ""
          result += try await prepare("**\(label)**: \(value)", width).displayLines
        }
        result.append([])
      }
      return result
    }
    let available = width - count * 3 - 1
    let widths = (0 ..< count).map { available / count + ($0 < available % count ? 1 : 0) }
    let divider = "├" + widths.lazy.map { String(repeating: "─", count: $0 + 2) }.joined(separator: "┼") + "┤"
    for (rowIndex, row) in rows.enumerated() {
      try Task.checkCancellation()
      var cells = [[[DiffSpan]]]()
      for column in 0 ..< count {
        let value = row.indices.contains(column) ? row[column] : ""
        let prepared = try await prepare(value, widths[column])
        cells.append(prepared.displayLines.map { $0.map { span in var span = span
          span.bold = span.bold || rowIndex == 0
          return span
        } })
      }
      let height = cells.map(\.count).max() ?? 1
      for line in 0 ..< height {
        var spans: [DiffSpan] = [.init(text: "│ ", role: .commentQuote)]
        for column in 0 ..< count {
          let parts = cells[column].indices.contains(line) ? cells[column][line] : []
          spans += parts
          let cellsUsed = TerminalWidth.of(parts.map(\.text).joined())
          spans.append(.init(
            text: String(repeating: " ", count: max(0, widths[column] - cellsUsed)) + " │" + (column == count - 1 ? "" : " "),
            role: .commentQuote,
          ))
        }
        result.append(spans)
      }
      if rowIndex == 0 {
        result.append([.init(text: divider, role: .commentQuote)])
      }
    }
    return result
  }

}
