// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CryptoKit
import Foundation
import TataraCore

/// Markdown is prepared only for prose. Immutable diff source never enters this renderer.
enum CommentRenderer {
  private static let cache = PreparedDocumentCache(maximumCost: 8 * 1024 * 1024, maximumCount: 64)

  @concurrent
  static func prepare(_ markdown: String, _ width: Int) async throws -> ReviewDocument {
    try Task.checkCancellation()
    let key = "comment:\(width):" + SHA256.hash(data: Data(markdown.utf8)).map { String(format: "%02x", $0) }.joined()
    if let result = await cache.value(for: key) {
      try Task.checkCancellation()
      return result
    }
    let clean = TerminalText.sanitize(markdown).replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(
      of: "\t",
      with: "    ",
    )
    var spans: [DiffSpan] = [], fence: (Character, Int)?
    for (index, line) in clean.components(separatedBy: "\n").enumerated() {
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
        if marker == active.0, markerCount >= active.1,
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
      let headingCount = line.prefix { $0 == "#" }.count
      let heading = (1 ... 6).contains(headingCount) && line.dropFirst(headingCount).first == " "
      let quote = line.hasPrefix("> ")
      let source = heading ? String(line.dropFirst(headingCount + 1)) : quote ? String(line.dropFirst(2)) : line
      if quote {
        spans.append(.init(text: "> ", role: .commentQuote))
      }
      let parsed = try AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
      var lastLink: URL?
      var linkLabel = ""
      for run in parsed.runs {
        let intent = run.inlinePresentationIntent ?? []
        let link = run.link ?? run.imageURL
        let role: DiffRole = intent.contains(.code) ? .commentCode : link != nil ? .commentLink :
          intent.contains(.strikethrough) ? .commentStrikethrough : intent.contains(.emphasized) ? .commentEmphasis :
          quote ? .commentQuote : .commentBody
        if let previous = lastLink, link != previous {
          if linkLabel != previous.absoluteString {
            spans.append(.init(text: " (\(TerminalText.sanitize(previous.absoluteString)))", role: .commentLink))
          }
          linkLabel = ""
        }
        let label = String(parsed[run.range].characters)
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
    var bounds: [Range<Int>] = [], length = 0
    for span in spans {
      bounds.append(length ..< length + span.text.utf16.count)
      length += span.text.utf16.count
    }
    var cursor = 0, styleIndex = 0, lines: [[DiffSpan]] = []
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
      var projected: [DiffSpan] = [], position = styleIndex
      while position < bounds.count, bounds[position].lowerBound < end {
        let lower = max(range.location, bounds[position].lowerBound), upper = min(end, bounds[position].upperBound)
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
}
