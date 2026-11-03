// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TataraCore
import TermLoom
import Testing

struct CommentRenderingTests {
  @Test
  func `comment markdown separates typography while preserving code and link destinations`() async throws {
    let markdown = """
      ## Review notes
      **중요**: `x < y` and *emphasis* with ~~old~~ behavior.
      [**Reference**](https://example.com/review) and ![diagram](https://example.com/image.png)
      https://example.com/plain
      > Keep this boundary.
      - Check the empty collection.
      ```swift
      let literal = "**source**" // <tag>
      ```
      """
    let document = try await CommentRenderer.prepare(markdown, 110)
    let spans = document.lines.flatMap(\.self)
    let text = document.searchableLines.joined(separator: "\n")
    #expect(spans.contains { $0.text.contains("중요") && $0.bold })
    #expect(spans.contains { $0.text == "x < y" && $0.role == .commentCode })
    #expect(spans.contains { $0.text == "emphasis" && $0.role == .commentEmphasis })
    #expect(spans.contains { $0.text == "old" && $0.role == .commentStrikethrough })
    #expect(text.components(separatedBy: "https://example.com/plain").count == 2)
    #expect(text.contains("https://example.com/review"))
    #expect(text.contains("https://example.com/image.png"))
    #expect(text.contains("let literal = \"**source**\" // <tag>"))
    #expect(!text.contains("**중요**"))
    #expect(!text.contains("```"))
  }

  @Test
  func `styled comment wrapping preserves Unicode and produces searchable visible rows`() async throws {
    let body = "**한글 👩🏽‍💻 café** repeats `veryLongIdentifier` and **한글 👩🏽‍💻 café** again."
    for width in [16, 36, 110] {
      let document = try await CommentRenderer.prepare(body, width)
      #expect(document.lines == document.displayLines)
      #expect(document.searchableLines.allSatisfy { TerminalWidth.of($0) <= width })
      #expect(document.searchableLines.joined().contains("veryLongIdentifier"))
      let emphasized = document.lines.flatMap(\.self).filter(\.bold).map(\.text).joined()
      #expect(emphasized.contains("한글"))
      #expect(emphasized.contains("👩🏽‍💻"))
      #expect(emphasized.contains("café"))
    }
  }
}
