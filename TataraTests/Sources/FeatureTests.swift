// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import Foundation
import TataraCore
import TataraKit
import Testing

@MainActor
struct FeatureTests {
  @Test func `help navigation does not change the review selection`() async throws {
    var state = try WorkspaceFeature.State(repository: RepositoryID("owner/repo"))
    state.showsHelp = true
    let store = TestStore(initialState: state) { WorkspaceFeature() }
    await store.send(.commandPressed(.down)) { $0.scroll = 1 }
    await store.send(.commandPressed(.refresh))
    await store.send(.commandPressed(.back)) { $0.showsHelp = false
      $0.scroll = 0
    }
  }

  private func item(_ number: Int = 1, kind: ItemKind = .pullRequest) throws -> ForgeItem {
    let repository = try RepositoryID("owner/repo")
    return try ForgeItem(
      id: .init(repository: repository, number: number),
      kind: kind,
      title: "Example",
      author: "reviewer",
      url: #require(URL(string: "https://github.com/owner/repo/pull/\(number)")),
    )
  }

  @Test func `stale detail cannot replace selected pull request`() async throws {
    let first = try item()
    let second = try item(2)
    var state = WorkspaceFeature.State(repository: first.id.repository)
    state.items = [first, second]
    state.selectedItemID = second.id
    state.detailGeneration = 3
    let store = TestStore(initialState: state) { WorkspaceFeature() }
    await store.send(.detailResponse(generation: 2, .success(.init(item: first))))
    #expect(store.state.detail == nil)
  }

  @Test func `stale diff cannot replace new viewport`() async throws {
    var state = try WorkspaceFeature.State(repository: RepositoryID("owner/repo"))
    state.diffGeneration = 5
    state.diff = "current"
    let store = TestStore(initialState: state) { WorkspaceFeature() }
    await store.send(.diffResponse(generation: 4, .success("obsolete")))
    #expect(store.state.diff == "current")
  }

  @Test func `submitting requires preview and keeps draft on failure`() async throws {
    let reviewItem = try item()
    let store = TestStore(initialState: ReviewFeature.State(item: reviewItem, expectedHead: "head")) { ReviewFeature()
    } withDependencies: {
      $0[ForgeClient.self].submit = { _ in throw TataraError(.revisionChanged) }
    }
    await store.send(.submitButtonPressed)
    await store.send(.bodyChanged("Please test the boundary.")) { $0.body = "Please test the boundary." }
    await store.send(.previewButtonPressed) { $0.isConfirming = true }
    await store.send(.submitButtonPressed) { $0.isSubmitting = true }
    await store.receive(\.submissionResponse) {
      $0.isSubmitting = false
      $0.isConfirming = false
      $0.error = .init(.revisionChanged)
    }
    #expect(store.state.body == "Please test the boundary.")
  }

  @Test func `issues cannot be approved`() async throws {
    let reviewItem = try item(kind: .issue)
    let store = TestStore(initialState: ReviewFeature.State(item: reviewItem, expectedHead: nil)) { ReviewFeature() }
    await store.send(.eventSelected(.approve))
    #expect(store.state.event == .comment)
  }

  @Test func `duplicate submission is ignored while in flight`() async throws {
    var state = try ReviewFeature.State(item: item(), expectedHead: "head")
    state.isSubmitting = true
    state.isConfirming = true
    let store = TestStore(initialState: state) { ReviewFeature() }
    await store.send(.submitButtonPressed)
  }

  @Test func `search consumes quit key as text`() async throws {
    var state = try WorkspaceFeature.State(repository: RepositoryID("owner/repo"))
    state.isSearching = true
    let store = TestStore(initialState: state) { WorkspaceFeature() }
    await store.send(.keyPressed("q")) { $0.search = "q" }
    await store.send(.keyPressed("esc")) { $0.search = ""
      $0.isSearching = false
    }
  }

  @Test func `reviewed status is scoped to commit`() async throws {
    let item = try item()
    var state = WorkspaceFeature.State(repository: item.id.repository)
    state.detail = .init(item: item, revision: .init(mergeBase: "base", head: "one"), files: [.init(path: "File.swift")])
    state.selectedFilePath = "File.swift"
    let store = TestStore(initialState: state) { WorkspaceFeature() }
    await store.send(.markReviewedPressed) { $0.reviewedFiles = ["github.com/owner/repo#1|base|one|File.swift"] }
    await store.send(.markReviewedPressed) { $0.reviewedFiles = [] }
  }
}
