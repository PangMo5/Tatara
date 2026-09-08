// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import SwiftTUI
import TataraKit

struct FilterView: View {
  let store: StoreOf<FilterFeature>
  let l10n: Localization
  let palette: Palette
  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(l10n("Filters and presets")).bold().foregroundStyle(palette.accent)
      TextField(l10n("GitHub search query"), text: .init(get: { store.query }, set: { store.send(.queryChanged($0)) }))
        .onKeyPress(.escape) { _ in store.send(.close)
          return .handled
        }
        .onKeyPress(.return) { _ in store.send(.apply)
          return .handled
        }
      Text("is:open author:@me review-requested:@me label:bug draft:false").foregroundStyle(palette.muted).lineLimit(1)
      Text(l10n("Presets")).bold()
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(store.allPresets) { preset in
            Button("\(store.selectedID == preset.id ? "▸ " : "  ")\(preset.isBuiltIn ? l10n(preset.name) : preset.name)") {
              store.send(.presetSelected(preset.id))
            }
            .onKeyPress(.escape) { _ in store.send(.close)
              return .handled
            }
          }
        }
      }.frame(height: 8)
        .onKeyPress(.escape) { _ in store.send(.close)
          return .handled
        }
      TextField(l10n("Preset name"), text: .init(get: { store.name }, set: { store.send(.nameChanged($0)) }))
        .onKeyPress(.escape) { _ in store.send(.close)
          return .handled
        }
      HStack(spacing: 2) {
        Button(l10n("Apply")) { store.send(.apply) }.buttonStyle(.bordered)
          .onKeyPress(.escape) { _ in store.send(.close)
            return .handled
          }
        Button(l10n("Save preset")) { store.send(.save) }.buttonStyle(.bordered)
          .onKeyPress(.escape) { _ in store.send(.close)
            return .handled
          }
        Button(l10n("Delete preset")) { store.send(.delete) }.buttonStyle(.bordered)
          .onKeyPress(.escape) { _ in store.send(.close)
            return .handled
          }
          .disabled(!store.presets.contains { $0.id == store.selectedID })
        Button(l10n("Close")) { store.send(.close) }.buttonStyle(.bordered)
          .onKeyPress(.escape) { _ in store.send(.close)
            return .handled
          }
      }.disabled(store.isSaving)
      if let error = store.error {
        Text(l10n.error(error)).foregroundStyle(palette.red).lineLimit(2)
      }
      if let message = store.message {
        Text(l10n(message)).foregroundStyle(palette.yellow)
      }
      if store.isSaving {
        Text(l10n("Loading…"))
      }
      Spacer(minLength: 0)
    }.padding(1).foregroundStyle(palette.text)
      .onKeyPress(.escape) { _ in store.send(.close)
        return .handled
      }
  }
}
