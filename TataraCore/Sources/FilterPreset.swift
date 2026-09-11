// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

public struct FilterPreset: Codable, Equatable, Sendable, Identifiable {
  public var id: String
  public var name: String
  public var query: String
  public var isBuiltIn: Bool {
    id.hasPrefix("builtin:")
  }

  public init(id: String, name: String, query: String) {
    self.id = id
    self.name = name
    self.query = query
  }

  public static func defaults(for kind: ItemKind) -> [Self] {
    let common: [Self] = [
      .init(id: "builtin:open", name: "Open", query: "is:open"),
      .init(id: "builtin:closed", name: "Closed", query: "is:closed"),
      .init(id: "builtin:author", name: "Authored by me", query: "is:open author:@me"),
      .init(id: "builtin:assigned", name: "Assigned to me", query: "is:open assignee:@me"),
    ]
    return common + (kind == .pullRequest ? [
      .init(id: "builtin:review", name: "Review requested", query: "is:open review-requested:@me"),
      .init(id: "builtin:drafts", name: "Draft pull requests", query: "is:open draft:true"),
      .init(id: "builtin:merged", name: "Merged", query: "is:merged"),
    ] : [])
  }
}

/// Quoted label qualifiers preserve spaces and escapes when toggled from the picker.
public enum LabelQuery {
  public static func contains(_ label: String, in query: String) -> Bool {
    tokens(query).contains { $0.raw.hasPrefix("label:") && $0.decoded == "label:" + label }
  }

  public static func toggling(_ label: String, in query: String) -> String {
    let words = tokens(query)
    if contains(label, in: query) {
      return words.filter { !($0.raw.hasPrefix("label:") && $0.decoded == "label:" + label) }.map(\.raw).joined(separator: " ")
    }
    let escaped = label.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    return (words.map(\.raw) + ["label:\"\(escaped)\""]).joined(separator: " ")
  }

  private static func tokens(_ query: String) -> [(raw: String, decoded: String)] {
    var words: [(raw: String, decoded: String)] = [], raw = "", decoded = "", quoted = false, escaped = false
    for character in query {
      if character.isWhitespace, !quoted, !escaped {
        if !raw.isEmpty {
          words.append((raw, decoded))
          raw = ""
          decoded = ""
        }
        continue
      }
      raw.append(character)
      if escaped {
        decoded.append(character)
        escaped = false
      } else if character == "\\" {
        escaped = true
      } else if character == "\"" {
        quoted.toggle()
      } else {
        decoded.append(character)
      }
    }
    if !raw.isEmpty {
      words.append((raw, decoded))
    }
    return words
  }
}
