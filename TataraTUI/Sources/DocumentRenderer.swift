// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CryptoKit
import Foundation
import TataraCore
import TataraKit
import TermLoom

// MARK: - DocumentRenderer

enum DocumentRenderer {

  // MARK: Internal

  static let client = DocumentClient(
    prepare: prepare,
    prepareComment: CommentRenderer.prepare,
    search: search,
    revealMatch: revealMatch,
    prepareDiff: prepareDiff,
  )

  @concurrent
  static func prepareDiff(_ diff: ReviewDiff, _ width: Int) async throws -> ReviewDocument {
    try await prepareDiff(diff, DiffViewport(width: width))
  }

  @concurrent
  static func prepareDiff(_ diff: ReviewDiff, _ viewport: DiffViewport) async throws -> ReviewDocument {
    try Task.checkCancellation()
    let width = viewport.width
    let hasLeft = diff.rows.contains { $0.left != nil }
    let hasRight = diff.rows.contains { $0.right != nil }
    let both = width >= 100 && (hasLeft == hasRight)
    var offset = viewport.wrap ? 0 : max(0, viewport.offset)
    let key = diff.cacheIdentity.map { "structured-v2:\(width):\(viewport.wrap):\(offset):" + $0 }
    if let key, let cached = await cache.value(for: key) {
      return cached
    }
    let rows = both ? diff.rows : try unifiedRows(diff.rows, path: diff.path)
    let sideWidth = both ? max(1, (width - 3) / 2) : width
    let largest = rows.reduce(1) { max($0, $1.left?.number ?? 0, $1.right?.number ?? 0) }
    let gutter = max(3, String(largest).count)
    let prefixWidth = both ? gutter + 3 : gutter * 2 + 4
    let bodyWidth = max(1, sideWidth - prefixWidth)
    var glyphWidths = [Character: Int]()
    var maximumWidth = 0
    var estimatedCost = 0
    if !viewport.wrap {
      for row in rows {
        try Task.checkCancellation()
        for line in [row.left, row.right].compactMap(\.self) {
          let columns = line.spans.reduce(0) { $0 + TerminalWidth.of(TerminalText.sanitize($1.text).replacing(
            "\t",
            with: "    ",
          )) }
          maximumWidth = max(maximumWidth, columns)
        }
      }
      offset = min(offset, max(0, maximumWidth - bodyWidth))
    }
    typealias Segment = (spans: [DiffSpan], columns: Int, offset: Int)
    func segments(_ line: ReviewDiffLine?) throws -> [Segment] {
      guard let line else { return [] }
      if !viewport.wrap {
        let value = clipped(line.spans, width: bodyWidth, offset: offset, widths: &glyphWidths)
        return [(value.spans, value.columns, offset)]
      }
      var result = [Segment]()
      var spans = [DiffSpan]()
      var columns = 0
      var consumed = 0
      for span in line.spans {
        var part = span
        part.text = ""
        for (index, character) in span.text.enumerated() {
          if index % 1024 == 0 {
            try Task.checkCancellation()
          }
          let clean = character == "\t" ? "    " : TerminalText.sanitize(String(character))
          for glyph in clean where glyph != "\n" {
            let cells = glyphWidths[glyph] ?? TerminalWidth.of(glyph)
            if glyphWidths.count < 256 {
              glyphWidths[glyph] = cells
            }
            if columns > 0, columns + cells > bodyWidth {
              if !part.text.isEmpty {
                spans.append(part)
                part.text = ""
              }
              result.append((spans, columns, consumed))
              consumed += columns
              columns = 0
              spans = []
            }
            part.text.append(glyph)
            columns += cells
          }
        }
        if !part.text.isEmpty {
          spans.append(part)
        }
      }
      if !spans.isEmpty || result.isEmpty {
        result.append((spans, columns, consumed))
      }
      maximumWidth = max(maximumWidth, consumed + columns)
      return result
    }
    func number(_ line: ReviewDiffLine?, continuation: Bool = false) -> String {
      let value = continuation ? "" : line.map { String($0.number) } ?? ""
      return String(repeating: " ", count: gutter - value.count) + value
    }
    func project(
      _ line: ReviewDiffLine?,
      segment: Segment?,
      side: InlineComment.Side,
      row: ReviewDiffRow,
      continuation: Bool,
    ) -> [DiffSpan] {
      guard let line, let segment else { return [.init(text: String(repeating: " ", count: sideWidth), side: side)] }
      let changed = line.spans.contains(where: \.isChanged) || row.left == nil || row.right == nil
      let marker = changed ? (side == .left ? "-" : "+") : " "
      let prefix = both
        ? " " + number(line, continuation: continuation) + marker + " "
        : " " + number(row.left, continuation: continuation) + " " + number(row.right, continuation: continuation) + marker + " "
      var result: [DiffSpan] = [.init(
        text: prefix,
        bold: changed,
        side: side,
        role: changed ? (side == .left ? .removed : .added) : .metadata,
      )]
      result += segment.spans.map { span in var span = span
        span.side = side
        return span
      }
      result.append(.init(text: String(repeating: " ", count: max(0, bodyWidth - segment.columns)), side: side))
      return result
    }
    var lines = [[DiffSpan]]()
    var displayed = [[DiffSpan]]()
    var projectedRows = [ReviewDiffRow]()
    for (index, row) in rows.enumerated() {
      if index % 128 == 0 {
        try Task.checkCancellation()
        await Task.yield()
      }
      if row.left == nil, row.right == nil {
        let annotation = row.annotation ?? [.init(text: "…", role: .hunkHeader)]
        let side = annotation.first(where: { $0.commentSide != nil })?.commentSide
        let indentation = both && side == .right ? sideWidth + 3 : 0
        let room = both && side != nil ? sideWidth : width
        let padding: [DiffSpan] = indentation == 0
          ? []
          : [.init(
            text: String(repeating: " ", count: indentation),
            role: .commentGap,
          )]
        lines.append(padding + annotation)
        displayed.append(padding + clipped(annotation, width: room, widths: &glyphWidths).spans)
        projectedRows.append(row)
        estimatedCost += annotation.reduce(192) { $0 + $1.text.utf8.count * 2 }
        continue
      }
      let left = try segments(row.left)
      let right = try segments(row.right)
      for part in 0 ..< max(left.count, right.count) {
        let lhs = left.indices.contains(part) ? left[part] : nil
        let rhs = right.indices.contains(part) ? right[part] : nil
        let projected = ReviewDiffRow(
          left: lhs == nil ? nil : row.left,
          right: rhs == nil ? nil : row.right,
          path: row.path,
          leftOffset: lhs?.offset ?? 0,
          rightOffset: rhs?.offset ?? 0,
        )
        projectedRows.append(projected)
        lines.append(viewport.wrap
          ? (lhs?.spans ?? []) + [.init(text: "  ")] + (rhs?.spans ?? [])
          : (row.left?.spans ?? []) + [.init(text: "  ")] + (row.right?.spans ?? []))
        if both {
          displayed.append(project(row.left, segment: lhs, side: .left, row: row, continuation: part > 0)
            + [.init(text: " │ ", role: .metadata)] + project(
              row.right,
              segment: rhs,
              side: .right,
              row: row,
              continuation: part > 0,
            ))
        } else {
          let side: InlineComment.Side = row.right == nil ? .left : .right
          displayed.append(project(
            row.line(on: side),
            segment: side == .left ? lhs : rhs,
            side: side,
            row: row,
            continuation: part > 0,
          ))
        }
        estimatedCost += 384 + width * 4
      }
      estimatedCost += (row.left?.spans ?? []).reduce(0) { $0 + $1.text.utf8.count + 64 }
        + (row.right?.spans ?? []).reduce(0) { $0 + $1.text.utf8.count + 64 }
    }
    if lines.isEmpty {
      lines = [[.init(text: "\(diff.path) · \(diff.language) · \(diff.status)")]]
      displayed = lines
    }
    let projected = ReviewDiff(
      path: diff.path,
      language: diff.language,
      status: diff.status,
      rows: projectedRows,
      revision: diff.revision,
      previousPath: diff.previousPath,
      cacheIdentity: diff.cacheIdentity,
    )
    let result = try ReviewDocument(
      lines: lines,
      displayLines: displayed,
      diff: projected,
      sourceDiff: diff,
      diffSideWidth: sideWidth,
      diffPrefixWidth: prefixWidth,
      isUnifiedDiff: !both,
      horizontalOffset: offset,
      wrapsLines: viewport.wrap,
      maximumHorizontalOffset: max(0, maximumWidth - bodyWidth),
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
  static func search(_ document: ReviewDocument, _ query: String) async throws -> SearchMatches {
    guard !query.isEmpty else { return [] }
    let pattern = try SearchPattern(query)
    var foundMatches = [(row: Int, side: InlineComment.Side?, range: Range<Int>?, source: Range<Int>?)]()
    var highlights = [Int: [Range<Int>]]()
    var visited = Set<SourceLocation>()
    for (index, line) in document.searchableLines.enumerated() {
      if index % 128 == 0 {
        try Task.checkCancellation()
        await Task.yield()
      }
      if
        let diff = document.diff,
        diff.rows.indices.contains(index),
        diff.rows[index].left != nil || diff.rows[index].right != nil
      {
        for side in InlineComment.Side.allCases {
          if document.isUnifiedDiff, side == .left, diff.rows[index].right != nil {
            continue
          }
          guard let source = diff.rows[index].line(on: side) else { continue }
          let location = SourceLocation(path: diff.rows[index].path ?? diff.path, line: source.number, side: side)
          guard visited.insert(location).inserted else { continue }
          let text = source.spans.map(\.text).joined()
          let glyphs = try sourceGlyphs(text)
          let sourceRows = document.rows(for: location)
          var projections = [Int: (start: Int, sourceStart: Int, columnStart: Int)]()
          for row in sourceRows {
            let offset = side == .left ? diff.rows[row].leftOffset : diff.rows[row].rightOffset
            let first = lowerBound(glyphs) { $0.column >= offset }
            var start = 0
            for span in document.displayLines[row] {
              if span.side == side {
                break
              }
              start += span.text.utf16.count
            }
            projections[row] = (
              start + document.diffPrefixWidth,
              first < glyphs.count ? glyphs[first].displayOffset : 0,
              first < glyphs.count ? glyphs[first].column : offset,
            )
          }
          let columns = max(1, document.diffSideWidth - document.diffPrefixWidth)
          for range in try pattern.ranges(in: text) {
            if foundMatches.count % 256 == 0 {
              try Task.checkCancellation()
            }
            let first = lowerBound(glyphs) { $0.sourceEnd > range.lowerBound }
            let column = first < glyphs.count ? glyphs[first].column : (glyphs.last.map { $0.column + $0.columns } ?? 0)
            let matchRow = document.row(for: location, column: column) ?? index
            var portions = [Int: Range<Int>]()
            if range.isEmpty {
              if
                let projection = projections[matchRow],
                column >= projection.columnStart,
                column < projection.columnStart + columns
              {
                let start = projection
                  .start +
                  (first < glyphs.count
                    ? glyphs[first].displayOffset - projection
                      .sourceStart
                    : (glyphs.last.map { $0.displayOffset + $0.displayLength } ?? 0) - projection.sourceStart)
                portions[matchRow] = start ..< start + 1
              }
            } else {
              var glyphIndex = first
              while glyphIndex < glyphs.count, glyphs[glyphIndex].sourceStart < range.upperBound {
                let glyph = glyphs[glyphIndex]
                glyphIndex += 1
                let row = document.row(for: location, column: glyph.column) ?? index
                guard
                  let projection = projections[row],
                  glyph.column >= projection.columnStart,
                  glyph.column + glyph.columns <= projection.columnStart + columns
                else { continue }
                let start = projection.start + glyph.displayOffset - projection.sourceStart
                let end = start + glyph.displayLength
                portions[row] = portions[row].map { min($0.lowerBound, start) ..< max($0.upperBound, end) } ?? start ..< end
              }
            }
            for (row, portion) in portions {
              highlights[row, default: []].append(portion)
            }
            foundMatches.append((matchRow, side, portions[matchRow], range))
            guard foundMatches.count <= 100_000 else { throw TataraError(
              .invalidResponse,
              detail: "Search exceeds 100,000 matches; narrow the expression.",
            ) }
          }
        }
      } else {
        for range in try pattern.ranges(in: line) {
          foundMatches.append((index, nil, range, nil))
          highlights[index, default: []].append(range)
          guard foundMatches.count <= 100_000 else { throw TataraError(
            .invalidResponse,
            detail: "Search exceeds 100,000 matches; narrow the expression.",
          ) }
        }
      }
    }
    foundMatches.sort { lhs, rhs in
      if lhs.row != rhs.row {
        return lhs.row < rhs.row
      }
      if lhs.side != rhs.side {
        return lhs.side == .left
      }
      return (lhs.source?.lowerBound ?? lhs.range?.lowerBound ?? 0) < (rhs.source?.lowerBound ?? rhs.range?.lowerBound ?? 0)
    }
    try Task.checkCancellation()
    return .init(
      lines: foundMatches.map(\.row),
      highlights: highlights,
      sides: foundMatches.map(\.side),
      ranges: foundMatches.map(\.range),
      sourceRanges: foundMatches.map(\.source),
    )
  }

  @concurrent
  static func revealMatch(
    _ document: ReviewDocument,
    _ matches: SearchMatches,
    _ index: Int,
    _ width: Int,
  ) async throws -> ReviewDocument {
    guard
      !document.wrapsLines,
      let diff = document.diff,
      matches.lines.indices.contains(index),
      matches.sides.indices.contains(index),
      let side = matches.sides[index],
      matches.sourceRanges.indices.contains(index),
      let range = matches.sourceRanges[index],
      diff.rows.indices.contains(matches.lines[index]),
      let source = diff.rows[matches.lines[index]].line(on: side)
    else { return document }
    let text = source.spans.map(\.text).joined()
    let prefix = String(decoding: text.utf16.prefix(range.lowerBound), as: UTF16.self)
    let column = TerminalWidth.of(TerminalText.sanitize(prefix).replacing("\t", with: "    "))
    try Task.checkCancellation()
    let bodyWidth = max(1, document.diffSideWidth - document.diffPrefixWidth)
    return try await prepareDiff(document.sourceDiff ?? diff, DiffViewport(width: width, offset: max(0, column - bodyWidth / 3)))
  }

  // MARK: Private

  private struct SourceGlyph {
    var sourceStart: Int
    var sourceEnd: Int
    var column: Int
    var columns: Int
    var displayOffset: Int
    var displayLength: Int
  }

  private static let cache = PreparedDocumentCache()

  /// Keep every source identity once: old rows, new rows, then shared context.
  /// Annotation boundaries retain their placement and never become source rows.
  private static func unifiedRows(_ rows: [ReviewDiffRow], path: String) throws -> [ReviewDiffRow] {
    var result = [ReviewDiffRow]()
    var old = [ReviewDiffRow]()
    var new = [ReviewDiffRow]()
    var lastOld: SourceLocation?
    var lastNew: SourceLocation?
    func flush() {
      result.append(contentsOf: old)
      result.append(contentsOf: new)
      old.removeAll(keepingCapacity: true)
      new.removeAll(keepingCapacity: true)
      lastOld = nil
      lastNew = nil
    }
    for (index, row) in rows.enumerated() {
      if index % 128 == 0 {
        try Task.checkCancellation()
      }
      if row.left == nil, row.right == nil, let location = row.annotationLocation {
        if location == lastOld {
          old.append(row)
          continue
        }
        if location == lastNew {
          new.append(row)
          continue
        }
      }
      let shared =
        if let left = row.left, let right = row.right {
          !left.spans.contains(where: \.isChanged) && !right.spans.contains(where: \.isChanged)
            && left.spans.map(\.text).joined() == right.spans.map(\.text).joined()
        } else {
          false
        }
      if shared || (row.left == nil && row.right == nil) {
        flush()
        result.append(row)
      } else {
        if let left = row.left {
          old.append(.init(left: left, right: nil, path: row.path))
          lastOld = .init(path: row.path ?? path, line: left.number, side: .left)
        }
        if let right = row.right {
          new.append(.init(left: nil, right: right, path: row.path))
          lastNew = .init(path: row.path ?? path, line: right.number, side: .right)
        }
      }
    }
    flush()
    return result
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

  /// Clip presentation to terminal columns. Source and search rows remain complete.
  private static func clipped(
    _ spans: [DiffSpan],
    width: Int,
    offset: Int = 0,
    widths: inout [Character: Int],
  ) -> (spans: [DiffSpan], columns: Int) {
    var result = [DiffSpan]()
    var columns = 0
    var sourceColumns = 0
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
            cells = TerminalWidth.of(glyph)
            if widths.count >= 256 {
              widths.removeAll(keepingCapacity: true)
            }
            widths[glyph] = cells
          }
          if sourceColumns < offset {
            sourceColumns += cells
            continue
          }
          sourceColumns += cells
          if columns + cells > width {
            if !prefix.isEmpty {
              var clipped = span
              clipped.text = prefix
              result.append(clipped)
            }
            return (result, columns)
          }
          prefix.append(glyph)
          columns += cells
        }
      }
      if !prefix.isEmpty {
        var clipped = span
        clipped.text = prefix
        result.append(clipped)
      }
    }
    return (result, columns)
  }

  private static func sourceGlyphs(_ source: String) throws -> [SourceGlyph] {
    var result = [SourceGlyph]()
    var sourceOffset = 0
    var displayOffset = 0
    var column = 0
    var widths = [Character: Int]()
    for (index, character) in source.enumerated() {
      if index % 1024 == 0 {
        try Task.checkCancellation()
      }
      let length = character.utf16.count
      let clean = character == "\t" ? "    " : TerminalText.sanitize(String(character))
      for glyph in clean {
        let width = widths[glyph] ?? TerminalWidth.of(glyph)
        if widths.count < 256 {
          widths[glyph] = width
        }
        let displayLength = glyph.utf16.count
        result.append(.init(
          sourceStart: sourceOffset,
          sourceEnd: sourceOffset + length,
          column: column,
          columns: width,
          displayOffset: displayOffset,
          displayLength: displayLength,
        ))
        column += width
        displayOffset += displayLength
      }
      sourceOffset += length
    }
    return result
  }

  private static func lowerBound(_ values: [SourceGlyph], predicate: (SourceGlyph) -> Bool) -> Int {
    var lower = 0
    var upper = values.count
    while lower < upper {
      let middle = lower + (upper - lower) / 2
      if predicate(values[middle]) {
        upper = middle
      } else {
        lower = middle + 1
      }
    }
    return lower
  }

}

// MARK: - PreparedDocumentCache

/// Retain prepared values so revisiting a file does not repeat wrapping, projection or indexing.
/// Eviction and destruction of the cache's large arrays happen on this actor's executor.
actor PreparedDocumentCache {

  // MARK: Lifecycle

  init(maximumCost: Int = 64 * 1024 * 1024, maximumCount: Int = 24) {
    self.maximumCost = maximumCost
    self.maximumCount = maximumCount
  }

  // MARK: Internal

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
      guard
        let oldest = entries.min(by: { $0.value.access < $1.value.access })?.key,
        let removed = entries.removeValue(forKey: oldest)
      else { break }
      cost -= removed.cost
    }
    access += 1
    entries[key] = Entry(document: document, cost: newCost, access: access)
    cost += newCost
  }

  // MARK: Private

  private struct Entry {
    let document: ReviewDocument
    let cost: Int
    var access: Int
  }

  private let maximumCost: Int
  private let maximumCount: Int
  private var entries = [String: Entry]()
  private var cost = 0
  private var access = 0

}

// MARK: - WordWrapper

/// Word-aware streaming wrapping with literal hard breaks for oversized tokens.
/// Bounded worker-local glyph runs avoid sharing document-sized cache locks with input.
private struct WordWrapper {

  // MARK: Lifecycle

  init(width: Int) {
    self.width = width
  }

  // MARK: Internal

  let width: Int
  var lines = [[DiffSpan]]()

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

  // MARK: Private

  private var row = ""
  private var columns = 0
  private var run = ""
  private var runBytes = 0
  private var whitespace = false
  private var continuation = false
  private var atParagraphStart = true
  private var paragraphHasRows = false
  private var separators = [[DisplayCluster]]()
  private var separatorColumns = 0
  private var widths = [String: [DisplayCluster]]()

  private mutating func finishRun() {
    guard !run.isEmpty else { return }
    let cells: [DisplayCluster]
    if let cached = widths[run] {
      cells = cached
    } else {
      cells = run.map { DisplayCluster(character: $0, cellWidth: TerminalWidth.of($0)) }
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

  private mutating func appendCells(_ cells: [DisplayCluster]) {
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

// MARK: - DisplayCluster

private struct DisplayCluster {
  let character: Character
  let cellWidth: Int
}
