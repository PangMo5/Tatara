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
    guard range.lowerBound > 0, let patch else { return false }
    var old = 0, new = 0
    var active = false
    var lower: Int?, upper: Int?
    func matches() -> Bool {
      guard let lower, let upper else { return false }
      return range.lowerBound >= lower && range.upperBound <= upper
    }
    for row in patch.components(separatedBy: "\n") {
      if row.hasPrefix("@@ ") {
        if matches() {
          return true
        }
        lower = nil
        upper = nil
        active = false
        let parts = row.split(separator: " ")
        guard parts.count >= 4,
              parts[1].hasPrefix("-"), parts[2].hasPrefix("+"),
              let beforeToken = parts[1].dropFirst().split(separator: ",").first,
              let afterToken = parts[2].dropFirst().split(separator: ",").first,
              let before = Int(beforeToken), let after = Int(afterToken) else { continue }
        old = before
        new = after
        active = true
        continue
      }
      guard active else { continue }
      var number: Int?
      switch row.first {
      case " ": number = side == .left ? old : new
        old += 1
        new += 1
      case "-": if side == .left {
          number = old
        }
        old += 1
      case "+": if side == .right {
          number = new
        }
        new += 1
      default: break
      }
      if let number, number > 0 {
        lower = lower ?? number
        upper = number
      }
    }
    return matches()
  }
}
