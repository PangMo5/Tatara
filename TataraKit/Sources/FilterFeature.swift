// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import Foundation
import TataraCore

@Reducer
public struct FilterFeature {

  // MARK: Lifecycle

  public init() { }

  // MARK: Public

  @ObservableState
  public struct State: Equatable {

    // MARK: Lifecycle

    public init(repository: RepositoryID, kind: ItemKind, query: String) {
      self.repository = repository
      self.kind = kind
      self.query = query
    }

    // MARK: Public

    public var repository: RepositoryID
    public var kind: ItemKind
    public var query: String
    public var name = ""
    public var presets = [FilterPreset]()
    public var labelOffset = 0
    public var isLoadingLabels = false
    public var labelsGeneration = 0
    public var labels = [String]()
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

  }

  public enum Action {
    case appeared
    case apply
    case close
    case save
    case delete
    case sectionSelected(labels: Bool)
    case labelSelected(String)
    case labelsScrolled(Int)
    case labelsLoaded(generation: Int, Result<[String], TataraError>)
    case queryChanged(String)
    case nameChanged(String)
    case presetSelected(String)
    case loaded(generation: Int, Result<[FilterPreset], TataraError>)
    case delegate(Delegate)

    public enum Delegate { case apply(String), close }
  }

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

      case .sectionSelected(let labels): state.showsLabels = labels
        return .none

      case .labelSelected(let label):
        guard state.labels.contains(label) else { return .none }
        state.selectedLabel = label
        state.query = LabelQuery.toggling(label, in: state.query)
        state.message = nil
        return .none

      case .labelsScrolled(let delta):
        state.labelOffset = max(0, min(max(0, state.labels.count - 1), state.labelOffset + delta))
        return .none

      case .labelsLoaded(let generation, let result):
        guard generation == state.labelsGeneration else { return .none }
        state.isLoadingLabels = false
        switch result {
        case .success(let labels): state.labels = labels
          state.labelsError = nil

        case .failure(let error): state.labelsError = error
        }
        return .none

      case .queryChanged(let query): state.query = query
        state.message = nil
        return .none

      case .nameChanged(let name): state.name = name
        state.message = nil
        return .none

      case .presetSelected(let id):
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

      case .loaded(let generation, let result):
        guard generation == state.generation else { return .none }
        state.isSaving = false
        switch result {
        case .success(let presets): state.presets = presets
          state.error = nil

        case .failure(let error): state.error = error
        }
        return .none

      case .delegate: return .none
      }
    }
  }

  // MARK: Internal

  @Dependency(ForgeClient.self) var forge
  @Dependency(FilterPresetClient.self) var storage
  @Dependency(\.uuid) var uuid

  // MARK: Private

  private enum CancelID { case load, labels }

}
