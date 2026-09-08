// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SwiftTUI
import TataraCore
import TataraKit
import TataraPersistence
import TataraSystem
import Testing

struct CacheAndLoadingTests {
  @Test func `wide diff rows retain source and search with bounded presentation`() async throws {
    let source = String(repeating: "한국어😀 source ", count: 10000) + "needle"
    let diff = ReviewDiff(path: "Source.swift", language: "Swift", status: "changed", rows: [
      .init(left: nil, right: .init(number: 7, spans: [.init(text: source, color: 2)])),
    ])
    let document = try await DocumentRenderer.prepareDiff(diff, 160, .right)
    #expect(document.lines[0].map(\.text).joined().hasSuffix("needle"))
    #expect(document.searchableLines[0].contains("needle"))
    let rendered = document.displayLines[0].map(\.text).joined()
    #expect(layoutText(for: rendered, width: nil).lines.flatMap(\.clusters).reduce(0) { $0 + $1.cellWidth } <= 160)
    #expect(!rendered.contains("needle"))
  }

  @Test func `presentation clipping respects wide graphemes and style boundaries`() async throws {
    let diff = ReviewDiff(path: "Source.swift", language: "Swift", status: "changed", rows: [
      .init(
        left: nil,
        right: .init(number: 3, spans: [.init(text: "ab한", color: 1), .init(text: "😀tail", color: 1, bold: true)]),
      ),
    ])
    let document = try await DocumentRenderer.prepareDiff(diff, 11, .right)
    #expect(document.displayLines[0].filter { $0.color == 1 } == [
      .init(text: "ab한", color: 1, side: .right),
      .init(text: "😀", color: 1, bold: true, side: .right),
    ])
    #expect(document.lines[0].map(\.text).joined().hasSuffix("ab한😀tail"))
  }

  @Test func `prepared documents use a bounded least recently used cache`() async {
    let cache = PreparedDocumentCache(maximumCost: 10, maximumCount: 2)
    let document = ReviewDocument(lines: [[.init(text: "Prepared source")]])
    await cache.insert(document, for: "a", cost: 4)
    await cache.insert(document, for: "b", cost: 4)
    #expect(await cache.value(for: "a") == document)
    await cache.insert(document, for: "c", cost: 4)
    #expect(await cache.value(for: "b") == nil)
    #expect(await cache.value(for: "a") == document)
    #expect(await cache.value(for: "c") == document)
    await cache.insert(document, for: "oversized", cost: 11)
    #expect(await cache.value(for: "oversized") == nil)
    #expect(await cache.value(for: "a") == document)
  }

  @Test func `cancelled preparation cannot populate the document cache`() async {
    let cache = PreparedDocumentCache()
    let task = Task {
      while !Task.isCancelled {
        await Task.yield()
      }
      await cache.insert(.init(lines: [[.init(text: "Obsolete")]]), for: "obsolete", cost: 100)
    }
    task.cancel()
    await task.value
    #expect(await cache.value(for: "obsolete") == nil)
  }

  private actor RenderCalls {
    var renders = 0
    var waits = 0
    var cacheReads = 0
    func record() {
      renders += 1
    }

    func wait() {
      waits += 1
    }

    func read() {
      cacheReads += 1
    }
  }

  @Test func `a new diff engine reuses persisted output without fetching files`() async throws {
    let url = location()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let storage = try await PersistentCache.bootstrapDatabase(at: url)
    let calls = RenderCalls()
    let runner = CommandRunner { _, arguments, _ in
      if arguments == ["--version"] {
        return .init(output: Data("difft 1".utf8))
      }
      await calls.record()
      return .init(output: Data(#"{"status":"unchanged","language":"Swift"}"#.utf8))
    }
    var forge = ForgeClient()
    forge.content = { _, _, _ in Data("source".utf8) }
    let request = try DiffRequest(
      repository: RepositoryID("owner/repo"),
      revision: .init(
        mergeBase: String(repeating: "a", count: 40),
        head: String(repeating: "b", count: 40),
      ),
      file: .init(path: "Source.swift"),
      width: 120,
      theme: .mocha,
    )
    let first = Difftastic(forge: forge, runner: runner, cache: storage.client, settle: { await calls.wait() })
    #expect(try await first.render(request).status == "unchanged")
    let reopened = try await PersistentCache.bootstrapDatabase(at: url)
    forge.content = { _, _, _ in
      Issue.record("A persistent diff cache hit fetched source content.")
      return Data()
    }
    let monitored = CacheClient(read: { namespace, key, age in
      await calls.read()
      return try await reopened.client.read(namespace, key, age)
    }, write: reopened.client.write, invalidate: reopened.client.invalidate)
    let second = Difftastic(forge: forge, runner: runner, cache: monitored, settle: { await calls.wait() })
    #expect(try await second.render(request).status == "unchanged")
    #expect(try await second.render(request).status == "unchanged")
    #expect(await calls.renders == 1)
    #expect(await calls.waits == 1)
    #expect(await calls.cacheReads == 1)
  }

  private func location() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("tatara-cache-test-\(UUID())/cache.sqlite")
  }

  @Test func `persistent bytes survive reopening and stay account scoped`() async throws {
    let url = location()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let first = try await PersistentCache.bootstrapDatabase(at: url)
    let data = Data([0, 255, 128, 1])
    try await first.client.scoped(to: "account-a").write("snapshot:repo:sha", "File.swift", data)
    let reopened = try await PersistentCache.bootstrapDatabase(at: url)
    #expect(try await reopened.client.scoped(to: "account-a").read("snapshot:repo:sha", "File.swift", nil) == data)
    #expect(try await reopened.client.scoped(to: "account-b").read("snapshot:repo:sha", "File.swift", nil) == nil)
  }

  @Test func `metadata expires but immutable snapshots remain`() async throws {
    let url = location()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let writer = try await PersistentCache.bootstrapDatabase(at: url, now: { Date(timeIntervalSince1970: 100) })
    try await writer.client.write("metadata:one", "list", Data([1]))
    try await writer.client.write("snapshot:one", "sha", Data([2]))
    let reader = try await PersistentCache.bootstrapDatabase(at: url, now: { Date(timeIntervalSince1970: 131) })
    #expect(try await reader.client.read("metadata:one", "list", 30) == nil)
    #expect(try await reader.client.read("snapshot:one", "sha", nil) == Data([2]))
    try await reader.client.invalidate("metadata:one")
    #expect(try await reader.client.read("metadata:one", "list", nil) == nil)
    #expect(try await reader.client.read("snapshot:one", "sha", nil) == Data([2]))
  }

  @Test func `cache evicts to its byte budget`() async throws {
    let url = location()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let cache = try await PersistentCache.bootstrapDatabase(at: url, maximumBytes: 10)
    try await cache.client.write("test", "a", Data(repeating: 1, count: 6))
    try await cache.client.write("test", "b", Data(repeating: 2, count: 6))
    let a = try await cache.client.read("test", "a", nil)
    let b = try await cache.client.read("test", "b", nil)
    #expect((a?.count ?? 0) + (b?.count ?? 0) <= 10)
  }

  @Test func `cancelling a running subprocess tears it down promptly`() async throws {
    let task = Task { try await CommandRunner.live.checked("sleep", ["30"]) }
    try await Task.sleep(for: .milliseconds(200))
    let clock = ContinuousClock()
    let start = clock.now
    task.cancel()
    do {
      _ = try await task.value
      Issue.record("A cancelled subprocess returned successfully.")
    } catch {
      #expect(error is CancellationError)
    }
    #expect(start.duration(to: clock.now) < .seconds(2))
  }

  @Test func `cancellation interrupts search index construction`() {
    let lines = (0 ..< 1024).map { [DiffSpan(text: "Line \($0)")] }
    var checks = 0
    #expect(throws: CancellationError.self) {
      try ReviewDocument(lines: lines, checkingCancellation: {
        checks += 1
        if checks == 2 {
          throw CancellationError()
        }
      })
    }
  }

  @Test(arguments: [String(repeating: "A sentence with words. ", count: 600), String(repeating: "한국어😀 text ", count: 1000)])
  func `chunked wrapping matches native layout`(_ source: String) async throws {
    let document = try await DocumentRenderer.prepare(source, 79)
    let expected = layoutText(for: source, width: 79).lines.map(\.text)
    #expect(document.lines.map { $0.map(\.text).joined() } == expected)
  }

  @Test func `oversized tokens wrap without changing their text`() async throws {
    let source = String(repeating: "word", count: 3000)
    let document = try await DocumentRenderer.prepare(source, 79)
    #expect(document.lines.flatMap { $0.map(\.text) }.joined() == source)
    #expect(document.lines.allSatisfy { $0.map(\.text).joined().count <= 79 })
  }

  @Test func `scroll thumb covers boundaries and maps pointer positions`() {
    let top = ScrollMetrics(total: 1000, page: 20, offset: 0, track: 20)
    #expect(top.thumbStart == 0)
    #expect(top.offset(at: -100) == 0)
    #expect(top.offset(at: 100) == 980)
    let bottom = ScrollMetrics(total: 1000, page: 20, offset: 980, track: 20)
    #expect(bottom.thumbStart + bottom.thumbLength == bottom.track)
    #expect(!ScrollMetrics(total: 3, page: 20, offset: 100, track: 20).isScrollable)
    let almostVisible = ScrollMetrics(total: 101, page: 100, offset: 0, track: 20)
    #expect(almostVisible.thumbLength < almostVisible.track)
    #expect(almostVisible.offset(at: 20) == 1)
  }
}
