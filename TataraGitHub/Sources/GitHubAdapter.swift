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
