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

  @Test func `ansi never executes terminal controls`() {
    let lines = StyledDiff.lines("\u{1B}[31mremoved\u{1B}[0m\n\u{1B}]52;c;secret\u{7}safe\u{1B}[2J")
    #expect(lines == [[.init(text: "removed", color: 1)], [.init(text: "safe")]])
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
