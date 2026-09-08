// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CryptoKit
import Foundation
import SwiftTUI
import TataraCore
import TataraKit

enum DocumentRenderer {
  static let client = DocumentClient(prepare: prepare, search: search, prepareDiff: prepareDiff)
  private static let cache = PreparedDocumentCache()

  @concurrent
  static func prepareDiff(_ diff: ReviewDiff, _ width: Int, _ side: InlineComment.Side) async throws -> ReviewDocument {
    try Task.checkCancellation()
    let key = diff.cacheIdentity.map { "structured:\(width):\(side):" + $0 }
    if let key, let cached = await cache.value(for: key) {
      return cached
    }
    let both = width >= 100
    let sideWidth = both ? max(1, (width - 3) / 2) : width
    let largest = diff.rows.reduce(1) { max($0, $1.left?.number ?? 0, $1.right?.number ?? 0) }
    let gutter = max(3, String(largest).count)
    let bodyWidth = max(1, sideWidth - gutter - 2)
    var glyphWidths: [Character: Int] = [:]
    func project(_ line: ReviewDiffLine?, side: InlineComment.Side) -> [DiffSpan] {
      guard let line else { return [.init(text: String(repeating: " ", count: sideWidth), side: side)] }
      let projection = clipped(line.spans, width: bodyWidth, widths: &glyphWidths)
      var spans = projection.spans
      let cells = projection.columns
      spans = spans.map { .init(text: $0.text, color: $0.color, bold: $0.bold, side: side) }
      let number = String(line.number)
      let prefix = " " + String(repeating: " ", count: gutter - number.count) + number + " "
      var result: [DiffSpan] = [.init(text: prefix, color: 8, side: side)]
      result.append(contentsOf: spans)
      result.append(.init(text: String(repeating: " ", count: max(0, bodyWidth - cells)), side: side))
      return result
    }
    var lines: [[DiffSpan]] = [], displayed: [[DiffSpan]] = []
    var estimatedCost = 0
    for (index, row) in diff.rows.enumerated() {
      if index % 128 == 0 {
        try Task.checkCancellation()
        await Task.yield()
      }
      if row.left == nil, row.right == nil {
        lines.append([.init(text: "…")])
        displayed.append([.init(text: "…", color: 8)])
        continue
      }
      let source = (row.left?.spans ?? []) + [.init(text: "  ")] + (row.right?.spans ?? [])
      estimatedCost += 256 + width * 2 + source.reduce(0) { $0 + $1.text.utf8.count * 2 + 48 }
      lines.append(source)
      displayed.append(both ? project(row.left, side: .left) + [.init(text: " │ ", color: 8)] + project(row.right, side: .right)
        : project(row.line(on: side), side: side))
    }
    if lines.isEmpty {
      let message = "\(diff.path) · \(diff.language) · \(diff.status)"
      lines = [[.init(text: message)]]
      displayed = lines
    }
    let result = try ReviewDocument(
      lines: lines,
      displayLines: displayed,
      diff: diff,
      diffSideWidth: sideWidth,
      diffNumberWidth: gutter,
      checkingCancellation: Task.checkCancellation,
    )
    if let key {
      await cache.insert(result, for: key, cost: estimatedCost)
    }
    return result
  }

  @concurrent
  static func prepare(_ text: String, _ width: Int) async throws -> ReviewDocument {
    try Task.checkCancellation()
    let key = "text:\(width):" + SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    try Task.checkCancellation()
    if let document = await cache.value(for: key) {
      try Task.checkCancellation()
      return document
    }
    let document = try await render(text, width)
    try Task.checkCancellation()
    // Include index text and per-row allocations in the conservative cache budget.
    await cache.insert(document, for: key, cost: text.utf8.count * 2 + document.lines.count * 192)
    return document
  }

  @concurrent
  private static func render(_ text: String, _ width: Int) async throws -> ReviewDocument {
    try Task.checkCancellation()
    var wrapper = WordWrapper(width: max(1, width))
    var visited = 0
    for character in text {
      visited += 1
      if visited % 1024 == 0 {
        try Task.checkCancellation()
        await Task.yield()
      }
      if character == "\n" || character == "\r\n" {
        wrapper.newline()
        continue
      }
      if character == "\t" {
        for _ in 0 ..< 4 {
          wrapper.append(" ")
        }
        continue
      }
      if let ascii = character.asciiValue {
        if ascii >= 32, ascii != 127 {
          wrapper.append(character)
        }
      } else {
        let value = TerminalText.sanitize(String(character))
        for clean in value {
          wrapper.append(clean)
        }
      }
    }
    try Task.checkCancellation()
    wrapper.newline()
    return try ReviewDocument(lines: wrapper.lines, checkingCancellation: Task.checkCancellation)
  }

  /// Clip presentation before SwiftTUI measures Text. Source and search rows remain complete.
  private static func clipped(
    _ spans: [DiffSpan],
    width: Int,
    widths: inout [Character: Int],
  ) -> (spans: [DiffSpan], columns: Int) {
    var result: [DiffSpan] = [], columns = 0
    for span in spans {
      var prefix = ""
      for character in span.text {
        let clean: String
        if let ascii = character.asciiValue {
          if ascii == 9 {
            clean = "    "
          } else if ascii >= 32, ascii != 127 {
            clean = String(character)
          } else {
            continue
          }
        } else {
          clean = TerminalText.sanitize(String(character))
        }
        for glyph in clean {
          let cells: Int
          if glyph.isASCII {
            cells = 1
          } else if let cached = widths[glyph] {
            cells = cached
          } else {
            cells = layoutText(for: String(glyph), width: nil).lines.flatMap(\.clusters).reduce(0) { $0 + $1.cellWidth }
            if widths.count >= 256 {
              widths.removeAll(keepingCapacity: true)
            }
            widths[glyph] = cells
          }
          if columns + cells > width {
            if !prefix.isEmpty {
              result.append(.init(text: prefix, color: span.color, bold: span.bold))
            }
            return (result, columns)
          }
          prefix.append(glyph)
          columns += cells
        }
      }
      if !prefix.isEmpty {
        result.append(.init(text: prefix, color: span.color, bold: span.bold))
      }
    }
    return (result, columns)
  }

  @concurrent
  static func search(_ document: ReviewDocument, _ query: String) async throws -> [Int] {
    guard !query.isEmpty else { return [] }
    let needle = ReviewDocument.fold(query)
    var matches: [Int] = []
    for (index, line) in document.searchableLines.enumerated() {
      if index % 256 == 0 {
        try Task.checkCancellation()
        await Task.yield()
      }
      if line.contains(needle) {
        matches.append(index)
      }
    }
    return matches
  }
}

/// Retain prepared values so revisiting a file does not repeat wrapping, projection or indexing.
/// Eviction and destruction of the cache's large arrays happen on this actor's executor.
actor PreparedDocumentCache {
  private struct Entry {
    let document: ReviewDocument
    let cost: Int
    var access: Int
  }

  private let maximumCost: Int
  private let maximumCount: Int
  private var entries: [String: Entry] = [:]
  private var cost = 0
  private var access = 0

  init(maximumCost: Int = 64 * 1024 * 1024, maximumCount: Int = 24) {
    self.maximumCost = maximumCost
    self.maximumCount = maximumCount
  }

  func value(for key: String) -> ReviewDocument? {
    guard var entry = entries[key] else { return nil }
    access += 1
    entry.access = access
    entries[key] = entry
    return entry.document
  }

  func insert(_ document: ReviewDocument, for key: String, cost newCost: Int) {
    guard !Task.isCancelled, newCost <= maximumCost, maximumCount > 0 else { return }
    if let old = entries.removeValue(forKey: key) {
      cost -= old.cost
    }
    while cost + newCost > maximumCost || entries.count >= maximumCount {
      guard let oldest = entries.min(by: { $0.value.access < $1.value.access })?.key,
            let removed = entries.removeValue(forKey: oldest) else { break }
      cost -= removed.cost
    }
    access += 1
    entries[key] = Entry(document: document, cost: newCost, access: access)
    cost += newCost
  }
}

/// Word-aware streaming wrapping with literal hard breaks for oversized tokens.
/// Only bounded runs enter SwiftTUI's shared glyph-width cache; no full document
/// competes with interactive view layout or acquires a document-sized cache lock.
private struct WordWrapper {
  let width: Int
  var lines: [[DiffSpan]] = []
  private var row = ""
  private var columns = 0
  private var run = ""
  private var runBytes = 0
  private var whitespace = false
  private var continuation = false
  private var atParagraphStart = true
  private var paragraphHasRows = false
  private var separators: [[TextCluster]] = []
  private var separatorColumns = 0
  private var widths: [String: [TextCluster]] = [:]

  init(width: Int) {
    self.width = width
  }

  mutating func append(_ character: Character) {
    if whitespace != character.isWhitespace {
      finishRun()
      continuation = false
    }
    whitespace = character.isWhitespace
    run.append(character)
    runBytes += character.utf8.count
    if runBytes >= 4096 {
      finishRun()
      continuation = true
    }
  }

  mutating func newline() {
    finishRun()
    for separator in separators {
      appendCells(separator)
    }
    separators = []
    separatorColumns = 0
    if !row.isEmpty || !paragraphHasRows {
      flush()
    }
    atParagraphStart = true
    paragraphHasRows = false
    continuation = false
  }

  private mutating func finishRun() {
    guard !run.isEmpty else { return }
    let cells: [TextCluster]
    if let cached = widths[run] {
      cells = cached
    } else {
      cells = layoutText(for: run, width: nil).lines.flatMap(\.clusters)
      if runBytes <= 256 {
        if widths.count >= 128 {
          widths.removeAll(keepingCapacity: true)
        }
        widths[run] = cells
      }
    }
    let size = cells.reduce(0) { $0 + $1.cellWidth }
    if whitespace {
      if atParagraphStart {
        appendCells(cells)
      } else {
        separators.append(cells)
        separatorColumns += size
      }
    } else {
      if !continuation {
        if !row.isEmpty, columns + separatorColumns + size <= width {
          for separator in separators {
            appendCells(separator)
          }
        } else if !row.isEmpty, !separators.isEmpty || columns + size > width {
          flush()
        }
        separators = []
        separatorColumns = 0
      }
      appendCells(cells)
      atParagraphStart = false
    }
    run = ""
    runBytes = 0
  }

  private mutating func appendCells(_ cells: [TextCluster]) {
    for cell in cells {
      if columns + cell.cellWidth > width, !row.isEmpty {
        flush()
      }
      row.append(cell.character)
      columns += cell.cellWidth
    }
  }

  private mutating func flush() {
    lines.append([DiffSpan(text: row)])
    row = ""
    columns = 0
    paragraphHasRows = true
  }
}
