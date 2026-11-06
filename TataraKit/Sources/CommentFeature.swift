// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import Foundation
import TataraCore

@Reducer
public struct CommentFeature {

  // MARK: Lifecycle

  public init() { }

  // MARK: Public

  @ObservableState
  public struct State: Equatable {

    // MARK: Lifecycle

    public init(
      item: ForgeItem,
      expectedHead: String?,
      target: DiscussionComment,
      operation: CommentOperation = .reply,
      strings: [String: String] = [:],
    ) {
      self.item = item
      self.expectedHead = expectedHead
      self.target = target
      self.operation = operation
      body = operation == .edit ? target.body : ""
      self.strings = strings
    }

    // MARK: Public

    public var item: ForgeItem
    public var expectedHead: String?
    public var target: DiscussionComment
    public var isViewing = false
    public var threadComments = [DiscussionComment]()
    public var threadTarget: DiscussionComment?
    public var threadDocument: ReviewDocument?
    public var threadScroll = 0
    public var threadWidth = 88
    public var threadHeight = 16
    public var threadGeneration = 0
    public var context: CommentContext?
    public var operation: CommentOperation
    public var body: String
    public var reaction = ReactionContent.thumbsUp
    public var isLoading = true
    public var isPreparing = false
    public var isConfirming = false
    public var isSubmitting = false
    public var hasSubmittedPreview = false
    public var preview: ReviewDocument?
    public var previewScroll = 0
    public var generation = 0
    public var error: TataraError?
    public var strings: [String: String]

    public var mutation: CommentMutation? {
      guard !isViewing, let context, context.allows(operation) else { return nil }
      let submittedBody = operation == .reply && target.anchor == nil ? "@\(context.comment.author)\n\n" + body : body
      return .init(
        item: item,
        expectedHead: expectedHead,
        context: context,
        operation: operation,
        body: submittedBody,
        reaction: reaction,
      )
    }

    public func text(_ key: String) -> String {
      strings[key] ?? key
    }

  }

  public enum Action: Sendable {
    case appeared
    case viewThread
    case threadRequested(width: Int, height: Int)
    case threadResponse(key: String, generation: Int, Result<ReviewDocument, TataraError>)
    case threadScrolled(Int)
    case contextResponse(Result<CommentContext, TataraError>)
    case operationSelected(CommentOperation)
    case bodyChanged(String)
    case reactionSelected(ReactionContent)
    case previewPressed(width: Int)
    case previewResponse(generation: Int, Result<ReviewDocument, TataraError>)
    case previewScrolled(Int)
    case editPressed
    case confirmPressed
    case submissionResponse(Result<Void, TataraError>)
    case close
    case delegate(Delegate)

    public enum Delegate: Sendable { case changed, dismissed }
  }

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .appeared:
        let item = state.item
        let target = state.target
        let context = Effect<Action>.run { [forge] send in
          do { try await send(.contextResponse(.success(forge.commentContext(item, target)))) }
          catch is CancellationError {} catch { await send(.contextResponse(.failure(.wrapping(error)))) }
        }.cancellable(id: CancelID.context, cancelInFlight: true)
        return state.isViewing
          ? .merge(context, .send(.threadRequested(width: state.threadWidth, height: state.threadHeight)))
          : context

      case .contextResponse(let result):
        state.isLoading = false
        switch result {
        case .success(let context):
          guard context.comment.key == state.target.key else { return .none }
          if state.operation == .edit, state.body == state.target.body {
            state.body = context.comment.body
          }
          state.context = context
          state.target = context.comment
          if state.operation == .resolve, context.thread?.isResolved == true {
            state.operation = .unresolve
          }
          if !state.isViewing, !context.allows(state.operation) {
            state.error = .init(.unavailable)
          }

        case .failure(let error): state.error = error
        }
        return state.isViewing ? .send(.threadRequested(width: state.threadWidth, height: state.threadHeight)) : .none

      case .viewThread:
        guard !state.isSubmitting else { return .none }
        state.isViewing = true
        state.isConfirming = false
        state.generation += 1
        return .merge(
          .cancel(id: CancelID.preview),
          .send(.threadRequested(width: state.threadWidth, height: state.threadHeight)),
        )

      case .threadRequested(let width, let height):
        guard state.isViewing else { return .none }
        let reusable = state.threadWidth == max(1, width) && state.threadTarget == state.target
        state.threadWidth = max(1, width)
        state.threadHeight = max(1, height)
        if reusable, state.isPreparing || state.threadDocument != nil {
          state.threadScroll = min(state.threadScroll, max(0, (state.threadDocument?.lines.count ?? 0) - state.threadHeight))
          return .none
        }
        state.threadTarget = state.target
        state.threadGeneration += 1
        let generation = state.threadGeneration
        let target = state.target
        let comments = state.threadComments
        state.isPreparing = true
        return .run(priority: .utility) { [documents] send in
          do {
            let markdown = try await Self.threadText(comments, target: target)
            let document = try await documents.prepareComment(markdown, max(1, width))
            try Task.checkCancellation()
            await send(.threadResponse(key: target.key, generation: generation, .success(document)))
          } catch is CancellationError {} catch {
            if
              !Task
                .isCancelled
            {
              await send(.threadResponse(key: target.key, generation: generation, .failure(.wrapping(error))))
            }
          }
        }.cancellable(id: CancelID.thread, cancelInFlight: true)

      case .threadResponse(let key, let generation, let result):
        guard state.isViewing, key == state.target.key, generation == state.threadGeneration else { return .none }
        state.isPreparing = false
        switch result {
        case .success(let document):
          state.threadDocument = document
          state.threadScroll = min(state.threadScroll, max(0, document.lines.count - state.threadHeight))

        case .failure(let error): state.error = error
        }
        return .none

      case .threadScrolled(let delta):
        state.threadScroll = max(
          0,
          min(max(0, (state.threadDocument?.lines.count ?? 0) - state.threadHeight), state.threadScroll + delta),
        )
        return .none

      case .operationSelected(let operation):
        guard !state.isSubmitting, state.context?.allows(operation) == true else { return .none }
        state.threadTarget = nil
        state.isViewing = false
        if state.operation != operation {
          state.body = operation == .edit ? state.target.body : ""
        }
        state.operation = operation
        state.isConfirming = false
        state.preview = nil
        state.isPreparing = false
        state.error = nil
        state.generation += 1
        return .merge(.cancel(id: CancelID.preview), .cancel(id: CancelID.thread))

      case .bodyChanged(let value):
        guard !state.isSubmitting else { return .none }
        state.body = value
        state.isConfirming = false
        state.isPreparing = false
        state.generation += 1
        return .cancel(id: CancelID.preview)

      case .reactionSelected(let value):
        guard !state.isSubmitting else { return .none }
        state.reaction = value
        state.isConfirming = false
        state.isPreparing = false
        state.generation += 1
        return .cancel(id: CancelID.preview)

      case .previewPressed(let width):
        guard !state.isSubmitting, !state.isLoading, let mutation = state.mutation else { return .none }
        if
          mutation.operation == .reply || mutation.operation == .edit,
          mutation.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.body
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
          state.error = .init(.emptyReview)
          return .none
        }
        state.generation += 1
        let generation = state.generation
        state.isPreparing = true
        state.error = nil
        let body: String
        if mutation.operation == .reply || mutation.operation == .edit {
          body = mutation.body
        } else if mutation.operation == .react {
          let remove = mutation.context.reactions.first { $0.content == mutation.reaction }?.viewerHasReacted == true
          body = state.text(remove ? "Remove reaction" : "Add reaction") + ": " + state
            .text(mutation.reaction.symbol) + "\n\n" + mutation.context.comment.body
        } else {
          body = mutation.context.comment.body
        }
        return .run { [documents] send in
          do { try await send(.previewResponse(
            generation: generation,
            .success(documents.prepareComment(body, max(1, width))),
          )) } catch is CancellationError {} catch { await send(.previewResponse(
            generation: generation,
            .failure(.wrapping(error)),
          )) }
        }.cancellable(id: CancelID.preview, cancelInFlight: true)

      case .previewResponse(let generation, let result):
        guard generation == state.generation else { return .none }
        state.isPreparing = false
        switch result {
        case .success(let document): state.preview = document
          state.previewScroll = 0
          state.isConfirming = true
          state.hasSubmittedPreview = false

        case .failure(let error): state.error = error
        }
        return .none

      case .previewScrolled(let delta):
        state.previewScroll = max(0, min(max(0, (state.preview?.lines.count ?? 0) - 1), state.previewScroll + delta))
        return .none

      case .editPressed:
        guard !state.isSubmitting else { return .none }
        state.isConfirming = false
        return .none

      case .confirmPressed:
        guard
          state.isConfirming,
          !state.hasSubmittedPreview,
          !state.isSubmitting,
          !state.isPreparing,
          state.preview != nil,
          let mutation = state.mutation
        else { return .none }
        state.isSubmitting = true
        state.hasSubmittedPreview = true
        state.error = nil
        return .run { [forge] send in
          do { try await forge.mutateComment(mutation)
            await send(.submissionResponse(.success(())))
          } catch { await send(.submissionResponse(.failure(.wrapping(error)))) }
        }.cancellable(id: CancelID.submission)

      case .submissionResponse(let result):
        state.isSubmitting = false
        switch result {
        case .success: return .send(.delegate(.changed))
        case .failure(let error): state.error = error
          state.isConfirming = false
        }
        return .none

      case .close:
        guard !state.isSubmitting else { return .none }
        return .send(.delegate(.dismissed))

      case .delegate: return .none
      }
    }
  }

  // MARK: Internal

  enum CancelID { case context, preview, submission, thread }

  @Dependency(ForgeClient.self) var forge
  @Dependency(DocumentClient.self) var documents

  // MARK: Private

  @concurrent
  private static func threadText(_ comments: [DiscussionComment], target: DiscussionComment) async throws -> String {
    let root = target.replyToID ?? target.id
    var thread = comments.filter { $0.id == root || $0.replyToID == root }
    if let index = thread.firstIndex(where: { $0.key == target.key }) {
      thread[index] = target
    } else {
      thread.append(target)
    }
    var blocks = [String]()
    for comment in thread {
      try Task.checkCancellation()
      blocks.append("### @" + comment.author + "\n\n" + comment.body)
    }
    return blocks.joined(separator: "\n\n---\n\n")
  }

}
