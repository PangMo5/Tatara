// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TataraCore
import Testing

struct CoreTests {
  @Test func `repository validation`() throws {
    #expect(throws: TataraError.self) { try RepositoryID("../repository") }
    #expect(throws: TataraError.self) { try RepositoryID("owner/repo;uname") }
    #expect(try RepositoryID("PangMo5/Tatara").slug == "PangMo5/Tatara")
  }

  @Test func `source text never executes terminal controls`() {
    let safe = TerminalText.sanitize("\u{1B}]52;c;secret\u{7}safe\u{1B}[2J")
    #expect(!safe.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) })
  }

  @Test func `keymap rejects conflicts`() {
    #expect(throws: TataraError.self) { try Keymap(overrides: ["quit": ["j"]]) }
    #expect(throws: TataraError.self) { try Keymap(overrides: ["down": ["g"]]) }
  }

  @Test func `locale uses taiwan traditional chinese`() {
    #expect(Language.resolve("zh_TW.UTF-8") == .traditionalChinese)
    #expect(Language.resolve("ko_KR.UTF-8") == .korean)
  }
}
