// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import TataraCore

@Reducer
public struct ReviewFeature {

  // MARK: Lifecycle

  public init() { }

  // MARK: Public

  @ObservableState
  public struct State: Equatable {

    // MARK: Lifecycle

    public init(item: ForgeItem, expectedHead: String?, expectedMergeBase: String? = nil) {
      self.item = item
      self.expectedHead = expectedHead
      latestHead = expectedHead
      self.expectedMergeBase = expectedMergeBase
      latestMergeBase = expectedMergeBase
    }

    // MARK: Public

    public var item: ForgeItem
    public var expectedHead: String?
    public var latestHead: String?
    public var expectedMergeBase: String?
    public var latestMergeBase: String?
    public var body = ""
    public var event = ReviewEvent.comment
    public var isConfirming = false
    public var isSubmitting = false
    public var error: TataraError?
    public var selectedFile: ChangedFile?
    public private(set) var commentIdentities = [Int]()
    public var isEditingInline = false
    public var inlineLine = ""
    public var inlineStartLine = ""
    public var inlineAnchorLocked = false
    public var editingCommentIndex: Int?
    public var inlineDrafts = [String: String]()
    public var inlineSide = InlineComment.Side.right
    public var inlineBody = ""

    public var comments: [InlineComment] {
      get { storedComments }
      set {
        storedComments = newValue
        commentIdentities = []
        for _ in newValue {
          let identity = nextCommentIdentity
          nextCommentIdentity += 1
          commentIdentities.append(identity)
        }
      }
    }

    public var revisionChanged: Bool {
      expectedHead != latestHead || expectedMergeBase != latestMergeBase
    }

    public mutating func stashInlineDraft() {
      if !inlineBody.isEmpty {
        inlineDrafts[inlineKey] = inlineBody
      }
    }

    public mutating func restoreInlineDraft(fallback: String = "") {
      inlineBody = inlineDrafts[inlineKey] ?? fallback
    }

    public mutating func discardInlineDraft() {
      inlineDrafts[inlineKey] = nil
    }

    public mutating func commitInlineComment(_ comment: InlineComment) {
      if let index = editingCommentIndex {
        storedComments[index] = comment
      } else {
        storedComments.append(comment)
        let identity = nextCommentIdentity
        nextCommentIdentity += 1
        commentIdentities.append(identity)
      }
    }

    public mutating func removeInlineComment(id: Int) {
      guard let index = commentIdentities.firstIndex(of: id) else { return }
      inlineDrafts["edit:\(id)"] = nil
      storedComments.remove(at: index)
      commentIdentities.remove(at: index)
      if let editing = editingCommentIndex {
        if editing == index {
          editingCommentIndex = nil
          isEditingInline = false
          inlineBody = ""
        } else if editing > index {
          editingCommentIndex = editing - 1
        }
      }
    }

    // MARK: Private

    private var storedComments = [InlineComment]()
    private var nextCommentIdentity = 0

    private var inlineKey: String {
      if let index = editingCommentIndex {
        return "edit:\(commentIdentities[index])"
      }
      return "\(selectedFile?.path ?? "")|\(inlineSide)|\(inlineStartLine)|\(inlineLine)"
    }

  }

  public enum Action {
    case bodyChanged(String)
    case eventSelected(ReviewEvent)
    case previewButtonPressed
    case editButtonPressed
    case submitButtonPressed
    case inlineLineChanged(String)
    case inlineStartLineChanged(String)
    case inlineSideSelected(InlineComment.Side)
    case inlineBodyChanged(String)
    case addInlineButtonPressed
    case cancelInlineButtonPressed
    case cancelButtonPressed
    case reviewLatestRevisionButtonPressed
    case removeInlineButtonPressed(Int)
    case submissionResponse(Result<Void, TataraError>)
    case delegate(Delegate)

    public enum Delegate { case submitted, dismissed }
  }

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .reviewLatestRevisionButtonPressed:
        guard !state.isSubmitting, state.revisionChanged else { return .none }
        state.expectedHead = state.latestHead
        state.expectedMergeBase = state.latestMergeBase
        state.comments = []
        state.inlineBody = ""
        state.inlineLine = ""
        state.inlineStartLine = ""
        state.inlineDrafts = [:]
        state.editingCommentIndex = nil
        state.isEditingInline = false
        state.isConfirming = false
        state.error = nil
        return .none

      case .cancelButtonPressed:
        return state.isSubmitting ? .none : .send(.delegate(.dismissed))

      case .inlineLineChanged(let line): state.inlineLine = line
        state.error = nil
        return .none

      case .inlineStartLineChanged(let line): state.inlineStartLine = line
        state.error = nil
        return .none

      case .inlineSideSelected(let side): state.inlineSide = side
        state.error = nil
        return .none

      case .inlineBodyChanged(let body): state.inlineBody = body
        state.error = nil
        return .none

      case .addInlineButtonPressed:
        guard !state.isSubmitting else { return .none }
        guard !state.revisionChanged else { state.error = .init(.revisionChanged)
          return .none
        }
        guard
          let file = state.selectedFile,
          let line = Int(state.inlineLine),
          let start = state.inlineStartLine.isEmpty ? line : Int(state.inlineStartLine),
          start > 0,
          start <= line,
          file.anchors.contains(range: start ... line, side: state.inlineSide)
        else { state.error = .init(.invalidLine)
          return .none
        }
        guard !state.inlineBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          state.error = .init(.emptyReview)
          return .none
        }
        let comment = InlineComment(
          path: file.path,
          line: line,
          side: state.inlineSide,
          body: state.inlineBody,
          startLine: start == line ? nil : start,
        )
        state.commitInlineComment(comment)
        state.discardInlineDraft()
        state.editingCommentIndex = nil
        state.isEditingInline = false
        state.inlineBody = ""
        state.inlineLine = ""
        state.inlineStartLine = ""
        state.isConfirming = false
        state.error = nil
        return .none

      case .cancelInlineButtonPressed:
        state.stashInlineDraft()
        state.isEditingInline = false
        state.editingCommentIndex = nil
        state.inlineBody = ""
        state.error = nil
        return .none

      case .removeInlineButtonPressed(let id):
        guard !state.isSubmitting else { return .none }
        state.removeInlineComment(id: id)
        state.isConfirming = false
        return .none

      case .bodyChanged(let value):
        guard !state.isSubmitting else { return .none }
        state.body = value
        state.isConfirming = false
        state.error = nil
        return .none

      case .eventSelected(let value):
        guard !state.isSubmitting, state.item.kind == .pullRequest || value == .comment else { return .none }
        state.event = value
        state.isConfirming = false
        return .none

      case .previewButtonPressed:
        guard !state.isSubmitting else { return .none }
        guard !state.revisionChanged else { state.error = .init(.revisionChanged)
          return .none
        }
        guard
          !state.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !state.comments.isEmpty || state
            .event == .approve
        else {
          state.error = .init(.emptyReview)
          return .none
        }
        state.error = nil
        state.isConfirming = true
        return .none

      case .editButtonPressed:
        guard !state.isSubmitting else { return .none }
        state.isConfirming = false
        return .none

      case .submitButtonPressed:
        guard state.isConfirming, !state.isSubmitting, !state.revisionChanged else { return .none }
        state.isSubmitting = true
        let submission = ReviewSubmission(
          item: state.item,
          expectedHead: state.expectedHead,
          event: state.event,
          body: state.body,
          comments: state.comments,
          expectedMergeBase: state.expectedMergeBase,
        )
        return .run { [forge] send in
          do { try await forge.submit(submission)
            await send(.submissionResponse(.success(())))
          } catch { await send(.submissionResponse(.failure(.wrapping(error)))) }
        }

      case .submissionResponse(.success):
        state.isSubmitting = false
        return .send(.delegate(.submitted))

      case .submissionResponse(.failure(let error)):
        state.isSubmitting = false
        state.error = error
        state.isConfirming = false
        return .none

      case .delegate:
        return .none
      }
    }
  }

  // MARK: Internal

  @Dependency(ForgeClient.self) var forge

}
