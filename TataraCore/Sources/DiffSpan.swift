// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

public struct DiffSpan: Equatable, Codable, Sendable {
  public var text: String
  public var color: Int?
  public var bold: Bool
  public var side: InlineComment.Side?
  public init(text: String, color: Int? = nil, bold: Bool = false, side: InlineComment.Side? = nil) {
    self.text = text
    self.color = color
    self.bold = bold
    self.side = side
  }
}
