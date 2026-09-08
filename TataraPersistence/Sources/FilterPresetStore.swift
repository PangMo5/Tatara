// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SQLiteData
import TataraCore
import TataraKit

@Table
private struct SavedFilterPreset: Identifiable, Sendable {
  let id: String
  var repository: String
  var name: String
  var query: String
}

public actor FilterPresetStore {
  private let database: any DatabaseWriter
  private init(_ database: any DatabaseWriter) {
    self.database = database
  }

  @concurrent
  public static func open(at url: URL? = nil) async throws -> Self {
    let base = ProcessInfo.processInfo.environment["XDG_DATA_HOME"].map { URL(fileURLWithPath: $0) }
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share")
    let file = url ?? base.appendingPathComponent("tatara/state/filters.sqlite")
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(),
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700],
    )
    let database = try DatabaseQueue(path: file.path)
    var migrator = DatabaseMigrator()
    migrator.registerMigration("Create filter presets") { db in
      try #sql("""
      CREATE TABLE "savedFilterPresets" (
        "id" TEXT PRIMARY KEY NOT NULL,
        "repository" TEXT NOT NULL,
        "name" TEXT NOT NULL,
        "query" TEXT NOT NULL
      ) STRICT
      """).execute(db)
    }
    try migrator.migrate(database)
    return Self(database)
  }

  public nonisolated var client: FilterPresetClient {
    .init(load: { try await self.load($0) }, save: { try await self.save($0, $1) }, delete: { try await self.delete($0, $1) })
  }

  private func load(_ repository: RepositoryID) async throws -> [FilterPreset] {
    let scope = "\(repository.forge.rawValue):\(repository)"
    let prefix = scope + "|"
    return try await database.read { db in
      try SavedFilterPreset.where { $0.repository.eq(scope) }.order { $0.name }.fetchAll(db)
        .map { FilterPreset(id: String($0.id.dropFirst(prefix.count)), name: $0.name, query: $0.query) }
    }
  }

  private func save(_ repository: RepositoryID, _ preset: FilterPreset) async throws {
    guard !preset.isBuiltIn else { throw TataraError(.configuration, detail: "Built-in presets cannot be overwritten.") }
    let scope = "\(repository.forge.rawValue):\(repository)"
    try await database.write { db in
      try SavedFilterPreset.upsert { SavedFilterPreset(
        id: scope + "|" + preset.id,
        repository: scope,
        name: preset.name,
        query: preset.query,
      ) }.execute(db)
    }
  }

  private func delete(_ repository: RepositoryID, _ id: String) async throws {
    let scope = "\(repository.forge.rawValue):\(repository)"
    try await database.write { db in
      try SavedFilterPreset.where { $0.id.eq(scope + "|" + id) && $0.repository.eq(scope) }.delete().execute(db)
    }
  }
}
