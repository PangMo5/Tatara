// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

public struct SourceLocation: Hashable, Codable, Sendable {
  public let path: String
  public let line: Int
  public let side: InlineComment.Side
  public init(path: String, line: Int, side: InlineComment.Side) {
    self.path = path
    self.line = line
    self.side = side
  }
}

public struct DiffViewport: Equatable, Sendable {
  public var width: Int
  public var wrap: Bool
  public var offset: Int
  public init(width: Int, wrap: Bool = false, offset: Int = 0) {
    self.width = width
    self.wrap = wrap
    self.offset = offset
  }
}

public struct ReviewDocument: Equatable, Sendable {
  public let lines: [[DiffSpan]]
  public let displayLines: [[DiffSpan]]
  public let searchableLines: [String]
  public let diff: ReviewDiff?
  /// Original alignment, retained when presentation expands changed pairs into separate rows.
  public let sourceDiff: ReviewDiff?
  public let diffSideWidth: Int
  public let horizontalOffset: Int
  public let wrapsLines: Bool
  public let maximumHorizontalOffset: Int
  public let commentKeys: [String]
  private let commentRows: [String: Int]
  private let commentIndices: [String: Int]
  private let wrappedRows: [SourceLocation: [Int]]
  private let logicalLeftRows: [Int]
  private let logicalRightRows: [Int]
  private let logicalAllRows: [Int]
  public let isUnifiedDiff: Bool
  public let diffPrefixWidth: Int
  private let sourceRows: [SourceLocation: Int]
  private let leftRows: [Int]
  private let rightRows: [Int]
  private let allSourceRows: [Int]
  private let counterpartRows: [Int: Int]

  public init(lines: [[DiffSpan]] = []) {
    self.init(lines: lines, checkingCancellation: {})
  }

  public init(
    lines: [[DiffSpan]],
    displayLines: [[DiffSpan]]? = nil,
    diff: ReviewDiff? = nil,
    sourceDiff: ReviewDiff? = nil,
    diffSideWidth: Int = 0,
    diffPrefixWidth: Int = 0,
    isUnifiedDiff: Bool = false,
    horizontalOffset: Int = 0,
    wrapsLines: Bool = false,
    maximumHorizontalOffset: Int = 0,
    checkingCancellation: () throws -> Void,
  ) rethrows {
    self.lines = lines
    self.displayLines = displayLines ?? lines
    self.diff = diff
    self.sourceDiff = sourceDiff
    self.diffSideWidth = diffSideWidth
    self.diffPrefixWidth = diffPrefixWidth
    self.isUnifiedDiff = isUnifiedDiff
    self.horizontalOffset = horizontalOffset
    self.wrapsLines = wrapsLines
    self.maximumHorizontalOffset = maximumHorizontalOffset
    precondition(self.displayLines.count == lines.count, "Display rows must preserve source row indices.")
    var indexLines: [String] = []
    var left: [Int] = [], right: [Int] = [], all: [Int] = []
    var sourceRows: [SourceLocation: Int] = [:]
    var wrapped: [SourceLocation: [Int]] = [:]
    var commentRows: [String: Int] = [:], commentKeys: [String] = []
    var logicalLeft: [Int] = [], logicalRight: [Int] = [], logicalAll: [Int] = []
    indexLines.reserveCapacity(lines.count)
    for (index, line) in lines.enumerated() {
      if index % 128 == 0 {
        try checkingCancellation()
      }
      indexLines.append(line.map(\.text).joined())
      if let key = line.first(where: { $0.commentKey != nil })?.commentKey, commentRows[key] == nil {
        commentRows[key] = index
        commentKeys.append(key)
      }
      if let diff, diff.rows.indices.contains(index) {
        for side in InlineComment.Side.allCases {
          if let source = diff.rows[index].line(on: side) {
            let location = SourceLocation(path: diff.rows[index].path ?? diff.path, line: source.number, side: side)
            wrapped[location, default: []].append(index)
            if sourceRows[location] == nil {
              sourceRows[location] = index
              if side == .left {
                logicalLeft.append(index)
              } else {
                logicalRight.append(index)
              }
              if logicalAll.last != index {
                logicalAll.append(index)
              }
            }
          }
        }
        if diff.rows[index].left != nil {
          left.append(index)
        }
        if diff.rows[index].right != nil {
          right.append(index)
        }
        if diff.rows[index].left != nil || diff.rows[index].right != nil {
          all.append(index)
        }
      }
    }
    wrappedRows = wrapped
    self.commentRows = commentRows
    self.commentKeys = commentKeys
    commentIndices = Dictionary(uniqueKeysWithValues: commentKeys.enumerated().map { ($0.element, $0.offset) })
    logicalLeftRows = logicalLeft
    logicalRightRows = logicalRight
    logicalAllRows = logicalAll
    searchableLines = indexLines
    self.sourceRows = sourceRows
    leftRows = left
    rightRows = right
    allSourceRows = all
    var counterparts: [Int: Int] = [:]
    if isUnifiedDiff, let sourceDiff {
      for (index, row) in sourceDiff.rows.enumerated() {
        if index % 128 == 0 {
          try checkingCancellation()
        }
        guard let lhs = row.left, let rhs = row.right,
              let left = sourceRows[.init(path: row.path ?? sourceDiff.path, line: lhs.number, side: .left)],
              let right = sourceRows[.init(path: row.path ?? sourceDiff.path, line: rhs.number, side: .right)] else { continue }
        counterparts[left] = right
        counterparts[right] = left
      }
    }
    counterpartRows = counterparts
  }

  public func row(for location: SourceLocation, column: Int = 0) -> Int? {
    guard column > 0, let candidates = wrappedRows[location], let diff else { return sourceRows[location] }
    var lower = 0, upper = candidates.count
    while lower < upper {
      let middle = lower + (upper - lower) / 2
      let row = diff.rows[candidates[middle]]
      let offset = location.side == .left ? row.leftOffset : row.rightOffset
      if offset <= column {
        lower = middle + 1
      } else {
        upper = middle
      }
    }
    return candidates[max(0, lower - 1)]
  }

  public func rows(for location: SourceLocation) -> [Int] {
    wrappedRows[location] ?? []
  }

  public func commentIndex(for key: String) -> Int? {
    commentIndices[key]
  }

  public func commentRow(for key: String) -> Int? {
    commentRows[key]
  }

  public func commentKey(at row: Int) -> String? {
    guard lines.indices.contains(row) else { return nil }
    return lines[row].first(where: { $0.commentKey != nil })?.commentKey
  }

  public func location(at row: Int, side: InlineComment.Side) -> SourceLocation? {
    guard let diff, diff.rows.indices.contains(row), let line = diff.rows[row].line(on: side) else { return nil }
    return .init(path: diff.rows[row].path ?? diff.path, line: line.number, side: side)
  }

  public func sourceSide(at row: Int, preferred: InlineComment.Side) -> InlineComment.Side? {
    guard let diff, diff.rows.indices.contains(row) else { return nil }
    if diff.rows[row].line(on: preferred) != nil {
      return preferred
    }
    let other: InlineComment.Side = preferred == .left ? .right : .left
    return diff.rows[row].line(on: other) == nil ? nil : other
  }

  public func counterpartRow(at row: Int, side: InlineComment.Side) -> Int? {
    guard let diff, diff.rows.indices.contains(row) else { return nil }
    if diff.rows[row].line(on: side) != nil {
      return row
    }
    return counterpartRows[row]
  }

  /// Search immutable source-row indices instead of scanning the diff during input.
  public func diffRow(at row: Int, side: InlineComment.Side?, direction: Int = 0, logical: Bool = false) -> Int? {
    let indices = logical
      ? side.map { $0 == .left ? logicalLeftRows : logicalRightRows } ?? logicalAllRows
      : side.map { $0 == .left ? leftRows : rightRows } ?? allSourceRows
    guard !indices.isEmpty else { return nil }
    var lower = 0, upper = indices.count
    while lower < upper {
      let middle = lower + (upper - lower) / 2
      if indices[middle] < row {
        lower = middle + 1
      } else {
        upper = middle
      }
    }
    if lower < indices.count, indices[lower] == row {
      return row
    }
    let before = lower > 0 ? indices[lower - 1] : nil
    let after = lower < indices.count ? indices[lower] : nil
    if direction < 0 {
      return before
    }
    if direction > 0 {
      return after
    }
    guard let before else { return after }
    guard let after else { return before }
    return row - before <= after - row ? before : after
  }
}

/// Prepare both ordered navigation and viewport membership on the search worker.
public struct SearchMatches: Equatable, Sendable, ExpressibleByArrayLiteral {
  public let lines: [Int]
  public let membership: Set<Int>
  public let highlights: [Int: [Range<Int>]]
  public let sides: [InlineComment.Side?]
  public let ranges: [Range<Int>?]
  public let sourceRanges: [Range<Int>?]

  public init(
    lines: [Int],
    highlights: [Int: [Range<Int>]] = [:],
    sides: [InlineComment.Side?] = [],
    ranges: [Range<Int>?] = [],
    sourceRanges: [Range<Int>?] = [],
  ) {
    self.lines = lines
    self.highlights = highlights
    self.sides = sides
    self.ranges = ranges
    self.sourceRanges = sourceRanges
    membership = Set(lines)
  }

  public init(arrayLiteral elements: Int...) {
    self.init(lines: elements)
  }
}

public struct PaneSearch: Equatable, Sendable {
  public var query = ""
  public var isEditing = false
  public var result: SearchMatches = []
  public var matches: [Int] {
    get { result.lines }
    set { result = .init(lines: newValue) }
  }

  public var matchingLines: Set<Int> {
    result.membership
  }

  public var origin = 0
  public var originSide: InlineComment.Side?
  public var originColumn: Int?
  public var direction = 1
  public var selection = 0
  public init() {}
  public var isActive: Bool {
    isEditing || !query.isEmpty
  }
}

/// A case-sensitive regular expression, with explicit (?i) for insensitive matching.
/// Progress callbacks allow cancellation during expensive matching, not only between lines.
public struct SearchPattern: Sendable {
  public struct WordQuery: Equatable, Sendable {
    public let pattern: String
    public let range: Range<Int>
  }

  /// The line cursor starts at column zero; a search hit retains its source offset.
  /// Extraction runs with the search worker, including for very long source lines.
  @concurrent
  public static func word(in spans: [DiffSpan], column: Int, whole: Bool) async throws -> WordQuery? {
    try Task.checkCancellation()
    let text = spans.map(\.text).joined()
    let keywords = try SearchPattern(#"\w+"#).ranges(in: text)
    let range: Range<Int>
    let keyword: Bool
    if let found = keywords.first(where: { $0.upperBound > column }) {
      range = found
      keyword = true
    } else if let found = try SearchPattern(#"\S+"#).ranges(in: text).first(where: { $0.upperBound > column }) {
      range = found
      keyword = false
    } else {
      return nil
    }
    try Task.checkCancellation()
    let value = (text as NSString).substring(with: NSRange(range))
    let literal = NSRegularExpression.escapedPattern(for: value)
    return WordQuery(pattern: whole && keyword ? #"(?<!\w)"# + literal + #"(?!\w)"# : literal, range: range)
  }

  private let expression: NSRegularExpression
  public init(_ query: String) throws {
    do { expression = try NSRegularExpression(pattern: query) }
    catch { throw TataraError(.invalidResponse, detail: "Invalid search expression: \(error.localizedDescription)") }
  }

  public func ranges(in text: String) throws -> [Range<Int>] {
    var result: [Range<Int>] = [], exceededLimit = false
    expression.enumerateMatches(in: text, options: [.reportProgress], range: NSRange(
      text.startIndex...,
      in: text,
    )) { match, _, stop in
      if Task.isCancelled {
        stop.pointee = true
        return
      }
      if let match {
        if result.count >= 100_000 {
          exceededLimit = true
          stop.pointee = true
          return
        }
        result.append(match.range.location ..< match.range.location + match.range.length)
      }
    }
    try Task.checkCancellation()
    guard !exceededLimit else { throw TataraError(
      .invalidResponse,
      detail: "Search exceeds 100,000 matches; narrow the expression.",
    ) }
    return result
  }

  public func contains(in text: String) throws -> Bool {
    var found = false
    expression.enumerateMatches(in: text, options: [.reportProgress], range: NSRange(
      text.startIndex...,
      in: text,
    )) { match, _, stop in
      if Task.isCancelled {
        stop.pointee = true
        return
      }
      if match != nil {
        found = true
        stop.pointee = true
      }
    }
    try Task.checkCancellation()
    return found
  }
}
