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
    public var labelOffset = 0
    public var isLoadingLabels = false
    public var labelsGeneration = 0
    public var labels: [String] = []
    public var showsLabels = false
    public var selectedLabel: String?
    public var labelsError: TataraError?
    public var selectedID: String?
    public var isSaving = false
    public var generation = 0
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
    case sectionSelected(labels: Bool), labelSelected(String), labelsScrolled(Int)
    case labelsLoaded(generation: Int, Result<[String], TataraError>)
    case queryChanged(String), nameChanged(String), presetSelected(String)
    case loaded(generation: Int, Result<[FilterPreset], TataraError>)
    case delegate(Delegate)
    public enum Delegate { case apply(String), close }
  }

  private enum CancelID { case load, labels }

  @Dependency(ForgeClient.self) var forge
  @Dependency(FilterPresetClient.self) var storage
  @Dependency(\.uuid) var uuid
  public init() {}
  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .appeared:
        guard !state.isSaving else { return .none }
        state.generation += 1
        let generation = state.generation
        state.isLoadingLabels = true
        state.labelsGeneration += 1
        let labelsGeneration = state.labelsGeneration
        return .merge(
          .run { [repository = state.repository, forge] send in
            do {
              let labels = try await forge.labels(repository)
              try Task.checkCancellation()
              await send(.labelsLoaded(generation: labelsGeneration, .success(labels)))
            } catch is CancellationError {} catch {
              if !Task.isCancelled {
                await send(.labelsLoaded(generation: labelsGeneration, .failure(.wrapping(error))))
              }
            }
          }.cancellable(id: CancelID.labels, cancelInFlight: true),
          .concatenate(.cancel(id: CancelID.load), .run { [repository = state.repository, storage] send in
            do {
              let presets = try await storage.load(repository)
              try Task.checkCancellation()
              await send(.loaded(generation: generation, .success(presets)))
            } catch is CancellationError {
            } catch {
              if !Task.isCancelled {
                await send(.loaded(generation: generation, .failure(.wrapping(error))))
              }
            }
          }.cancellable(id: CancelID.load)),
        )
      case let .sectionSelected(labels): state.showsLabels = labels
        return .none
      case let .labelSelected(label):
        guard state.labels.contains(label) else { return .none }
        state.selectedLabel = label
        state.query = LabelQuery.toggling(label, in: state.query)
        state.message = nil
        return .none
      case let .labelsScrolled(delta):
        state.labelOffset = max(0, min(max(0, state.labels.count - 1), state.labelOffset + delta))
        return .none
      case let .labelsLoaded(generation, result):
        guard generation == state.labelsGeneration else { return .none }
        state.isLoadingLabels = false
        switch result {
        case let .success(labels): state.labels = labels
          state.labelsError = nil
        case let .failure(error): state.labelsError = error
        }
        return .none
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
        state.generation += 1
        let generation = state.generation
        state.isSaving = true
        state.selectedID = preset.id
        return .concatenate(.cancel(id: CancelID.load), .run { [repository = state.repository, storage] send in
          do { try await storage.save(repository, preset)
            let presets = try await storage.load(repository)
            try Task.checkCancellation()
            await send(.loaded(generation: generation, .success(presets)))
          } catch is CancellationError {
          } catch {
            if !Task.isCancelled {
              await send(.loaded(generation: generation, .failure(.wrapping(error))))
            }
          }
        })
      case .delete:
        guard !state.isSaving, let id = state.selectedID, state.presets.contains(where: { $0.id == id }) else { return .none }
        state.generation += 1
        let generation = state.generation
        state.isSaving = true
        state.selectedID = nil
        return .concatenate(.cancel(id: CancelID.load), .run { [repository = state.repository, storage] send in
          do { try await storage.delete(repository, id)
            let presets = try await storage.load(repository)
            try Task.checkCancellation()
            await send(.loaded(generation: generation, .success(presets)))
          } catch is CancellationError {
          } catch {
            if !Task.isCancelled {
              await send(.loaded(generation: generation, .failure(.wrapping(error))))
            }
          }
        })
      case let .loaded(generation, result):
        guard generation == state.generation else { return .none }
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
