// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

public struct InlineComment: Equatable, Codable, Sendable {
  public enum Side: String, Codable, CaseIterable, Sendable { case left = "LEFT", right = "RIGHT" }
  public var path: String
  public var line: Int
  public var side: Side
  public var body: String
  public var startLine: Int?
  public var startSide: Side?
  public init(path: String, line: Int, side: Side, body: String, startLine: Int? = nil) {
    self.path = path
    self.line = line
    self.side = side
    self.body = body
    self.startLine = startLine
    startSide = startLine == nil ? nil : side
  }

  enum CodingKeys: String, CodingKey { case path, line, side, body
    case startLine = "start_line", startSide = "start_side"
  }
}

/// GitHub anchors are source coordinates from its patch, never difftastic screen coordinates.
public enum ReviewAnchor {
  public static func contains(line: Int, side: InlineComment.Side, patch: String?) -> Bool {
    guard line > 0 else { return false }
    return contains(range: line ... line, side: side, patch: patch)
  }

  public static func contains(range: ClosedRange<Int>, side: InlineComment.Side, patch: String?) -> Bool {
    ReviewAnchorIndex(patch: patch).contains(range: range, side: side)
  }
}

/// Build once with a changed-file snapshot; querying a review range is logarithmic.
public struct ReviewAnchorIndex: Equatable, Sendable {
  private let left: [ClosedRange<Int>]
  private let right: [ClosedRange<Int>]

  public init(patch: String?) {
    var old = 0, new = 0
    var active = false
    var oldLower: Int?, oldUpper: Int?, newLower: Int?, newUpper: Int?
    var left: [ClosedRange<Int>] = [], right: [ClosedRange<Int>] = []
    func finish() {
      if let oldLower, let oldUpper {
        left.append(oldLower ... oldUpper)
      }
      if let newLower, let newUpper {
        right.append(newLower ... newUpper)
      }
    }
    for row in (patch ?? "").split(separator: "\n", omittingEmptySubsequences: false) {
      if row.hasPrefix("@@ ") {
        finish()
        oldLower = nil
        oldUpper = nil
        newLower = nil
        newUpper = nil
        active = false
        let parts = row.split(separator: " ")
        guard parts.count >= 4, parts[1].hasPrefix("-"), parts[2].hasPrefix("+"),
              let beforeToken = parts[1].dropFirst().split(separator: ",").first,
              let afterToken = parts[2].dropFirst().split(separator: ",").first,
              let before = Int(beforeToken), let after = Int(afterToken),
              before >= 0, after >= 0 else { continue }
        old = before
        new = after
        active = true
        continue
      }
      guard active else { continue }
      if row.first == " " || row.first == "-" {
        if old > 0 {
          oldLower = oldLower ?? old
          oldUpper = old
        }
        if old < Int.max {
          old += 1
        } else {
          active = false
        }
      }
      if row.first == " " || row.first == "+" {
        if new > 0 {
          newLower = newLower ?? new
          newUpper = new
        }
        if new < Int.max {
          new += 1
        } else {
          active = false
        }
      }
    }
    finish()
    /// Prefix maxima preserve containment even for overlapping or unordered hunks.
    func indexed(_ ranges: [ClosedRange<Int>]) -> [ClosedRange<Int>] {
      var maximum = 0
      return ranges.sorted { $0.lowerBound < $1.lowerBound }.map {
        maximum = max(maximum, $0.upperBound)
        return $0.lowerBound ... maximum
      }
    }
    self.left = indexed(left)
    self.right = indexed(right)
  }

  public func contains(range: ClosedRange<Int>, side: InlineComment.Side) -> Bool {
    guard range.lowerBound > 0 else { return false }
    let hunks = side == .left ? left : right
    var lower = 0, upper = hunks.count
    while lower < upper {
      let middle = lower + (upper - lower) / 2
      if hunks[middle].lowerBound <= range.lowerBound {
        lower = middle + 1
      } else {
        upper = middle
      }
    }
    return lower > 0 && hunks[lower - 1].upperBound >= range.upperBound
  }
}
