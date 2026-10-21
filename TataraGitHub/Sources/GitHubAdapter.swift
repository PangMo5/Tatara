// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TataraCore
import TataraKit
import TataraSystem

public struct GitHubAdapter: Sendable {
  public let runner: CommandRunner
  public let cache: CacheClient
  public init(runner: CommandRunner = .live, cache: CacheClient = .disabled) {
    self.runner = runner
    self.cache = cache
  }

  public var capabilities: ForgeCapabilities {
    .init(reviews: true, inlineComments: true, issues: true)
  }

  public var client: ForgeClient {
    ForgeClient(
      invalidate: { try await cache.invalidate(Self.metadataNamespace($0)) },
      list: list,
      search: search,
      labels: labels,
      detail: detail,
      content: content,
      submit: submit,
      commentContext: commentContext,
      mutateComment: mutateComment,
    )
  }

  @concurrent
  public func accountIdentifier(host: String) async throws -> String {
    let value = try await runner.checked("gh", ["api", "--hostname", host, "user", "--jq", ".id"]).text
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, value.allSatisfy(\.isNumber) else { throw TataraError(
      .invalidResponse,
      detail: "Missing GitHub account identity.",
    ) }
    return value
  }

  private static func metadataNamespace(_ repository: RepositoryID) -> String {
    "metadata-v3:\(repository)"
  }

  @concurrent
  public func detectRepository(host: String? = nil) async throws -> RepositoryID {
    struct Repository: Decodable { var nameWithOwner: String
      var url: URL
    }
    let output = try await runner.checked("gh", ["repo", "view", "--json", "nameWithOwner,url"])
    let value = try decode(Repository.self, output.output)
    guard let resolvedHost = value.url.host, host == nil || host?.lowercased() == resolvedHost.lowercased() else {
      throw TataraError(.invalidRepository, detail: "The current repository does not match --host. Pass --repo explicitly.")
    }
    return try RepositoryID(value.nameWithOwner, host: resolvedHost)
  }

  @concurrent
  public func list(_ repository: RepositoryID, _ kind: ItemKind, _ page: Int) async throws -> ItemPage {
    let key = "list:\(kind):\(page)"
    if let data = try await cache.read(Self.metadataNamespace(repository), key, 30) {
      return try decode(ItemPage.self, data)
    }
    let collection = kind == .pullRequest ? "pulls" : "issues"
    let values: [ItemDTO] = try await get(
      repository,
      "\(collection)?state=open&sort=updated&direction=desc&per_page=100&page=\(page)",
    )
    let items = try await enrich(
      values.filter { kind != .issue || $0.pullRequest == nil }.map { $0.model(repository, kind) },
      repository: repository,
    )
    let result = ItemPage(items: items, nextPage: values.count == 100 ? page + 1 : nil)
    try Task.checkCancellation()
    try await cache.write(Self.metadataNamespace(repository), key, JSONEncoder().encode(result))
    return result
  }

  @concurrent
  public func search(_ repository: RepositoryID, _ kind: ItemKind, _ query: String, _ page: Int) async throws -> ItemPage {
    struct Results: Decodable {
      let total_count: Int
      let incomplete_results: Bool
      let items: [ItemDTO]
    }
    let key = "search:\(kind):\(query):\(page)"
    if let data = try await cache.read(Self.metadataNamespace(repository), key, 30) {
      return try decode(ItemPage.self, data)
    }
    let q = "repo:\(repository.slug) is:\(kind == .pullRequest ? "pr" : "issue") \(query)"
    let output = try await runner.checked("gh", ["api", "--hostname", repository.host, "--method", "GET", "search/issues",
                                                 "-f", "q=\(q)", "-f", "sort=updated", "-f", "order=desc",
                                                 "-f", "per_page=100", "-f", "page=\(page)"])
    let result = try decode(Results.self, output.output)
    guard !result.incomplete_results, result.total_count <= 1000 else {
      throw TataraError(.incompleteResponse, detail: "Refine the search to at most 1,000 complete results.")
    }
    for item in result.items {
      let path = item.htmlURL.path.split(separator: "/")
      guard item.htmlURL.host?.lowercased() == repository.host.lowercased(), path.count >= 4,
            "\(path[0])/\(path[1])".lowercased() == repository.slug.lowercased(),
            path[2] == (kind == .pullRequest ? "pull" : "issues"), Int(path[3]) == item.number
      else {
        throw TataraError(.invalidResponse, detail: "The search escaped the selected repository or item kind.")
      }
    }
    let value = try await ItemPage(
      items: enrich(result.items.map { $0.model(repository, kind) }, repository: repository),
      nextPage: page * 100 < result.total_count ? page + 1 : nil,
    )
    try Task.checkCancellation()
    try await cache.write(Self.metadataNamespace(repository), key, JSONEncoder().encode(value))
    return value
  }

  @concurrent
  public func labels(_ repository: RepositoryID) async throws -> [String] {
    if let data = try await cache.read(Self.metadataNamespace(repository), "labels", 300) {
      return try decode([String].self, data)
    }
    let values: [LabelDTO] = try await pages(repository, "labels")
    let result = values.map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    try Task.checkCancellation()
    try await cache.write(Self.metadataNamespace(repository), "labels", JSONEncoder().encode(result))
    return result
  }

  @concurrent
  public func detail(_ item: ForgeItem) async throws -> ItemDetail {
    let repository = item.id.repository
    let number = item.id.number
    let key = "detail:\(number)"
    if let data = try await cache.read(Self.metadataNamespace(repository), key, 30) {
      let result = try decode(ItemDetail.self, data)
      if result.item.title == item.title, result.item.body == item.body, result.item.isDraft == item.isDraft,
         result.item.state == item.state, result.item.labels == item.labels,
         result.item.github == item.github
      {
        return result
      }
    }
    async let comments: [CommentDTO] = pages(repository, "issues/\(number)/comments")
    if item.kind == .issue {
      let value: ItemDTO = try await get(repository, "issues/\(number)")
      let result = try await ItemDetail(item: value.model(repository, .issue), comments: comments.map(\.model))
      try Task.checkCancellation()
      try await cache.write(Self.metadataNamespace(repository), key, JSONEncoder().encode(result))
      return result
    }
    let value: PullRequestDTO = try await get(repository, "pulls/\(number)")
    async let summary = enrich([value.model(repository)], repository: repository)
    async let files: [FileDTO] = pages(repository, "pulls/\(number)/files")
    async let comparison: CompareDTO = get(repository, "compare/\(value.base.sha)...\(value.head.sha)")
    async let reviews: [ReviewDTO] = pages(repository, "pulls/\(number)/reviews")
    async let inline: [CommentDTO] = pages(repository, "pulls/\(number)/comments")
    async let checks: [ChecksDTO] = pageObjects(repository, "commits/\(value.head.sha)/check-runs")
    async let status: StatusDTO = get(repository, "commits/\(value.head.sha)/status")
    let (changed, compared, reviewed, discussions, checkPages, commitStatus, conversation) = try await (
      files,
      comparison,
      reviews,
      inline,
      checks,
      status,
      comments,
    )
    guard changed.count == value.changedFiles else {
      throw TataraError(.incompleteResponse, detail: "GitHub returned \(changed.count) of \(value.changedFiles) changed files.")
    }
    let metadata = GitHubMetadata(
      baseBranch: value.base.ref, headBranch: value.head.label,
      mergeableState: value.mergeableState ?? "unknown",
      checks: checkPages.flatMap(\.checkRuns).map { "\($0.name): \($0.conclusion ?? $0.status)" }
        + commitStatus.statuses.map { "\($0.context): \($0.state)" },
      reviews: reviewed.map { "@\($0.user?.login ?? "ghost"): \($0.state)" },
    )
    let enriched = try await summary
    guard let current = enriched.first, current.github?.headOID == value.head.sha else {
      throw TataraError(
        .revisionChanged,
        detail: "The pull request head changed while loading metadata. Refresh to load its current head.",
      )
    }
    let result = ItemDetail(
      item: current,
      revision: .init(mergeBase: compared.mergeBaseCommit.sha, head: value.head.sha),
      files: changed.map(\.model),
      comments: (conversation + discussions).map(\.model),
      metadata: .github(metadata),
    )
    try Task.checkCancellation()
    try await cache.write(Self.metadataNamespace(repository), key, JSONEncoder().encode(result))
    return result
  }

  @concurrent
  public func content(_ repository: RepositoryID, _ revision: String, _ path: String) async throws -> Data {
    guard revision.range(of: "^[a-fA-F0-9]{40,64}$", options: .regularExpression) != nil else {
      throw TataraError(.invalidResponse, detail: "Invalid Git object ID.")
    }
    let namespace = "snapshot-v1:\(repository):\(revision)"
    if let data = try await cache.read(namespace, path, nil) {
      return data
    }
    let escaped = path.split(separator: "/", omittingEmptySubsequences: false)
      .map { String($0).addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "" }.joined(separator: "/")
    let result = try await runner.checked("gh", [
      "api", "--hostname", repository.host, "--method", "GET", "-H", "Accept: application/vnd.github.raw+json",
      "repos/\(repository.slug)/contents/\(escaped)?ref=\(revision)",
    ]).output
    try Task.checkCancellation()
    try await cache.write(namespace, path, result)
    return result
  }

  @concurrent
  public func submit(_ submission: ReviewSubmission) async throws {
    guard !submission.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !submission.comments.isEmpty || submission
      .event == .approve
    else {
      throw TataraError(.emptyReview)
    }
    let repository = submission.item.id.repository
    let number = submission.item.id.number
    let endpoint: String
    let payload: Data
    if submission.item.kind == .pullRequest {
      let current: PullRequestDTO = try await get(repository, "pulls/\(number)")
      guard current.head.sha == submission.expectedHead else { throw TataraError(.revisionChanged) }
      if let expectedBase = submission.expectedMergeBase {
        let comparison: CompareDTO = try await get(repository, "compare/\(current.base.sha)...\(current.head.sha)")
        guard comparison.mergeBaseCommit.sha == expectedBase else { throw TataraError(.revisionChanged) }
      }
      guard current.state == "open", !current.draft else { throw TataraError(
        .unavailable,
        detail: "The pull request is closed or a draft.",
      ) }
      endpoint = "pulls/\(number)/reviews"
      payload = try JSONEncoder().encode(ReviewPayload(
        body: submission.body,
        event: submission.event.rawValue,
        commitID: current.head.sha,
        comments: submission.comments,
      ))
    } else {
      guard submission.event == .comment, submission.comments.isEmpty else { throw TataraError(
        .unavailable,
        detail: "Issues support comments, not pull request reviews.",
      ) }
      endpoint = "issues/\(number)/comments"
      payload = try JSONEncoder().encode(CommentPayload(body: submission.body))
    }
    try await cache.invalidate(Self.metadataNamespace(repository))
    // The reviewed commit is part of the write itself. Never retry writes automatically.
    _ = try await runner.checked(
      "gh",
      ["api", "--hostname", repository.host, "--method", "POST",
       "repos/\(repository.slug)/\(endpoint)", "--input", "-"],
      input: String(decoding: payload, as: UTF8.self),
    )
  }

  /// One bounded GraphQL request enriches a REST page; no per-row subprocesses or inferred decisions.
  private func enrich(_ items: [ForgeItem], repository: RepositoryID) async throws -> [ForgeItem] {
    let pulls = items.filter { $0.kind == .pullRequest }
    guard !pulls.isEmpty else { return items }
    let fields = pulls.map { "p\($0.id.number): pullRequest(number: \($0.id.number)) { ...Summary }" }.joined(separator: "\n")
    let query = """
    query($owner: String!, $name: String!) {
      repository(owner: $owner, name: $name) { \(fields) }
    }
    fragment Summary on PullRequest {
      number url state isDraft
      createdAt updatedAt closedAt mergedAt headRefOid headRefName baseRefName
      reviewDecision totalCommentsCount statusCheckRollup { state }
      additions deletions changedFiles commits { totalCount }
    }
    """
    let payload = try JSONSerialization.data(withJSONObject: [
      "query": query,
      "variables": ["owner": repository.owner, "name": repository.name],
    ])
    let output = try await runner.checked(
      "gh",
      ["api", "--hostname", repository.host, "graphql", "--input", "-"],
      input: String(decoding: payload, as: UTF8.self),
    )
    let response = try decode(SummaryResponse.self, output.output)
    if let errors = response.errors, !errors.isEmpty {
      throw TataraError(.invalidResponse, detail: errors.map(\.message).joined(separator: "\n"))
    }
    guard let values = response.data?.repository else {
      throw TataraError(.incompleteResponse, detail: "GitHub did not return pull request metadata.")
    }
    return try items.map { item in
      guard item.kind == .pullRequest else { return item }
      guard let optional = values["p\(item.id.number)"], let summary = optional,
            summary.number == item.id.number, summary.url == item.url
      else {
        throw TataraError(.incompleteResponse, detail: "GitHub metadata does not match pull request #\(item.id.number).")
      }
      // REST owns labels, assignees and requested reviewers; reject mixed update snapshots.
      if let updated = item.github?.updatedAt, updated != summary.updatedAt {
        throw TataraError(
          .revisionChanged,
          detail: "Pull request #\(item.id.number) changed while loading. Refresh to load current metadata.",
        )
      }
      var result = item
      result.state = summary.state == "MERGED" ? .merged : summary.state == "OPEN" ? .open : .closed
      result.isDraft = summary.isDraft
      var info = item.github ?? .init()
      info.createdAt = summary.createdAt
      info.updatedAt = summary.updatedAt
      info.closedAt = summary.closedAt
      info.mergedAt = summary.mergedAt
      info.headOID = summary.headRefOid
      info.headBranch = summary.headRefName
      info.baseBranch = summary.baseRefName
      info.reviewDecision = summary.reviewDecision
      info.checksState = summary.statusCheckRollup?.state
      info.commentCount = summary.totalCommentsCount
      info.additions = summary.additions
      info.deletions = summary.deletions
      info.changedFiles = summary.changedFiles
      info.commits = summary.commits.totalCount
      result.github = info
      return result
    }
  }

  private func get<Value: Decodable>(_ repository: RepositoryID, _ endpoint: String) async throws -> Value {
    let result = try await runner.checked(
      "gh",
      ["api", "--hostname", repository.host, "--method", "GET", "repos/\(repository.slug)/\(endpoint)"],
    )
    return try decode(Value.self, result.output)
  }

  private func pages<Value: Decodable>(_ repository: RepositoryID, _ endpoint: String) async throws -> [Value] {
    let values: [[Value]] = try await pageObjects(repository, endpoint)
    return values.flatMap(\.self)
  }

  private func pageObjects<Value: Decodable>(_ repository: RepositoryID, _ endpoint: String) async throws -> [Value] {
    let result = try await runner.checked(
      "gh",
      [
        "api",
        "--hostname",
        repository.host,
        "--method",
        "GET",
        "--paginate",
        "--slurp",
        "repos/\(repository.slug)/\(endpoint)?per_page=100",
      ],
    )
    return try decode([Value].self, result.output)
  }

  private func decode<Value: Decodable>(_ type: Value.Type, _ data: Data) throws -> Value {
    try Task.checkCancellation()
    let value: Value
    do { value = try JSONDecoder().decode(type, from: data) }
    catch { throw TataraError(.invalidResponse, detail: String(describing: error)) }
    try Task.checkCancellation()
    return value
  }
}

private struct UserDTO: Decodable { var login: String }
private struct LabelDTO: Decodable { var name: String }
private struct MilestoneDTO: Decodable { var title: String }
private struct TeamDTO: Decodable { var slug: String }
private struct SummaryResponse: Decodable {
  struct Payload: Decodable { var repository: [String: PullSummaryDTO?]? }
  struct Failure: Decodable { var message: String }
  var data: Payload?
  var errors: [Failure]?
}

private struct PullSummaryDTO: Decodable {
  struct Rollup: Decodable { var state: GitHubItemSummary.ChecksState }
  struct Count: Decodable { var totalCount: Int }
  var number: Int
  var url: URL
  var state: String
  var isDraft: Bool
  var createdAt: String
  var updatedAt: String
  var closedAt: String?
  var mergedAt: String?
  var headRefOid: String
  var headRefName: String
  var baseRefName: String
  var reviewDecision: GitHubItemSummary.ReviewDecision?
  var totalCommentsCount: Int?
  var statusCheckRollup: Rollup?
  var additions: Int
  var deletions: Int
  var changedFiles: Int
  var commits: Count
}

private struct ItemDTO: Decodable {
  struct PullMarker: Decodable {
    var mergedAt: String?
    enum CodingKeys: String, CodingKey { case mergedAt = "merged_at" }
  }

  var createdAt: String?
  var updatedAt: String?
  var closedAt: String?
  var assignees: [UserDTO]?
  var milestone: MilestoneDTO?
  var requestedReviewers: [UserDTO]?
  var requestedTeams: [TeamDTO]?
  var comments: Int?
  var number: Int
  var title: String
  var user: UserDTO?
  var body: String?
  var htmlURL: URL
  var state: String
  var labels: [LabelDTO]
  var draft: Bool?
  var pullRequest: PullMarker?
  enum CodingKeys: String, CodingKey {
    case createdAt = "created_at", updatedAt = "updated_at", closedAt = "closed_at"
    case requestedReviewers = "requested_reviewers", requestedTeams = "requested_teams"
    case assignees, milestone, comments
    case number, title, user, body, state, labels, draft
    case htmlURL = "html_url", pullRequest = "pull_request"
  }

  func model(_ repository: RepositoryID, _ kind: ItemKind) -> ForgeItem {
    ForgeItem(
      id: .init(repository: repository, number: number),
      kind: kind,
      title: title,
      author: user?.login ?? "ghost",
      body: body ?? "",
      url: htmlURL,
      state: pullRequest?.mergedAt != nil ? .merged : state == "open" ? .open : .closed,
      labels: labels.map(\.name),
      isDraft: draft ?? false,
      github: .init(
        createdAt: createdAt,
        updatedAt: updatedAt,
        closedAt: closedAt,
        assignees: assignees?.map(\.login) ?? [],
        milestone: milestone?.title,
        requestedReviewers: requestedReviewers?.map(\.login) ?? [],
        requestedTeams: requestedTeams?.map(\.slug) ?? [],
        commentCount: kind == .issue ? comments : nil,
      ),
    )
  }
}

private struct PullRequestDTO: Decodable {
  struct Ref: Decodable { var sha: String
    var ref: String
    var label: String
  }

  var createdAt: String?
  var updatedAt: String?
  var closedAt: String?
  var assignees: [UserDTO]?
  var milestone: MilestoneDTO?
  var requestedReviewers: [UserDTO]?
  var requestedTeams: [TeamDTO]?
  var comments: Int?
  var number: Int
  var title: String
  var user: UserDTO?
  var body: String?
  var htmlURL: URL
  var state: String
  var labels: [LabelDTO]
  var draft: Bool
  var merged: Bool
  var base: Ref
  var head: Ref
  var changedFiles: Int
  var mergeableState: String?
  enum CodingKeys: String, CodingKey {
    case createdAt = "created_at", updatedAt = "updated_at", closedAt = "closed_at"
    case requestedReviewers = "requested_reviewers", requestedTeams = "requested_teams"
    case assignees, milestone, comments
    case number, title, user, body, state, labels, draft, merged, base, head
    case htmlURL = "html_url", changedFiles = "changed_files", mergeableState = "mergeable_state"
  }

  func model(_ repository: RepositoryID) -> ForgeItem {
    ForgeItem(
      id: .init(repository: repository, number: number),
      kind: .pullRequest,
      title: title,
      author: user?.login ?? "ghost",
      body: body ?? "",
      url: htmlURL,
      state: merged ? .merged : state == "open" ? .open : .closed,
      labels: labels.map(\.name),
      isDraft: draft,
      github: .init(
        createdAt: createdAt,
        updatedAt: updatedAt,
        closedAt: closedAt,
        assignees: assignees?.map(\.login) ?? [],
        milestone: milestone?.title,
        requestedReviewers: requestedReviewers?.map(\.login) ?? [],
        requestedTeams: requestedTeams?.map(\.slug) ?? [],
        commentCount: nil,
      ),
    )
  }
}

private struct FileDTO: Decodable {
  var filename: String
  var previousFilename: String?
  var status: String
  var additions: Int
  var deletions: Int
  var patch: String?
  enum CodingKeys: String, CodingKey { case filename, status, additions, deletions, patch
    case previousFilename = "previous_filename"
  }

  var model: ChangedFile {
    .init(
      path: filename,
      previousPath: previousFilename,
      status: status,
      additions: additions,
      deletions: deletions,
      patch: patch,
    )
  }
}

private struct CompareDTO: Decodable {
  struct Commit: Decodable { var sha: String }
  var mergeBaseCommit: Commit
  enum CodingKeys: String, CodingKey { case mergeBaseCommit = "merge_base_commit" }
}

private struct CommentDTO: Decodable {
  var id: Int
  var node_id: String?
  var html_url: URL?
  var updated_at: String?
  var in_reply_to_id: Int?
  var user: UserDTO?
  var body: String
  var path: String?
  var line: Int?
  var side: InlineComment.Side?
  var start_line: Int?
  var subject_type: String?
  var original_line: Int?
  var commit_id: String?
  var model: DiscussionComment {
    .init(
      id: id,
      author: user?.login ?? "ghost",
      body: body,
      context: path.map { "\($0):\(line.map(String.init) ?? "–")" },
      anchor: path.map { path in
        DiscussionAnchor(
          path: path,
          line: line,
          side: side,
          startLine: start_line,
          originalLine: original_line,
          commitID: commit_id,
          subjectType: subject_type,
        )
      },
      nodeID: node_id, url: html_url, updatedAt: updated_at, replyToID: in_reply_to_id,
    )
  }
}

private struct ReviewDTO: Decodable { var user: UserDTO?
  var state: String
}

private struct ChecksDTO: Decodable {
  struct Check: Decodable { var name: String
    var status: String
    var conclusion: String?
  }

  var checkRuns: [Check]
  enum CodingKeys: String, CodingKey { case checkRuns = "check_runs" }
}

private struct StatusDTO: Decodable {
  struct Status: Decodable { var context: String
    var state: String
  }

  var statuses: [Status]
}

private struct ReviewPayload: Encodable {
  var body: String
  var event: String
  var commitID: String
  var comments: [InlineComment]
  enum CodingKeys: String, CodingKey { case body, event, comments
    case commitID = "commit_id"
  }
}

private struct CommentPayload: Encodable { var body: String }

private struct CommentGraphQL<Value: Decodable>: Decodable {
  struct Failure: Decodable { var message: String }
  var data: Value?
  var errors: [Failure]?
}

private struct CommentNodePayload: Decodable {
  struct Parent: Decodable {
    struct Repository: Decodable { var nameWithOwner: String }
    var number: Int
    var locked: Bool
    var viewerCanUpdate: Bool
    var repository: Repository
  }

  struct Node: Decodable {
    struct Ref: Decodable { var id: String }
    struct Group: Decodable {
      struct Users: Decodable { var totalCount: Int }
      var content: ReactionContent
      var viewerHasReacted: Bool
      var users: Users
    }

    var id: String
    var body: String
    var updatedAt: String
    var url: URL
    var viewerCanUpdate: Bool
    var viewerDidAuthor: Bool
    var viewerCanDelete: Bool
    var viewerCanReact: Bool
    var parent: Parent
    var replyTo: Ref?
    var reactionGroups: [Group]
  }

  var node: Node?
  var viewer: UserDTO
}

private struct ThreadPayload: Decodable {
  struct PageInfo: Decodable { var hasNextPage: Bool
    var endCursor: String?
  }

  struct Thread: Decodable {
    struct Comments: Decodable { struct Node: Decodable { var id: String }
      var nodes: [Node]
    }

    var id: String
    var isResolved: Bool
    var viewerCanResolve: Bool
    var viewerCanUnresolve: Bool
    var viewerCanReply: Bool
    var comments: Comments
  }

  struct Connection: Decodable { var nodes: [Thread]
    var pageInfo: PageInfo
  }

  struct Pull: Decodable { var reviewThreads: Connection }
  struct Repository: Decodable { var pullRequest: Pull? }
  var repository: Repository?
}

extension GitHubAdapter {
  @concurrent
  public func commentContext(_ item: ForgeItem, _ target: DiscussionComment) async throws -> CommentContext {
    let repository = item.id.repository
    let category = target.anchor == nil ? "issues" : "pulls"
    let response: CommentDTO = try await get(repository, "\(category)/comments/\(target.id)")
    var comment = response.model
    guard comment.key == target.key, let nodeID = comment.nodeID else {
      throw TataraError(.invalidResponse, detail: "GitHub did not return the selected comment identity.")
    }
    let common = "id body updatedAt url viewerCanUpdate viewerDidAuthor viewerCanDelete viewerCanReact reactionGroups { content viewerHasReacted users { totalCount } }"
    let query = """
    query($id: ID!) {
      viewer { login }
      node(id: $id) {
        ... on IssueComment { \(common) parent: issue { number locked viewerCanUpdate repository { nameWithOwner } } }
        ... on PullRequestReviewComment { \(common) replyTo { id } parent: pullRequest { number locked viewerCanUpdate repository { nameWithOwner } } }
      }
    }
    """
    let payload: CommentNodePayload = try await commentQuery(repository, query, variables: ["id": nodeID])
    guard let node = payload.node, node.id == nodeID, node.parent.number == item.id.number,
          node.parent.repository.nameWithOwner.lowercased() == repository.slug.lowercased(),
          node.url.scheme == "https", node.url.host == repository.host
    else {
      throw TataraError(.invalidResponse, detail: "Comment ownership does not match the selected repository and item.")
    }
    comment.body = node.body
    comment.updatedAt = node.updatedAt
    comment.url = node.url
    let thread = target.anchor == nil ? nil : try await commentThread(item, root: node.replyTo?.id ?? node.id)
    return .init(
      comment: comment,
      canReply: thread?.canReply ?? (!node.parent.locked || node.parent.viewerCanUpdate),
      canEdit: node.viewerDidAuthor && node.viewerCanUpdate,
      canDelete: node.viewerDidAuthor && node.viewerCanDelete,
      canReact: node.viewerCanReact,
      thread: thread,
      reactions: node.reactionGroups.map { .init(
        content: $0.content,
        count: $0.users.totalCount,
        viewerHasReacted: $0.viewerHasReacted,
      ) },
      viewer: payload.viewer.login,
    )
  }

  @concurrent
  private func commentThread(_ item: ForgeItem, root: String) async throws -> ReviewThread {
    let repository = item.id.repository
    let query = """
    query($owner: String!, $name: String!, $after: String) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: \(item.id.number)) {
          reviewThreads(first: 100, after: $after) {
            nodes { id isResolved viewerCanResolve viewerCanUnresolve viewerCanReply comments(first: 1) { nodes { id } } }
            pageInfo { hasNextPage endCursor }
          }
        }
      }
    }
    """
    var cursor: String?, seen = Set<String>()
    for _ in 0 ..< 100 {
      try Task.checkCancellation()
      var variables = ["owner": repository.owner, "name": repository.name]
      variables["after"] = cursor
      let payload: ThreadPayload = try await commentQuery(repository, query, variables: variables)
      guard let page = payload.repository?.pullRequest?.reviewThreads else { throw TataraError(
        .invalidResponse,
        detail: "Missing review threads.",
      ) }
      if let thread = page.nodes.first(where: { $0.comments.nodes.first?.id == root }) {
        return .init(
          id: thread.id,
          isResolved: thread.isResolved,
          canResolve: thread.viewerCanResolve,
          canUnresolve: thread.viewerCanUnresolve,
          canReply: thread.viewerCanReply,
        )
      }
      guard page.pageInfo.hasNextPage else { throw TataraError(
        .invalidResponse,
        detail: "The selected comment no longer belongs to a review thread.",
      ) }
      guard let next = page.pageInfo.endCursor, seen.insert(next).inserted else { throw TataraError(
        .incompleteResponse,
        detail: "Invalid review thread pagination.",
      ) }
      cursor = next
    }
    throw TataraError(.incompleteResponse, detail: "Review thread lookup exceeds 10,000 threads.")
  }

  @concurrent
  public func mutateComment(_ mutation: CommentMutation) async throws {
    let repository = mutation.item.id.repository
    let current = try await commentContext(mutation.item, mutation.context.comment)
    guard current.viewer == mutation.context.viewer else { throw TataraError(
      .authentication,
      detail: "The active GitHub account changed. Reopen the comment before submitting.",
    ) }
    guard current.comment.body == mutation.context.comment.body,
          current.comment.updatedAt == mutation.context.comment.updatedAt
    else {
      throw TataraError(.invalidResponse, detail: "The comment changed after the preview. Reopen it before submitting.")
    }
    guard current.allows(mutation.operation) else { throw TataraError(
      .unavailable,
      detail: "This comment action is no longer permitted.",
    ) }
    if mutation.item.kind == .pullRequest {
      let pull: PullRequestDTO = try await get(repository, "pulls/\(mutation.item.id.number)")
      guard let expected = mutation.expectedHead, pull.head.sha == expected else { throw TataraError(.revisionChanged) }
    }
    try Task.checkCancellation()
    let comment = current.comment
    let category = comment.anchor == nil ? "issues" : "pulls"
    var endpoint = "\(category)/comments/\(comment.id)"
    var method = "POST"
    var payload: [String: String] = [:]
    switch mutation.operation {
    case .reply, .edit:
      guard !mutation.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TataraError(.emptyReview) }
      payload["body"] = mutation.body
      if mutation.operation == .edit {
        method = "PATCH"
      } else if comment.anchor == nil {
        endpoint = "issues/\(mutation.item.id.number)/comments"
      } else {
        endpoint = "pulls/\(mutation.item.id.number)/comments/\(comment.replyToID ?? comment.id)/replies"
      }
    case .delete: method = "DELETE"
    case .react:
      guard let node = comment.nodeID else { throw TataraError(.invalidResponse, detail: "Missing comment node ID.") }
      let wasSelected = mutation.context.reactions.first { $0.content == mutation.reaction }?.viewerHasReacted ?? false
      let isSelected = current.reactions.first { $0.content == mutation.reaction }?.viewerHasReacted ?? false
      guard wasSelected == isSelected else { throw TataraError(
        .invalidResponse,
        detail: "The reaction changed after the preview. Reopen the comment.",
      ) }
      let operation = isSelected ? "removeReaction" : "addReaction"
      let query = "mutation($id: ID!, $content: ReactionContent!) { \(operation)(input: {subjectId: $id, content: $content}) { subject { id } } }"
      try await cache.invalidate(Self.metadataNamespace(repository))
      let response: [String: MutationAcknowledgement] = try await commentQuery(
        repository,
        query,
        variables: ["id": node, "content": mutation.reaction.rawValue],
      )
      guard response[operation]?.subject?.id == node else { throw TataraError(
        .invalidResponse,
        detail: "GitHub did not acknowledge the reaction target. Refresh before attempting another write.",
      ) }
      return
    case .resolve, .unresolve:
      guard let thread = current.thread, thread.id == mutation.context.thread?.id else { throw TataraError(
        .invalidResponse,
        detail: "The review thread changed after the preview.",
      ) }
      let operation = mutation.operation == .resolve ? "resolveReviewThread" : "unresolveReviewThread"
      let query = "mutation($id: ID!) { \(operation)(input: {threadId: $id}) { thread { id } } }"
      try await cache.invalidate(Self.metadataNamespace(repository))
      let response: [String: MutationAcknowledgement] = try await commentQuery(repository, query, variables: ["id": thread.id])
      guard response[operation]?.thread?.id == thread.id else { throw TataraError(
        .invalidResponse,
        detail: "GitHub did not acknowledge the review thread. Refresh before attempting another write.",
      ) }
      return
    }
    try await cache.invalidate(Self.metadataNamespace(repository))
    let data = try JSONEncoder().encode(payload)
    _ = try await runner.checked("gh", ["api", "--hostname", repository.host, "--method", method,
                                        "repos/\(repository.slug)/\(endpoint)", "--input", "-"], input: String(
        decoding: data,
        as: UTF8.self,
      ))
  }

  @concurrent
  private func commentQuery<Value: Decodable>(
    _ repository: RepositoryID,
    _ query: String,
    variables: [String: String],
  ) async throws -> Value {
    let input = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
    let output = try await runner.checked(
      "gh",
      ["api", "--hostname", repository.host, "graphql", "--input", "-"],
      input: String(decoding: input, as: UTF8.self),
    )
    let response = try decode(CommentGraphQL<Value>.self, output.output)
    guard response.errors?.isEmpty != false, let value = response.data else {
      throw TataraError(
        .invalidResponse,
        detail: response.errors?.map(\.message).joined(separator: "; ") ?? "Missing GitHub GraphQL response.",
      )
    }
    return value
  }
}

private struct MutationAcknowledgement: Decodable {
  struct Node: Decodable { var id: String }
  var subject: Node?
  var thread: Node?
}
