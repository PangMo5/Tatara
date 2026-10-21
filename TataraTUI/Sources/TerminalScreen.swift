// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TataraCore
import TermLoom
import TermLoomTextArea

/// One viewport-sized value snapshot; controls retain TermLoom interaction metadata.
struct TerminalScreen: Widget {
  enum Operation {
    case fill(Rect, Color), border(Rect, Color, Color), text(Rect, Text)
    case field(Rect, TextField), editor(Rect, TextArea), button(Rect, Button)
  }

  var ascii = false
  var cursor: Position?
  var operations: [Operation] = []

  func render(in area: Rect, into frame: inout Frame) {
    if let cursor {
      frame.placeCursor(at: cursor)
    }
    for operation in operations {
      switch operation {
      case let .fill(rect, color): frame.buffer.fill(
          rect.intersection(area),
          with: Cell(symbol: " ", style: Style(background: color)),
        )
      case let .border(rect, color, background): frame.render(
          Block(borders: ascii ? BorderSet(
            topLeft: "+",
            topRight: "+",
            bottomLeft: "+",
            bottomRight: "+",
            horizontal: "-",
            vertical: "|",
          ) : .rounded, borderStyle: Style(foreground: color, background: background)),
          in: rect.intersection(area),
        )
      case let .text(rect, text): frame.render(text, in: rect.intersection(area))
      case let .field(rect, field): frame.render(field, in: rect.intersection(area))
      case let .editor(rect, editor): frame.render(editor, in: rect.intersection(area))
      case let .button(rect, button): frame.render(button, in: rect.intersection(area))
      }
    }
  }

  mutating func text(_ value: String, in rect: Rect, color: Color = .reset, bold: Bool = false) {
    operations.append(.text(
      rect,
      Text(TerminalText.sanitize(value), style: Style(foreground: color, modifiers: bold ? .bold : [])),
    ))
  }

  mutating func scrollbar(_ rect: Rect, total: Int, page: Int, offset: Int, palette: Palette) {
    let metrics = ScrollMetrics(total: total, page: page, offset: offset, track: max(1, rect.height - 2))
    guard metrics.isScrollable else { return }
    for row in 0 ..< metrics.track {
      let thumb = (metrics.thumbStart ..< (metrics.thumbStart + metrics.thumbLength)).contains(row)
      text(
        thumb ? (ascii ? "#" : "█") : (ascii ? "|" : "│"),
        in: Rect(x: rect.right - 1, y: rect.y + 1 + row, width: 1, height: 1),
        color: thumb ? palette.overlay2 : palette.overlay0,
      )
    }
  }
}

struct WorkspaceGeometry {
  let size: Size
  var preferredSidebarWidth = Preferences.defaultSidebarWidth
  var isSelectingItems = false
  var body: Rect {
    Rect(x: 0, y: 1, width: size.width, height: max(1, size.height - 3))
  }

  var sidebarWidth: Int {
    min(
      max(24, isSelectingItems ? max(preferredSidebarWidth, size.width * 2 / 5) : preferredSidebarWidth),
      max(24, size.width - 60),
    )
  }

  var items: Rect {
    size.width >= 100 ? Rect(
      x: 0,
      y: 1,
      width: sidebarWidth,
      height: isSelectingItems ? body.height : min(8, max(5, body.height / 4)),
    ) : body
  }

  var files: Rect {
    size.width >= 100 ? Rect(x: 0, y: items.bottom, width: sidebarWidth, height: body.height - items.height) : body
  }

  var content: Rect {
    size.width >= 100 ? Rect(x: sidebarWidth, y: 1, width: size.width - sidebarWidth, height: body.height) : body
  }

  var reviewCommentCapacity: Int {
    max(1, min(size.height / 3, size.height - 16))
  }

  var popup: Rect {
    let width = min(96, max(20, size.width - 8)), height = max(8, min(26, body.height < 26 ? body.height : body.height - 4))
    return Rect(x: max(0, (size.width - width) / 2), y: max(1, 1 + (body.height - height) / 2), width: width, height: height)
  }
}
