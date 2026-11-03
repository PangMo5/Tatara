// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CryptoKit
import Foundation
import SQLiteData
import TataraKit

// MARK: - CacheEntry

@Table
struct CacheEntry: Identifiable, Sendable {
  let id: String
  var namespace: String
  var payload: Data
  var createdAt: Double
  var byteCount: Int
}

// MARK: - PersistentCache

public actor PersistentCache {

  // MARK: Lifecycle

  private init(database: any DatabaseWriter, maximumBytes: Int, now: @escaping @Sendable () -> Date) {
    self.database = database
    self.maximumBytes = maximumBytes
    self.now = now
  }

  // MARK: Public

  public nonisolated var client: CacheClient {
    CacheClient(
      read: { try await self.read(namespace: $0, key: $1, maximumAge: $2) },
      write: { try await self.write(namespace: $0, key: $1, value: $2) },
      invalidate: { try await self.invalidate(namespace: $0) },
    )
  }

  @concurrent
  public static func bootstrapDatabase(
    at url: URL? = nil,
    maximumBytes: Int = 128 * 1024 * 1024,
    now: @escaping @Sendable () -> Date = { Date() },
  ) async throws -> PersistentCache {
    let directory = ProcessInfo.processInfo.environment["XDG_CACHE_HOME"].map { URL(fileURLWithPath: $0) }
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache")
    let location = url ?? directory.appendingPathComponent("tatara/cache.sqlite")
    try FileManager.default.createDirectory(
      at: location.deletingLastPathComponent(),
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700],
    )
    let database = try DatabaseQueue(path: location.path)
    var migrator = DatabaseMigrator()
    migrator.registerMigration("Create cache entries") { db in
      try #sql("""
        CREATE TABLE "cacheEntries" (
          "id" TEXT PRIMARY KEY NOT NULL,
          "namespace" TEXT NOT NULL,
          "payload" BLOB NOT NULL,
          "createdAt" REAL NOT NULL,
          "byteCount" INTEGER NOT NULL
        ) STRICT;
        """).execute(db)
      try #sql("CREATE INDEX \"cacheEntries_namespace\" ON \"cacheEntries\" (\"namespace\")").execute(db)
    }
    try migrator.migrate(database)
    return PersistentCache(database: database, maximumBytes: maximumBytes, now: now)
  }

  // MARK: Private

  private let database: any DatabaseWriter
  private let maximumBytes: Int
  private let now: @Sendable () -> Date

  private func identifier(_ namespace: String, _ key: String) throws -> String {
    try SHA256.hash(data: JSONEncoder().encode([namespace, key])).map { String(format: "%02x", $0) }.joined()
  }

  private func read(namespace: String, key: String, maximumAge: Double?) async throws -> Data? {
    try Task.checkCancellation()
    let id = try identifier(namespace, key)
    let timestamp = now().timeIntervalSince1970
    return try await database.read { db in
      if let maximumAge {
        return try CacheEntry.find(id)
          .where { $0.createdAt.gte(timestamp - maximumAge) }
          .where { $0.createdAt.lte(timestamp) }
          .select(\.payload).fetchOne(db)
      }
      return try CacheEntry.find(id).select(\.payload).fetchOne(db)
    }
  }

  private func write(namespace: String, key: String, value: Data) async throws {
    try Task.checkCancellation()
    guard value.count <= maximumBytes else { return }
    let entry = try CacheEntry(
      id: identifier(namespace, key),
      namespace: namespace,
      payload: value,
      createdAt: now().timeIntervalSince1970,
      byteCount: value.count,
    )
    let limit = maximumBytes
    try await database.write { db in
      try CacheEntry.upsert { entry }.execute(db)
      let sizes = try CacheEntry.order { $0.createdAt.desc() }.select { ($0.id, $0.byteCount) }.fetchAll(db)
      var retained = 0
      for (index, row) in sizes.enumerated() {
        retained += row.1
        if retained > limit || index >= 256 {
          try CacheEntry.find(row.0).delete().execute(db)
        }
      }
    }
  }

  private func invalidate(namespace: String) async throws {
    try await database.write { db in try CacheEntry.where { $0.namespace.eq(namespace) }.delete().execute(db) }
  }

}
