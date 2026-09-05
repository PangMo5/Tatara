// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

public struct DiffSpan: Equatable, Sendable {
  public var text: String
  public var color: Int?
  public var bold: Bool
  public init(text: String, color: Int? = nil, bold: Bool = false) {
    self.text = text
    self.color = color
    self.bold = bold
  }
}

/// Decode only SGR style instructions. OSC, cursor motion, clipboard writes and other control sequences never reach the renderer.
public enum StyledDiff {
  public static func lines(_ source: String) -> [[DiffSpan]] {
    let input = Array(source.unicodeScalars)
    var lines: [[DiffSpan]] = [[]]
    var buffer = ""
    var color: Int?
    var bold = false
    var index = 0
    func flush() {
      guard !buffer.isEmpty else { return }
      lines[lines.count - 1].append(.init(text: buffer, color: color, bold: bold))
      buffer = ""
    }
    while index < input.count {
      let scalar = input[index]
      if scalar.value == 0x1B {
        flush()
        index += 1
        guard index < input.count else { break }
        if input[index] == "[" {
          index += 1
          var codes = ""
          while index < input.count, !(0x40 ... 0x7E).contains(input[index].value) {
            codes.unicodeScalars.append(input[index])
            index += 1
          }
          if index < input.count, input[index] == "m" {
            let values = codes.isEmpty ? [0] : codes.split(separator: ";", omittingEmptySubsequences: false)
              .compactMap { Int($0) }
            var position = 0
            while position < values.count {
              let code = values[position]
              switch code {
              case 0: color = nil
                bold = false
              case 1: bold = true
              case 22: bold = false
              case 30 ... 37: color = code - 30
              case 90 ... 97: color = code - 90 + 8
              case 39: color = nil
              case 38, 48:
                // difftastic uses ANSI palette colors. Extended sequences are consumed atomically.
                if position + 2 < values.count, values[position + 1] == 5 {
                  if code == 38 {
                    color = values[position + 2] < 16 ? values[position + 2] : nil
                  }
                  position += 2
                } else if position + 4 < values.count, values[position + 1] == 2 {
                  position += 4
                }
              default: break
              }
              position += 1
            }
          }
        } else if input[index] == "]" || input[index] == "P" || input[index] == "_" || input[index] == "^" {
          index += 1
          while index < input.count {
            if input[index].value == 7 {
              break
            }
            if input[index].value == 0x1B, index + 1 < input.count, input[index + 1] == "\\" {
              index += 1
              break
            }
            index += 1
          }
        }
      } else if scalar == "\n" {
        flush()
        lines.append([])
      } else if scalar == "\t" {
        buffer += "    "
      } else if !CharacterSet.controlCharacters.contains(scalar), scalar.value != 0x7F {
        buffer.unicodeScalars.append(scalar)
      }
      index += 1
    }
    flush()
    return lines
  }
}
