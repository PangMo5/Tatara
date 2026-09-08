// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

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
