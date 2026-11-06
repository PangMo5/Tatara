// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import TataraCore
import TataraKit
import TermLoom

extension WorkspacePresentation {
  func commentFooter(_ comment: CommentFeature.State, in rect: Rect, into result: inout TerminalScreen) {
    let title = comment.isViewing ? "Conversation" : comment.isConfirming ? "Preview" : comment.operation.titleKey
    result.text(
      " " + l10n(title) + " · #\(comment.item.id.number) · @" + comment.target.author,
      in: Rect(x: rect.x, y: rect.y, width: rect.width, height: 1),
      color: palette.accent,
      bold: true,
    )
    let hints = comment.isViewing
      ? "\(key(.down))/\(key(.up)) · \(l10n("Scroll"))  \(key(.comment)) · \(l10n("Reply"))  Esc · \(l10n("Close"))"
      : "Tab · \(l10n("Focus pane"))  Esc · " + l10n(comment.isConfirming ? "Edit" : "Conversation")
    result.text(" " + hints, in: Rect(x: rect.x, y: rect.y + 1, width: rect.width, height: 1), color: palette.muted)
  }

  func commentThread(_ comment: CommentFeature.State, into result: inout TerminalScreen) {
    let rect = geometry.popup
    let x = rect.x + 2
    let width = max(1, rect.width - 4)
    pane(rect, title: l10n("Conversation") + " · #\(comment.item.id.number)", selected: true, into: &result)
    let anchor = comment.target.anchor
    let state = anchor != nil && anchor?.line == nil && anchor?.subjectType != "file"
      ? l10n("Outdated")
      : comment.context?.thread?.isResolved == true ? l10n("Resolved") : l10n("Comment")
    result.text(
      (anchor?.path ?? l10n("Discussion")) + " · " + state,
      in: Rect(x: x, y: rect.y + 1, width: width, height: 1),
      color: palette.blue,
    )
    if let error = comment.error {
      result.text(
        l10n.error(error),
        in: Rect(x: x, y: rect.y + 2, width: width, height: 1),
        color: palette.red,
      )
    }
    if let document = comment.threadDocument {
      for (index, spans) in document.displayLines.dropFirst(comment.threadScroll).prefix(max(1, rect.height - 9)).enumerated() {
        let line = Line(spans.map { span in Span(span.text, style: Style(
          foreground: palette.foreground(span),
          background: span.role == .commentCode
            ? palette.surface
            : palette.background,
          modifiers: (span.bold ? Modifier.bold : [])
            .union(span.role == .commentEmphasis || span
              .role == .commentQuote
              ? .italic
              : []).union(span.role == .commentLink
              ? .underlined
              : []).union(span.role == .commentStrikethrough ? .crossedOut : []),
        )) })
        result.operations.append(.text(Rect(x: x, y: rect.y + 3 + index, width: width, height: 1), Text([line])))
      }
    } else {
      result.text(loadingLabel(), in: Rect(x: x, y: rect.y + 3, width: width, height: 1), color: palette.muted)
    }
    if let context = comment.context {
      let operations: [CommentOperation] = [
        .reply,
        .edit,
        .delete,
        .react,
        context.thread?.isResolved == true
          ? .unresolve
          : .resolve,
      ]
      let allowed = operations.filter { context.allows($0) }
      let room = max(1, width / max(1, allowed.count))
      for (index, operation) in allowed.enumerated() {
        button(
          "comment-op:" + operation.rawValue,
          title: l10n(operation == .reply
            ? "Reply"
            : operation == .edit
              ? "Edit"
              : operation == .delete ? "Delete" : operation == .react ? "React" : operation == .resolve ? "Resolve" : "Reopen"),
          rect: Rect(x: x + index * room, y: rect.bottom - 4, width: max(1, room - 1), height: 1),
          into: &result,
        )
      }
    }
    result.text(
      "\(key(.down))/\(key(.up)) · \(l10n("Scroll"))  \(key(.comment)) · \(l10n("Reply"))  Esc · \(l10n("Back"))",
      in: Rect(x: x, y: rect.bottom - 2, width: width, height: 1),
      color: palette.muted,
    )
  }
}
