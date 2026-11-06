// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Search projections preserve the complete list and its stable row identities.
public struct ListSearchResults: Equatable, Sendable {

  // MARK: Lifecycle

  public init(ids: [String] = [], rows: [Int] = [], highlights: [String: [[Range<Int>]]] = [:]) {
    self.ids = ids
    self.rows = rows
    self.highlights = highlights
    indices = Dictionary(ids.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
  }

  // MARK: Public

  public let ids: [String]
  public let rows: [Int]
  public let highlights: [String: [[Range<Int>]]]

  @concurrent
  public static func find(_ entries: [(id: String, fields: [String])], query: String) async throws -> Self {
    let pattern = try SearchPattern(query)
    var ids = [String]()
    var rows = [Int]()
    var highlights = [String: [[Range<Int>]]]()
    for (index, entry) in entries.enumerated() {
      try Task.checkCancellation()
      let ranges = try entry.fields.map { try pattern.ranges(in: $0) }
      if ranges.contains(where: { !$0.isEmpty }) {
        ids.append(entry.id)
        rows.append(index)
        highlights[entry.id] = ranges
      }
    }
    return .init(ids: ids, rows: rows, highlights: highlights)
  }

  public func index(for id: String) -> Int? {
    indices[id]
  }

  public func next(from row: Int, direction: Int) -> Int? {
    guard !rows.isEmpty else { return nil }
    var low = 0
    var high = rows.count
    while low < high {
      let middle = (low + high) / 2
      if direction > 0 ? rows[middle] <= row : rows[middle] < row {
        low = middle + 1
      } else {
        high = middle
      }
    }
    return direction > 0 ? low % rows.count : (low + rows.count - 1) % rows.count
  }

  // MARK: Private

  private let indices: [String: Int]

}
