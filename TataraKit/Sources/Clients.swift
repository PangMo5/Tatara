// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import Foundation
import TataraCore

@DependencyClient
public struct ForgeClient: Sendable {
  public var list: @Sendable (RepositoryID, ItemKind, Int) async throws -> ItemPage
  public var detail: @Sendable (ForgeItem) async throws -> ItemDetail
  public var content: @Sendable (RepositoryID, String, String) async throws -> Data
  public var submit: @Sendable (ReviewSubmission) async throws -> Void
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
  public var render: @Sendable (DiffRequest) async throws -> String
}

extension DiffClient: TestDependencyKey {
  public static var testValue: Self {
    Self()
  }
}
