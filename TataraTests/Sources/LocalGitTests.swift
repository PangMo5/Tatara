// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TataraCore
import TataraGitHub
import TataraSystem
import Testing

struct LocalGitTests {
  @Test
  func `local immutable blobs preserve binary bytes unusual paths and dirty worktrees`() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tatara-local-git-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let runner = CommandRunner.live
    for args in [
      ["init", "--quiet"],
      ["config", "user.name", "Fixture"],
      ["config", "user.email", "fixture@example.invalid"],
      ["remote", "add", "origin", "https://github.com/owner/repo.git"],
    ] {
      _ = try await runner.checked("git", ["-C", directory.path] + args)
    }
    let path = "odd \n name:한글.bin"
    let original = Data([0, 255, 10, 13, 65, 0])
    try original.write(to: directory.appendingPathComponent(path))
    _ = try await runner.checked("git", ["-C", directory.path, "add", "--", path])
    _ = try await runner.checked("git", ["-C", directory.path, "commit", "--quiet", "-m", "fixture"])
    let revision = try await runner.checked("git", ["-C", directory.path, "rev-parse", "HEAD"]).text
      .trimmingCharacters(in: .whitespacesAndNewlines)
    try Data("uncommitted replacement".utf8).write(to: directory.appendingPathComponent(path))
    let repository = try RepositoryID("owner/repo")
    let outside = try await LocalGitReader.discover(repository: repository, directory: directory.deletingLastPathComponent().path)
    #expect(try await outside.read(repository, revision, path) == nil)
    let reader = try await LocalGitReader.discover(repository: repository, directory: directory.path)
    #expect(try await reader.read(repository, revision, path) == original)
    #expect(try await reader.read(repository, revision, "missing") == nil)
    #expect(try await reader.read(repository, String(repeating: "f", count: 40), path) == nil)
    let other = try RepositoryID("other/repository")
    #expect(try await reader.read(other, revision, path) == nil)
    let unrelated = try await LocalGitReader.discover(repository: other, directory: directory.path)
    #expect(try await unrelated.read(other, revision, path) == nil)
    _ = try await runner.checked("git", ["-C", directory.path, "config", "remote.origin.promisor", "true"])
    let partial = try await LocalGitReader.discover(repository: repository, directory: directory.path)
    #expect(try await partial.read(repository, revision, path) == nil)
  }

  @Test
  func `GitHub content uses available immutable bytes and never hides local read failures`() async throws {
    let repository = try RepositoryID("owner/repo")
    let revision = String(repeating: "a", count: 40)
    let bytes = Data([0, 255, 1])
    let runner = CommandRunner { _, _, _ in
      Issue.record("A local blob must not start a GitHub request.")
      return CommandResult()
    }
    let adapter = GitHubAdapter(runner: runner, localGit: .init { _, _, _ in bytes })
    #expect(try await adapter.content(repository, revision, "renamed.bin") == bytes)
    let failure = TataraError(.commandFailed, detail: "Local object read failed")
    let broken = GitHubAdapter(runner: runner, localGit: .init { _, _, _ in throw failure })
    await #expect(throws: failure) { try await broken.content(repository, revision, "renamed.bin") }
  }
}
