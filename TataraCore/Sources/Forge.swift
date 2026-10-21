// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

public enum ForgeKind: String, Codable, Sendable { case github }

public struct RepositoryID: Hashable, Codable, Sendable, CustomStringConvertible {
  public var forge: ForgeKind
  public var host: String
  public var owner: String
  public var name: String

  public init(_ slug: String, host: String = "github.com", forge: ForgeKind = .github) throws {
    let parts = slug.split(separator: "/", omittingEmptySubsequences: false)
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
    guard parts.count == 2,
          parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.unicodeScalars.allSatisfy(allowed.contains) }),
          !host.isEmpty, host.unicodeScalars.allSatisfy(allowed.contains), !host.hasPrefix("-")
    else { throw TataraError(.invalidRepository, detail: "Expected OWNER/REPO and a hostname.") }
    self.forge = forge
    self.host = host.lowercased()
    owner = String(parts[0])
    name = String(parts[1])
  }

  public var slug: String {
    "\(owner)/\(name)"
  }

  public var description: String {
    "\(host)/\(slug)"
  }
}

public enum ItemKind: String, Codable, CaseIterable, Sendable { case pullRequest, issue }
public enum ItemState: String, Codable, Sendable { case open, closed, merged }

public struct ItemID: Hashable, Codable, Sendable {
  public var repository: RepositoryID
  public var number: Int
  public init(repository: RepositoryID, number: Int) {
    self.repository = repository
    self.number = number
  }
}

public struct ForgeItem: Identifiable, Equatable, Codable, Sendable {
  public var id: ItemID
  public var kind: ItemKind
  public var title: String
  public var author: String
  public var body: String
  public var url: URL
  public var state: ItemState
  public var labels: [String]
  public var isDraft: Bool
  public var github: GitHubItemSummary?

  public init(
    id: ItemID,
    kind: ItemKind,
    title: String,
    author: String,
    body: String = "",
    url: URL,
    state: ItemState = .open,
    labels: [String] = [],
    isDraft: Bool = false,
    github: GitHubItemSummary? = nil,
  ) {
    self.id = id
    self.kind = kind
    self.title = title
    self.author = author
    self.body = body
    self.url = url
    self.state = state
    self.labels = labels
    self.isDraft = isDraft
    self.github = github
  }
}

/// Nullable GitHub fields retain absence; review decisions are never inferred from review counts.
public struct GitHubItemSummary: Equatable, Codable, Sendable {
  public enum ReviewDecision: String, Codable, Sendable {
    case approved = "APPROVED", changesRequested = "CHANGES_REQUESTED", reviewRequired = "REVIEW_REQUIRED"
  }

  public enum ChecksState: String, Codable, Sendable {
    case success = "SUCCESS", failure = "FAILURE", error = "ERROR", pending = "PENDING", expected = "EXPECTED"
  }

  public var createdAt: String?
  public var updatedAt: String?
  public var closedAt: String?
  public var mergedAt: String?
  public var assignees: [String]
  public var milestone: String?
  public var requestedReviewers: [String]
  public var requestedTeams: [String]
  public var commentCount: Int?
  public var reviewDecision: ReviewDecision?
  public var checksState: ChecksState?
  public var headOID: String?
  public var headBranch: String?
  public var baseBranch: String?
  public var additions: Int?
  public var deletions: Int?
  public var changedFiles: Int?
  public var commits: Int?

  public init(
    createdAt: String? = nil,
    updatedAt: String? = nil,
    closedAt: String? = nil,
    mergedAt: String? = nil,
    assignees: [String] = [],
    milestone: String? = nil,
    requestedReviewers: [String] = [],
    requestedTeams: [String] = [],
    commentCount: Int? = nil,
    reviewDecision: ReviewDecision? = nil,
    checksState: ChecksState? = nil,
    headOID: String? = nil,
    headBranch: String? = nil,
    baseBranch: String? = nil,
    additions: Int? = nil,
    deletions: Int? = nil,
    changedFiles: Int? = nil,
    commits: Int? = nil,
  ) {
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.closedAt = closedAt
    self.mergedAt = mergedAt
    self.assignees = assignees
    self.milestone = milestone
    self.requestedReviewers = requestedReviewers
    self.requestedTeams = requestedTeams
    self.commentCount = commentCount
    self.reviewDecision = reviewDecision
    self.checksState = checksState
    self.headOID = headOID
    self.headBranch = headBranch
    self.baseBranch = baseBranch
    self.additions = additions
    self.deletions = deletions
    self.changedFiles = changedFiles
    self.commits = commits
  }

  public var reviewTitleKey: String {
    switch reviewDecision {
    case .approved: "Approved"
    case .changesRequested: "Changes requested"
    case .reviewRequired: "Review required"
    case nil: "Not reported"
    }
  }

  public var checksTitleKey: String {
    switch checksState {
    case .success: "Passed"
    case .failure: "Failed"
    case .error: "Error"
    case .pending: "Pending"
    case .expected: "Expected"
    case nil: "Not reported"
    }
  }

  public var estimatedByteCount: Int {
    (assignees + requestedReviewers + requestedTeams +
      [createdAt, updatedAt, closedAt, mergedAt, milestone, headOID, headBranch, baseBranch].compactMap(\.self))
      .reduce(512) { $0 + $1.utf8.count + 32 }
  }
}

public struct ItemPage: Equatable, Codable, Sendable {
  public var items: [ForgeItem]
  public var nextPage: Int?
  public init(items: [ForgeItem], nextPage: Int? = nil) {
    self.items = items
    self.nextPage = nextPage
  }
}

public struct ForgeCapabilities: Equatable, Sendable {
  public var reviews: Bool
  public var inlineComments: Bool
  public var issues: Bool
  public init(reviews: Bool, inlineComments: Bool, issues: Bool) {
    self.reviews = reviews
    self.inlineComments = inlineComments
    self.issues = issues
  }
}

public struct DiscussionComment: Identifiable, Equatable, Codable, Sendable {
  public var id: Int
  public var author: String
  public var body: String
  public var context: String?
  public var anchor: DiscussionAnchor?
  public var nodeID: String?
  public var url: URL?
  public var updatedAt: String?
  public var replyToID: Int?
  public var key: String {
    (anchor == nil ? "issue:" : "review:") + String(id)
  }

  public init(
    id: Int,
    author: String,
    body: String,
    context: String? = nil,
    anchor: DiscussionAnchor? = nil,
    nodeID: String? = nil,
    url: URL? = nil,
    updatedAt: String? = nil,
    replyToID: Int? = nil,
  ) {
    self.id = id
    self.author = author
    self.body = body
    self.context = context
    self.anchor = anchor
    self.nodeID = nodeID
    self.url = url
    self.updatedAt = updatedAt
    self.replyToID = replyToID
  }
}

/// GitHub's current diff coordinates are distinct from the original, potentially outdated line.
public struct DiscussionAnchor: Equatable, Codable, Sendable {
  public var path: String
  public var line: Int?
  public var startLine: Int?
  public var side: InlineComment.Side?
  public var subjectType: String?
  public var originalLine: Int?
  public var commitID: String?
  public init(
    path: String,
    line: Int?,
    side: InlineComment.Side?,
    startLine: Int? = nil,
    originalLine: Int? = nil,
    commitID: String? = nil,
    subjectType: String? = nil,
  ) {
    self.path = path
    self.line = line
    self.side = side
    self.startLine = startLine
    self.subjectType = subjectType
    self.originalLine = originalLine
    self.commitID = commitID
  }
}

/// GitHub semantics remain typed; a future GitLab adapter adds its own case.
public enum ForgeMetadata: Equatable, Codable, Sendable {
  case github(GitHubMetadata)
}

public struct GitHubMetadata: Equatable, Codable, Sendable {
  public var baseBranch: String
  public var headBranch: String
  public var mergeableState: String
  public var checks: [String]
  public var reviews: [String]
  public init(
    baseBranch: String,
    headBranch: String,
    mergeableState: String,
    checks: [String] = [],
    reviews: [String] = [],
  ) {
    self.baseBranch = baseBranch
    self.headBranch = headBranch
    self.mergeableState = mergeableState
    self.checks = checks
    self.reviews = reviews
  }
}

public struct ItemDetail: Equatable, Codable, Sendable {
  public let item: ForgeItem
  public let revision: PullRequestRevision?
  public let files: [ChangedFile]
  public let fileTree: FileTree
  private let fileIndices: [String: Int]
  private let commentIndices: [String: Int]
  private let fileCommentCounts: [String: Int]
  public let comments: [DiscussionComment]
  public let metadata: ForgeMetadata?
  public let estimatedByteCount: Int
  public init(
    item: ForgeItem,
    revision: PullRequestRevision? = nil,
    files: [ChangedFile] = [],
    comments: [DiscussionComment] = [],
    metadata: ForgeMetadata? = nil,
  ) {
    self.item = item
    self.revision = revision
    self.files = files
    fileTree = FileTree(paths: files.map(\.path))
    fileIndices = Dictionary(files.enumerated().map { ($0.element.path, $0.offset) }, uniquingKeysWith: { first, _ in first })
    self.comments = comments
    commentIndices = Dictionary(
      comments.enumerated().map { ($0.element.key, $0.offset) },
      uniquingKeysWith: { first, _ in first },
    )
    fileCommentCounts = comments.reduce(into: [:]) { counts, comment in
      if let path = comment.anchor?.path {
        counts[path, default: 0] += 1
      }
    }
    self.metadata = metadata
    let itemBytes = [item.title, item.author, item.body, item.url.absoluteString].reduce(512) { $0 + $1.utf8.count }
      + item.labels.reduce(0) { $0 + $1.utf8.count + 32 }
    let fileBytes = files.reduce(0) { $0 + $1.path.utf8.count * 3 + ($1.previousPath?.utf8.count ?? 0)
      + ($1.patch?.utf8.count ?? 0) + 512
    }
    let commentBytes = comments.reduce(0) { $0 + $1.body.utf8.count + $1.author.utf8.count
      + ($1.context?.utf8.count ?? 0) + 128
    }
    let metadataBytes: Int = if case let .github(value) = metadata {
      (value.checks + value.reviews + [value.baseBranch, value.headBranch, value.mergeableState])
        .reduce(0) { $0 + $1.utf8.count + 32 }
    } else {
      0
    }
    let commentIndexBytes = fileCommentCounts.keys.reduce(0) { $0 + $1.utf8.count + 64 }
    estimatedByteCount = itemBytes + fileBytes + commentBytes + commentIndexBytes + metadataBytes
      + (item.github?.estimatedByteCount ?? 0)
  }

  public func file(at path: String) -> ChangedFile? {
    fileIndices[path].map { files[$0] }
  }

  public func comment(for key: String) -> DiscussionComment? {
    commentIndices[key].map { comments[$0] }
  }

  /// Published file comments, including replies and outdated anchors; excludes PR-level discussion.
  public func commentCount(at path: String) -> Int {
    fileCommentCounts[path, default: 0]
  }

  private enum CodingKeys: String, CodingKey { case item, revision, files, comments, metadata }
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      item: values.decode(ForgeItem.self, forKey: .item),
      revision: values.decodeIfPresent(PullRequestRevision.self, forKey: .revision),
      files: values.decode([ChangedFile].self, forKey: .files),
      comments: values.decode([DiscussionComment].self, forKey: .comments),
      metadata: values.decodeIfPresent(ForgeMetadata.self, forKey: .metadata),
    )
  }
}

public struct PullRequestRevision: Hashable, Codable, Sendable {
  public var mergeBase: String
  public var head: String
  public init(mergeBase: String, head: String) {
    self.mergeBase = mergeBase
    self.head = head
  }
}

public struct ChangedFile: Identifiable, Equatable, Codable, Sendable {
  public var path: String
  public var previousPath: String?
  public var status: String
  public var additions: Int
  public var deletions: Int
  public let patch: String?
  public let anchors: ReviewAnchorIndex
  public var id: String {
    path
  }

  public init(
    path: String,
    previousPath: String? = nil,
    status: String = "modified",
    additions: Int = 0,
    deletions: Int = 0,
    patch: String? = nil,
  ) {
    self.path = path
    self.previousPath = previousPath
    self.status = status
    self.additions = additions
    self.deletions = deletions
    self.patch = patch
    anchors = ReviewAnchorIndex(patch: patch)
  }

  private enum CodingKeys: String, CodingKey { case path, previousPath, status, additions, deletions, patch }
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      path: values.decode(String.self, forKey: .path),
      previousPath: values.decodeIfPresent(String.self, forKey: .previousPath),
      status: values.decode(String.self, forKey: .status),
      additions: values.decode(Int.self, forKey: .additions),
      deletions: values.decode(Int.self, forKey: .deletions),
      patch: values.decodeIfPresent(String.self, forKey: .patch),
    )
  }
}

public enum ReviewEvent: String, CaseIterable, Codable, Sendable {
  case comment = "COMMENT", approve = "APPROVE", requestChanges = "REQUEST_CHANGES"
}

public struct ReviewSubmission: Equatable, Sendable {
  public var item: ForgeItem
  public var expectedHead: String?
  public var event: ReviewEvent
  public var body: String
  public var comments: [InlineComment]
  public var expectedMergeBase: String?
  public init(
    item: ForgeItem,
    expectedHead: String?,
    event: ReviewEvent,
    body: String,
    comments: [InlineComment] = [],
    expectedMergeBase: String? = nil,
  ) {
    self.item = item
    self.expectedHead = expectedHead
    self.event = event
    self.body = body
    self.comments = comments
    self.expectedMergeBase = expectedMergeBase
  }
}

public struct TataraError: Error, Equatable, Sendable, CustomStringConvertible {
  public enum Code: String, Sendable {
    case invalidRepository, configuration, authentication, commandFailed, timedOut, incompleteResponse
    case revisionChanged, unavailable, invalidResponse, emptyReview, invalidLine
  }

  public var code: Code
  public var detail: String
  public init(_ code: Code, detail: String = "") {
    self.code = code
    self.detail = detail
  }

  public var description: String {
    "\(code.rawValue): \(detail)"
  }

  public static func wrapping(_ error: any Error) -> Self {
    error as? Self ?? Self(.commandFailed, detail: String(describing: error))
  }
}

public enum CommentOperation: String, Equatable, Sendable {
  case reply, edit, delete, react, resolve, unresolve
  public var titleKey: String {
    switch self {
    case .reply: "Reply"
    case .edit: "Edit comment"
    case .delete: "Delete comment"
    case .react: "React to comment"
    case .resolve: "Resolve thread"
    case .unresolve: "Reopen thread"
    }
  }
}

public enum ReactionContent: String, CaseIterable, Codable, Sendable {
  case thumbsUp = "THUMBS_UP", thumbsDown = "THUMBS_DOWN", laugh = "LAUGH", hooray = "HOORAY"
  case confused = "CONFUSED", heart = "HEART", rocket = "ROCKET", eyes = "EYES"
  public var symbol: String {
    switch self {
    case .thumbsUp: "+1"
    case .thumbsDown: "-1"
    case .laugh: "Laugh"
    case .hooray: "Hooray"
    case .confused: "Confused"
    case .heart: "Heart"
    case .rocket: "Rocket"
    case .eyes: "Eyes"
    }
  }
}

public struct CommentReaction: Equatable, Sendable {
  public var content: ReactionContent
  public var count: Int
  public var viewerHasReacted: Bool
  public init(content: ReactionContent, count: Int, viewerHasReacted: Bool) {
    self.content = content
    self.count = count
    self.viewerHasReacted = viewerHasReacted
  }
}

public struct ReviewThread: Equatable, Sendable {
  public var id: String
  public var isResolved: Bool
  public var canResolve: Bool
  public var canUnresolve: Bool
  public var canReply: Bool
  public init(id: String, isResolved: Bool, canResolve: Bool, canUnresolve: Bool, canReply: Bool) {
    self.id = id
    self.isResolved = isResolved
    self.canResolve = canResolve
    self.canUnresolve = canUnresolve
    self.canReply = canReply
  }
}

public struct CommentContext: Equatable, Sendable {
  public var viewer: String
  public var comment: DiscussionComment
  public var canReply: Bool
  public var canEdit: Bool
  public var canDelete: Bool
  public var canReact: Bool
  public var thread: ReviewThread?
  public var reactions: [CommentReaction]
  public init(
    comment: DiscussionComment,
    canReply: Bool,
    canEdit: Bool,
    canDelete: Bool,
    canReact: Bool,
    thread: ReviewThread? = nil,
    reactions: [CommentReaction] = [],
    viewer: String = "",
  ) {
    self.viewer = viewer
    self.comment = comment
    self.canReply = canReply
    self.canEdit = canEdit
    self.canDelete = canDelete
    self.canReact = canReact
    self.thread = thread
    self.reactions = reactions
  }

  public func allows(_ operation: CommentOperation) -> Bool {
    switch operation {
    case .reply: canReply
    case .edit: canEdit
    case .delete: canDelete
    case .react: canReact
    case .resolve: thread?.canResolve == true && thread?.isResolved == false
    case .unresolve: thread?.canUnresolve == true && thread?.isResolved == true
    }
  }
}

public struct CommentMutation: Equatable, Sendable {
  public var item: ForgeItem
  public var expectedHead: String?
  public var context: CommentContext
  public var operation: CommentOperation
  public var body: String
  public var reaction: ReactionContent
  public init(
    item: ForgeItem,
    expectedHead: String?,
    context: CommentContext,
    operation: CommentOperation,
    body: String = "",
    reaction: ReactionContent = .thumbsUp,
  ) {
    self.item = item
    self.expectedHead = expectedHead
    self.context = context
    self.operation = operation
    self.body = body
    self.reaction = reaction
  }
}
