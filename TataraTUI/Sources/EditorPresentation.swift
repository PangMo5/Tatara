// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import TataraCore
import TataraKit
import TermLoom
import TermLoomTextArea

extension WorkspacePresentation {
  static func anchor(_ comment: InlineComment) -> String {
    "\(TerminalText.sanitize(comment.path)):\(comment.startLine.map { String($0) + "–" } ?? "")\(comment.line) · \(comment.side.rawValue)"
  }

  static func eventTitle(_ event: ReviewEvent) -> String {
    switch event { case .comment: "Comment"
    case .approve: "Approve"
    case .requestChanges: "Request changes" }
  }

  func field(_ id: String, value: String, placeholder: String, rect: Rect, into result: inout TerminalScreen) {
    let state = fields[id].flatMap { $0.text == value ? $0 : nil } ?? TextFieldState(text: value)
    result.operations.append(.field(rect, TextField(
      state,
      id: ControlID(id),
      placeholder: l10n(placeholder),
      style: Style(foreground: palette.text, background: palette.surface),
      focusedStyle: Style(foreground: palette.text, background: palette.surface1),
      selectionStyle: Style(foreground: palette.text, background: palette.editorSelection, modifiers: noColor ? .reversed : []),
    )))
  }

  func editor(_ id: String, value: String, rect: Rect, into result: inout TerminalScreen) {
    let state = editorTexts[id] == value ? editors[id] ?? TextAreaState(text: value) : TextAreaState(text: value)
    result.operations.append(.editor(rect, TextArea(
      state,
      id: ControlID(id),
      style: Style(foreground: palette.text, background: palette.surface),
      focusedStyle: Style(foreground: palette.text, background: palette.surface1),
      selectionStyle: Style(foreground: palette.text, background: palette.editorSelection, modifiers: noColor ? .reversed : []),
    )))
  }

  func button(_ id: String, title: String, rect: Rect, into result: inout TerminalScreen) {
    let primary = [
      "filter-apply",
      "review-add",
      "review-preview",
      "review-submit",
      "review-latest",
      "comment-preview",
      "comment-confirm",
    ].contains(id)
    result.operations.append(.button(rect, Button(
      " " + title + " ",
      id: ControlID(id),
      action: ActionID(id),
      style: Style(
        foreground: primary ? palette.base : palette.lavender,
        background: primary ? palette.lavender : palette.surface,
        modifiers: primary ? .bold : [],
      ),
      focusedStyle: Style(foreground: palette.base, background: palette.lavender, modifiers: noColor ? .reversed : .bold),
      alignment: .leading,
    )))
  }

  func filterScreen(_ filter: FilterFeature.State, into result: inout TerminalScreen) {
    let rect = geometry.popup
    let x = rect.x + 2
    let width = rect.width - 4
    let compact = rect.height < 22
    let listY = rect.y + (compact ? 5 : 8)
    let capacity = max(1, min(8, rect.height - (compact ? 11 : 17)))
    pane(rect, title: l10n("Filters and presets"), selected: true, into: &result)
    field(
      "filter-query",
      value: filter.query,
      placeholder: "GitHub search query",
      rect: Rect(x: x, y: rect.y + 3, width: width, height: 1),
      into: &result,
    )
    if !compact {
      result.text(
        "is:open author:@me review-requested:@me label:bug draft:false",
        in: Rect(x: x, y: rect.y + 5, width: width, height: 1),
        color: palette.muted,
      )
    }
    button("filter-presets", title: l10n("Presets"), rect: Rect(x: x, y: listY - 1, width: width / 2, height: 1), into: &result)
    button(
      "filter-labels",
      title: l10n("Labels"),
      rect: Rect(x: x + width / 2, y: listY - 1, width: width / 2, height: 1),
      into: &result,
    )
    if filter.showsLabels {
      let start = min(filter.labelOffset, max(0, filter.labels.count - capacity))
      for (index, label) in filter.labels.dropFirst(start).prefix(capacity).enumerated() {
        button(
          "label:" + label,
          title: "\(LabelQuery.contains(label, in: filter.query) ? "[x]" : "[ ]") \(TerminalText.sanitize(label))",
          rect: Rect(x: x, y: listY + index, width: width, height: 1),
          into: &result,
        )
      }
      if filter.labels.isEmpty {
        result.text(
          filter.labelsError.map { l10n.error($0) } ?? (filter.isLoadingLabels ? loadingLabel() : l10n("No labels.")),
          in: Rect(x: x, y: listY, width: width, height: 1),
          color: filter.labelsError == nil ? palette.muted : palette.red,
        )
      }
    } else {
      let selected = filter.allPresets.firstIndex { $0.id == filter.selectedID } ?? 0
      let start = max(0, selected - capacity + 1)
      for (index, preset) in filter.allPresets.dropFirst(start).prefix(capacity).enumerated() {
        let name = preset.isBuiltIn ? l10n(preset.name) : TerminalText.sanitize(preset.name)
        button(
          "preset:" + preset.id,
          title: "\(filter.selectedID == preset.id ? (ascii ? "> " : "▸ ") : "  ")\(name)",
          rect: Rect(x: x, y: listY + index, width: width, height: 1),
          into: &result,
        )
      }
    }
    let nameY = listY + capacity + (compact ? 0 : 1)
    field(
      "filter-name",
      value: filter.name,
      placeholder: "Preset name",
      rect: Rect(x: x, y: nameY, width: width, height: 1),
      into: &result,
    )
    if filter.showsLabels, filter.labels.count > capacity {
      button("labels-prev", title: ascii ? "<" : "↑", rect: Rect(x: x, y: nameY + 1, width: width / 2, height: 1), into: &result)
      button(
        "labels-next",
        title: ascii ? ">" : "↓",
        rect: Rect(x: x + width / 2, y: nameY + 1, width: width / 2, height: 1),
        into: &result,
      )
    }
    if !filter.isSaving {
      let titles = ["Apply", "Save preset", "Delete preset", "Close"]
      let ids = ["filter-apply", "filter-save", "filter-delete", "filter-close"]
      let cell = max(1, width / 4)
      for index in 0 ..< 4 where index != 2 || filter.presets.contains(where: { $0.id == filter.selectedID }) {
        button(
          ids[index],
          title: l10n(titles[index]),
          rect: Rect(x: x + index * cell, y: nameY + 2, width: cell, height: 1),
          into: &result,
        )
      }
    }
    let message = filter.error.map { l10n.error($0) } ?? filter.message
      .map { l10n($0) } ?? (filter.isSaving ? loadingLabel() : "")
    result.text(
      message,
      in: Rect(x: x, y: nameY + 4, width: width, height: 1),
      color: filter.error == nil ? palette.yellow : palette.red,
    )
  }

  func inlineReview(_ review: ReviewFeature.State, rect: Rect, into result: inout TerminalScreen) {
    let x = rect.x + 1
    let width = rect.width - 2
    let bottom = rect.bottom
    pane(rect, title: "\(l10n("Write your review")) · #\(review.item.id.number)", selected: true, into: &result)
    let location = review.selectedFile?.path ?? store.reviewLocation?.path ?? ""
    let range = review.inlineLine.isEmpty
      ? store.reviewLocation.map { String($0.line) } ?? ""
      : review.inlineStartLine
        .isEmpty ? review.inlineLine : review.inlineStartLine + "–" + review.inlineLine
    let status = review.error
      .map { l10n.error($0) } ??
      (review.isConfirming ? l10n("This will be posted to GitHub.") : "\(review.inlineSide.rawValue) · \(range) · \(location)")
    result.text(
      status,
      in: Rect(x: x, y: rect.y + 2, width: width, height: 1),
      color: review.error == nil ? palette.muted : palette.red,
    )
    if review.isSubmitting {
      result.text(l10n("Submitting…"), in: Rect(x: x, y: rect.y + 3, width: width, height: 1), color: palette.yellow)
    } else if review.isConfirming || review.revisionChanged {
      result.text(
        l10n(Self.eventTitle(review.event)),
        in: Rect(x: x, y: rect.y + 3, width: width, height: 1),
        color: palette.blue,
      )
      let height = max(1, rect.height - 7)
      if let reviewPreview {
        for (index, spans) in reviewPreview.displayLines.dropFirst(reviewScroll).prefix(height).enumerated() {
          result.text(
            spans.map(\.text).joined(),
            in: Rect(x: x, y: rect.y + 4 + index, width: width, height: 1),
            color: palette.text,
          )
        }
        result.scrollbar(
          Rect(x: rect.x, y: rect.y + 3, width: rect.width, height: height + 2),
          total: reviewPreview.lines.count,
          page: height,
          offset: reviewScroll,
          palette: palette,
        )
      } else {
        result.text(loadingLabel(), in: Rect(x: x, y: rect.y + 4, width: width, height: 1), color: palette.muted)
      }
      if review.revisionChanged {
        button(
          "review-latest",
          title: l10n("Review latest revision"),
          rect: Rect(x: x, y: bottom - 2, width: width, height: 1),
          into: &result,
        )
      } else if reviewPreview != nil {
        button(
          "review-submit",
          title: l10n("Submit review"),
          rect: Rect(x: x, y: bottom - 2, width: width / 2, height: 1),
          into: &result,
        )
        button(
          "review-edit",
          title: l10n("Edit"),
          rect: Rect(x: x + width / 2, y: bottom - 2, width: width / 2, height: 1),
          into: &result,
        )
      }
    } else if review.isEditingInline {
      editor(
        "review-inline",
        value: review.inlineBody,
        rect: Rect(x: x, y: rect.y + 3, width: width, height: max(1, rect.height - 6)),
        into: &result,
      )
      button(
        "review-add",
        title: l10n("Add comment to review"),
        rect: Rect(x: x, y: bottom - 2, width: width * 2 / 3, height: 1),
        into: &result,
      )
      button(
        "review-back",
        title: l10n("Back"),
        rect: Rect(x: x + width * 2 / 3, y: bottom - 2, width: width / 3, height: 1),
        into: &result,
      )
    } else {
      let count = min(review.comments.count, max(0, min(3, rect.height - 11)))
      editor(
        "review-body",
        value: review.body,
        rect: Rect(x: x, y: rect.y + 4, width: width, height: max(1, rect.height - 8 - count)),
        into: &result,
      )
      for (index, event) in ReviewEvent.allCases.enumerated() {
        button(
          "event:" + event.rawValue,
          title: "\(review.event == event ? "* " : "  ")\(l10n(Self.eventTitle(event)))",
          rect: Rect(x: x + index * width / 3, y: rect.y + 3, width: width / 3, height: 1),
          into: &result,
        )
      }
      let start = min(commentScroll, max(0, review.comments.count - count))
      for (offset, comment) in review.comments.dropFirst(start).prefix(count).enumerated() {
        let y = bottom - 3 - count + offset
        result.text(Self.anchor(comment), in: Rect(x: x, y: y, width: width - 12, height: 1), color: palette.blue)
        button(
          "remove:\(review.commentIdentities[start + offset])",
          title: l10n("Remove"),
          rect: Rect(x: x + width - 12, y: y, width: 12, height: 1),
          into: &result,
        )
      }
      button(
        "review-preview",
        title: "\(l10n("Preview")) · \(review.comments.count)",
        rect: Rect(x: x, y: bottom - 2, width: max(1, width - 12), height: 1),
        into: &result,
      )
      if count > 0, review.comments.count > count {
        button(
          "comments-previous",
          title: ascii ? "<" : "↑",
          rect: Rect(x: x + width - 10, y: bottom - 2, width: 4, height: 1),
          into: &result,
        )
        button(
          "comments-next",
          title: ascii ? ">" : "↓",
          rect: Rect(x: x + width - 5, y: bottom - 2, width: 4, height: 1),
          into: &result,
        )
      }
    }
  }

  func reviewScreen(_ review: ReviewFeature.State, into result: inout TerminalScreen) {
    let rect = geometry.review
    pane(rect, title: l10n("Finish review"), selected: true, into: &result)
    let x = rect.x + 2
    let width = max(1, rect.width - 4)
    let bottom = rect.bottom - 1
    result.text(
      "\(l10n("Write your review")) · #\(review.item.id.number) · " + String(review.expectedHead?.prefix(8) ?? ""),
      in: Rect(x: x, y: 2, width: width, height: 1),
      color: palette.text,
      bold: true,
    )
    result.text(review.item.title, in: Rect(x: x, y: 3, width: width, height: 1), color: palette.text)
    if
      let error = review
        .error
    {
      result.text(l10n.error(error), in: Rect(x: x, y: 4, width: width, height: 1), color: palette.red)
    }
    if review.isSubmitting {
      result.text(l10n("Submitting…"), in: Rect(x: x, y: 6, width: width, height: 1), color: palette.yellow)
      return
    }
    if review.isConfirming || review.revisionChanged {
      result.text(
        l10n(review
          .revisionChanged
          ? "Keep the summary and remove old inline comments to review the latest revision."
          : "This will be posted to GitHub."),
        in: Rect(x: x, y: 6, width: width, height: 1),
        color: palette.yellow,
      )
      result.text(
        "\(review.item.id.repository) · \(l10n(Self.eventTitle(review.event)))",
        in: Rect(x: x, y: 7, width: width, height: 1),
        color: palette.text,
      )
      let height = max(1, bottom - 11)
      if let reviewPreview {
        for (index, spans) in reviewPreview.displayLines.dropFirst(reviewScroll).prefix(height).enumerated() {
          result.text(spans.map(\.text).joined(), in: Rect(x: x, y: 9 + index, width: width, height: 1), color: palette.text)
        }
        result.scrollbar(
          Rect(x: rect.x, y: 8, width: rect.width, height: height + 2),
          total: reviewPreview.lines.count,
          page: height,
          offset: reviewScroll,
          palette: palette,
        )
      } else {
        result.text(loadingLabel(), in: Rect(x: x, y: 9, width: width, height: 1), color: palette.muted)
      }
      if review.revisionChanged {
        button(
          "review-latest",
          title: l10n("Review latest revision"),
          rect: Rect(x: x, y: bottom - 1, width: width, height: 1),
          into: &result,
        )
      } else if reviewPreview != nil {
        button(
          "review-submit",
          title: l10n(review.item.kind == .pullRequest ? "Submit review" : "Submit comment"),
          rect: Rect(x: x, y: bottom - 1, width: width / 2, height: 1),
          into: &result,
        )
        button(
          "review-edit",
          title: l10n("Edit"),
          rect: Rect(x: x + width / 2, y: bottom - 1, width: width / 2, height: 1),
          into: &result,
        )
      }
    } else if review.isEditingInline {
      result.text(review.selectedFile?.path ?? "", in: Rect(x: x, y: 6, width: width, height: 1), color: palette.blue)
      if review.inlineAnchorLocked {
        result.text(
          "\(review.inlineSide.rawValue) · \(review.inlineStartLine.isEmpty ? review.inlineLine : review.inlineStartLine + "–" + review.inlineLine)",
          in: Rect(x: x, y: 7, width: width, height: 1),
          color: palette.accent,
        )
      } else {
        result.text(
          l10n("Choose a source line included in this file's patch."),
          in: Rect(x: x, y: 7, width: width, height: 1),
          color: palette.muted,
        )
        for (index, side) in InlineComment.Side.allCases.enumerated() {
          button(
            "side:" + side.rawValue,
            title: "\(review.inlineSide == side ? (ascii ? "*" : "●") : (ascii ? "o" : "○")) \(side.rawValue)",
            rect: Rect(x: x + index * 12, y: 8, width: 12, height: 1),
            into: &result,
          )
        }
        field(
          "inline-line",
          value: review.inlineLine,
          placeholder: "Line",
          rect: Rect(x: x + 26, y: 8, width: 12, height: 1),
          into: &result,
        )
        field(
          "inline-start",
          value: review.inlineStartLine,
          placeholder: "Start line",
          rect: Rect(x: x + 40, y: 8, width: 14, height: 1),
          into: &result,
        )
      }
      editor(
        "review-inline",
        value: review.inlineBody,
        rect: Rect(x: x, y: 10, width: width, height: max(1, bottom - 13)),
        into: &result,
      )
      button(
        "review-add",
        title: l10n("Add comment to review"),
        rect: Rect(x: x, y: bottom - 1, width: width / 2, height: 1),
        into: &result,
      )
      button(
        "review-back",
        title: l10n("Back"),
        rect: Rect(x: x + width / 2, y: bottom - 1, width: width / 2, height: 1),
        into: &result,
      )
    } else {
      // Register the editor first so typing resumes in the summary after an inline draft.
      let count = min(review.comments.count, geometry.reviewCommentCapacity)
      editor(
        "review-body",
        value: review.body,
        rect: Rect(x: x, y: 8, width: width, height: max(1, bottom - 12 - count)),
        into: &result,
      )
      if review.item.kind == .pullRequest {
        let cell = width / 3
        for (index, event) in ReviewEvent.allCases.enumerated() {
          button(
            "event:" + event.rawValue,
            title: "\(review.event == event ? (ascii ? "*" : "●") : (ascii ? "o" : "○")) \(l10n(Self.eventTitle(event)))",
            rect: Rect(x: x + index * cell, y: 6, width: cell, height: 1),
            into: &result,
          )
        }
      }
      if review.comments.count > count {
        button(
          "comments-previous",
          title: ascii ? "<" : "↑",
          rect: Rect(x: x + width - 20, y: bottom, width: 8, height: 1),
          into: &result,
        )
        button(
          "comments-next",
          title: ascii ? ">" : "↓",
          rect: Rect(x: x + width - 10, y: bottom, width: 8, height: 1),
          into: &result,
        )
      }
      for (visibleIndex, comment) in review.comments.dropFirst(min(commentScroll, max(0, review.comments.count - count)))
        .prefix(count).enumerated()
      {
        let index = min(commentScroll, max(0, review.comments.count - count)) + visibleIndex
        let identity = review.commentIdentities[index]
        let y = bottom - 3 - count + visibleIndex
        button(
          "draft-open:\(identity)",
          title: compactFileName(Self.anchor(comment), width: max(1, width - 28)),
          rect: Rect(x: x, y: y, width: max(1, width - 28), height: 1),
          into: &result,
        )
        button(
          "draft-edit:\(identity)",
          title: l10n("Edit"),
          rect: Rect(x: x + width - 27, y: y, width: 11, height: 1),
          into: &result,
        )
        button(
          "remove:\(identity)",
          title: l10n("Remove"),
          rect: Rect(x: x + width - 15, y: y, width: 15, height: 1),
          into: &result,
        )
      }
      button("review-preview", title: l10n("Preview"), rect: Rect(x: x, y: bottom - 2, width: width, height: 1), into: &result)
      result.text(
        "Esc · \(l10n("Back")) · \(l10n("Your draft stays here until you quit."))",
        in: Rect(x: x, y: bottom, width: review.comments.count > count ? width - 22 : width, height: 1),
        color: palette.muted,
      )
    }
  }
}
