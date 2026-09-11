// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

public struct SourceLocation: Hashable, Sendable {
  public let path: String
  public let line: Int
  public let side: InlineComment.Side
  public init(path: String, line: Int, side: InlineComment.Side) {
    self.path = path
    self.line = line
    self.side = side
  }
}

public struct ReviewDocument: Equatable, Sendable {
  public let lines: [[DiffSpan]]
  public let displayLines: [[DiffSpan]]
  public let searchableLines: [String]
  public let diff: ReviewDiff?
  public let diffSideWidth: Int
  public let horizontalOffset: Int
  public let visibleDiffSide: InlineComment.Side?
  public let diffNumberWidth: Int
  private let sourceRows: [SourceLocation: Int]
  private let leftRows: [Int]
  private let rightRows: [Int]

  public init(lines: [[DiffSpan]] = []) {
    self.init(lines: lines, checkingCancellation: {})
  }

  public init(
    lines: [[DiffSpan]],
    displayLines: [[DiffSpan]]? = nil,
    diff: ReviewDiff? = nil,
    diffSideWidth: Int = 0,
    diffNumberWidth: Int = 0,
    visibleDiffSide: InlineComment.Side? = nil,
    horizontalOffset: Int = 0,
    checkingCancellation: () throws -> Void,
  ) rethrows {
    self.lines = lines
    self.displayLines = displayLines ?? lines
    self.diff = diff
    self.diffSideWidth = diffSideWidth
    self.diffNumberWidth = diffNumberWidth
    self.visibleDiffSide = visibleDiffSide
    self.horizontalOffset = horizontalOffset
    precondition(self.displayLines.count == lines.count, "Display rows must preserve source row indices.")
    var indexLines: [String] = []
    var left: [Int] = [], right: [Int] = []
    var sourceRows: [SourceLocation: Int] = [:]
    indexLines.reserveCapacity(lines.count)
    for (index, line) in lines.enumerated() {
      if index % 128 == 0 {
        try checkingCancellation()
      }
      indexLines.append(line.map(\.text).joined())
      if let diff, diff.rows.indices.contains(index) {
        for side in InlineComment.Side.allCases {
          if let source = diff.rows[index].line(on: side) {
            sourceRows[.init(path: diff.rows[index].path ?? diff.path, line: source.number, side: side)] = index
          }
        }
        if diff.rows[index].left != nil {
          left.append(index)
        }
        if diff.rows[index].right != nil {
          right.append(index)
        }
      }
    }
    searchableLines = indexLines
    self.sourceRows = sourceRows
    leftRows = left
    rightRows = right
  }

  public func row(for location: SourceLocation) -> Int? {
    sourceRows[location]
  }

  public func location(at row: Int, side: InlineComment.Side) -> SourceLocation? {
    guard let diff, diff.rows.indices.contains(row), let line = diff.rows[row].line(on: side) else { return nil }
    return .init(path: diff.rows[row].path ?? diff.path, line: line.number, side: side)
  }

  /// Search immutable source-row indices instead of scanning the diff during input.
  public func diffRow(at row: Int, side: InlineComment.Side, direction: Int = 0) -> Int? {
    let indices = side == .left ? leftRows : rightRows
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
