// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TataraCore

/// Reads immutable blobs only from a proven matching local repository. Never fetches or checks out.
public struct LocalGitReader: Sendable {

  // MARK: Lifecycle

  public init(read: @escaping @Sendable (RepositoryID, String, String) async throws -> Data?) {
    self.read = read
  }

  // MARK: Public

  public static let disabled = Self { _, _, _ in nil }

  public var read: @Sendable (RepositoryID, String, String) async throws -> Data?

  @concurrent
  public static func discover(
    repository: RepositoryID,
    directory: String = FileManager.default.currentDirectoryPath,
    runner: CommandRunner = .live,
  ) async throws -> Self {
    let paths = ProcessInfo.processInfo.environment["PATH", default: ""].split(separator: ":", omittingEmptySubsequences: false)
    guard
      let git = paths.map({ URL(fileURLWithPath: String($0)).appendingPathComponent("git").path })
        .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    else { return .disabled }
    let version = try await runner.checked(git, ["--version"]).text.split(separator: " ")
    guard version.count >= 3 else { throw TataraError(.invalidResponse, detail: "Missing Git version.") }
    let numbers = version[2].split(separator: ".").compactMap { Int($0.prefix(while: \.isNumber)) }
    guard numbers.count >= 2, numbers[0] > 2 || numbers[0] == 2 && numbers[1] >= 43 else { return .disabled }
    let location = try await runner.run(
      "/usr/bin/env",
      ["LC_ALL=C", git, "-C", directory, "rev-parse", "--absolute-git-dir"],
      nil,
    )
    if location.status != 0, location.error.contains("not a git repository") {
      return .disabled
    }
    guard location.status == 0 else { throw TataraError(.commandFailed, detail: location.error) }
    let gitDirectory = location.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard gitDirectory.hasPrefix("/")
    else { throw TataraError(.invalidResponse, detail: "Git object directory is not absolute.") }
    let config = try await runner.run(git, [
      "--git-dir",
      gitDirectory,
      "config",
      "--null",
      "--get-regexp",
      #"^remote\..*\.(url|promisor)$|^extensions\.partialclone$"#,
    ], nil)
    if config.status == 1 {
      return .disabled
    }
    guard config.status == 0 else { throw TataraError(.commandFailed, detail: config.error) }
    var matches = false
    for entry in config.text.split(separator: "\0") {
      guard let newline = entry.firstIndex(of: "\n") else {
        throw TataraError(.invalidResponse, detail: "Invalid Git remote configuration record.")
      }
      let key = entry[..<newline].lowercased()
      let value = String(entry[entry.index(after: newline)...])
      if
        key == "extensions.partialclone" || key.hasSuffix(".promisor") && !["false", "no", "off", "0"]
          .contains(value.lowercased())
      {
        return .disabled
      }
      if key.hasSuffix(".url"), matchesRemote(value, repository: repository) {
        matches = true
      }
    }
    guard matches else { return .disabled }
    return Self { requestedRepository, revision, path in
      guard requestedRepository == repository else { return nil }
      guard
        revision.range(of: #"^[a-fA-F0-9]{40,64}$"#, options: .regularExpression) != nil,
        !path.utf8.contains(0)
      else {
        throw TataraError(.invalidResponse, detail: "Invalid immutable Git blob request.")
      }
      let spec = "\(revision):\(path)"
      let result = try await runner.checked("/usr/bin/env", [
        "GIT_NO_LAZY_FETCH=1",
        git,
        "--git-dir",
        gitDirectory,
        "cat-file",
        "--batch",
        "-Z",
      ], input: spec + "\0")
      return try decodeBlob(result.output, spec: spec)
    }
  }

  // MARK: Private

  private static func matchesRemote(_ raw: String, repository: RepositoryID) -> Bool {
    let value: String
    if raw.contains("://") {
      value = raw
    } else if let colon = raw.firstIndex(of: ":"), raw[..<colon].contains("@") {
      value = "ssh://" + raw[..<colon] + "/" + raw[raw.index(after: colon)...]
    } else {
      return false
    }
    guard let url = URL(string: value), url.host?.lowercased() == repository.host.lowercased() else { return false }
    var slug = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    if slug.hasSuffix(".git") {
      slug.removeLast(4)
    }
    return slug.lowercased() == repository.slug.lowercased()
  }

  private static func decodeBlob(_ output: Data, spec: String) throws -> Data? {
    guard let separator = output.firstIndex(of: 0) else {
      throw TataraError(.invalidResponse, detail: "Missing Git blob response header.")
    }
    let header = String(decoding: output[..<separator], as: UTF8.self)
    if header == spec + " missing" {
      return nil
    }
    let fields = header.split(separator: " ")
    guard fields.count == 3, let size = Int(fields[2]), size >= 0 else {
      throw TataraError(.invalidResponse, detail: "Invalid Git blob response header.")
    }
    if fields[1] == "commit" || fields[1] == "tree" {
      return nil
    }
    let start = separator + 1
    guard
      fields[1] == "blob",
      size <= output.count - start,
      output.count - start == size + 1,
      output.last == 0
    else {
      throw TataraError(.invalidResponse, detail: "Incomplete Git blob response.")
    }
    try Task.checkCancellation()
    return output.subdata(in: start ..< start + size)
  }

}
