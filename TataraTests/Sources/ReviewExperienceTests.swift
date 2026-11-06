// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import Foundation
import Synchronization
import TataraCore
import TataraGitHub
import TataraKit
import TataraSystem
import TermLoom
import Testing
@testable import TataraTUI

// MARK: - ReviewExperienceTests

@MainActor
struct ReviewExperienceTests {

  // MARK: Internal

  @Test(arguments: Theme.allCases)
  func `cursor tint preserves source styling and sticky path follows the viewport`(_ theme: Theme) async throws {
    var state = try await fixture()
    state.preferences.theme = theme
    let view = presentation(state)
    var frame = Frame(buffer: Buffer(area: Rect(size: view.size)))
    frame.render(view.screen())
    let rect = view.geometry.content
    let row = rect.y + 2 + state.diffCursor
    #expect(frame.buffer[.init(x: rect.x + 1 + state.document.diffSideWidth + 5, y: row)].style.background == Palette(theme)
      .cursorLine)
    #expect(frame.buffer.lines()[rect.y].contains("Diff"))
    #expect(frame.buffer.lines()[rect.y + 1].contains("A.swift"))
    #expect(frame.buffer.lines()[view.geometry.files.y].contains("Files"))
    #expect(state.visualStart == nil)
    let combined = ReviewDiff(path: "/", language: "Swift", status: "changed", rows: [
      .init(left: nil, right: .init(number: 1, spans: [.init(text: "first")]), path: "A.swift"),
      .init(left: nil, right: .init(number: 1, spans: [.init(text: "second")]), path: "B.swift"),
    ])
    state.document = try await DocumentRenderer.prepareDiff(combined, 120)
    let target = try #require(state.document.row(for: .init(path: "B.swift", line: 1, side: .right)))
    state.scroll = target
    let scrolled = presentation(state)
    var next = Frame(buffer: Buffer(area: Rect(size: scrolled.size)))
    next.render(scrolled.screen())
    #expect(next.buffer.lines()[scrolled.geometry.content.y + 1].contains("B.swift"))
    #expect(state.selectedFilePath == "A.swift")
  }

  @Test(arguments: [60, 80, 99], [16, 27, 40])
  func `narrow workspace keeps equal Files and Diff panels visible for either focus`(_ columns: Int, _ rows: Int) async throws {
    var state = try await fixture()
    let size = Size(width: columns, height: rows)
    let geometry = WorkspaceGeometry(size: size)
    #expect(geometry.isStacked)
    #expect(geometry.items.height == 0)
    #expect(geometry.files.width == columns && geometry.content.width == columns)
    #expect(geometry.files.bottom == geometry.content.y)
    #expect(geometry.files.height + geometry.content.height == geometry.body.height)
    #expect(abs(geometry.files.height - geometry.content.height) <= 1)
    state.document = try await DocumentRenderer.prepareDiff(Self.diff(), columns - 2)
    for pane in [WorkspaceFeature.Pane.files, .content] {
      state.pane = pane
      let view = presentation(state, size: size)
      var frame = Frame(buffer: Buffer(area: Rect(size: size)))
      frame.render(view.screen())
      let lines = frame.buffer.lines()
      #expect(lines[geometry.files.y].contains("Files"))
      #expect(lines[geometry.content.y].contains("Diff"))
      #expect(lines[(geometry.files.y + 1)..<(geometry.files.bottom - 1)].joined().contains("A.swift"))
      #expect(lines[geometry.content.y + 1].contains("A.swift"))
    }
    let selector = WorkspaceGeometry(size: size, isSelectingItems: true)
    #expect(!selector.isStacked)
    #expect(selector.items == selector.body)
  }

  @Test
  func `short stacked workspace keeps the source anchored composer inside the screen`() async throws {
    var state = try await fixture()
    let detail = try #require(state.detail)
    state.review = .init(item: detail.item, expectedHead: "head", expectedMergeBase: "base")
    state.review?.selectedFile = detail.files.first
    state.review?.isEditingInline = true
    state.review?.inlineAnchorLocked = true
    state.review?.inlineLine = "2"
    state.reviewLocation = .init(path: "A.swift", line: 2, side: .right)
    let size = Size(width: 80, height: 20)
    let view = presentation(state, size: size)
    #expect(!view.geometry.canShowInlineReview)
    var frame = Frame(buffer: Buffer(area: Rect(size: size)))
    frame.render(view.screen())
    let text = frame.buffer.lines().joined(separator: "\n")
    #expect(text.contains("Write your review"))
    #expect(text.contains("Add comment to review"))
    #expect(text.contains("Back"))
  }

  @Test(arguments: Theme.allCases)
  func `PR summary shows typed review metadata changes and optional participants`(_ theme: Theme) async throws {
    var state = try await fixture()
    let detail = try #require(state.detail)
    var item = detail.item
    item.isDraft = true
    item.labels = ["bug", "swift"]
    item.github = .init(
      updatedAt: "2026-11-09T10:15:30Z",
      requestedReviewers: ["alice", "bob"],
      commentCount: 3,
      reviewDecision: .reviewRequired,
      checksState: .pending,
      headBranch: "author/a-very-long-feature-branch-for-uploading-community-videos",
      baseBranch: "main",
      additions: 321,
      deletions: 54,
      changedFiles: 93,
      commits: 12,
    )
    state.preferences.theme = theme
    state.items = [item]
    state.detail = .init(item: item, revision: detail.revision, files: detail.files, comments: detail.comments)
    let view = presentation(state, size: .init(width: 176, height: 56))
    let rect = view.geometry.items
    #expect(rect.height <= 10)
    #expect(view.geometry.files.height >= view.geometry.body.height * 3 / 4)
    var frame = Frame(buffer: Buffer(area: Rect(size: view.size)))
    frame.render(view.screen())
    let lines = frame.buffer.lines()[rect.y..<rect.bottom].map { String($0.prefix(rect.width)) }
    let text = lines.joined(separator: "\n")
    for expected in [
      "Draft",
      "Review required",
      "CI Pending",
      "→ main",
      "Files 1",
      "Comments 0",
      "+321",
      "−54",
      "Commits 12",
      "Updated 2026-11-09 10:15Z",
      "@alice",
      "Labels bug",
    ] {
      #expect(text.contains(expected))
    }
    let changeRow = try #require(lines.firstIndex { $0.contains("+321") })
    let changeLine = lines[changeRow]
    let start = try #require(changeLine.range(of: "+321")?.lowerBound)
    let x = changeLine.distance(from: changeLine.startIndex, to: start)
    #expect(frame.buffer[.init(x: x, y: rect.y + changeRow)].style.foreground == Palette(theme).green)
  }

  @Test
  func `loading summary keeps known totals and does not invent a successful review state`() async throws {
    var state = try await fixture()
    var item = try #require(state.selectedItem)
    item.github = .init(commentCount: 3, changedFiles: 93)
    state.items = [item]
    state.detail = .init(item: item)
    state.isLoadingDetail = true
    let view = presentation(state)
    var frame = Frame(buffer: Buffer(area: Rect(size: view.size)))
    frame.render(view.screen())
    let rect = view.geometry.items
    let text = frame.buffer.lines()[rect.y..<rect.bottom].lazy.map { String($0.prefix(rect.width)) }.joined(separator: "\n")
    #expect(text.contains("Files 93"))
    #expect(text.contains("Comments 3"))
    #expect(text.contains("Not reported"))
    #expect(!text.contains("Passed"))
    #expect(!text.contains("Approved"))
  }

  @Test
  func `unified shared source keeps the cursor tint when the left identity is focused`() async throws {
    var state = try await fixture()
    let line = ReviewDiffLine(number: 1, spans: [.init(text: "shared source")])
    state.document = try await DocumentRenderer.prepareDiff(
      .init(path: "A.swift", language: "Swift", status: "changed", rows: [.init(left: line, right: line)]),
      80,
    )
    state.diffSide = .left
    state.diffCursor = try #require(state.document.row(for: .init(path: "A.swift", line: 1, side: .left)))
    let view = presentation(state)
    var frame = Frame(buffer: Buffer(area: Rect(size: view.size)))
    frame.render(view.screen())
    let y = view.geometry.content.y + 2 + state.diffCursor
    let text = frame.buffer.lines()[y]
    let start = try #require(text.range(of: "shared source")?.lowerBound)
    let x = text.distance(from: text.startIndex, to: start)
    #expect(frame.buffer[.init(x: x, y: y)].style.background == Palette(state.preferences.theme).cursorLine)
  }

  @Test(arguments: [KeyCommand.comment, .review])
  func `draft PRs allow inline comments and review completion`(_ command: KeyCommand) async throws {
    var state = try await fixture()
    let detail = try #require(state.detail)
    var item = detail.item
    item.isDraft = true
    state.detail = .init(item: item, revision: detail.revision, files: detail.files, comments: detail.comments)
    state.items = [item]
    let store = TestStore(initialState: state) { WorkspaceFeature() }
    store.exhaustivity = .off
    await store.send(.commandPressed(command))
    #expect(store.state.review != nil)
    #expect(store.state.review?.item.isDraft == true)
    #expect(store.state.review?.isEditingInline == (command == .comment))
    #expect(store.state.reviewEntryHint == nil)
  }

  @Test
  func `review entry while preparing shows a hint without stopping document loading`() async throws {
    var state = try await fixture()
    state.isPreparingDocument = true
    state.contentGeneration = 1
    let document = state.document
    let store = TestStore(initialState: state) { WorkspaceFeature() }
    store.exhaustivity = .off
    await store.send(.commandPressed(.comment))
    #expect(store.state.review == nil)
    #expect(store.state.reviewEntryHint == "Wait for the current document to finish loading.")
    #expect(store.state.error == nil)
    #expect(store.state.isPreparingDocument)
    await store.send(.contentResponse(generation: 1, .success(document)))
    #expect(store.state.reviewEntryHint == nil)
    await store.send(.commandPressed(.comment))
    #expect(store.state.review?.isEditingInline == true)
  }

  @Test
  func `commenting from a folder gives a visible navigation hint`() async throws {
    var state = try await fixture()
    state.pane = .files
    state.fileCursorID = "directory:/"
    let store = TestStore(initialState: state) { WorkspaceFeature() }
    store.exhaustivity = .off
    await store.send(.commandPressed(.comment))
    #expect(store.state.review == nil)
    #expect(store.state.reviewEntryHint == "Select a file and press Enter to open Diff.")
    let view = presentation(store.state)
    var frame = Frame(buffer: Buffer(area: Rect(size: view.size)))
    frame.render(view.screen())
    #expect(frame.buffer.lines().last?.contains("Select a file") == true)
    #expect(store.state.error == nil)
  }

  @Test
  func `adding and editing a pending inline comment returns to diff without duplicating drafts`() async throws {
    let state = try await fixture()
    let store = TestStore(initialState: state) { WorkspaceFeature() } withDependencies: {
      $0[DocumentClient.self] = DocumentRenderer.client
      $0[DiffClient.self].render = { request in Self.diff(request.file.path) }
    }
    store.exhaustivity = .off
    await store.send(.commandPressed(.comment))
    await store.send(.review(.inlineBodyChanged("First draft")))
    await store.send(.review(.addInlineButtonPressed))
    await store.receive(\.contentResponse)
    #expect(store.state.review == nil)
    #expect(store.state.drafts[try #require(state.selectedItemID)]?.comments.count == 1)
    #expect(store.state.document.lines.flatMap { $0 }.contains { $0.text.contains("First draft") })
    await store.send(.commandPressed(.review))
    #expect(store.state.review?.comments.count == 1)
    #expect(store.state.reviewLocation == nil)
    await store.send(.draftCommentSelected(0, edit: true))
    await store.receive(\.contentResponse)
    #expect(store.state.review?.inlineBody == "First draft")
    await store.send(.review(.inlineBodyChanged("Edited draft")))
    await store.send(.review(.addInlineButtonPressed))
    await store.receive(\.contentResponse)
    #expect(store.state.review == nil)
    #expect(store.state.drafts[try #require(state.selectedItemID)]?.comments.map(\.body) == ["Edited draft"])
    #expect(store.state.document.location(at: store.state.diffCursor, side: store.state.diffSide)?.line == 2)
  }

  @Test
  func `cancelled draft edits stay separate from new comments and removing the last draft clears its card`() async throws {
    var state = try await fixture()
    let item = try #require(state.selectedItem)
    var draft = ReviewFeature.State(item: item, expectedHead: "head", expectedMergeBase: "base")
    draft.comments = [.init(path: "A.swift", line: 2, side: .right, body: "Original draft")]
    state.drafts[item.id] = draft
    let store = TestStore(initialState: state) { WorkspaceFeature() } withDependencies: {
      $0[DocumentClient.self] = DocumentRenderer.client
      $0[DiffClient.self].render = { request in Self.diff(request.file.path) }
    }
    store.exhaustivity = .off
    await store.send(.commandPressed(.review))
    await store.send(.draftCommentSelected(0, edit: true))
    await store.receive(\.contentResponse)
    await store.send(.review(.inlineBodyChanged("Unfinished edit")))
    await store.send(.reviewDismissed)
    await store.receive(\.contentResponse)
    await store.send(.commandPressed(.comment))
    #expect(store.state.review?.editingCommentIndex == nil)
    #expect(store.state.review?.inlineBody.isEmpty == true)
    await store.send(.review(.inlineBodyChanged("Second draft")))
    await store.send(.review(.addInlineButtonPressed))
    await store.receive(\.contentResponse)
    #expect(store.state.drafts[item.id]?.comments.map(\.body) == ["Original draft", "Second draft"])
    await store.send(.commandPressed(.review))
    await store.send(.draftCommentSelected(0, edit: true))
    await store.receive(\.contentResponse)
    #expect(store.state.review?.inlineBody == "Unfinished edit")
    await store.send(.reviewDismissed)
    await store.receive(\.contentResponse)
    await store.send(.commandPressed(.review))
    await store.send(.review(.removeInlineButtonPressed(1)))
    await store.send(.review(.removeInlineButtonPressed(0)))
    await store.send(.reviewDismissed)
    await store.receive(\.contentResponse)
    #expect(store.state.drafts[item.id]?.comments.isEmpty == true)
    #expect(!store.state.document.searchableLines.joined().contains("Original draft"))
  }

  @Test
  func `pending comment identity survives removing an earlier comment`() async throws {
    var state = try await fixture()
    let item = try #require(state.selectedItem)
    var draft = ReviewFeature.State(item: item, expectedHead: "head", expectedMergeBase: "base")
    draft.comments = [
      .init(path: "A.swift", line: 2, side: .right, body: "First"),
      .init(path: "A.swift", line: 2, side: .right, body: "Second"),
    ]
    draft.selectedFile = state.detail?.files.first
    draft.editingCommentIndex = 1
    draft.inlineBody = "Unfinished second edit"
    draft.stashInlineDraft()
    draft.editingCommentIndex = nil
    state.drafts[item.id] = draft
    let store = TestStore(initialState: state) { WorkspaceFeature() } withDependencies: {
      $0[DocumentClient.self] = DocumentRenderer.client
      $0[DiffClient.self].render = { request in Self.diff(request.file.path) }
    }
    store.exhaustivity = .off
    await store.send(.commandPressed(.review))
    await store.send(.review(.removeInlineButtonPressed(0)))
    await store.send(.draftCommentSelected(1, edit: true))
    await store.receive(\.contentResponse)
    #expect(store.state.review?.comments.map(\.body) == ["Second"])
    #expect(store.state.review?.inlineBody == "Unfinished second edit")
    await store.send(.review(.inlineBodyChanged("Finished second edit")))
    await store.send(.review(.addInlineButtonPressed))
    await store.receive(\.contentResponse)
    #expect(store.state.drafts[item.id]?.comments.map(\.body) == ["Finished second edit"])
  }

  @Test
  func `identical reader preparation requests preserve the active worker`() async throws {
    let workspace = try await fixture()
    let target = DiscussionComment(id: 1, author: "author", body: "Reader text")
    var state = CommentFeature.State(item: try #require(workspace.selectedItem), expectedHead: "head", target: target)
    state.isViewing = true
    let (started, start) = AsyncStream<Void>.makeStream()
    let (pending, release) = AsyncStream<Void>.makeStream()
    defer { start.finish()
      release.finish()
    }
    let count = Mutex(0)
    let cancelled = Mutex(false)
    let store = TestStore(initialState: state) { CommentFeature() } withDependencies: {
      $0[DocumentClient.self].prepareComment = { _, _ in
        count.withLock { $0 += 1 }
        return await withTaskCancellationHandler {
          start.yield(())
          for await _ in pending { break }
          return ReviewDocument(lines: [[.init(text: "Reader text")]])
        } onCancel: { cancelled.withLock { $0 = true } }
      }
    }
    store.exhaustivity = .off
    await store.send(.threadRequested(width: 80, height: 12))
    var iterator = started.makeAsyncIterator()
    _ = await iterator.next()
    await store.send(.threadRequested(width: 80, height: 16))
    #expect(store.state.threadGeneration == 1)
    #expect(count.withLock { $0 } == 1)
    #expect(!cancelled.withLock { $0 })
    release.yield(())
    await store.receive(\.threadResponse)
    #expect(store.state.threadDocument?.searchableLines == ["Reader text"])
    #expect(!store.state.isPreparing)
    await store.finish()
  }

  @Test
  func `comment reader renders the thread and retains an unfinished reply across reading`() async throws {
    let state = try await fixture()
    let root = DiscussionComment(
      id: 1,
      author: "author",
      body: "Original **context**",
      anchor: .init(path: "A.swift", line: 2, side: .right),
    )
    let reply = DiscussionComment(id: 2, author: "reviewer", body: "Existing reply", anchor: root.anchor, replyToID: 1)
    var initial = CommentFeature.State(item: try #require(state.selectedItem), expectedHead: "head", target: root)
    initial.isViewing = true
    initial.threadComments = [root, reply]
    let store = TestStore(initialState: initial) { CommentFeature() } withDependencies: {
      $0[DocumentClient.self] = DocumentRenderer.client
      $0[ForgeClient.self].commentContext = { _, target in .init(
        comment: target,
        canReply: true,
        canEdit: true,
        canDelete: false,
        canReact: true,
        viewer: "reviewer",
      ) }
    }
    store.exhaustivity = .off
    await store.send(.appeared)
    await store.receive(\.contextResponse)
    await store.receive(\.threadResponse)
    while store.state.isPreparing { await store.receive(\.threadResponse) }
    #expect(store.state.threadDocument?.searchableLines.joined().contains("Existing reply") == true)
    #expect(store.state.mutation == nil)
    await store.send(.operationSelected(.reply))
    await store.send(.bodyChanged("Unfinished reply"))
    await store.send(.viewThread)
    await store.receive(\.threadResponse)
    await store.send(.operationSelected(.reply))
    #expect(store.state.body == "Unfinished reply")
    #expect(!store.state.isConfirming)
    await store.finish()
  }

  @Test
  func `current branch startup keeps its PR when the list excludes it`() async throws {
    var state = try await fixture()
    let target = try #require(state.selectedItem)
    let detail = try #require(state.detail)
    state.initialItem = target
    state.selectedItemID = nil
    state.detail = nil
    state.items = []
    let other = ForgeItem(
      id: .init(repository: state.repository, number: 2),
      kind: .pullRequest,
      title: "Other PR",
      author: "author",
      url: try #require(URL(string: "https://github.com/owner/repo/pull/2")),
    )
    let (ready, release) = AsyncStream<Void>.makeStream()
    defer { release.finish() }
    let store = TestStore(initialState: state) { WorkspaceFeature() } withDependencies: {
      $0[ForgeClient.self].list = { _, _, _ in .init(items: [other]) }
      $0[ForgeClient.self].detail = { _ in
        for await _ in ready { break }
        return detail
      }
      $0[DocumentClient.self] = DocumentRenderer.client
      $0[DiffClient.self].render = { request in Self.diff(request.file.path) }
    }
    store.exhaustivity = .off
    await store.send(.appeared)
    await store.receive(\.initialItemListResponse)
    release.yield(())
    await store.receive(\.detailResponse)
    await store.receive(\.contentResponse)
    await store.finish()
    #expect(store.state.selectedItemID == target.id)
    #expect(!store.state.isSelectingItems)
    #expect(store.state.pane == .files)
    #expect(Set(store.state.items.map(\.id)) == [target.id, other.id])
  }

  // MARK: Private

  private nonisolated static func diff(_ path: String = "A.swift") -> ReviewDiff {
    .init(path: path, language: "Swift", status: "changed", rows: (1...30).map { number in
      .init(
        left: .init(number: number, spans: [.init(text: "old line", role: .removed)]),
        right: .init(number: number, spans: [.init(text: "new line", role: .added)]),
      )
    }, revision: .init(mergeBase: "base", head: "head"))
  }

  private func fixture() async throws -> WorkspaceFeature.State {
    let repository = try RepositoryID("owner/repo")
    let item = ForgeItem(
      id: .init(repository: repository, number: 1),
      kind: .pullRequest,
      title: "Review UX",
      author: "author",
      url: URL(string: "https://github.com/owner/repo/pull/1")!,
    )
    var state = WorkspaceFeature.State(repository: repository)
    state.items = [item]
    state.selectedItemID = item.id
    state.detail = .init(
      item: item,
      revision: .init(mergeBase: "base", head: "head"),
      files: [.init(path: "A.swift", patch: "@@ -1,3 +1,3 @@\n-a\n-b\n-c\n+a\n+b\n+c")],
    )
    state.selectedFilePath = "A.swift"
    state.pane = .content
    state.tab = .diff
    state.document = try await DocumentRenderer.prepareDiff(Self.diff(), 120)
    state.diffCursor = try #require(state.document.row(for: .init(path: "A.swift", line: 2, side: .right)))
    return state
  }

  private func presentation(
    _ state: WorkspaceFeature.State,
    size: Size = .init(width: 176, height: 40),
  ) -> WorkspacePresentation {
    .init(
      store: Store(initialState: state) { WorkspaceFeature() },
      size: size,
      demo: true,
      fields: [:],
      editors: [:],
      editorTexts: [:],
      reviewScroll: 0,
      reviewPreview: nil,
      commentScroll: 0,
      failure: nil,
      noColor: false,
      ascii: false,
      cursorFollowsFocus: false,
      palette: Palette(state.preferences.theme),
    )
  }

}

// MARK: - CurrentBranchTests

struct CurrentBranchTests {
  @Test(arguments: ["github.com", "github.example.com"])
  func `current branch lookup validates the repository and preserves gh failures`(_ host: String) async throws {
    let repository = try RepositoryID("owner/repo", host: host)
    let runner = CommandRunner { executable, arguments, _ in
      #expect(executable == "gh")
      #expect(arguments == ["pr", "view", "--json", "number,title,url,author,state,isDraft"])
      return .init(
        output: Data(
          "{\"number\":7,\"title\":\"Current\",\"state\":\"CLOSED\",\"isDraft\":false,\"url\":\"https://\(host)/owner/repo/pull/7\",\"author\":{\"login\":\"author\"}}"
            .utf8
        )
      )
    }
    let item = try await GitHubAdapter(runner: runner).currentPullRequest(repository)
    #expect(item.id == .init(repository: repository, number: 7))
    #expect(item.state == .closed)
    await #expect(throws: TataraError.self) { try await GitHubAdapter(runner: runner).currentPullRequest(RepositoryID(
      "different/repo",
      host: host,
    )) }
    let missing = CommandRunner { _, _, _ in .init(error: "no pull requests found for branch", status: 1) }
    await #expect(throws: TataraError.self) { try await GitHubAdapter(runner: missing).currentPullRequest(repository) }
  }
}
