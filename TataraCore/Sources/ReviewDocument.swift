// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

public struct ReviewDocument: Equatable, Sendable {
  public let lines: [[DiffSpan]]
  public let displayLines: [[DiffSpan]]
  public let searchableLines: [String]
  public let diff: ReviewDiff?
  public let diffSideWidth: Int
  public let diffNumberWidth: Int

  public init(lines: [[DiffSpan]] = []) {
    self.init(lines: lines, checkingCancellation: {})
  }

  public init(
    lines: [[DiffSpan]],
    displayLines: [[DiffSpan]]? = nil,
    diff: ReviewDiff? = nil,
    diffSideWidth: Int = 0,
    diffNumberWidth: Int = 0,
    checkingCancellation: () throws -> Void,
  ) rethrows {
    self.lines = lines
    self.displayLines = displayLines ?? lines
    self.diff = diff
    self.diffSideWidth = diffSideWidth
    self.diffNumberWidth = diffNumberWidth
    precondition(self.displayLines.count == lines.count, "Display rows must preserve source row indices.")
    var indexLines: [String] = []
    indexLines.reserveCapacity(lines.count)
    for (index, line) in lines.enumerated() {
      if index % 128 == 0 {
        try checkingCancellation()
      }
      indexLines.append(Self.fold(line.map(\.text).joined()))
    }
    searchableLines = indexLines
  }

  public static func fold(_ text: String) -> String {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
  }
}

public struct PaneSearch: Equatable, Sendable {
  public var query = ""
  public var isEditing = false
  public var matches: [Int] = [] {
    didSet { matchingLines = Set(matches) }
  }

  public private(set) var matchingLines: Set<Int> = []
  public var selection = 0
  public init() {}
  public var isActive: Bool {
    isEditing || !query.isEmpty
  }
}
