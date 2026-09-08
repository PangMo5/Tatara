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
  public init(id: Int, author: String, body: String, context: String? = nil) {
    self.id = id
    self.author = author
    self.body = body
    self.context = context
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
  public var item: ForgeItem
  public var revision: PullRequestRevision?
  public let files: [ChangedFile]
  public let fileTree: FileTree
  public var comments: [DiscussionComment]
  public var metadata: ForgeMetadata?
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
    self.comments = comments
    self.metadata = metadata
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
  public var patch: String?
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
