// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

public struct InlineComment: Equatable, Codable, Sendable {
  public enum Side: String, Codable, CaseIterable, Sendable { case left = "LEFT", right = "RIGHT" }
  public var path: String
  public var line: Int
  public var side: Side
  public var body: String
  public init(path: String, line: Int, side: Side, body: String) {
    self.path = path
    self.line = line
    self.side = side
    self.body = body
  }
}

/// GitHub anchors are source coordinates from its patch, never difftastic screen coordinates.
public enum ReviewAnchor {
  public static func contains(line: Int, side: InlineComment.Side, patch: String?) -> Bool {
    guard line > 0, let patch else { return false }
    var old = 0
    var new = 0
    var inHunk = false
    for row in patch.components(separatedBy: "\n") {
      if row.hasPrefix("@@ ") {
        let parts = row.split(separator: " ")
        guard parts.count >= 4, parts[1].hasPrefix("-"), parts[2].hasPrefix("+"),
              let beforeToken = parts[1].dropFirst().split(separator: ",").first,
              let afterToken = parts[2].dropFirst().split(separator: ",").first,
              let before = Int(beforeToken), let after = Int(afterToken)
        else { inHunk = false
          continue
        }
        old = before
        new = after
        inHunk = true
        continue
      }
      guard inHunk, let prefix = row.first else { continue }
      switch prefix {
      case " ":
        if (side == .left ? old : new) == line {
          return true
        }
        old += 1
        new += 1
      case "-":
        if side == .left, old == line {
          return true
        }
        old += 1
      case "+":
        if side == .right, new == line {
          return true
        }
        new += 1
      default: break
      }
    }
    return false
  }
}
