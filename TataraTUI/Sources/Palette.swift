// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import TataraCore
import TermLoom

/// Catppuccin palette and ANSI values, verified against catppuccin/palette.
/// Alpha roles are blended against the actual opaque terminal background.
struct Palette {
  let rosewater: Color
  let flamingo: Color
  let pink: Color
  let mauve: Color
  let red: Color
  let maroon: Color
  let peach: Color
  let yellow: Color
  let green: Color
  let teal: Color
  let sky: Color
  let sapphire: Color
  let blue: Color
  let lavender: Color
  let text: Color
  let subtext1: Color
  let subtext0: Color
  let overlay2: Color
  let overlay1: Color
  let overlay0: Color
  let surface2: Color
  let surface1: Color
  let surface0: Color
  let base: Color
  let mantle: Color
  let crust: Color
  let selection: Color
  let editorSelection: Color
  let sidebarSelection: Color
  let search: Color
  let activeSearch: Color
  private let ansiColors: [Color]
  var surface: Color {
    surface0
  }

  var muted: Color {
    subtext0
  }

  var accent: Color {
    lavender
  }

  init(_ theme: TataraCore.Theme, noColor: Bool = false) {
    let values: [UInt32]
    let ansi: [UInt32]
    switch theme {
    case .latte:
      values = [
        0xDC8A78,
        0xDD7878,
        0xEA76CB,
        0x8839EF,
        0xD20F39,
        0xE64553,
        0xFE640B,
        0xDF8E1D,
        0x40A02B,
        0x179299,
        0x04A5E5,
        0x209FB5,
        0x1E66F5,
        0x7287FD,
        0x4C4F69,
        0x5C5F77,
        0x6C6F85,
        0x7C7F93,
        0x8C8FA1,
        0x9CA0B0,
        0xACB0BE,
        0xBCC0CC,
        0xCCD0DA,
        0xEFF1F5,
        0xE6E9EF,
        0xDCE0E8,
      ]
      ansi = [
        0x5C5F77,
        0xD20F39,
        0x40A02B,
        0xDF8E1D,
        0x1E66F5,
        0xEA76CB,
        0x179299,
        0xACB0BE,
        0x6C6F85,
        0xDE293E,
        0x49AF3D,
        0xEEA02D,
        0x456EFF,
        0xFE85D8,
        0x2D9FA8,
        0xBCC0CC,
      ]
    case .frappe:
      values = [
        0xF2D5CF,
        0xEEBEBE,
        0xF4B8E4,
        0xCA9EE6,
        0xE78284,
        0xEA999C,
        0xEF9F76,
        0xE5C890,
        0xA6D189,
        0x81C8BE,
        0x99D1DB,
        0x85C1DC,
        0x8CAAEE,
        0xBABBF1,
        0xC6D0F5,
        0xB5BFE2,
        0xA5ADCE,
        0x949CBB,
        0x838BA7,
        0x737994,
        0x626880,
        0x51576D,
        0x414559,
        0x303446,
        0x292C3C,
        0x232634,
      ]
      ansi = [
        0x51576D,
        0xE78284,
        0xA6D189,
        0xE5C890,
        0x8CAAEE,
        0xF4B8E4,
        0x81C8BE,
        0xA5ADCE,
        0x626880,
        0xE67172,
        0x8EC772,
        0xD9BA73,
        0x7B9EF0,
        0xF2A4DB,
        0x5ABFB5,
        0xB5BFE2,
      ]
    case .macchiato:
      values = [
        0xF4DBD6,
        0xF0C6C6,
        0xF5BDE6,
        0xC6A0F6,
        0xED8796,
        0xEE99A0,
        0xF5A97F,
        0xEED49F,
        0xA6DA95,
        0x8BD5CA,
        0x91D7E3,
        0x7DC4E4,
        0x8AADF4,
        0xB7BDF8,
        0xCAD3F5,
        0xB8C0E0,
        0xA5ADCB,
        0x939AB7,
        0x8087A2,
        0x6E738D,
        0x5B6078,
        0x494D64,
        0x363A4F,
        0x24273A,
        0x1E2030,
        0x181926,
      ]
      ansi = [
        0x494D64,
        0xED8796,
        0xA6DA95,
        0xEED49F,
        0x8AADF4,
        0xF5BDE6,
        0x8BD5CA,
        0xA5ADCB,
        0x5B6078,
        0xEC7486,
        0x8CCF7F,
        0xE1C682,
        0x78A1F6,
        0xF2A9DD,
        0x63CBC0,
        0xB8C0E0,
      ]
    case .mocha:
      values = [
        0xF5E0DC,
        0xF2CDCD,
        0xF5C2E7,
        0xCBA6F7,
        0xF38BA8,
        0xEBA0AC,
        0xFAB387,
        0xF9E2AF,
        0xA6E3A1,
        0x94E2D5,
        0x89DCEB,
        0x74C7EC,
        0x89B4FA,
        0xB4BEFE,
        0xCDD6F4,
        0xBAC2DE,
        0xA6ADC8,
        0x9399B2,
        0x7F849C,
        0x6C7086,
        0x585B70,
        0x45475A,
        0x313244,
        0x1E1E2E,
        0x181825,
        0x11111B,
      ]
      ansi = [
        0x45475A,
        0xF38BA8,
        0xA6E3A1,
        0xF9E2AF,
        0x89B4FA,
        0xF5C2E7,
        0x94E2D5,
        0xA6ADC8,
        0x585B70,
        0xF37799,
        0x89D88B,
        0xEBD391,
        0x74A8FC,
        0xF2AEDE,
        0x6BD7CA,
        0xBAC2DE,
      ]
    }
    func color(_ value: UInt32) -> Color {
      noColor ? .reset : Color(rgb: value)
    }
    rosewater = color(values[0])
    flamingo = color(values[1])
    pink = color(values[2])
    mauve = color(values[3])
    red = color(values[4])
    maroon = color(values[5])
    peach = color(values[6])
    yellow = color(values[7])
    green = color(values[8])
    teal = color(values[9])
    sky = color(values[10])
    sapphire = color(values[11])
    blue = color(values[12])
    lavender = color(values[13])
    text = color(values[14])
    subtext1 = color(values[15])
    subtext0 = color(values[16])
    overlay2 = color(values[17])
    overlay1 = color(values[18])
    overlay0 = color(values[19])
    surface2 = color(values[20])
    surface1 = color(values[21])
    surface0 = color(values[22])
    base = color(values[23])
    mantle = color(values[24])
    crust = color(values[25])
    selection = color(Self.blend(values[17], over: values[23], opacity: 0.25))
    editorSelection = color(Self.blend(values[17], over: values[22], opacity: 0.25))
    sidebarSelection = color(Self.blend(values[17], over: values[24], opacity: 0.25))
    search = color(Self.blend(values[9], over: values[23], opacity: 0.25))
    activeSearch = color(Self.blend(values[4], over: values[23], opacity: 0.3))
    ansiColors = ansi.map(color)
  }

  func ansi(_ index: Int?) -> Color {
    guard let index else { return text }
    if index == 16 {
      return peach
    }
    if index == 17 {
      return rosewater
    }
    guard ansiColors.indices.contains(index) else { return text }
    return ansiColors[index]
  }

  func foreground(_ span: DiffSpan) -> Color {
    switch span.role {
    case .metadata: overlay2
    case .filePath: pink
    case .hunkHeader: peach
    case .diffHeader: blue
    case .comment: teal
    case .commentBody: text
    case .commentCode: peach
    case .commentEmphasis: text
    case .commentLink: blue
    case .commentQuote, .commentStrikethrough, .commentGap: subtext0
    case .added: green
    case .removed: red
    case nil: ansi(span.color)
    }
  }

  private static func blend(_ foreground: UInt32, over background: UInt32, opacity: Double) -> UInt32 {
    [16, 8, 0].reduce(0) { result, shift in
      let front = Double((foreground >> shift) & 255), back = Double((background >> shift) & 255)
      return result | (UInt32((front * opacity + back * (1 - opacity)).rounded()) << shift)
    }
  }
}
