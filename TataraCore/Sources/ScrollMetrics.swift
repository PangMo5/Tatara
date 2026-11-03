// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

public struct ScrollMetrics: Equatable, Sendable {

  // MARK: Lifecycle

  public init(total: Int, page: Int, offset: Int, track: Int) {
    self.total = max(0, total)
    self.page = max(1, page)
    self.track = max(1, track)
    self.offset = min(max(0, total - max(1, page)), max(0, offset))
  }

  // MARK: Public

  public let total: Int
  public let page: Int
  public let offset: Int
  public let track: Int

  public var isScrollable: Bool {
    total > page
  }

  public var thumbLength: Int {
    let maximum = isScrollable ? max(1, track - 1) : track
    return min(maximum, max(1, Int((Double(page) / Double(max(1, total)) * Double(track)).rounded())))
  }

  public var thumbStart: Int {
    guard isScrollable else { return 0 }
    return Int((Double(offset) / Double(total - page) * Double(track - thumbLength)).rounded())
  }

  /// Keep neighboring entries visible around a selection, including in short panes.
  public static func selectionOffset(selected: Int, total: Int, page: Int, previous: Int = 0) -> Int {
    let page = max(1, page)
    let context = min(2, max(0, (page - 1) / 2))
    let selected = min(max(0, total - 1), max(0, selected))
    let maximum = max(0, total - page)
    let previous = min(maximum, max(0, previous))
    if selected < previous + context {
      return max(0, selected - context)
    }
    if selected >= previous + page - context {
      return min(maximum, selected - page + 1 + context)
    }
    return previous
  }

  public func offset(at row: Double) -> Int {
    let available = track - thumbLength
    guard available > 0, isScrollable else { return 0 }
    let fraction = min(1, max(0, (row - Double(thumbLength) / 2) / Double(available)))
    return Int((fraction * Double(total - page)).rounded())
  }

}
