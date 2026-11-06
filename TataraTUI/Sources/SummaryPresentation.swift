// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TataraCore
import TermLoom

extension WorkspacePresentation {
  func summary(into result: inout TerminalScreen) {
    let rect = geometry.items
    let item = store.detail?.item ?? store.selectedItem
    let info = item?.github
    let updated = info?.updatedAt.map { value in
      let timestamp = value.hasSuffix("Z")
        ? String(value.prefix(16)).replacing("T", with: " ") + "Z"
        : String(value.prefix(25))
      return l10n("Updated") + " " + timestamp
    }
    pane(
      rect,
      title: l10n(store.kind == .pullRequest ? "Current pull request" : "Current issue") + " · " + key(.pickItem),
      selected: false,
      trailing: rect.width >= 40 ? updated : nil,
      into: &result,
    )
    guard let item else { return }
    let width = max(1, rect.width - 4)
    var y = rect.y + 1
    func span(_ value: String, _ color: Color, bold: Bool = false) -> Span {
      Span(TerminalText.sanitize(value), style: Style(foreground: color, modifiers: bold ? .bold : []))
    }
    func row(_ spans: [Span]) {
      guard y < rect.bottom - 1 else { return }
      result.operations.append(.text(Rect(x: rect.x + 2, y: y, width: width, height: 1), Text([Line(spans)])))
      y += 1
    }
    func count(_ value: Int?) -> String {
      value.map(String.init) ?? (ascii ? "-" : "–")
    }
    func names(_ values: [String], prefix: String = "") -> String {
      let shown = values.prefix(2).map { prefix + $0 }.joined(separator: ", ")
      return shown + (values.count > 2 ? " +\(values.count - 2)" : "")
    }
    row([span("#\(item.id.number) \(item.title)", palette.text, bold: true)])
    let state = item.isDraft ? "Draft" : item.state == .open ? "Open" : item.state == .merged ? "Merged" : "Closed"
    let stateColor = item.isDraft || item.state == .merged ? palette.mauve : item.state == .open ? palette.green : palette.red
    row([span("@\(item.author) · ", palette.muted), span(l10n(state), stateColor, bold: true)])
    if item.kind == .pullRequest {
      let reviewColor = info?.reviewDecision == .approved
        ? palette.green
        : info?.reviewDecision == .changesRequested
          ? palette.red
          : info?.reviewDecision == .reviewRequired ? palette.yellow : palette.muted
      let checksColor = info?.checksState == .success
        ? palette.green
        : info?.checksState == .failure || info?.checksState == .error
          ? palette.red
          : info?.checksState == .pending || info?.checksState == .expected ? palette.yellow : palette.muted
      let review = info?.reviewDecision == nil
        ? l10n("Review") + ": " + l10n("Not reported")
        : l10n(info?.reviewTitleKey ?? "Not reported")
      row([
        span(review, reviewColor),
        span(" · ", palette.muted),
        span("CI " + l10n(info?.checksTitleKey ?? "Not reported"), checksColor),
      ])
      if let head = info?.headBranch {
        let base = info?.baseBranch ?? (ascii ? "?" : "–")
        let separator = ascii ? " -> " : " → "
        let baseWidth = min(max(1, width / 3), TerminalWidth.of(base))
        let branch = compactFileName(head, width: max(1, width - baseWidth - TerminalWidth.of(separator)))
          + separator + compactFileName(base, width: baseWidth)
        row([span(branch, palette.blue)])
      } else {
        row([span(store.isLoadingDetail ? loadingLabel("Loading details…") : l10n("Not reported"), palette.muted)])
      }
    }
    let hasDetail = store.detail != nil && !store.isLoadingDetail
    let files = hasDetail ? store.detail?.files.count : info?.changedFiles
    let comments = hasDetail ? store.detail?.comments.count : info?.commentCount
    let pending = store.drafts[item.id]?.comments.count ?? 0
    let totals = (item.kind == .pullRequest ? l10n("Files") + " " + count(files) + " · " : "")
      + l10n("Comments") + " " + count(comments)
      + (pending > 0 ? " · " + l10n("Pending") + " \(pending)" : "")
    row([span(totals, palette.subtext0)])
    if item.kind == .pullRequest {
      var changes = [Span]()
      if let additions = info?.additions {
        changes.append(span("+\(additions)", palette.green))
      }
      if let deletions = info?.deletions {
        changes.append(span(" " + (ascii ? "-" : "−") + "\(deletions)", palette.red))
      }
      if !changes.isEmpty {
        changes.append(span(" · ", palette.muted))
      }
      changes.append(span(l10n("Commits") + " " + count(info?.commits), palette.subtext0))
      row(changes)
    }
    if let info {
      if !info.requestedReviewers.isEmpty || !info.requestedTeams.isEmpty {
        let people = names(info.requestedReviewers, prefix: "@")
        let teams = names(info.requestedTeams)
        let reviewers = people + (!people.isEmpty && !teams.isEmpty ? " · " : "") + teams
        row([span(l10n("Requested reviewers") + " " + reviewers, palette.lavender)])
      }
      if !info.assignees.isEmpty {
        row([span(l10n("Assignees") + " " + names(info.assignees, prefix: "@"), palette.subtext0)])
      }
    }
    if !item.labels.isEmpty {
      row([span(l10n("Labels") + " " + names(item.labels), palette.mauve)])
    }
    if let milestone = info?.milestone {
      row([span(l10n("Milestone") + " " + milestone, palette.peach)])
    }
  }
}
