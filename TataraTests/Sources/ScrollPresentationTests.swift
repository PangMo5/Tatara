// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Darwin
import Foundation
@testable import TermLoom
import Testing

@MainActor
struct ScrollPresentationTests {
  private final class Application: TerminalApplication {
    let automaticallyTracksObservableState = false
    let coalescesScrollPresentation: Bool
    var offset = 0
    var wheelCount = 0
    var frames: [Int] = []
    var boundaries: [Int] = []

    init(coalesces: Bool = true) {
      coalescesScrollPresentation = coalesces
    }

    var body: Paragraph {
      frames.append(offset)
      return Paragraph("Offset \(offset)")
    }

    func update(_ event: TerminalEvent) async -> ApplicationUpdate {
      if case let .mouse(mouse) = event {
        switch mouse.kind {
        case .scrollDown: offset = min(30, offset + 1)
          wheelCount += 1
        case .scrollUp: offset = max(0, offset - 1)
          wheelCount += 1
        default: boundaries.append(frames.last ?? -1)
        }
        return .redraw
      }
      if case let .key(key) = event {
        if key.key == .character("q") {
          return .quit
        }
        boundaries.append(frames.last ?? -1)
      }
      return .ignore
    }
  }

  @MainActor private final class TerminalPair {
    var master: Int32 = -1
    var slave: Int32 = -1
    let session: TerminalSession

    init() throws {
      var window = winsize(ws_row: 8, ws_col: 24, ws_xpixel: 0, ws_ypixel: 0)
      guard openpty(&master, &slave, nil, nil, &window) == 0 else { throw POSIXError(.EIO) }
      session = try TerminalSession(
        viewport: .fullscreen,
        capturesMouse: true,
        inputDescriptor: slave,
        output: FileHandle(fileDescriptor: slave, closeOnDealloc: false),
      )
    }

    func send(_ text: String) throws {
      let data = Data(text.utf8)
      let written = data.withUnsafeBytes { Darwin.write(master, $0.baseAddress, $0.count) }
      guard written == data.count else { throw POSIXError(.EIO) }
    }

    deinit {
      close(master)
      close(slave)
    }
  }

  private let down = "\u{1B}[<65;10;4M"
  private let up = "\u{1B}[<64;10;4M"

  @Test func `wheel batches preserve every transition including clamping and reversal`() async throws {
    let pair = try TerminalPair()
    defer { try? pair.session.restore() }
    let app = Application()
    try pair.send(String(repeating: down, count: 68) + String(repeating: up, count: 2) + "q")
    try await app.run(in: pair.session)
    #expect(app.wheelCount == 70)
    #expect(app.offset == 28)
    #expect(app.frames == [0, 30, 28])
  }

  @Test func `keyboard clicks and pointer changes end the current wheel presentation`() async throws {
    let pair = try TerminalPair()
    defer { try? pair.session.restore() }
    let app = Application()
    try pair.send(down + down + "x" + down + down + "\u{1B}[<0;10;4M" + down + "\u{1B}[<65;11;4M" + "q")
    try await app.run(in: pair.session)
    #expect(app.wheelCount == 6)
    #expect(app.boundaries == [2, 4])
    #expect(app.frames.contains(5))
    #expect(app.frames.last == 6)
  }

  @Test func `applications retain per-event presentation unless they opt in`() async throws {
    let pair = try TerminalPair()
    defer { try? pair.session.restore() }
    let app = Application(coalesces: false)
    try pair.send(down + down + up + "q")
    try await app.run(in: pair.session)
    #expect(app.frames == [0, 1, 2, 1])
  }

  @Test func `nonblocking lookahead preserves a fragmented escape sequence`() throws {
    let pair = try TerminalPair()
    defer { try? pair.session.restore() }
    var input = pair.session.makeInput()
    try pair.send("\u{1B}")
    #expect(try input.readEvent(timeoutMilliseconds: 0, wakeup: nil, flushPendingEscape: false) == nil)
    #expect(try input.readEvent(timeoutMilliseconds: 0, wakeup: nil, flushPendingEscape: false) == nil)
    try pair.send("[A")
    #expect(try input.readEvent(timeoutMilliseconds: 0) == .key(KeyEvent(.up)))
    try pair.send("\u{1B}")
    #expect(try input.readEvent(timeoutMilliseconds: 0, wakeup: nil, flushPendingEscape: false) == nil)
    #expect(try input.readEvent(timeoutMilliseconds: 0) == .key(KeyEvent(.escape)))
  }

  @Test func `idle input remains cancellable with scroll presentation enabled`() async throws {
    let pair = try TerminalPair()
    defer { try? pair.session.restore() }
    let app = Application()
    let task = Task { try await app.run(in: pair.session) }
    await Task.yield()
    task.cancel()
    try await task.value
  }
}
