// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import TataraCore
import TataraKit
import TermLoom
import TermLoomTextArea

extension TerminalWorkspace {
  static func characterIndex(in text: String, column: Int) -> Int {
    var width = 0
    var index = 0
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

  func handleMouse(_ event: MouseEvent) {
    guard let store else { return }
    if let picker = store.picker {
      let rect = geometry.popup
      if
        event.kind == .down(.left),
        rect.contains(event.position),
        event.position.y >= rect.y + 5,
        event.position.y < rect.bottom - 3
      {
        let count = max(1, rect.height - 8)
        let start = max(0, picker.selection - count + 1)
        store.send(.pickerRowActivated(start + event.position.y - rect.y - 5))
        updateViewport()
      }
      return
    }
    if !store.isSelectingItems, geometry.items.contains(event.position), event.kind == .down(.left) {
      store.send(.commandPressed(.pickItem))
      return
    }
    if event.kind == .scrollLeft || event.kind == .scrollRight {
      store.send(.horizontalScrolled(event.kind == .scrollLeft ? -6 : 6))
      return
    }
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
    if scope == .content, event.kind == .down(.left), event.position.y == rect.y + 1 {
      let localization = Localization(language: store.preferences.language)
      var x = rect.x + 1
      for tab in WorkspaceFeature.ContentTab.allCases {
        let width = TerminalWidth.of(localization(WorkspacePresentation.tabTitle(tab))) + 3
        if event.position.x >= x, event.position.x < x + width {
          store.send(.tabSelected(tab))
          return
        }
        x += width
      }
      return
    }
    if event.kind == .scrollUp || event.kind == .scrollDown {
      store.send(.wheelScrolled(scope, delta: event.kind == .scrollUp ? -3 : 3))
      return
    }
    guard event.kind == .down(.left) || event.kind == .drag(.left) else { return }
    let rowHeight = scope == .items ? store.itemRowHeight : 1
    let page = max(1, (rect.height - (scope == .help ? 5 : 3)) / rowHeight)
    let total: Int
    let offset: Int
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

    case .files: if
      store.visibleFileRows.indices.contains(row),
      event.kind == .down(.left) {
        store.send(.fileRowActivated(store.visibleFileRows[row].id))
      }

    case .content:
      let side: InlineComment.Side = store.document.isUnifiedDiff
        ? store.document.sourceSide(at: row, preferred: store.diffSide) ?? store.diffSide
        : event.position.x - rect.x - 1 < store
          .document
          .diffSideWidth ? .left : .right
      store.send(.diffCursorSelected(row: row, side: side))

    case .help: break
    }
  }

  func handleEditor(_ event: TerminalEvent) -> ApplicationUpdate {
    guard let store else { return .ignore }
    if case .key(let key) = event, key.key == .escape {
      if store.commentEditor != nil {
        store.send(.commentEditor(.close))
      } else if store.filterEditor != nil {
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
    if case .action(let action) = event {
      let id = action.rawValue
      if store.commentEditor != nil {
        if id == "comment-preview" {
          store.send(.commentEditor(.previewPressed(width: geometry.popup.width - 4)))
        } else if id == "comment-confirm" {
          store.send(.commentEditor(.confirmPressed))
        } else if id == "comment-back" {
          store.send(.commentEditor(.editPressed))
        } else if id == "comment-close" {
          store.send(.commentEditor(.close))
        } else if id.hasPrefix("comment-op:"), let operation = CommentOperation(rawValue: String(id.dropFirst(11))) {
          store.send(.commentEditor(.operationSelected(operation)))
          editors["comment-body"] = nil
          editorTexts["comment-body"] = nil
        } else if
          id.hasPrefix("reaction:"),
          let reaction = ReactionContent(rawValue: String(id.dropFirst(9)))
        {
          store.send(.commentEditor(.reactionSelected(reaction)))
        }
        return .redraw
      }
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
          if
            id.hasPrefix("event:"),
            let value = ReviewEvent(rawValue: String(id.dropFirst(6)))
          {
            store.send(.review(.eventSelected(value)))
          }
          if
            id.hasPrefix("side:"),
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
      let delta: Int =
        switch event {
        case .key(let key):
          switch key.key { case .home: -reviewScroll
          case .end: reviewPreview?.lines.count ?? 0
          case .down: 1
          case .up: -1
          case .pageDown: 10
          case .pageUp: -10
          default: 0 }

        case .mouse(let mouse): mouse.kind == .scrollDown ? 3 : mouse.kind == .scrollUp ? -3 : 0

        default: 0
        }
      reviewScroll = min(max(0, (reviewPreview?.lines.count ?? 0) - reviewPreviewHeight), max(0, reviewScroll + delta))
      return delta == 0 ? .ignore : .redraw
    }
    if
      let filter = store.filterEditor,
      focusedControl?.rawValue.hasPrefix("preset:") == true,
      case .key(let key) = event,
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
      if case .mouse(let mouse) = event, mouse.position.y >= size.height - 7 - min(
        review.comments.count,
        reviewCommentCapacity,
      ) {
        delta = mouse.kind == .scrollDown ? 3 : mouse.kind == .scrollUp ? -3 : 0
      }
      if focusedControl?.rawValue.hasPrefix("remove:") == true, case .key(let key) = event {
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
    if let comment = store.commentEditor, comment.isConfirming {
      if
        case .key(let key) = event,
        key.modifiers.contains(.control),
        key.key == .character("f") || key.key == .character("b")
      {
        store.send(.commentEditor(.previewScrolled(key.key == .character("f")
            ? max(1, geometry.popup.height - 11)
            : -max(
              1,
              geometry.popup.height - 11,
            ))))
        return .redraw
      }
      if case .mouse(let mouse) = event, mouse.kind == .scrollDown || mouse.kind == .scrollUp {
        store.send(.commentEditor(.previewScrolled(mouse.kind == .scrollDown ? 3 : -3)))
        return .redraw
      }
    }
    guard let id = focusedControl?.rawValue else { return .ignore }
    let value: String? =
      switch id {
      case "filter-query": store.filterEditor?.query
      case "filter-name": store.filterEditor?.name
      case "inline-line": store.review?.inlineLine
      case "inline-start": store.review?.inlineStartLine
      case "review-inline": store.review?.inlineBody
      case "review-body": store.review?.body
      case "comment-body": store.commentEditor?.body
      default: nil
      }
    guard let value else { return .ignore }
    let pointer: MouseEvent? =
      if
        case .mouse(let mouse) = event,
        mouse.kind == .down(.left) || mouse.kind == .drag(.left)
      {
        mouse
      } else {
        nil
      }
    let rect = pointer.flatMap { _ in body.operations.compactMap { operation -> Rect? in
      switch operation {
      case .editor(let rect, let widget) where widget.id.rawValue == id: rect
      case .field(let rect, let widget) where widget.id.rawValue == id: rect
      default: nil
      }
    }.first }
    let updated: String
    if id == "review-inline" || id == "review-body" || id == "comment-body" {
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
      if id == "filter-query", case .key(let key) = event, key.key == .enter {
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
        field.cursor = Self.characterIndex(
          in: field.text,
          column: max(0, pointer.position.x - rect.x + field.horizontalOffset),
        )
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
    case "comment-body": store.send(.commentEditor(.bodyChanged(updated)))
    default: break
    }
    return .redraw
  }
}
