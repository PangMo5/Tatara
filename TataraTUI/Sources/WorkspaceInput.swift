// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import TataraCore
import TataraKit
import TermLoom
import TermLoomTextArea

extension TerminalWorkspace {
  func handleMouse(_ event: MouseEvent) {
    guard let store else { return }
    let scope: WorkspaceFeature.SearchScope
    let rect: Rect
    if store.showsHelp {
      scope = .help
      rect = geometry.popup
    } else if size.width < 100 {
      rect = geometry.body
      switch store.pane { case .items: scope = .items
      case .files: scope = .files
      case .content: scope = .content }
    } else if geometry.items.contains(event.position) {
      scope = .items
      rect = geometry.items
    } else if geometry.files.contains(event.position) {
      scope = .files
      rect = geometry.files
    } else {
      scope = .content
      rect = geometry.content
    }
    guard rect.contains(event.position) else { return }
    if event.kind == .scrollUp || event.kind == .scrollDown {
      store.send(.wheelScrolled(scope, delta: event.kind == .scrollUp ? -3 : 3))
      return
    }
    guard event.kind == .down(.left) || event.kind == .drag(.left) else { return }
    let rowHeight = scope == .items ? store.itemRowHeight : 1
    let page = max(1, (rect.height - (scope == .help ? 5 : 3)) / rowHeight)
    let total: Int, offset: Int
    switch scope {
    case .items: total = store.visibleItems.count
      offset = min(max(0, total - page), max(0, store.itemsScroll))
    case .files: total = store.visibleFileRows.count
      offset = min(max(0, total - page), max(0, store.filesScroll))
    case .content: total = store.document.lines.count
      offset = store.scroll
    case .help: total = store.visibleHelp.count
      offset = store.helpScroll
    }
    if event.position.x == rect.right - 1 {
      let metrics = ScrollMetrics(total: total, page: page, offset: offset, track: rect.height - 2)
      store.send(.scrollbarMoved(scope, offset: metrics.offset(at: Double(event.position.y - rect.y - 1))))
      return
    }
    let row = offset + (event.position.y - rect.y - 2) / rowHeight
    guard event.position.y >= rect.y + 2, event.position.y < rect.bottom - 1 else { return }
    switch scope {
    case .items: if store.visibleItems.indices.contains(row) {
        store.send(.itemSelected(store.visibleItems[row].id))
      }
    case .files: if store.visibleFileRows.indices.contains(row),
                    event.kind == .down(.left)
      {
        store.send(.fileRowActivated(store.visibleFileRows[row].id))
      }
    case .content:
      let side: InlineComment.Side = rect.width - 2 < 100 ? store.diffSide : event.position.x - rect.x - 1 < store.document
        .diffSideWidth ? .left : .right
      store.send(.diffCursorSelected(row: row, side: side))
    case .help: break
    }
  }

  func handleEditor(_ event: TerminalEvent) -> ApplicationUpdate {
    guard let store else { return .ignore }
    if case let .key(key) = event, key.key == .escape {
      if store.filterEditor != nil {
        store.send(.filterEditor(.close))
      } else {
        store.send(.reviewDismissed)
      }
      fields = [:]
      editors = [:]
      editorTexts = [:]
      reviewScroll = 0
      commentScroll = 0
      previewTask?.cancel()
      reviewPreview = nil
      return .redraw
    }
    if case let .action(action) = event {
      let id = action.rawValue
      if store.filterEditor != nil {
        switch id {
        case "labels-prev": store.send(.filterEditor(.labelsScrolled(-1)))
        case "labels-next": store.send(.filterEditor(.labelsScrolled(1)))
        case "filter-labels": store.send(.filterEditor(.sectionSelected(labels: true)))
        case "filter-presets": store.send(.filterEditor(.sectionSelected(labels: false)))
        case "filter-apply": store.send(.filterEditor(.apply))
        case "filter-save": store.send(.filterEditor(.save))
        case "filter-delete": store.send(.filterEditor(.delete))
        case "filter-close": store.send(.filterEditor(.close))
        default: if id.hasPrefix("preset:") {
            store.send(.filterEditor(.presetSelected(String(id.dropFirst(7)))))
          } else if id.hasPrefix("label:") {
            store.send(.filterEditor(.labelSelected(String(id.dropFirst(6)))))
          }
        }
      } else if store.review != nil {
        switch id {
        case "comments-previous": commentScroll = max(0, commentScroll - reviewCommentCapacity)
        case "comments-next": commentScroll = min(
            max(0, (store.review?.comments.count ?? 0) - reviewCommentCapacity),
            commentScroll + reviewCommentCapacity,
          )
        case "review-preview": reviewScroll = 0
          store.send(.review(.previewButtonPressed))
          prepareReviewPreview()
        case "review-submit": store.send(.review(.submitButtonPressed))
        case "review-edit": store.send(.review(.editButtonPressed))
        case "review-add": store.send(.review(.addInlineButtonPressed))
          if store.review?.isEditingInline == false {
            editors["review-inline"] = nil
            editorTexts["review-inline"] = nil
          }
        case "review-back": store.send(.review(.cancelInlineButtonPressed))
        case "review-latest": store.send(.review(.reviewLatestRevisionButtonPressed))
        default:
          if id.hasPrefix("event:"),
             let value = ReviewEvent(rawValue: String(id.dropFirst(6)))
          {
            store.send(.review(.eventSelected(value)))
          }
          if id.hasPrefix("side:"),
             let value = InlineComment.Side(rawValue: String(id.dropFirst(5)))
          {
            store.send(.review(.inlineSideSelected(value)))
          }
          if id.hasPrefix("remove:"), let index = Int(id.dropFirst(7)) {
            store.send(.review(.removeInlineButtonPressed(index)))
          }
        }
      }
      return .redraw
    }
    if store.review?.isSubmitting == true || store.filterEditor?.isSaving == true {
      return .ignore
    }
    if store.review?.isConfirming == true || store.review?.revisionChanged == true {
      let delta: Int = switch event {
      case let .key(key):
        switch key.key { case .home: -reviewScroll
        case .end: reviewPreview?.lines.count ?? 0
        case .down: 1
        case .up: -1
        case .pageDown: 10
        case .pageUp: -10
        default: 0 }
      case let .mouse(mouse): mouse.kind == .scrollDown ? 3 : mouse.kind == .scrollUp ? -3 : 0
      default: 0
      }
      reviewScroll = min(max(0, (reviewPreview?.lines.count ?? 0) - reviewPreviewHeight), max(0, reviewScroll + delta))
      return delta == 0 ? .ignore : .redraw
    }
    if let filter = store.filterEditor, focusedControl?.rawValue.hasPrefix("preset:") == true, case let .key(key) = event,
       key.key == .up || key.key == .down
    {
      let index = filter.allPresets.firstIndex { $0.id == filter.selectedID } ?? 0
      let next = min(max(0, index + (key.key == .up ? -1 : 1)), filter.allPresets.count - 1)
      if filter.allPresets.indices.contains(next) {
        store.send(.filterEditor(.presetSelected(filter.allPresets[next].id)))
      }
      return .redraw
    }
    if let review = store.review, !review.isEditingInline {
      var delta = 0
      if case let .mouse(mouse) = event, mouse.position.y >= size.height - 7 - min(
        review.comments.count,
        reviewCommentCapacity,
      ) {
        delta = mouse.kind == .scrollDown ? 3 : mouse.kind == .scrollUp ? -3 : 0
      }
      if focusedControl?.rawValue.hasPrefix("remove:") == true, case let .key(key) = event {
        delta = key.key == .down ? 1 : key.key == .up ? -1 : 0
      }
      if delta != 0 {
        commentScroll = min(
          max(0, review.comments.count - reviewCommentCapacity),
          max(0, commentScroll + delta),
        )
        return .redraw
      }
    }
    guard let id = focusedControl?.rawValue else { return .ignore }
    let value: String? = switch id {
    case "filter-query": store.filterEditor?.query
    case "filter-name": store.filterEditor?.name
    case "inline-line": store.review?.inlineLine
    case "inline-start": store.review?.inlineStartLine
    case "review-inline": store.review?.inlineBody
    case "review-body": store.review?.body
    default: nil
    }
    guard let value else { return .ignore }
    let pointer: MouseEvent? = if case let .mouse(mouse) = event,
                                  mouse.kind == .down(.left) || mouse.kind == .drag(.left)
    {
      mouse
    } else {
      nil
    }
    let rect = pointer.flatMap { _ in body.operations.compactMap { operation -> Rect? in
      switch operation {
      case let .editor(rect, widget) where widget.id.rawValue == id: rect
      case let .field(rect, widget) where widget.id.rawValue == id: rect
      default: nil
      }
    }.first }
    let updated: String
    if id == "review-inline" || id == "review-body" {
      var editor = editorTexts[id] == value ? editors[id] ?? TextAreaState(text: value) : TextAreaState(text: value)
      let previousLines = editor.lines
      if let pointer, let rect {
        editor.ensureCursorVisible(viewport: rect.size)
        let row = min(editor.lines.count - 1, max(0, pointer.position.y - rect.y + editor.verticalOffset))
        editor.selectionAnchor = pointer.kind == .drag(.left) ? (editor.selectionAnchor ?? editor.cursor) : nil
        editor.cursor = TextPosition(
          row: row,
          column: Self.characterIndex(
            in: editor.lines[row],
            column: max(0, pointer.position.x - rect.x + editor.horizontalOffset),
          ),
        )
      } else {
        guard editor.handle(event) else { return .ignore }
      }
      editors[id] = editor
      // Cursor and selection changes retain the same line storage; only edits rebuild the draft string.
      updated = editor.lines == previousLines ? value : editor.text
      editorTexts[id] = updated
    } else {
      if id == "filter-query", case let .key(key) = event, key.key == .enter {
        store.send(.filterEditor(.apply))
        return .redraw
      }
      var field = fields[id].flatMap { $0.text == value ? $0 : nil } ?? TextFieldState(text: value)
      if let pointer, let rect {
        let cursorColumn = TerminalWidth.of(String(field.text.prefix(field.cursor)))
        if cursorColumn < field.horizontalOffset {
          field.horizontalOffset = cursorColumn
        } else if cursorColumn >= field.horizontalOffset + rect.width {
          let minimum = cursorColumn - rect.width + 1
          var boundary = 0
          for character in field.text.prefix(field.cursor) {
            if boundary >= minimum {
              break
            }
            boundary += TerminalWidth.of(character)
          }
          field.horizontalOffset = boundary
        }
        field.selectionAnchor = pointer.kind == .drag(.left) ? (field.selectionAnchor ?? field.cursor) : nil
        field.cursor = Self.characterIndex(in: field.text, column: max(0, pointer.position.x - rect.x + field.horizontalOffset))
      } else {
        guard field.handle(event) else { return .ignore }
      }
      fields[id] = field
      updated = field.text
    }
    guard updated != value else { return .redraw }
    switch id {
    case "filter-query": store.send(.filterEditor(.queryChanged(updated)))
    case "filter-name": store.send(.filterEditor(.nameChanged(updated)))
    case "inline-line": store.send(.review(.inlineLineChanged(updated)))
    case "inline-start": store.send(.review(.inlineStartLineChanged(updated)))
    case "review-inline": store.send(.review(.inlineBodyChanged(updated)))
    case "review-body": store.send(.review(.bodyChanged(updated)))
    default: break
    }
    return .redraw
  }

  static func characterIndex(in text: String, column: Int) -> Int {
    var width = 0, index = 0
    for character in text {
      let next = width + TerminalWidth.of(character)
      if next > column {
        break
      }
      width = next
      index += 1
    }
    return index
  }
}
