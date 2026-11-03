// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import CoreText
import Foundation
import SwiftTerm

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
