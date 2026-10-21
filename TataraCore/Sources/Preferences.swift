// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

public enum Theme: String, CaseIterable, Codable, Sendable {
  case latte, frappe, macchiato, mocha
  public var isLight: Bool {
    self == .latte
  }

  public var next: Self {
    switch self {
    case .latte: .frappe
    case .frappe: .macchiato
    case .macchiato: .mocha
    case .mocha: .latte
    }
  }
}

public enum Language: String, CaseIterable, Codable, Sendable {
  case english = "en", korean = "ko", japanese = "ja", simplifiedChinese = "zh-Hans", traditionalChinese = "zh-Hant"
  public static func resolve(_ identifier: String) -> Self {
    let tag = identifier.replacingOccurrences(of: "_", with: "-").lowercased()
    if tag.hasPrefix("ko") {
      return .korean
    }
    if tag.hasPrefix("ja") {
      return .japanese
    }
    if tag.hasPrefix("zh") {
      return tag.contains("hant") || tag.contains("tw") || tag.contains("hk") ? .traditionalChinese : .simplifiedChinese
    }
    return .english
  }
}

public enum KeyCommand: String, Codable, CaseIterable, Sendable {
  case down, up, left, right, nextPane, previousPane, first, last, halfPageDown, halfPageUp
  case open, back, refresh, search, nextMatch, previousMatch, toggleKind, loadMore, review, comment, theme, help, quit
  case previousTab, nextTab, markReviewed, openBrowser
  case contentPageDown, contentPageUp
  case selectLines, filters
  case searchWordForward, searchWordBackward, searchPartialWordForward, searchPartialWordBackward
  case cursorToTop, cursorToCenter, cursorToBottom
  case pickItem, toggleWrap, scrollLeft, scrollRight, scrollFarLeft, scrollFarRight, scrollStart, visualDown, visualUp
  case focusComments, nextComment, previousComment, editComment, deleteComment, reactComment, resolveComment, copyComment

  public var defaultKeys: [String] {
    switch self {
    case .pickItem: ["ctrl-p"]
    case .toggleWrap: ["w"]
    case .scrollLeft: ["zh"]
    case .scrollRight: ["zl"]
    case .scrollFarLeft: ["zH"]
    case .scrollFarRight: ["zL"]
    case .scrollStart: ["z0"]
    case .visualDown: ["gj"]
    case .visualUp: ["gk"]
    case .focusComments: ["gc"]
    case .nextComment: ["}"]
    case .previousComment: ["{"]
    case .editComment: ["e"]
    case .deleteComment: ["D"]
    case .reactComment: ["a"]
    case .resolveComment: ["s"]
    case .copyComment: ["y"]
    case .selectLines: ["V"]
    case .filters: ["f"]
    case .searchWordForward: ["*"]
    case .searchWordBackward: ["#"]
    case .searchPartialWordForward: ["g*"]
    case .searchPartialWordBackward: ["g#"]
    case .cursorToTop: ["zt"]
    case .cursorToCenter: ["zz"]
    case .cursorToBottom: ["zb"]
    case .down: ["j", "down"]
    case .up: ["k", "up"]
    case .left: ["h", "left"]
    case .right: ["l", "right"]
    case .nextPane: ["tab"]
    case .previousPane: ["shift-tab"]
    case .first: ["gg", "home"]
    case .last: ["G", "end"]
    case .halfPageDown: ["ctrl-d", "page-down"]
    case .halfPageUp: ["ctrl-u", "page-up"]
    case .contentPageDown: ["ctrl-f"]
    case .contentPageUp: ["ctrl-b"]
    case .open: ["enter"]
    case .back: ["esc"]
    case .refresh: ["r"]
    case .search: ["/"]
    case .nextMatch: ["n"]
    case .previousMatch: ["N"]
    case .toggleKind: ["I"]
    case .loadMore: ["L"]
    case .review: ["R"]
    case .comment: ["c"]
    case .previousTab: ["["]
    case .nextTab: ["]"]
    case .markReviewed: ["space"]
    case .openBrowser: ["o"]
    case .theme: ["T"]
    case .help: ["?"]
    case .quit: ["q"]
    }
  }
}

public struct Keymap: Equatable, Sendable {
  public var bindings: [KeyCommand: [String]]
  public init(overrides: [String: [String]] = [:]) throws {
    var result = Dictionary(uniqueKeysWithValues: KeyCommand.allCases.map { ($0, $0.defaultKeys) })
    for (name, keys) in overrides {
      guard let command = KeyCommand(rawValue: name), !keys.isEmpty,
            keys.allSatisfy(Self.isValid)
      else { throw TataraError(.configuration, detail: "Invalid key binding: \(name)") }
      result[command] = keys
    }
    var used = Set<String>()
    for keys in result.values {
      for key in keys where !used.insert(key).inserted {
        throw TataraError(.configuration, detail: "Duplicate key binding: \(key)")
      }
    }
    bindings = result
  }

  public static let standard = Self(bindings: Dictionary(uniqueKeysWithValues: KeyCommand.allCases.map { ($0, $0.defaultKeys) }))
  private init(bindings: [KeyCommand: [String]]) {
    self.bindings = bindings
  }

  public func command(for key: String) -> KeyCommand? {
    bindings.first { $0.value.contains(key) }?.key
  }

  private static func isValid(_ key: String) -> Bool {
    if key.count == 1 {
      return key != "g" && key != "z" && key.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }
    return [
      "gg",
      "g*", "g#", "zt", "zz", "zb", "zh", "zl", "zH", "zL", "z0", "gj", "gk", "gc", "ctrl-p",
      "space",
      "up",
      "down",
      "left",
      "right",
      "tab",
      "shift-tab",
      "enter",
      "esc",
      "home",
      "end",
      "page-up",
      "page-down",
      "ctrl-d",
      "ctrl-u",
      "ctrl-f",
      "ctrl-b",
    ].contains(key)
  }
}

public extension KeyCommand {
  var titleKey: String {
    switch self {
    case .pickItem: "Switch pull request"
    case .toggleWrap: "Toggle line wrapping"
    case .scrollLeft: "Scroll left"
    case .scrollRight: "Scroll right"
    case .scrollFarLeft: "Scroll half screen left"
    case .scrollFarRight: "Scroll half screen right"
    case .scrollStart: "Scroll to line start"
    case .visualDown: "Next display line"
    case .visualUp: "Previous display line"
    case .focusComments: "Focus comments / source"
    case .nextComment: "Next comment"
    case .previousComment: "Previous comment"
    case .editComment: "Edit comment"
    case .deleteComment: "Delete comment"
    case .reactComment: "React to comment"
    case .resolveComment: "Resolve / reopen thread"
    case .copyComment: "Copy comment"
    case .selectLines: "Select lines"
    case .filters: "Filters and presets"
    case .searchWordForward: "Search word forward"
    case .searchWordBackward: "Search word backward"
    case .searchPartialWordForward: "Search partial word forward"
    case .searchPartialWordBackward: "Search partial word backward"
    case .cursorToTop: "Current line to top"
    case .cursorToCenter: "Current line to center"
    case .cursorToBottom: "Current line to bottom"
    case .down: "Move down"
    case .up: "Move up"
    case .left: "Collapse folder"
    case .previousPane: "Previous pane"
    case .right: "Expand folder"
    case .nextPane: "Next pane"
    case .first: "First"
    case .last: "Last"
    case .halfPageDown: "Half page down"
    case .halfPageUp: "Half page up"
    case .contentPageDown: "Page down in content"
    case .contentPageUp: "Page up in content"
    case .open: "Open"
    case .back: "Back"
    case .refresh: "Refresh"
    case .search: "Search"
    case .nextMatch: "Next match"
    case .previousMatch: "Previous match"
    case .toggleKind: "Switch PRs / issues"
    case .loadMore: "Load more"
    case .review: "Write your review"
    case .comment: "Comment"
    case .theme: "Theme"
    case .help: "Help"
    case .quit: "Quit"
    case .nextTab: "Next tab"
    case .previousTab: "Previous tab"
    case .markReviewed: "Mark reviewed"
    case .openBrowser: "Open in browser"
    }
  }
}

public struct Preferences: Equatable, Sendable {
  public static let defaultSidebarWidth = 52
  public var theme: Theme
  public var language: Language
  public var keymap: Keymap
  public var filesView: FilesView
  public var wrap: Bool
  public var sidebarWidth: Int
  public init(
    theme: Theme = .mocha,
    language: Language = .english,
    keymap: Keymap = .standard,
    filesView: FilesView = .tree,
    sidebarWidth: Int = Self.defaultSidebarWidth,
    wrap: Bool = true,
  ) {
    self.theme = theme
    self.language = language
    self.keymap = keymap
    self.filesView = filesView
    self.sidebarWidth = sidebarWidth
    self.wrap = wrap
  }
}

/// Remote text never controls the terminal. Preserve text, tabs and line feeds only.
public enum TerminalText {
  public static func sanitize(_ value: String) -> String {
    String(String.UnicodeScalarView(value.unicodeScalars.filter {
      $0 == "\n" || $0 == "\t" || ($0.value >= 0x20 && !(0x7F ... 0x9F).contains($0.value))
    }))
  }
}
