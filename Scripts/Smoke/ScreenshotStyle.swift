// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import CoreText
import Foundation
import SwiftTerm

// MARK: - ScreenshotStyle

struct ScreenshotStyle: Decodable {

  // MARK: Internal

  var fonts: [String] = ["Menlo-Regular", "Menlo-Bold", "Menlo-Italic", "Menlo-BoldItalic"]
  var fontSize: Double = 14
  var extraLineHeight: Double = 4
  var scale: Double = 1
  var fontFeatures = [String]()
  var foreground: String?
  var background: String?
  var ansiPalette: [String]?

  static func load() throws -> Self {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: "--screenshot-style") else { return Self() }
    try expect(args.indices.contains(index + 1), "Missing screenshot style path.")
    let style = try JSONDecoder().decode(Self.self, from: Data(contentsOf: URL(fileURLWithPath: args[index + 1])))
    try expect(style.fonts.count == 4, "Screenshot style needs regular, bold, italic and bold-italic fonts.")
    try expect(style.fontSize > 0 && style.extraLineHeight >= 0, "Invalid screenshot font metrics.")
    try expect(style.scale.isFinite && style.scale > 0, "Invalid screenshot scale.")
    if let palette = style.ansiPalette {
      try expect(palette.count == 16, "Screenshot style needs exactly 16 ANSI colors.")
    }
    return style
  }

  func font(bold: Bool = false, italic: Bool = false) throws -> NSFont {
    let name = fonts[(bold ? 1 : 0) + (italic ? 2 : 0)]
    let features = fontFeatures.map { [
      kCTFontOpenTypeFeatureTag as String: $0,
      kCTFontOpenTypeFeatureValue as String: 1,
    ] as [String: Any] }
    let descriptor = NSFontDescriptor(fontAttributes: [.name: name, .featureSettings: features])
    guard let font = NSFont(descriptor: descriptor, size: fontSize), font.fontName == name else {
      throw SmokeError("Missing screenshot font: \(name). Install the font named in the style profile.")
    }
    return font
  }

  func color(_ value: Attribute.Color, terminal: Terminal, background isBackground: Bool = false) throws -> NSColor {
    switch value {
    case .trueColor(let red, let green, let blue):
      return NSColor(srgbRed: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255, alpha: 1)

    case .defaultColor,
         .defaultInvertedColor:
      let usesForeground = (value == .defaultInvertedColor) == isBackground
      if let hex = usesForeground ? foreground : background {
        return try color(hex)
      }
      return color(usesForeground ? terminal.foregroundColor : terminal.backgroundColor)

    case .ansi256(let index):
      if let ansiPalette, Int(index) < ansiPalette.count {
        return try color(ansiPalette[Int(index)])
      }
      guard let entry = terminal.paletteColor(index: Int(index)) else {
        throw SmokeError("Unexpected ANSI palette index: \(index)")
      }
      return color(entry)
    }
  }

  // MARK: Private

  private func color(_ value: SwiftTerm.Color) -> NSColor {
    NSColor(srgbRed: Double(value.red) / 65535, green: Double(value.green) / 65535, blue: Double(value.blue) / 65535, alpha: 1)
  }

  private func color(_ hex: String) throws -> NSColor {
    let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    guard digits.count == 6, let value = UInt32(digits, radix: 16) else {
      throw SmokeError("Invalid screenshot color: \(hex)")
    }
    return NSColor(
      srgbRed: Double((value >> 16) & 255) / 255,
      green: Double((value >> 8) & 255) / 255,
      blue: Double(value & 255) / 255,
      alpha: 1,
    )
  }

}

// MARK: - ScreenshotCellGraphic

/// Terminal graphics occupy the entire cell, independently of the text baseline.
enum ScreenshotCellGraphic {
  static let characters = Set("─│┌┐└┘├┤┬┴┼╭╮╰╯█▀▄▌▐")

  static func draw(_ character: Character, in frame: CGRect, context: CGContext, scale: Double, color: NSColor) {
    precondition(characters.contains(character), "Unsupported screenshot cell graphic.")
    func snap(_ value: Double) -> Double {
      (value * scale).rounded() / scale
    }
    let rect = CGRect(
      x: snap(frame.minX),
      y: snap(frame.minY),
      width: snap(frame.maxX) - snap(frame.minX),
      height: snap(frame.maxY) - snap(frame.minY),
    )
    let center = CGPoint(x: snap(frame.midX), y: snap(frame.midY))
    context.saveGState()
    defer { context.restoreGState() }
    context.setFillColor(color.cgColor)
    context.setStrokeColor(color.cgColor)
    context.setShouldAntialias(false)
    switch character {
    case "█": context.fill(rect)
      return

    case "▀": context.fill(CGRect(x: rect.minX, y: center.y, width: rect.width, height: rect.maxY - center.y))
      return

    case "▄": context.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: center.y - rect.minY))
      return

    case "▌": context.fill(CGRect(x: rect.minX, y: rect.minY, width: center.x - rect.minX, height: rect.height))
      return

    case "▐": context.fill(CGRect(x: center.x, y: rect.minY, width: rect.maxX - center.x, height: rect.height))
      return

    default: break
    }
    let path = CGMutablePath()
    let up = CGPoint(x: center.x, y: rect.maxY)
    let down = CGPoint(x: center.x, y: rect.minY)
    let left = CGPoint(x: rect.minX, y: center.y)
    let right = CGPoint(x: rect.maxX, y: center.y)
    if "╭╮╰╯".contains(character) {
      let start = "╭╮".contains(character) ? down : up
      let end = "╭╰".contains(character) ? right : left
      path.move(to: start)
      path.addArc(tangent1End: center, tangent2End: end, radius: min(rect.width, rect.height) / 2)
      path.addLine(to: end)
      context.setShouldAntialias(true)
    } else {
      let ends: [CGPoint]
      switch character {
      case "─": ends = [left, right]
      case "│": ends = [down, up]
      case "┌": ends = [down, right]
      case "┐": ends = [down, left]
      case "└": ends = [up, right]
      case "┘": ends = [up, left]
      case "├": ends = [up, down, right]
      case "┤": ends = [up, down, left]
      case "┬": ends = [left, right, down]
      case "┴": ends = [left, right, up]
      case "┼": ends = [left, right, up, down]
      default: preconditionFailure("Unsupported screenshot border.")
      }
      for end in ends { path.move(to: center)
        path.addLine(to: end)
      }
    }
    context.addPath(path)
    context.setLineWidth(max(1, scale.rounded()) / scale)
    context.setLineCap(.butt)
    context.setLineJoin(.round)
    context.strokePath()
  }
}

extension ScreenshotStyle {
  /// Inspect the rendered PNG, independently of the glyph paths, for missing border pixels.
  func verifyBorders(in bitmap: NSBitmapImageRep, text: String) throws {
    let rows = text.components(separatedBy: "\n").map(Array.init)
    var vertical = 0 ..< 0
    var start: Int?
    for row in 0 ... rows.count {
      let connects = row < rows.count && rows[row].first == "│"
      if connects, start == nil {
        start = row
      }
      if !connects, let first = start {
        if row - first > vertical.count {
          vertical = first ..< row
        }
        start = nil
      }
    }
    var horizontal = (row: 0, start: 0, end: 0)
    for (row, characters) in rows.enumerated() {
      var start: Int?
      for column in 0 ... characters.count {
        let connects = column < characters.count && characters[column] == "─"
        if connects, start == nil {
          start = column
        }
        if !connects, let first = start {
          if column - first > horizontal.end - horizontal.start {
            horizontal = (row, first, column)
          }
          start = nil
        }
      }
    }
    try expect(vertical.count > 1 && horizontal.end - horizontal.start > 1, "Missing connected screenshot borders.")
    guard let background = bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB) else {
      throw SmokeError("Could not inspect screenshot background.")
    }
    func ink(_ x: Int, _ y: Int) throws -> Bool {
      guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
        throw SmokeError("Could not inspect screenshot pixel.")
      }
      return abs(color.redComponent - background.redComponent) + abs(color.greenComponent - background.greenComponent)
        + abs(color.blueComponent - background.blueComponent) > 0.04
    }
    let padding = 16.0
    let cellWidth = ("M" as NSString).size(withAttributes: [.font: try font()]).width
    let cellHeight = (Double(bitmap.pixelsHigh) / scale - padding * 2) / Double(rows.count)
    let x = Int(((padding + cellWidth / 2) * scale).rounded())
    let top = Int((padding + Double(vertical.lowerBound) * cellHeight) * scale)
    let bottom = Int((padding + Double(vertical.upperBound) * cellHeight) * scale)
    let verticalGaps = try ((top - 1) ... bottom).count { y in try !(x - 1 ... x + 1).contains { try ink($0, y) } }
    let left = Int(((padding + Double(horizontal.start) * cellWidth) * scale).rounded())
    let right = Int(((padding + Double(horizontal.end) * cellWidth) * scale).rounded())
    let rowTop = Int((padding + Double(horizontal.row) * cellHeight) * scale)
    let rowBottom = Int((padding + Double(horizontal.row + 1) * cellHeight) * scale)
    // One-pixel strokes may occupy either neighboring pixel after raster rounding.
    // Require a continuous scanline within the source border row, independently of that phase.
    var horizontalGaps = right - left + 2
    for y in rowTop ..< rowBottom {
      let gaps = try ((left - 1) ... right).count { x in try !ink(x, y) }
      horizontalGaps = min(horizontalGaps, gaps)
    }
    try expect(
      verticalGaps == 0 && horizontalGaps == 0,
      "Screenshot borders contain gaps: vertical=\(verticalGaps), horizontal=\(horizontalGaps).",
    )
    print("Screenshot border pixels: vertical \(bottom - top), horizontal \(right - left); no gaps, including corner joins.")
  }
}
