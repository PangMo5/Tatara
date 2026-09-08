// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import SwiftTUI
import TataraCore

struct Palette {
  var base: Color
  var mantle: Color
  var surface: Color
  var text: Color
  var muted: Color
  var accent: Color
  var red: Color
  var green: Color
  var yellow: Color
  var blue: Color
  var mauve: Color
  var teal: Color
  var rosewater: Color

  init(_ theme: TataraCore.Theme) {
    let values: [UInt32] = switch theme {
    case .latte: [
        0xEFF1F5,
        0xE6E9EF,
        0xCCD0DA,
        0x4C4F69,
        0x6C6F85,
        0x8839EF,
        0xD20F39,
        0x40A02B,
        0xDF8E1D,
        0x1E66F5,
        0x8839EF,
        0x179299,
        0xDC8A78,
      ]
    case .frappe: [
        0x303446,
        0x292C3C,
        0x414559,
        0xC6D0F5,
        0xA5ADCE,
        0xCA9EE6,
        0xE78284,
        0xA6D189,
        0xE5C890,
        0x8CAAEE,
        0xCA9EE6,
        0x81C8BE,
        0xF2D5CF,
      ]
    case .macchiato: [
        0x24273A,
        0x1E2030,
        0x363A4F,
        0xCAD3F5,
        0xA5ADCB,
        0xC6A0F6,
        0xED8796,
        0xA6DA95,
        0xEED49F,
        0x8AADF4,
        0xC6A0F6,
        0x8BD5CA,
        0xF4DBD6,
      ]
    case .mocha: [
        0x1E1E2E,
        0x181825,
        0x313244,
        0xCDD6F4,
        0xA6ADC8,
        0xCBA6F7,
        0xF38BA8,
        0xA6E3A1,
        0xF9E2AF,
        0x89B4FA,
        0xCBA6F7,
        0x94E2D5,
        0xF5E0DC,
      ]
    }
    let colors = values.map { Color(
      red: Double(($0 >> 16) & 255) / 255,
      green: Double(($0 >> 8) & 255) / 255,
      blue: Double($0 & 255) / 255,
    ) }
    base = colors[0]
    mantle = colors[1]
    surface = colors[2]
    text = colors[3]
    muted = colors[4]
    accent = colors[5]
    red = colors[6]
    green = colors[7]
    yellow = colors[8]
    blue = colors[9]
    mauve = colors[10]
    teal = colors[11]
    rosewater = colors[12]
  }

  func ansi(_ index: Int?) -> Color {
    guard let index else { return text }
    return [muted, red, green, yellow, blue, mauve, teal, text][index % 8]
  }

  @MainActor
  func viewport(
    _ lines: [[DiffSpan]],
    offset: Int,
    count: Int,
    matches: Set<Int>,
    selectedRows: Set<Int> = [],
    selectedSide: InlineComment.Side = .right,
  ) -> Text {
    var content = Text.StringInterpolation(literalCapacity: 0, interpolationCount: count)
    for (row, spans) in lines.dropFirst(offset).prefix(count).enumerated() {
      if row > 0 {
        content.appendLiteral("\n")
      }
      let highlighted = matches.contains(offset + row)
      for span in spans {
        var fragment = Text(span.text).foregroundStyle(ansi(span.color)).bold(span.bold || highlighted).underline(highlighted)
        if selectedRows.contains(row), span.side == selectedSide {
          fragment = fragment.cellBackground(surface)
        }
        content.appendInterpolation(fragment)
      }
    }
    return Text(Text.RichContent(stringInterpolation: content))
  }
}
