// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import Foundation
import TataraCore

@Reducer
public struct FilterFeature {
  @ObservableState
  public struct State: Equatable {
    public var repository: RepositoryID
    public var kind: ItemKind
    public var query: String
    public var name = ""
    public var presets: [FilterPreset] = []
    public var selectedID: String?
    public var isSaving = false
    public var error: TataraError?
    public var message: String?
    public var allPresets: [FilterPreset] {
      FilterPreset.defaults(for: kind) + presets
    }

    public init(repository: RepositoryID, kind: ItemKind, query: String) {
      self.repository = repository
      self.kind = kind
      self.query = query
    }
  }

  public enum Action {
    case appeared, apply, close, save, delete
    case queryChanged(String), nameChanged(String), presetSelected(String)
    case loaded(Result<[FilterPreset], TataraError>)
    case delegate(Delegate)
    public enum Delegate { case apply(String), close }
  }

  @Dependency(FilterPresetClient.self) var storage
  @Dependency(\.uuid) var uuid
  public init() {}
  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .appeared: return .run { [repository = state.repository, storage] send in
          do { try await send(.loaded(.success(storage.load(repository)))) }
          catch { await send(.loaded(.failure(.wrapping(error)))) }
        }
      case let .queryChanged(query): state.query = query
        state.message = nil
        return .none
      case let .nameChanged(name): state.name = name
        state.message = nil
        return .none
      case let .presetSelected(id):
        guard let preset = state.allPresets.first(where: { $0.id == id }) else { return .none }
        state.query = preset.query
        state.selectedID = id
        state.name = preset.isBuiltIn ? "" : preset.name
        state.message = nil
        return .none
      case .apply: return state
        .isSaving ? .none : .send(.delegate(.apply(state.query.trimmingCharacters(in: .whitespacesAndNewlines))))
      case .close: return state.isSaving ? .none : .send(.delegate(.close))
      case .save:
        guard !state.isSaving else { return .none }
        let name = state.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { state.message = "Enter a preset name."
          return .none
        }
        let preset = FilterPreset(
          id: state.presets.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }?.id ?? uuid().uuidString,
          name: name,
          query: state.query,
        )
        state.isSaving = true
        state.selectedID = preset.id
        return .run { [repository = state.repository, storage] send in
          do { try await storage.save(repository, preset)
            try await send(.loaded(.success(storage.load(repository))))
          } catch { await send(.loaded(.failure(.wrapping(error)))) }
        }
      case .delete:
        guard !state.isSaving, let id = state.selectedID, state.presets.contains(where: { $0.id == id }) else { return .none }
        state.isSaving = true
        state.selectedID = nil
        return .run { [repository = state.repository, storage] send in
          do { try await storage.delete(repository, id)
            try await send(.loaded(.success(storage.load(repository))))
          } catch { await send(.loaded(.failure(.wrapping(error)))) }
        }
      case let .loaded(result):
        state.isSaving = false
        switch result {
        case let .success(presets): state.presets = presets
          state.error = nil
        case let .failure(error): state.error = error
        }
        return .none
      case .delegate: return .none
      }
    }
  }
}
