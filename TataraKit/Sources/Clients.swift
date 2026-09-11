// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import Foundation
import TataraCore

@DependencyClient
public struct ForgeClient: Sendable {
  public var invalidate: @Sendable (RepositoryID) async throws -> Void = { _ in }
  public var list: @Sendable (RepositoryID, ItemKind, Int) async throws -> ItemPage
  public var search: @Sendable (RepositoryID, ItemKind, String, Int) async throws -> ItemPage
  public var labels: @Sendable (RepositoryID) async throws -> [String]
  public var detail: @Sendable (ForgeItem) async throws -> ItemDetail
  public var content: @Sendable (RepositoryID, String, String) async throws -> Data
  public var submit: @Sendable (ReviewSubmission) async throws -> Void
}

@DependencyClient
public struct FilterPresetClient: Sendable {
  public var load: @Sendable (RepositoryID) async throws -> [FilterPreset]
  public var save: @Sendable (RepositoryID, FilterPreset) async throws -> Void
  public var delete: @Sendable (RepositoryID, String) async throws -> Void
}

extension FilterPresetClient: TestDependencyKey { public static var testValue: Self {
  Self()
} }

public struct CacheClient: Sendable {
  public var read: @Sendable (_ namespace: String, _ key: String, _ maximumAge: Double?) async throws -> Data?
  public var write: @Sendable (_ namespace: String, _ key: String, _ value: Data) async throws -> Void
  public var invalidate: @Sendable (_ namespace: String) async throws -> Void
  public init(
    read: @escaping @Sendable (String, String, Double?) async throws -> Data?,
    write: @escaping @Sendable (String, String, Data) async throws -> Void,
    invalidate: @escaping @Sendable (String) async throws -> Void,
  ) {
    self.read = read
    self.write = write
    self.invalidate = invalidate
  }

  public static let disabled = Self(read: { _, _, _ in nil }, write: { _, _, _ in }, invalidate: { _ in })
  public func scoped(to scope: String) -> Self {
    Self(
      read: { try await read(scope + ":" + $0, $1, $2) },
      write: { try await write(scope + ":" + $0, $1, $2) },
      invalidate: { try await invalidate(scope + ":" + $0) },
    )
  }
}

extension ForgeClient: TestDependencyKey {
  public static var testValue: Self {
    Self()
  }
}

public struct DiffRequest: Equatable, Sendable {
  public var repository: RepositoryID
  public var revision: PullRequestRevision
  public var file: ChangedFile
  public var width: Int
  public var theme: Theme
  public init(repository: RepositoryID, revision: PullRequestRevision, file: ChangedFile, width: Int, theme: Theme) {
    self.repository = repository
    self.revision = revision
    self.file = file
    self.width = width
    self.theme = theme
  }
}

@DependencyClient
public struct DiffClient: Sendable {
  public var render: @Sendable (DiffRequest) async throws -> ReviewDiff
}

extension DiffClient: TestDependencyKey {
  public static var testValue: Self {
    Self()
  }
}

@DependencyClient
public struct DocumentClient: Sendable {
  public var prepare: @Sendable (_ text: String, _ width: Int) async throws -> ReviewDocument
  public var prepareComment: @Sendable (_ markdown: String, _ width: Int) async throws -> ReviewDocument
  public var search: @Sendable (ReviewDocument, String) async throws -> SearchMatches
  public var revealMatch: @Sendable (ReviewDocument, SearchMatches, Int, Int) async throws -> ReviewDocument
  public var prepareDiff: @Sendable (ReviewDiff, Int, InlineComment.Side) async throws -> ReviewDocument
}

extension DocumentClient: TestDependencyKey {
  public static var testValue: Self {
    Self()
  }
}
