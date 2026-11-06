// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import TataraCore
import TataraKit
import TermLoom

extension WorkspacePresentation {
  func commentEditor(_ comment: CommentFeature.State, into result: inout TerminalScreen) {
    if comment.isViewing {
      commentThread(comment, into: &result)
      return
    }
    let rect = geometry.popup
    let x = rect.x + 2
    let width = rect.width - 4
    pane(rect, title: l10n(comment.operation.titleKey), selected: true, into: &result)
    if rect.height < 20 {
      result.text(
        l10n("Expand the terminal to edit comments."),
        in: Rect(x: x, y: rect.y + 3, width: width, height: 2),
        color: palette.text,
      )
      button("comment-close", title: l10n("Close"), rect: Rect(x: x, y: rect.bottom - 2, width: width, height: 1), into: &result)
      return
    }
    let anchor = comment.target.anchor
    let side = anchor?.side
      .map { $0 == .left ? (ascii ? "LEFT" : "← LEFT") : (ascii ? "RIGHT" : "RIGHT →") } ?? l10n("Discussion")
    let coordinate = anchor.map { " · \($0.path):\(($0.line ?? $0.originalLine).map(String.init) ?? "–")" } ?? ""
    result.text(
      "#\(comment.item.id.number) · @\(comment.target.author) · \(side)\(coordinate)",
      in: Rect(x: x, y: rect.y + 3, width: width, height: 1),
      color: palette.text,
      bold: true,
    )
    let viewer = comment.context.map { "@" + $0.viewer } ?? loadingLabel()
    result.text(
      viewer + " · " + (comment.expectedHead.map { String($0.prefix(8)) } ?? ""),
      in: Rect(x: x, y: rect.y + 4, width: width, height: 1),
      color: palette.muted,
    )
    if comment.isConfirming {
      if let preview = comment.preview {
        for (index, spans) in preview.displayLines.dropFirst(comment.previewScroll).prefix(max(1, rect.height - 11))
          .enumerated()
        {
          let line = Line(spans.map { span in
            Span(span.text, style: Style(
              foreground: palette.foreground(span),
              background: span.role == .commentCode ? palette.surface : palette.background,
              modifiers: (span.bold ? Modifier.bold : [])
                .union(span.role == .commentEmphasis ? .italic : [])
                .union(span.role == .commentLink ? .underlined : [])
                .union(span.role == .commentStrikethrough ? .crossedOut : []),
            ))
          })
          result.operations.append(.text(Rect(x: x, y: rect.y + 6 + index, width: width, height: 1), Text([line])))
        }
      }
    } else {
      if let context = comment.context, comment.operation != .reply && comment.operation != .edit {
        let operations: [CommentOperation] = [
          .reply,
          .edit,
          .delete,
          .react,
          context.thread?.isResolved == true ? .unresolve : .resolve,
        ]
        var column = 0
        for operation in operations where context.allows(operation) {
          let room = max(1, width / 5)
          button(
            "comment-op:" + operation.rawValue,
            title: l10n(operation.titleKey),
            rect: Rect(x: x + column * room, y: rect.y + 6, width: room - 1, height: 1),
            into: &result,
          )
          column += 1
        }
      }
      if comment.operation == .reply || comment.operation == .edit {
        editor(
          "comment-body",
          value: comment.body,
          rect: Rect(x: x, y: rect.y + 8, width: width, height: max(2, rect.height - 13)),
          into: &result,
        )
      } else if comment.operation == .react {
        for (index, reaction) in ReactionContent.allCases.enumerated() {
          let existing = comment.context?.reactions.first { $0.content == reaction }
          let title = (comment.reaction == reaction ? "▸ " : "  ") + l10n(reaction.symbol)
            + " \(existing?.count ?? 0)" + (existing?.viewerHasReacted == true ? " ✓" : "")
          button(
            "reaction:" + reaction.rawValue,
            title: title,
            rect: Rect(x: x + index % 2 * (width / 2), y: rect.y + 8 + index / 2, width: width / 2 - 1, height: 1),
            into: &result,
          )
        }
      } else {
        result.text(
          l10n(comment.operation.titleKey) + " · @" + comment.target.author,
          in: Rect(x: x, y: rect.y + 8, width: width, height: 1),
          color: comment.operation == .delete ? palette.red : palette.yellow,
        )
        for (index, line) in comment.target.body.split(separator: "\n").prefix(max(1, rect.height - 15)).enumerated() {
          result.text(String(line), in: Rect(x: x, y: rect.y + 10 + index, width: width, height: 1), color: palette.text)
        }
      }
    }
    let status = comment.error.map { l10n.error($0) }
      ?? (comment.isSubmitting ? l10n("Submitting…") : comment.isLoading || comment.isPreparing ? loadingLabel() : "")
    result.text(
      status,
      in: Rect(x: x, y: rect.bottom - 4, width: width, height: 1),
      color: comment.error == nil ? palette.muted : palette.red,
    )
    if !comment.isSubmitting {
      if comment.isConfirming {
        button(
          "comment-confirm",
          title: l10n("Confirm"),
          rect: Rect(x: x, y: rect.bottom - 2, width: width / 3 - 1, height: 1),
          into: &result,
        )
        button(
          "comment-back",
          title: l10n("Back"),
          rect: Rect(x: x + width / 3, y: rect.bottom - 2, width: width / 3 - 1, height: 1),
          into: &result,
        )
      } else if !comment.isLoading, comment.mutation != nil {
        button(
          "comment-preview",
          title: l10n("Preview"),
          rect: Rect(x: x, y: rect.bottom - 2, width: width / 3 - 1, height: 1),
          into: &result,
        )
      }
      button(
        "comment-close",
        title: l10n("Close"),
        rect: Rect(x: x + width * 2 / 3, y: rect.bottom - 2, width: width / 3 - 1, height: 1),
        into: &result,
      )
    }
  }
}
