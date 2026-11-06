// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import Foundation
import TataraKit
import TermLoom

/// Immutable pixel sprites; frame selection never mutates workspace or source state.
enum ForgeLoading {

  // MARK: Internal

  enum Ink: Int, Sendable {
    case shadow
    case steel
    case edge
    case wood
    case head
    case heat
    case spark

    func color(_ palette: Palette) -> Color {
      switch self {
      case .shadow: palette.surface2
      case .steel: palette.overlay1
      case .edge: palette.subtext0
      case .wood: palette.peach
      case .head: palette.text
      case .heat: palette.yellow
      case .spark: palette.rosewater
      }
    }
  }

  struct Point: Sendable {
    let x: Double
    let y: Double
  }

  struct Glyph: Sendable {
    let text: String
    let monochrome: String
    let ascii: String
    let foreground: Ink?
    let background: Ink?
  }

  struct Canvas: Sendable {

    // MARK: Lifecycle

    init(width: Int, height: Int) {
      self.width = width
      self.height = height
      pixels = Array(repeating: nil, count: width * height)
    }

    // MARK: Internal

    let width: Int
    let height: Int
    var pixels: [Ink?]

    subscript(_ x: Int, _ y: Int) -> Ink? {
      get { (0 ..< width).contains(x) && (0 ..< height).contains(y) ? pixels[y * width + x] : nil }
      set {
        if (0 ..< width).contains(x), (0 ..< height).contains(y) {
          pixels[y * width + x] = newValue
        }
      }
    }

    mutating func rectangle(_ x: Int, _ y: Int, _ width: Int, _ height: Int, _ ink: Ink, clipped: Bool = false) {
      for row in y ..< y + height {
        for column in x ..< x + width where !clipped || self[column, row] != nil {
          self[column, row] = ink
        }
      }
    }

    mutating func line(from start: Point, to end: Point, ink: Ink, thickness: Int = 1) {
      let steps = max(1, Int(ceil(max(abs(end.x - start.x), abs(end.y - start.y)) * 2)))
      for step in 0 ... steps {
        let fraction = Double(step) / Double(steps)
        let x = Int((start.x + (end.x - start.x) * fraction).rounded())
        let y = Int((start.y + (end.y - start.y) * fraction).rounded())
        rectangle(x, y, thickness, thickness, ink)
      }
    }

    mutating func polygon(_ vertices: [Point], ink: Ink) {
      for y in 0 ..< height {
        for x in 0 ..< width {
          let point = Point(x: Double(x) + 0.5, y: Double(y) + 0.5)
          var inside = false
          var previous = vertices.last!
          for current in vertices {
            if
              (current.y > point.y) != (previous.y > point.y),
              point.x < (previous.x - current.x) * (point.y - current.y) / (previous.y - current.y) + current.x
            {
              inside.toggle()
            }
            previous = current
          }
          if inside {
            self[x, y] = ink
          }
        }
      }
    }

  }

  static let frameDuration = 0.15
  static let angles: [Double] = [-140, -140, -158, -177, -181, -181, -162, -148]
  static let frameCount = angles.count
  static let width = 34
  static let height = 14
  static let compactWidth = 18
  static let compactHeight = 7
  static let largeFrames = angles.indices.map { halfBlocks(largeCanvas(frame: $0)) }
  static let compactFrames = angles.indices.map { halfBlocks(compactCanvas(frame: $0)) }

  static func frame(elapsed: Double) -> Int {
    Int(max(0, elapsed).truncatingRemainder(dividingBy: frameDuration * Double(frameCount)) / frameDuration)
  }

  @MainActor
  static func isActive(_ store: StoreOf<WorkspaceFeature>) -> Bool {
    guard store.error == nil else { return false }
    return store.isLoading || store.isLoadingDetail || store.isLoadingDiff || store.isPreparingDocument
      || store.isFinding || store.fileSearch?.isLoading == true || store.listSearchPending != nil || store.picker?
      .isLoading == true
      || store.filterEditor?.isLoadingLabels == true || store.filterEditor?.isSaving == true
      || store.commentEditor?.isLoading == true || store.commentEditor?.isPreparing == true
  }

  static func badge(frame: Int, ascii: Bool) -> String {
    let phase = frame % frameCount
    if phase == 4 || phase == 5 {
      return ascii ? "*_" : "✧━"
    }
    return phase == 3 || phase == 6 ? (ascii ? "T_" : "┬━") : (ascii ? "/_" : "╲━")
  }

  static func draw(
    in rect: Rect,
    message: String,
    frame: Int,
    ascii: Bool,
    palette: Palette,
    brand: Bool = false,
    into screen: inout TerminalScreen,
  ) {
    let titleHeight = brand ? 2 : 0
    let totalHeight = height + 2 + titleHeight
    guard rect.width >= width, rect.height >= totalHeight else {
      let label = badge(frame: frame, ascii: ascii) + " " + message
      screen.text(label, in: Rect(
        x: rect.x + max(0, (rect.width - TerminalWidth.of(label)) / 2),
        y: rect.y + rect.height / 2,
        width: rect.width,
        height: 1,
      ), color: palette.peach)
      return
    }
    let x = rect.x + (rect.width - width) / 2
    let top = rect.y + (rect.height - totalHeight) / 2
    if brand {
      screen.text("t a t a r a", in: Rect(x: x + (width - 11) / 2, y: top, width: 11, height: 1), color: palette.text, bold: true)
    }
    paint(largeFrames[frame % frameCount], at: .init(x: x, y: top + titleHeight), ascii: ascii, palette: palette, into: &screen)
    screen.text(
      message,
      in: Rect(
        x: rect.x + max(0, (rect.width - TerminalWidth.of(message)) / 2),
        y: top + titleHeight + height + 1,
        width: min(rect.width, TerminalWidth.of(message)),
        height: 1,
      ),
      color: palette.muted,
    )
  }

  static func drawCompact(in rect: Rect, frame: Int, ascii: Bool, palette: Palette, into screen: inout TerminalScreen) {
    paint(compactFrames[frame % frameCount], at: .init(x: rect.x, y: rect.y), ascii: ascii, palette: palette, into: &screen)
  }

  // MARK: Private

  private static func paint(
    _ rows: [[Glyph]],
    at origin: Position,
    ascii: Bool,
    palette: Palette,
    into screen: inout TerminalScreen,
  ) {
    for (y, row) in rows.enumerated() {
      let spans = row.map { glyph in
        Span(
          ascii ? glyph.ascii : palette.noColor ? glyph.monochrome : glyph.text,
          style: Style(
            foreground: glyph.foreground?.color(palette) ?? .reset,
            background: ascii || palette.noColor ? .reset : glyph.background?.color(palette) ?? .reset,
          ),
        )
      }
      screen.operations.append(.text(Rect(x: origin.x, y: origin.y + y, width: row.count, height: 1), Text([Line(spans)])))
    }
  }

  private static func largeCanvas(frame: Int) -> Canvas {
    var canvas = Canvas(width: width, height: height * 2)
    canvas.polygon(
      [
        (1, 18),
        (8, 16),
        (9, 15),
        (29, 15),
        (31, 17),
        (28, 20),
        (22, 21),
        (22, 23),
        (27, 24),
        (28, 27),
        (9, 27),
        (10, 25),
        (15, 23),
        (14, 21),
        (8, 21),
        (5, 20),
      ]
      .map { Point(x: Double($0.0), y: Double($0.1)) },
      ink: .steel,
    )
    canvas.rectangle(8, 15, 23, 1, .edge, clipped: true)
    canvas.rectangle(3, 19, 27, 1, .shadow, clipped: true)
    canvas.rectangle(16, 21, 6, 3, .shadow, clipped: true)
    canvas.rectangle(10, 25, 17, 1, .edge, clipped: true)
    canvas.rectangle(9, 26, 20, 1, .shadow, clipped: true)
    canvas.rectangle(13, 13, 8, 2, .wood)
    canvas.rectangle(14, 13, 6, 1, .heat)
    let angle = angles[frame] * .pi / 180
    let direction = Point(x: cos(angle), y: sin(angle))
    let normal = Point(x: -direction.y, y: direction.x)
    let pivot = Point(x: 26, y: 9.5)
    let head = Point(x: pivot.x + direction.x * 10, y: pivot.y + direction.y * 10)
    canvas.line(from: head, to: pivot, ink: .wood, thickness: 2)
    let corners: [(Double, Double)] = [(-3.5, -1.5), (3.5, -1.5), (3.5, 1.5), (-3.5, 1.5)]
    canvas.polygon(corners.map { along, across in
      Point(
        x: head.x + normal.x * along + direction.x * across,
        y: head.y + normal.y * along + direction.y * across,
      )
    }, ink: .head)
    if frame == 4 || frame == 5 {
      let points = frame == 4 ? [(11, 11), (13, 9), (22, 10), (24, 13)] : [(8, 9), (12, 6), (25, 7), (28, 12)]
      for (x, y) in points {
        canvas[x, y] = .spark
        if frame == 4 {
          canvas[x, y + 1] = .heat
        }
      }
    }
    return canvas
  }

  private static func compactCanvas(frame: Int) -> Canvas {
    var canvas = Canvas(width: compactWidth, height: compactHeight * 2)
    canvas.polygon(
      [
        (1, 9),
        (4, 8),
        (5, 7.5),
        (14.5, 7.5),
        (15.5, 8.5),
        (14, 10),
        (11, 10.5),
        (11, 11.5),
        (13.5, 12),
        (14, 13.5),
        (4.5, 13.5),
        (5, 12.5),
        (7.5, 11.5),
        (7, 10.5),
        (4, 10.5),
        (2.5, 10),
      ]
      .map { Point(x: $0.0, y: $0.1) },
      ink: .steel,
    )
    canvas.rectangle(5, 7, 10, 1, .edge, clipped: true)
    canvas.rectangle(2, 9, 13, 1, .shadow, clipped: true)
    canvas.rectangle(8, 10, 3, 2, .shadow, clipped: true)
    canvas.rectangle(5, 12, 8, 1, .edge, clipped: true)
    canvas.rectangle(7, 6, 4, 1, .heat)
    let angle = angles[frame] * .pi / 180
    let direction = Point(x: cos(angle), y: sin(angle))
    let normal = Point(x: -direction.y, y: direction.x)
    let pivot = Point(x: 13, y: 4.75)
    let head = Point(x: pivot.x + direction.x * 5, y: pivot.y + direction.y * 5)
    canvas.line(from: head, to: pivot, ink: .wood)
    let corners: [(Double, Double)] = [(-1.75, -0.75), (1.75, -0.75), (1.75, 0.75), (-1.75, 0.75)]
    canvas.polygon(corners.map { along, across in
      Point(
        x: head.x + normal.x * along + direction.x * across,
        y: head.y + normal.y * along + direction.y * across,
      )
    }, ink: .head)
    if frame == 4 || frame == 5 {
      canvas[frame == 4 ? 5 : 4, frame == 4 ? 5 : 3] = .spark
      canvas[frame == 4 ? 11 : 13, frame == 4 ? 5 : 3] = .heat
    }
    return canvas
  }

  private static func halfBlocks(_ canvas: Canvas) -> [[Glyph]] {
    stride(from: 0, to: canvas.height, by: 2).map { y in
      (0 ..< canvas.width).map { x in
        let top = canvas[x, y]
        let bottom = canvas[x, y + 1]
        let text = top == nil ? (bottom == nil ? " " : "▄") : bottom == nil ? "▀" : top == bottom ? "█" : "▀"
        return Glyph(
          text: text,
          monochrome: top != nil && bottom != nil ? "█" : text,
          ascii: top == nil ? (bottom == nil ? " " : "_") : bottom == nil ? "-" : "#",
          foreground: top ?? bottom,
          background: top != nil && bottom != nil && top != bottom ? bottom : nil,
        )
      }
    }
  }

}
