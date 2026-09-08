// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TataraCore
import TOML

public enum Configuration {
  private struct FileConfiguration: Decodable {
    var theme: Theme?
    var language: Language?
    var keys: [String: [String]]?
    var filesView: FilesView?
    private struct Key: CodingKey {
      var stringValue: String
      var intValue: Int? {
        nil
      }

      init?(stringValue: String) {
        self.stringValue = stringValue
      }

      init?(intValue _: Int) {
        nil
      }
    }

    private enum CodingKeys: String, CodingKey { case theme, language, keys
      case filesView = "files_view"
    }

    init(from decoder: any Decoder) throws {
      let all = try decoder.container(keyedBy: Key.self)
      let unknown = all.allKeys.map(\.stringValue).filter { !["theme", "language", "keys", "files_view"].contains($0) }
      guard unknown.isEmpty else { throw TataraError(
        .configuration,
        detail: "Unknown configuration keys: \(unknown.sorted().joined(separator: ", "))",
      ) }
      let container = try decoder.container(keyedBy: CodingKeys.self)
      theme = try container.decodeIfPresent(Theme.self, forKey: .theme)
      language = try container.decodeIfPresent(Language.self, forKey: .language)
      keys = try container.decodeIfPresent([String: [String]].self, forKey: .keys)
      filesView = try container.decodeIfPresent(FilesView.self, forKey: .filesView)
    }
  }

  public static func load(
    path: String? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment,
  ) throws -> Preferences {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let config = path ?? "\(environment["XDG_CONFIG_HOME"] ?? "\(home)/.config")/tatara/config.toml"
    let language = [environment["LC_ALL"], environment["LC_MESSAGES"], environment["LANG"], Locale.preferredLanguages.first]
      .compactMap(\.self).first { !$0.isEmpty } ?? "en"
    var preferences = Preferences(language: Language.resolve(language))
    guard FileManager.default.fileExists(atPath: config) else {
      if path != nil {
        throw TataraError(.configuration, detail: "Configuration file does not exist: \(config)")
      }
      return preferences
    }
    do {
      let value = try TOMLDecoder().decode(FileConfiguration.self, from: String(contentsOfFile: config, encoding: .utf8))
      preferences.theme = value.theme ?? preferences.theme
      preferences.language = value.language ?? preferences.language
      preferences.keymap = try Keymap(overrides: value.keys ?? [:])
      preferences.filesView = value.filesView ?? preferences.filesView
      return preferences
    } catch { throw TataraError(.configuration, detail: String(describing: error)) }
  }
}
