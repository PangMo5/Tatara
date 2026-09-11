// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import TataraCore

@Reducer
public struct ReviewFeature {
  @ObservableState
  public struct State: Equatable {
    public var item: ForgeItem
    public var expectedHead: String?
    public var latestHead: String?
    public var expectedMergeBase: String?
    public var latestMergeBase: String?
    public var revisionChanged: Bool {
      expectedHead != latestHead || expectedMergeBase != latestMergeBase
    }

    public var body = ""
    public var event = ReviewEvent.comment
    public var isConfirming = false
    public var isSubmitting = false
    public var error: TataraError?
    public var selectedFile: ChangedFile?
    public var comments: [InlineComment] = []
    public var isEditingInline = false
    public var inlineLine = ""
    public var inlineStartLine = ""
    public var inlineAnchorLocked = false
    public var inlineDrafts: [String: String] = [:]
    public var inlineSide = InlineComment.Side.right
    public var inlineBody = ""
    private var inlineKey: String {
      "\(selectedFile?.path ?? "")|\(inlineSide)|\(inlineStartLine)|\(inlineLine)"
    }

    public mutating func stashInlineDraft() {
      if !inlineBody.isEmpty {
        inlineDrafts[inlineKey] = inlineBody
      }
    }

    public mutating func restoreInlineDraft() {
      inlineBody = inlineDrafts[inlineKey] ?? ""
    }

    public init(item: ForgeItem, expectedHead: String?, expectedMergeBase: String? = nil) {
      self.item = item
      self.expectedHead = expectedHead
      latestHead = expectedHead
      self.expectedMergeBase = expectedMergeBase
      latestMergeBase = expectedMergeBase
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

  @Dependency(ForgeClient.self) var forge
  public init() {}
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
        state.isEditingInline = false
        state.isConfirming = false
        state.error = nil
        return .none
      case .cancelButtonPressed:
        return state.isSubmitting ? .none : .send(.delegate(.dismissed))
      case let .inlineLineChanged(line): state.inlineLine = line
        state.error = nil
        return .none
      case let .inlineStartLineChanged(line): state.inlineStartLine = line
        state.error = nil
        return .none
      case let .inlineSideSelected(side): state.inlineSide = side
        state.error = nil
        return .none
      case let .inlineBodyChanged(body): state.inlineBody = body
        state.error = nil
        return .none
      case .addInlineButtonPressed:
        guard !state.isSubmitting else { return .none }
        guard !state.revisionChanged else { state.error = .init(.revisionChanged)
          return .none
        }
        guard let file = state.selectedFile, let line = Int(state.inlineLine),
              let start = state.inlineStartLine.isEmpty ? line : Int(state.inlineStartLine), start > 0, start <= line,
              file.anchors.contains(range: start ... line, side: state.inlineSide)
        else { state.error = .init(.invalidLine)
          return .none
        }
        guard !state.inlineBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          state.error = .init(.emptyReview)
          return .none
        }
        state.comments.append(.init(
          path: file.path,
          line: line,
          side: state.inlineSide,
          body: state.inlineBody,
          startLine: start == line ? nil : start,
        ))
        state.inlineDrafts["\(file.path)|\(state.inlineSide)|\(state.inlineStartLine)|\(state.inlineLine)"] = nil
        state.isEditingInline = false
        state.inlineBody = ""
        state.inlineLine = ""
        state.inlineStartLine = ""
        state.isConfirming = false
        state.error = nil
        return .none
      case .cancelInlineButtonPressed: state.isEditingInline = false
        state.error = nil
        return .none
      case let .removeInlineButtonPressed(index):
        guard !state.isSubmitting, state.comments.indices.contains(index) else { return .none }
        state.comments.remove(at: index)
        state.isConfirming = false
        return .none
      case let .bodyChanged(value):
        guard !state.isSubmitting else { return .none }
        state.body = value
        state.isConfirming = false
        state.error = nil
        return .none
      case let .eventSelected(value):
        guard !state.isSubmitting, state.item.kind == .pullRequest || value == .comment else { return .none }
        state.event = value
        state.isConfirming = false
        return .none
      case .previewButtonPressed:
        guard !state.isSubmitting else { return .none }
        guard !state.revisionChanged else { state.error = .init(.revisionChanged)
          return .none
        }
        guard !state.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !state.comments.isEmpty || state
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
      case let .submissionResponse(.failure(error)):
        state.isSubmitting = false
        state.error = error
        state.isConfirming = false
        return .none
      case .delegate:
        return .none
      }
    }
  }
}
