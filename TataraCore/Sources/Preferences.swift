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
  case previousTab, nextTab, markReviewed, openBrowser, itemsPane, filesPane, contentPane

  public var defaultKeys: [String] {
    switch self {
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
    case .itemsPane: ["1"]
    case .filesPane: ["2"]
    case .contentPane: ["3"]
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
      return key != "g" && key.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }
    return [
      "gg",
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
    ].contains(key)
  }
}

public struct Preferences: Equatable, Sendable {
  public var theme: Theme
  public var language: Language
  public var keymap: Keymap
  public init(theme: Theme = .mocha, language: Language = .english, keymap: Keymap = .standard) {
    self.theme = theme
    self.language = language
    self.keymap = keymap
  }
}

/// Remote text never controls the terminal. Preserve text, tabs and line feeds only.
public enum TerminalText {
  public static func sanitize(_ value: String) -> String {
    String(String.UnicodeScalarView(value.unicodeScalars.filter {
      $0 == "\n" || $0 == "\t" || (!CharacterSet.controlCharacters.contains($0) && $0.value != 0x7F)
    }))
  }
}
