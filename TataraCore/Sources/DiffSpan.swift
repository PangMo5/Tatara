// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

public enum DiffRole: String, Codable, Sendable {
  case metadata, filePath, hunkHeader, diffHeader, comment, added, removed
  case commentBody, commentCode, commentEmphasis, commentLink, commentQuote, commentStrikethrough, commentGap

  public var isComment: Bool {
    switch self {
    case .comment, .commentBody, .commentCode, .commentEmphasis, .commentLink, .commentQuote, .commentStrikethrough: true
    default: false
    }
  }
}

public struct DiffSpan: Equatable, Codable, Sendable {
  public var text: String
  public var color: Int?
  public var bold: Bool
  public var role: DiffRole?
  public var side: InlineComment.Side?
  public init(text: String, color: Int? = nil, bold: Bool = false, side: InlineComment.Side? = nil, role: DiffRole? = nil) {
    self.text = text
    self.color = color
    self.bold = bold
    self.side = side
    self.role = role
  }
}
