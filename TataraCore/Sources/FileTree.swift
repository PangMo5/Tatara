// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

public enum FilesView: String, Codable, Sendable { case tree, list }

public struct FileTreeRow: Equatable, Sendable, Identifiable {
  public let path: String
  public let name: String
  public let depth: Int
  public let isDirectory: Bool
  public let id: String

  public var parent: String? {
    guard let slash = path.lastIndex(of: "/") else { return nil }
    return "directory:" + path[..<slash]
  }

  public init(path: String, name: String, depth: Int, isDirectory: Bool) {
    self.path = path
    self.name = name
    self.depth = depth
    self.isDirectory = isDirectory
    id = (isDirectory ? "directory:" : "file:") + path
  }
}

public struct FileTree: Equatable, Sendable {
  public let rows: [FileTreeRow]
  public init(paths: [String]) {
    var children: [String: [FileTreeRow]] = [:]
    var directories = Set<String>()
    for path in paths {
      let parts = path.split(separator: "/").map(String.init)
      var parent = ""
      for (depth, name) in parts.enumerated() {
        let current = parent.isEmpty ? name : parent + "/" + name
        let directory = depth < parts.count - 1
        if !directory || directories.insert(current).inserted {
          children[parent, default: []].append(.init(path: current, name: name, depth: depth, isDirectory: directory))
        }
        parent = current
      }
    }
    var ordered: [FileTreeRow] = []
    func append(_ parent: String) {
      for row in (children[parent] ?? []).sorted(by: {
        $0.isDirectory == $1.isDirectory ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : $0.isDirectory
      }) {
        ordered.append(row)
        if row.isDirectory {
          append(row.path)
        }
      }
    }
    append("")
    rows = ordered
  }

  public func visible(collapsed: Set<String>, matching paths: Set<String>? = nil) -> [FileTreeRow] {
    var included = paths ?? []
    if let paths {
      for path in paths {
        var parent = (path as NSString).deletingLastPathComponent
        while !parent.isEmpty, parent != "." {
          included.insert(parent)
          parent = (parent as NSString).deletingLastPathComponent
        }
      }
    }
    var hiddenDepth: Int?
    return rows.filter { row in
      if let depth = hiddenDepth {
        if row.depth > depth {
          return false
        }
        hiddenDepth = nil
      }
      if paths != nil {
        return included.contains(row.path)
      }
      if row.isDirectory, collapsed.contains(row.path) {
        hiddenDepth = row.depth
      }
      return true
    }
  }
}
