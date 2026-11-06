// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

// MARK: - ReviewDiffLine

public struct ReviewDiffLine: Equatable, Codable, Sendable {
  public init(number: Int, spans: [DiffSpan]) {
    self.number = number
    self.spans = spans
  }

  public let number: Int
  public let spans: [DiffSpan]
}

// MARK: - ReviewDiffRow

public struct ReviewDiffRow: Equatable, Codable, Sendable {

  // MARK: Lifecycle

  public init(
    left: ReviewDiffLine?,
    right: ReviewDiffLine?,
    path: String? = nil,
    annotation: [DiffSpan]? = nil,
    annotationLocation: SourceLocation? = nil,
    leftOffset: Int = 0,
    rightOffset: Int = 0,
  ) {
    self.left = left
    self.right = right
    self.path = path
    self.annotation = annotation
    self.annotationLocation = annotationLocation
    self.leftOffset = leftOffset
    self.rightOffset = rightOffset
  }

  // MARK: Public

  public let left: ReviewDiffLine?
  public let right: ReviewDiffLine?
  public let path: String?
  public let annotation: [DiffSpan]?
  /// Placement of a comment, distinct from a source row or a reviewable anchor.
  public let annotationLocation: SourceLocation?
  public let leftOffset: Int
  public let rightOffset: Int

  public func line(on side: InlineComment.Side) -> ReviewDiffLine? {
    side == .left ? left : right
  }

}

// MARK: - ReviewDiff

public struct ReviewDiff: Equatable, Codable, Sendable {

  // MARK: Lifecycle

  public init(
    path: String,
    language: String,
    status: String,
    rows: [ReviewDiffRow],
    revision: PullRequestRevision? = nil,
    previousPath: String? = nil,
    cacheIdentity: String? = nil,
  ) {
    self.path = path
    self.language = language
    self.status = status
    self.rows = rows
    self.revision = revision
    self.previousPath = previousPath
    self.cacheIdentity = cacheIdentity
  }

  // MARK: Public

  public let path: String
  public let language: String
  public let status: String
  public let rows: [ReviewDiffRow]
  public let revision: PullRequestRevision?
  public let previousPath: String?
  /// Names immutable forge revisions and diff-engine options; supplied by the live producer.
  public let cacheIdentity: String?

  /// Difftastic owns alignment and token changes. Coordinates are never recovered from ANSI columns.
  public static func decode(
    _ data: Data,
    before: String,
    after: String,
    path: String,
    context: Int = 3,
    revealing: SourceLocation? = nil,
  ) throws -> Self {
    try Task.checkCancellation()
    struct Change: Decodable { let start: Int
      let end: Int
      let content: String
      let highlight: String
    }
    struct Side: Decodable { let line_number: Int
      let changes: [Change]
    }
    struct Row: Decodable { let lhs: Side?
      let rhs: Side?
    }
    struct File: Decodable { let aligned_lines: [[Int?]]?
      let chunks: [[Row]]?
      let language: String
      let status: String
    }
    let file = try JSONDecoder().decode(File.self, from: data)
    func sourceLines(_ source: String) -> [String] {
      guard !source.isEmpty else { return [] }
      var lines = source.components(separatedBy: "\n")
      if source.hasSuffix("\n") {
        lines.removeLast()
      }
      return lines
    }
    let left = sourceLines(before)
    let right = sourceLines(after)
    if let revealing {
      let count = revealing.side == .left ? left.count : right.count
      guard revealing.path == path, revealing.line > 0, revealing.line <= count else {
        throw TataraError(.invalidLine, detail: "Search location is absent from the immutable source.")
      }
    }
    if file.language.lowercased().contains("binary") {
      return .init(
        path: path,
        language: file.language,
        status: file.status,
        rows: [],
      )
    }
    if file.status == "unchanged" {
      guard let revealing else { return .init(path: path, language: file.language, status: file.status, rows: []) }
      guard before == after
      else { throw TataraError(.invalidResponse, detail: "Unchanged diff disagrees with immutable source.") }
      let range = max(0, revealing.line - 1 - context) ..< min(right.count, revealing.line + context)
      let rows = range.map { index in
        let line = ReviewDiffLine(number: index + 1, spans: [.init(text: right[index])])
        return ReviewDiffRow(left: line, right: line)
      }
      return .init(path: path, language: file.language, status: file.status, rows: rows)
    }
    if file.status == "created" || file.status == "deleted" {
      let created = file.status == "created"
      let source = created ? right : left
      return .init(path: path, language: file.language, status: file.status, rows: source.enumerated().map {
        let line = ReviewDiffLine(number: $0.offset + 1, spans: [.init(text: $0.element, role: created ? .added : .removed)])
        return .init(left: created ? nil : line, right: created ? line : nil)
      })
    }
    guard file.status == "changed", let alignment = file.aligned_lines, let chunks = file.chunks else {
      throw TataraError(.invalidResponse, detail: "Unsupported difftastic JSON schema: missing source alignment.")
    }
    var oldChanges = [Int: [Change]]()
    var newChanges = [Int: [Change]]()
    for chunk in chunks {
      for row in chunk {
        if let side = row.lhs {
          oldChanges[side.line_number, default: []] += side.changes
        }
        if let side = row.rhs {
          newChanges[side.line_number, default: []] += side.changes
        }
      }
    }
    func line(_ number: Int?, source: [String], changes: [Int: [Change]], color: Int) throws -> ReviewDiffLine? {
      guard let number else { return nil }
      // The alignment may include one trailing EOF row; it is not an anchor.
      guard number >= 0, number <= source.count else { throw TataraError(
        .invalidResponse,
        detail: "Invalid difftastic line number.",
      ) }
      guard number < source.count else { return nil }
      let text = source[number]
      let bytes = Array(text.utf8)
      var spans = [DiffSpan]()
      var offset = 0
      for change in (changes[number] ?? []).sorted(by: { $0.start < $1.start }) {
        guard
          change.start >= offset,
          change.end >= change.start,
          change.end <= bytes.count,
          String(bytes: bytes[change.start ..< change.end], encoding: .utf8) == change.content
        else {
          throw TataraError(.invalidResponse, detail: "Difftastic token coordinates do not match the immutable source.")
        }
        if offset < change.start {
          spans.append(.init(text: String(decoding: bytes[offset ..< change.start], as: UTF8.self)))
        }
        spans.append(.init(
          text: change.content,
          bold: ["keyword", "type", "delimiter"].contains(change.highlight),
          role: color == 1 ? .removed : .added,
          highlight: change.highlight,
        ))
        offset = change.end
      }
      if offset < bytes.count {
        spans.append(.init(text: String(decoding: bytes[offset...], as: UTF8.self)))
      }
      return .init(number: number + 1, spans: spans)
    }
    var aligned = [ReviewDiffRow]()
    var changed = Set<Int>()
    var previousLeft = -1
    var previousRight = -1
    for pair in alignment {
      try Task.checkCancellation()
      guard pair.count == 2 else { throw TataraError(.invalidResponse, detail: "Invalid difftastic alignment pair.") }
      if let n = pair[0] {
        guard n > previousLeft
        else { throw TataraError(
          .invalidResponse,
          detail: "Non-monotonic left alignment.",
        ) }
        previousLeft = n
      }
      if let n = pair[1] {
        guard n > previousRight
        else { throw TataraError(
          .invalidResponse,
          detail: "Non-monotonic right alignment.",
        ) }
        previousRight = n
      }
      let row = try ReviewDiffRow(
        left: line(pair[0], source: left, changes: oldChanges, color: 1),
        right: line(pair[1], source: right, changes: newChanges, color: 2),
      )
      guard row.left != nil || row.right != nil else { continue }
      if
        pair[0].map({ oldChanges[$0] != nil }) == true || pair[1].map({ newChanges[$0] != nil }) == true || row
          .left == nil || row.right == nil
      {
        changed.insert(aligned.count)
      }
      aligned.append(row)
    }
    var visible = Set<Int>()
    for index in changed {
      for row in max(0, index - context) ..< min(aligned.count, index + context + 1) {
        visible.insert(row)
      }
    }
    if let revealing {
      guard
        revealing.path == path,
        let index = aligned.firstIndex(where: { $0.line(on: revealing.side)?.number == revealing.line })
      else {
        throw TataraError(.invalidLine, detail: "Search location is absent from the immutable diff alignment.")
      }
      visible.formUnion(max(0, index - context) ..< min(aligned.count, index + context + 1))
    }
    var result = [ReviewDiffRow]()
    var last = -2
    for index in visible.sorted() {
      if index > last + 1, !result.isEmpty {
        result.append(.init(left: nil, right: nil))
      }
      result.append(aligned[index])
      last = index
    }
    return .init(path: path, language: file.language, status: file.status, rows: result)
  }

}
