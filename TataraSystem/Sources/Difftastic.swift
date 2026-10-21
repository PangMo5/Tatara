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
  private let versions = SharedRead<String, String>()
  private let pending = SharedRead<String, ReviewDiff>()
  private struct SnapshotKey: Hashable, Sendable {
    let repository: RepositoryID
    let revision: String
    let path: String
  }

  private struct SnapshotEntry {
    let data: Data
    var access: Int
  }

  private var snapshots: [SnapshotKey: SnapshotEntry] = [:]
  private var snapshotBytes = 0
  private struct RenderEntry {
    let document: ReviewDiff
    let bytes: Int
    var access: Int
  }

  private var renders: [String: RenderEntry] = [:]
  private var renderBytes = 0
  private var access = 0

  public init(
    forge: ForgeClient,
    runner: CommandRunner = .live,
    cache: CacheClient = .disabled,
  ) {
    self.forge = forge
    self.runner = runner
    self.cache = cache
  }

  public nonisolated var client: DiffClient {
    DiffClient(render: { try await self.render($0) })
  }

  public func render(_ request: DiffRequest) async throws -> ReviewDiff {
    try Task.checkCancellation()
    if engineVersion == nil {
      let version = try await versions.value(for: "version") { [runner] in
        try await runner.checked("difft", ["--version"]).text
      }
      try Task.checkCancellation()
      engineVersion = version
    }
    let key = try String(decoding: JSONEncoder().encode([
      request.repository.forge.rawValue, request.repository.description, request.revision.mergeBase, request.revision.head,
      request.file.path, request.file.previousPath ?? "", request.file.status,
      "json:context-3:strip-cr-off", engineVersion ?? "",
    ]), as: UTF8.self)
    if var cached = renders[key] {
      access += 1
      cached.access = access
      renders[key] = cached
      return cached.document
    }
    return try await pending.value(for: key) { try await self.produce(request, key: key) }
  }

  private func produce(_ request: DiffRequest, key: String) async throws -> ReviewDiff {
    try Task.checkCancellation()
    // Another consumer may have populated memory while this request joined the flight.
    if let cached = renders[key] {
      return cached.document
    }
    if let data = try await cache.read("diff-v7", key, nil) {
      let document = try await Self.decodeCached(data)
      retain(document, for: key, bytes: data.count)
      return document
    }
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
    let (document, data) = try await Self.prepare(request, key: key, before: before, after: after, runner: runner)
    try Task.checkCancellation()
    retain(document, for: key, bytes: data.count)
    try await cache.write("diff-v7", key, data)
    return document
  }

  @concurrent
  private static func decodeCached(_ data: Data) async throws -> ReviewDiff {
    try Task.checkCancellation()
    let document = try JSONDecoder().decode(ReviewDiff.self, from: data)
    try Task.checkCancellation()
    return document
  }

  @concurrent
  private static func prepare(
    _ request: DiffRequest, key: String, before: Data, after: Data, runner: CommandRunner,
  ) async throws -> (ReviewDiff, Data) {
    try Task.checkCancellation()
    let file = request.file
    let document: ReviewDiff
    if let beforeText = String(data: before, encoding: .utf8), let afterText = String(data: after, encoding: .utf8) {
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tatara-\(UUID().uuidString)")
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700],
      )
      defer { try? FileManager.default.removeItem(at: directory) }
      // Only the extension influences syntax detection; remote paths never resolve locally.
      let ext = (file.path as NSString).pathExtension.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(20)
      let oldURL = directory.appendingPathComponent("before.\(ext)")
      let newURL = directory.appendingPathComponent("after.\(ext)")
      try before.write(to: oldURL)
      try Task.checkCancellation()
      try after.write(to: newURL)
      let output = try await runner.checked("difft", [
        "--display", "json", "--strip-cr", "off", "--context", "3", "--", oldURL.path, newURL.path,
      ])
      let parsed = try ReviewDiff.decode(output.output, before: beforeText, after: afterText, path: file.path)
      document = ReviewDiff(
        path: file.path, language: parsed.language, status: parsed.status, rows: parsed.rows,
        revision: request.revision, previousPath: file.previousPath, cacheIdentity: key,
      )
    } else {
      document = ReviewDiff(
        path: file.path, language: "Binary", status: "binary", rows: [],
        revision: request.revision, previousPath: file.previousPath, cacheIdentity: key,
      )
    }
    try Task.checkCancellation()
    let data = try JSONEncoder().encode(document)
    try Task.checkCancellation()
    return (document, data)
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
    try Task.checkCancellation()
    let key = SnapshotKey(repository: repository, revision: revision, path: path)
    if var entry = snapshots[key] {
      access += 1
      entry.access = access
      snapshots[key] = entry
      return entry.data
    }
    let value = try await forge.content(repository, revision, path)
    try Task.checkCancellation()
    let limit = 32 * 1024 * 1024
    guard value.count <= limit else { return value }
    if let old = snapshots.removeValue(forKey: key) {
      snapshotBytes -= old.data.count
    }
    while snapshots.count >= 64 || snapshotBytes + value.count > limit {
      guard let oldest = snapshots.min(by: { $0.value.access < $1.value.access })?.key,
            let removed = snapshots.removeValue(forKey: oldest) else { break }
      snapshotBytes -= removed.data.count
    }
    access += 1
    snapshots[key] = .init(data: value, access: access)
    snapshotBytes += value.count
    return value
  }
}

/// Share only active reads. Each caller owns its continuation; the last cancellation
/// tears down the producer, and a completed old flight cannot remove its replacement.
private actor SharedRead<Key: Hashable & Sendable, Value: Sendable> {
  private struct Flight {
    let id: UUID
    let task: Task<Void, Never>
    var waiters: [UUID: CheckedContinuation<Value, any Error>]
  }

  private var flights: [Key: Flight] = [:]

  func value(for key: Key, operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
    let waiter = UUID()
    let value = try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        if flights[key] != nil {
          flights[key]?.waiters[waiter] = continuation
        } else {
          let id = UUID()
          let task = Task { @concurrent in
            let result: Result<Value, any Error>
            do { result = try await .success(operation()) }
            catch { result = .failure(error) }
            await self.finish(key, id: id, result: result)
          }
          flights[key] = Flight(id: id, task: task, waiters: [waiter: continuation])
        }
      }
    } onCancel: {
      Task { @concurrent in await self.cancel(key, waiter: waiter) }
    }
    try Task.checkCancellation()
    return value
  }

  private func cancel(_ key: Key, waiter: UUID) {
    guard let continuation = flights[key]?.waiters.removeValue(forKey: waiter) else { return }
    continuation.resume(throwing: CancellationError())
    if flights[key]?.waiters.isEmpty == true {
      flights.removeValue(forKey: key)?.task.cancel()
    }
  }

  private func finish(_ key: Key, id: UUID, result: Result<Value, any Error>) {
    guard flights[key]?.id == id, let flight = flights.removeValue(forKey: key) else { return }
    for waiter in flight.waiters.values {
      waiter.resume(with: result)
    }
  }
}
