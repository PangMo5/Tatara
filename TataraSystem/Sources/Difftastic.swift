// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TataraCore
import TataraKit

public actor Difftastic {
  private let forge: ForgeClient
  private let runner: CommandRunner
  private var snapshots: [String: Data] = [:]
  private var snapshotBytes = 0
  private var renders: [String: String] = [:]

  public init(forge: ForgeClient, runner: CommandRunner = .live) {
    self.forge = forge
    self.runner = runner
  }

  public nonisolated var client: DiffClient {
    DiffClient(render: { try await self.render($0) })
  }

  public func render(_ request: DiffRequest) async throws -> String {
    let key = "\(request.repository)|\(request.revision.mergeBase)|\(request.revision.head)|\(request.file.path)|\(request.width)|\(request.theme)"
    if let cached = renders[key] {
      return cached
    }
    let file = request.file
    async let old = file.status == "added" ? Data() : content(
      request.repository,
      request.revision.mergeBase,
      file.previousPath ?? file.path,
    )
    async let new = file.status == "removed" ? Data() : content(request.repository, request.revision.head, file.path)
    let (before, after) = try await (old, new)
    try Task.checkCancellation()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tatara-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700],
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    // Never resolve a forge-supplied path on the local filesystem. Only the extension is used for syntax detection.
    let rawExtension = (file.path as NSString).pathExtension
    let ext = rawExtension.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(20)
    let oldURL = directory.appendingPathComponent("before.\(ext)")
    let newURL = directory.appendingPathComponent("after.\(ext)")
    try before.write(to: oldURL)
    try after.write(to: newURL)
    let output = try await runner.checked("difft", [
      "--color", "always", "--background", request.theme.isLight ? "light" : "dark",
      "--display", request.width < 100 ? "inline" : "side-by-side-show-both",
      "--width", String(max(20, request.width)), "--context", "3", "--syntax-highlight", "on",
      "--", oldURL.path, newURL.path,
    ])
    // Retain difftastic's structure and syntax colors. Replace temporary names with source provenance.
    let text = output.text.replacingOccurrences(of: oldURL.path, with: file.previousPath ?? file.path)
      .replacingOccurrences(of: newURL.path, with: file.path)
    try Task.checkCancellation()
    if renders.count >= 24 {
      renders.removeAll(keepingCapacity: true)
    }
    renders[key] = text
    return text
  }

  private func content(_ repository: RepositoryID, _ revision: String, _ path: String) async throws -> Data {
    let key = "\(repository)|\(revision)|\(path)"
    if let value = snapshots[key] {
      return value
    }
    let value = try await forge.content(repository, revision, path)
    try Task.checkCancellation()
    if snapshotBytes + value.count > 32 * 1024 * 1024 {
      snapshots.removeAll(keepingCapacity: true)
      snapshotBytes = 0
    }
    snapshots[key] = value
    snapshotBytes += value.count
    return value
  }
}
