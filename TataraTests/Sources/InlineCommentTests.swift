// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import Foundation
import TataraCore
import TataraKit
import Testing

struct InlineCommentTests {
  private static let patch = "@@ -10,3 +10,4 @@\n context\n-deleted\n+added\n+second\n tail"

  @Test func `patch coordinates distinguish old and new lines`() {
    #expect(ReviewAnchor.contains(line: 11, side: .left, patch: Self.patch))
    #expect(ReviewAnchor.contains(line: 13, side: .right, patch: Self.patch))
    #expect(!ReviewAnchor.contains(line: 13, side: .left, patch: Self.patch))
    #expect(!ReviewAnchor.contains(line: 1, side: .right, patch: Self.patch))
    #expect(!ReviewAnchor.contains(line: 10, side: .right, patch: nil))
  }

  @Test @MainActor func `inline draft cannot use an unmapped line`() async throws {
    let repository = try RepositoryID("owner/repo")
    let item = try ForgeItem(
      id: .init(repository: repository, number: 1),
      kind: .pullRequest,
      title: "Example",
      author: "author",
      url: #require(URL(string: "https://github.com/owner/repo/pull/1")),
    )
    var state = ReviewFeature.State(item: item, expectedHead: "head")
    state.selectedFile = .init(path: "File.swift", patch: Self.patch)
    state.isEditingInline = true
    state.inlineLine = "99"
    state.inlineBody = "Comment"
    let store = TestStore(initialState: state) { ReviewFeature() }
    await store.send(.addInlineButtonPressed) { $0.error = .init(.invalidLine) }
    await store.send(.inlineLineChanged("11")) { $0.inlineLine = "11"
      $0.error = nil
    }
    await store.send(.addInlineButtonPressed) {
      $0.comments = [.init(path: "File.swift", line: 11, side: .right, body: "Comment")]
      $0.isEditingInline = false
      $0.inlineLine = ""
      $0.inlineBody = ""
    }
    await store.send(.previewButtonPressed) { $0.isConfirming = true }
  }
}
