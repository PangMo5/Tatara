// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TataraCore
import TataraKit

public actor Difftastic {
  private let forge: ForgeClient
  private let runner: CommandRunner
  private let cache: CacheClient
  private var engineVersion: String?
  private var snapshots: [String: Data] = [:]
  private var snapshotBytes = 0
  private struct RenderEntry {
    let document: ReviewDiff
    let bytes: Int
    var access: Int
  }

  private var renders: [String: RenderEntry] = [:]
  private var renderBytes = 0
  private var access = 0
  private let settle: @Sendable () async throws -> Void

  public init(
    forge: ForgeClient,
    runner: CommandRunner = .live,
    cache: CacheClient = .disabled,
    settle: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .milliseconds(80)) },
  ) {
    self.forge = forge
    self.runner = runner
    self.cache = cache
    self.settle = settle
  }

  public nonisolated var client: DiffClient {
    DiffClient(render: { try await self.render($0) })
  }

  public func render(_ request: DiffRequest) async throws -> ReviewDiff {
    try Task.checkCancellation()
    if engineVersion == nil {
      engineVersion = try await runner.checked("difft", ["--version"]).text
    }
    let key = try String(decoding: JSONEncoder().encode([
      request.repository.description, request.revision.mergeBase, request.revision.head,
      request.file.path, request.file.previousPath ?? "", request.file.status,
      "json:context-3:strip-cr-off", engineVersion ?? "",
    ]), as: UTF8.self)
    if var cached = renders[key] {
      access += 1
      cached.access = access
      renders[key] = cached
      return cached.document
    }
    if let data = try await cache.read("diff-v3", key, nil) {
      let document = try JSONDecoder().decode(ReviewDiff.self, from: data)
      retain(document, for: key, bytes: data.count)
      return document
    }
    // Only uncached work waits for a selection to settle. Cached previews return immediately.
    try await settle()
    try Task.checkCancellation()
    let file = request.file
    async let old = file.status == "added" ? Data() : content(
      request.repository,
      request.revision.mergeBase,
      file.previousPath ?? file.path,
    )
    async let new = file.status == "removed" ? Data() : content(request.repository, request.revision.head, file.path)
    let (before, after) = try await (old, new)
    try Task.checkCancellation()
    guard let beforeText = String(data: before, encoding: .utf8), let afterText = String(data: after, encoding: .utf8) else {
      return .init(
        path: request.file.path,
        language: "Binary",
        status: "binary",
        rows: [],
        revision: request.revision,
        previousPath: request.file.previousPath,
      )
    }
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
      "--display", "json", "--strip-cr", "off", "--context", "3",
      "--", oldURL.path, newURL.path,
    ])
    let parsed = try ReviewDiff.decode(output.output, before: beforeText, after: afterText, path: file.path)
    let document = ReviewDiff(
      path: file.path,
      language: parsed.language,
      status: parsed.status,
      rows: parsed.rows,
      revision: request.revision,
      previousPath: file.previousPath,
      cacheIdentity: key,
    )
    let data = try JSONEncoder().encode(document)
    try Task.checkCancellation()
    retain(document, for: key, bytes: data.count)
    try await cache.write("diff-v3", key, data)
    return document
  }

  private func retain(_ document: ReviewDiff, for key: String, bytes: Int) {
    guard bytes <= 32 * 1024 * 1024 else { return }
    if let old = renders.removeValue(forKey: key) {
      renderBytes -= old.bytes
    }
    while renders.count >= 24 || renderBytes + bytes > 32 * 1024 * 1024 {
      guard let oldest = renders.min(by: { $0.value.access < $1.value.access })?.key,
            let removed = renders.removeValue(forKey: oldest) else { break }
      renderBytes -= removed.bytes
    }
    access += 1
    renders[key] = .init(document: document, bytes: bytes, access: access)
    renderBytes += bytes
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
