// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import SwiftTUI
import TataraCore
import TataraKit

struct ReviewView: View {
  let store: StoreOf<ReviewFeature>
  let l10n: Localization
  let palette: Palette

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      Text("\(l10n("Write your review")) · #\(store.item.id.number)").bold().foregroundStyle(palette.accent)
      Text(TerminalText.sanitize(store.item.title)).lineLimit(1)
      if let error = store.error {
        Text(l10n.error(error)).foregroundStyle(palette.red)
      }
      if store.isSubmitting {
        Text(l10n("Loading…"))
      } else if store.revisionChanged {
        Text(l10n("Keep the summary and remove old inline comments to review the latest revision."))
        ScrollView {
          VStack(alignment: .leading, spacing: 1) {
            Text(TerminalText.sanitize(store.body))
            ForEach(Array(store.comments.enumerated()), id: \.offset) { _, comment in
              Text(
                "\(TerminalText.sanitize(comment.path)):\(comment.startLine.map { String($0) + "–" } ?? "")\(comment.line) · \(comment.side.rawValue)",
              )
              Text(TerminalText.sanitize(comment.body))
            }
          }
        }
        .onKeyPress(.escape) { _ in store.send(.cancelButtonPressed)
          return .handled
        }
        Button(l10n("Review latest revision")) { store.send(.reviewLatestRevisionButtonPressed) }
          .buttonStyle(.bordered).onKeyPress(.escape) { _ in store.send(.cancelButtonPressed)
            return .handled
          }
      } else if store.isEditingInline {
        Text(TerminalText.sanitize(store.selectedFile?.path ?? "")).foregroundStyle(palette.blue)
        if store.inlineAnchorLocked {
          Text(
            "\(store.inlineSide.rawValue) · \(store.inlineStartLine.isEmpty ? store.inlineLine : store.inlineStartLine + "–" + store.inlineLine)",
          )
          .foregroundStyle(palette.accent)
        } else {
          Text(l10n("Choose a source line included in this file's patch.")).foregroundStyle(palette.muted)
          HStack(spacing: 2) {
            ForEach(InlineComment.Side.allCases, id: \.rawValue) { side in
              Button("\(store.inlineSide == side ? "● " : "○ ")\(side.rawValue)") { store.send(.inlineSideSelected(side)) }
                .buttonStyle(.bordered).onKeyPress(.escape) { _ in store.send(.cancelButtonPressed)
                  return .handled
                }
            }
            TextField(
              l10n("Line"),
              text: SwiftTUI.Binding(get: { store.inlineLine }, set: { store.send(.inlineLineChanged($0)) }),
            )
            .onKeyPress(.escape) { _ in store.send(.cancelButtonPressed)
              return .handled
            }
            TextField(
              l10n("Start line"),
              text: SwiftTUI.Binding(get: { store.inlineStartLine }, set: { store.send(.inlineStartLineChanged($0)) }),
            )
            .onKeyPress(.escape) { _ in store.send(.cancelButtonPressed)
              return .handled
            }
          }
        }
        TextEditor(text: SwiftTUI.Binding(get: { store.inlineBody }, set: { store.send(.inlineBodyChanged($0)) }))
          .frame(maxWidth: .infinity, maxHeight: .infinity).border(palette.surface)
          .onKeyPress(.escape) { _ in store.send(.cancelButtonPressed)
            return .handled
          }
        HStack(spacing: 2) {
          Button(l10n("Add comment to review")) { store.send(.addInlineButtonPressed) }.buttonStyle(.bordered)
            .onKeyPress(.escape) { _ in store.send(.cancelButtonPressed)
              return .handled
            }
          Button(l10n("Back")) { store.send(.cancelInlineButtonPressed) }.buttonStyle(.bordered)
            .onKeyPress(.escape) { _ in store.send(.cancelButtonPressed)
              return .handled
            }
        }
      } else if store.isConfirming {
        Text(l10n("This will be posted to GitHub.")).foregroundStyle(palette.yellow)
        Text("\(store.item.id.repository) · \(l10n(eventTitle(store.event)))")
        ScrollView {
          VStack(alignment: .leading, spacing: 1) {
            Text(TerminalText.sanitize(store.body)).frame(maxWidth: .infinity, alignment: .leading)
            ForEach(Array(store.comments.enumerated()), id: \.offset) { _, comment in
              Text(
                "\(TerminalText.sanitize(comment.path)):\(comment.startLine.map { String($0) + "–" } ?? "")\(comment.line) · \(comment.side.rawValue)",
              )
              .foregroundStyle(palette.blue)
              Text(TerminalText.sanitize(comment.body))
            }
          }
        }
        .onKeyPress(.escape) { _ in store.send(.cancelButtonPressed)
          return .handled
        }
        HStack(spacing: 2) {
          Button(l10n(store.item.kind == .pullRequest ? "Submit review" : "Submit comment")) { store.send(.submitButtonPressed) }
            .buttonStyle(.bordered).onKeyPress(.escape) { _ in store.send(.cancelButtonPressed)
              return .handled
            }
          Button(l10n("Edit")) { store.send(.editButtonPressed) }.buttonStyle(.bordered)
            .onKeyPress(.escape) { _ in store.send(.cancelButtonPressed)
              return .handled
            }
        }
      } else {
        if store.item.kind == .pullRequest {
          HStack(spacing: 2) {
            ForEach(ReviewEvent.allCases, id: \.rawValue) { event in
              Button("\(store.event == event ? "● " : "○ ")\(l10n(eventTitle(event)))") { store.send(.eventSelected(event)) }
                .buttonStyle(.bordered).onKeyPress(.escape) { _ in store.send(.cancelButtonPressed)
                  return .handled
                }
            }
          }
        }
        TextEditor(text: SwiftTUI.Binding(get: { store.body }, set: { store.send(.bodyChanged($0)) }))
          .frame(maxWidth: .infinity, maxHeight: .infinity).border(palette.surface)
          .onKeyPress(.escape) { _ in store.send(.cancelButtonPressed)
            return .handled
          }
        ForEach(Array(store.comments.enumerated()), id: \.offset) { index, comment in
          HStack(spacing: 2) {
            Text(
              "\(TerminalText.sanitize(comment.path)):\(comment.startLine.map { String($0) + "–" } ?? "")\(comment.line) · \(comment.side.rawValue)",
            )
            .lineLimit(1)
            Button(l10n("Remove")) { store.send(.removeInlineButtonPressed(index)) }
              .onKeyPress(.escape) { _ in store.send(.cancelButtonPressed)
                return .handled
              }
          }
        }
        Button(l10n("Preview")) { store.send(.previewButtonPressed) }.buttonStyle(.bordered)
          .onKeyPress(.escape) { _ in store.send(.cancelButtonPressed)
            return .handled
          }
        Text("Esc · \(l10n("Back"))  ·  \(l10n("Your draft stays here until you quit."))").foregroundStyle(palette.muted)
      }
      Spacer(minLength: 0)
    }.padding(2).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private func eventTitle(_ event: ReviewEvent) -> String {
    switch event { case .comment: "Comment"
    case .approve: "Approve"
    case .requestChanges: "Request changes" }
  }
}
