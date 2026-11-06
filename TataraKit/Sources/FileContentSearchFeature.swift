// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import Foundation
import TataraCore

// MARK: - FileContentHit

public struct FileContentHit: Equatable, Sendable {
  public init(location: SourceLocation, excerpt: String, ranges: [Range<Int>]) {
    self.location = location
    self.excerpt = excerpt
    self.ranges = ranges
  }

  public let location: SourceLocation
  public let excerpt: String
  public let ranges: [Range<Int>]
}

// MARK: - FileContentSearchFeature

@Reducer
public struct FileContentSearchFeature {

  // MARK: Lifecycle

  public init() { }

  // MARK: Public

  @ObservableState
  public struct State: Equatable {
    public init(detail: ItemDetail, keymap: Keymap) {
      self.detail = detail
      self.keymap = keymap
    }

    public let detail: ItemDetail
    public let keymap: Keymap
    public var query = ""
    public var completedQuery = ""
    public var pendingPrefix: String?
    public var isEditing = true
    public var isLoading = false
    public var results = [FileContentHit]()
    public var selection = 0
    public var generation = 0
    public var error: TataraError?
  }

  public enum Action {
    case keyPressed(String)
    case response(generation: Int, Result<[FileContentHit], TataraError>)
    case delegate(Delegate)

    public enum Delegate {
      case close
      case open(FileContentHit)
    }
  }

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .keyPressed(let key):
        if state.isEditing {
          switch key {
          case "esc": state.isEditing = false
            state.query = state.completedQuery

          case "enter":
            guard !state.query.isEmpty, state.detail.revision != nil else { return .none }
            state.isEditing = false
            state.completedQuery = state.query
            state.isLoading = true
            state.error = nil
            state.results = []
            state.selection = 0
            state.generation += 1
            let generation = state.generation
            let detail = state.detail
            let query = state.query
            return .run(priority: .utility) { [forge] send in
              do {
                let results = try await Self.search(detail, query: query, forge: forge)
                try Task.checkCancellation()
                await send(.response(generation: generation, .success(results)))
              } catch is CancellationError {} catch {
                if !Task.isCancelled {
                  await send(.response(generation: generation, .failure(.wrapping(error))))
                }
              }
            }.cancellable(id: CancelID.search, cancelInFlight: true)

          case "ctrl-u": state.query = ""

          case "backspace": if !state.query.isEmpty {
              state.query.removeLast()
            }

          case "space": state.query += " "

          default: if key.count == 1 {
              state.query += key
            }
          }
          return .none
        }
        if key == "esc" || state.keymap.command(for: key) == .quit {
          return .send(.delegate(.close))
        }
        if key == "i" || state.keymap.command(for: key) == .search {
          state.isEditing = true
          state.isLoading = false
          state.generation += 1
          return .cancel(id: CancelID.search)
        }
        if key == "g", state.pendingPrefix == nil {
          state.pendingPrefix = key
          return .none
        }
        let combined = state.pendingPrefix.map { $0 + key } ?? key
        state.pendingPrefix = nil
        switch state.keymap.command(for: combined) {
        case .open:
          guard state.results.indices.contains(state.selection) else { return .none }
          return .send(.delegate(.open(state.results[state.selection])))

        case .down: state.selection = min(max(0, state.results.count - 1), state.selection + 1)

        case .up: state.selection = max(0, state.selection - 1)

        case .nextMatch:
          if !state.results.isEmpty {
            state.selection = (state.selection + 1) % state.results.count
          }

        case .previousMatch:
          if !state.results.isEmpty {
            state.selection = (state.selection + state.results.count - 1) % state.results.count
          }

        case .first: state.selection = 0

        case .last: state.selection = max(0, state.results.count - 1)

        case .halfPageDown: state.selection = min(max(0, state.results.count - 1), state.selection + 8)

        case .halfPageUp: state.selection = max(0, state.selection - 8)

        default: break
        }
        return .none

      case .response(let generation, let result):
        guard generation == state.generation else { return .none }
        state.isLoading = false
        switch result {
        case .success(let results): state.results = results
          state.completedQuery = state.query

        case .failure(let error): state.error = error
        }
        return .none

      case .delegate: return .none
      }
    }
  }

  // MARK: Internal

  enum CancelID { case search }

  @Dependency(ForgeClient.self) var forge

  // MARK: Private

  @concurrent
  private static func search(_ detail: ItemDetail, query: String, forge: ForgeClient) async throws -> [FileContentHit] {
    guard let revision = detail.revision else { throw TataraError(
      .unavailable,
      detail: "File search requires immutable revisions.",
    ) }
    let pattern = try SearchPattern(query)
    return try await withThrowingTaskGroup(of: (Int, [FileContentHit]).self) { group in
      var files = detail.files.enumerated().makeIterator()
      var ordered = [Int: [FileContentHit]]()
      var total = 0
      func enqueue(_ index: Int, _ file: ChangedFile) {
        group.addTask {
          try Task.checkCancellation()
          let deleted = file.status == "removed"
          let data = try await forge.content(detail.item.id.repository, deleted ? revision.mergeBase : revision.head, file.path)
          guard data.count <= 32 * 1024 * 1024 else { throw TataraError(
            .invalidResponse,
            detail: "File exceeds the 32 MiB search limit: \(file.path)",
          ) }
          guard !data.contains(0), let source = String(data: data, encoding: .utf8) else { return (index, []) }
          var hits = [FileContentHit]()
          for (line, text) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            try Task.checkCancellation()
            let ranges = try pattern.ranges(in: String(text))
            guard let first = ranges.first else { continue }
            guard hits.count < 10_000 else { throw TataraError(
              .invalidResponse,
              detail: "Search exceeds 10,000 matching lines; narrow the expression.",
            ) }
            let utf16 = String(text) as NSString
            var start = max(0, first.lowerBound - 40)
            var end = min(utf16.length, max(first.lowerBound + 160, start + 200))
            if start > 0, (0xDC00 ... 0xDFFF).contains(utf16.character(at: start)) {
              start -= 1
            }
            if end < utf16.length, (0xDC00 ... 0xDFFF).contains(utf16.character(at: end)) {
              end += 1
            }
            let range = NSRange(location: start, length: end - start)
            let excerpt = utf16.substring(with: range)
            let local = ranges.compactMap { match -> Range<Int>? in
              let lower = max(start, match.lowerBound)
              let upper = min(end, match.upperBound)
              return lower < upper ? lower - start ..< upper - start : nil
            }
            hits.append(.init(
              location: .init(path: file.path, line: line + 1, side: deleted ? .left : .right),
              excerpt: excerpt,
              ranges: local,
            ))
          }
          return (index, hits)
        }
      }
      for _ in 0 ..< 4 {
        if let (index, file) = files.next() {
          enqueue(index, file)
        }
      }
      while let (index, hits) = try await group.next() {
        total += hits.count
        guard total <= 10_000 else { throw TataraError(
          .invalidResponse,
          detail: "Search exceeds 10,000 matching lines; narrow the expression.",
        ) }
        ordered[index] = hits
        if let (index, file) = files.next() {
          enqueue(index, file)
        }
      }
      return ordered.keys.sorted().flatMap { ordered[$0] ?? [] }
    }
  }

}
