// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Darwin
import Foundation
import SwiftTerm
import Synchronization

struct SmokeError: Error, CustomStringConvertible {
  let description: String
  init(_ message: String) {
    description = message
  }
}

func expect(_ value: Bool, _ message: String) throws {
  if !value {
    throw SmokeError(message)
  }
}

final class PTY: TerminalDelegate {
  private var master: Int32 = -1
  private let process = Process()
  private var terminal: Terminal!
  private var isSynchronizedOutput = false
  private var synchronizationPrefix = 0
  private(set) var raw = Data()
  private(set) var columns: Int
  private(set) var rows: Int
  let artifacts: URL

  init(
    binary: URL,
    arguments: [String],
    columns: Int = 176,
    rows: Int = 40,
    environment: [String: String] = [:],
    cwd: URL? = nil,
    artifacts: URL,
  ) throws {
    self.columns = columns
    self.rows = rows
    self.artifacts = artifacts
    try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
    var slave: Int32 = -1
    var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(columns), ws_xpixel: 0, ws_ypixel: 0)
    try expect(openpty(&master, &slave, nil, nil, &size) == 0, "openpty failed")
    terminal = Terminal(delegate: self, options: TerminalOptions(cols: columns, rows: rows, scrollback: 0))
    let flags = fcntl(master, F_GETFL)
    _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)
    let input = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
    process.executableURL = binary
    process.arguments = ["--stable-output", "--force-color"] + arguments + (arguments.contains("--files-view") ? [] : [
      "--files-view",
      "list",
    ])
    process.standardInput = input
    process.standardOutput = input
    process.standardError = input
    var env = ProcessInfo.processInfo.environment
    // Isolating Tatara's XDG state must not relocate mise's installed tools or cache.
    env["MISE_DATA_DIR"] = env["MISE_DATA_DIR"] ??
      (env["XDG_DATA_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        ".local/share",
      ).path) + "/mise"
    env["MISE_CACHE_DIR"] = env["MISE_CACHE_DIR"] ??
      (env["XDG_CACHE_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache").path) + "/mise"
    env["TERM"] = "xterm-256color"
    env["COLORTERM"] = "truecolor"
    env["NO_COLOR"] = nil
    env.merge(environment) { _, value in value }
    process.environment = env
    process.currentDirectoryURL = cwd
    try process.run()
    try input.close()
  }

  var pid: Int32 {
    process.processIdentifier
  }

  var text: String {
    (0 ..< rows).map(line).joined(separator: "\n")
  }

  func hasCompletedFrame(containing value: String) -> Bool {
    !isSynchronizedOutput && text.contains(value)
  }

  func selectedFileRow(_ index: Int) -> Bool {
    for row in 0 ..< rows where line(row).prefix(44).contains("2 · Files") {
      return terminal.getCharData(col: 2, row: row + index + 1)?.attribute.bg == .trueColor(red: 0x31, green: 0x32, blue: 0x44)
    }
    return false
  }

  func line(_ index: Int) -> String {
    terminal.getLine(row: index < 0 ? rows + index : index)?
      .translateToString(trimRight: true, skipNullCellsFollowingWide: true) ?? ""
  }

  func send(source _: Terminal, data: ArraySlice<UInt8>) {
    write(Data(data))
  }

  private func write(_ data: Data) {
    data.withUnsafeBytes { buffer in
      guard let address = buffer.baseAddress else { return }
      _ = Darwin.write(master, address, buffer.count)
    }
  }

  func key(_ value: String) {
    write(Data(value.utf8))
  }

  func replay(_ keys: [String], interval: TimeInterval) throws -> TimeInterval {
    let descriptor = master
    let payloads = keys.map { Data($0.utf8) }
    let result = Mutex((lastSent: 0.0, failed: false))
    let group = DispatchGroup()
    let queue = DispatchQueue(label: "tatara-smoke.input", qos: .userInitiated)
    // Input cadence must not wait for a rendered frame or for emulator parsing.
    queue.async(group: group) {
      for (index, payload) in payloads.enumerated() {
        let time = ProcessInfo.processInfo.systemUptime
        let sent = payload.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        result.withLock { $0.lastSent = time
          $0.failed = $0.failed || sent != payload.count
        }
        if index + 1 < payloads.count {
          Thread.sleep(forTimeInterval: interval)
        }
      }
    }
    while group.wait(timeout: .now()) == .timedOut {
      read(for: 0.005)
    }
    let receipt = result.withLock { $0 }
    try expect(!receipt.failed, "Timed keyboard replay failed to write input.")
    return receipt.lastSent
  }

  func read(for duration: TimeInterval = 0.02) {
    let deadline = ProcessInfo.processInfo.systemUptime + duration
    var bytes = [UInt8](repeating: 0, count: 65536)
    repeat {
      var descriptor = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
      let timeout = max(0, Int32((deadline - ProcessInfo.processInfo.systemUptime) * 1000))
      if poll(&descriptor, 1, timeout) > 0 {
        let count = Darwin.read(master, &bytes, bytes.count)
        if count > 0 {
          ingest(bytes.prefix(count))
        } else if count == 0 || errno != EAGAIN {
          break
        }
      }
    } while ProcessInfo.processInfo.systemUptime < deadline
  }

  /// Return on receipt instead of adding a fixed polling window to every latency sample.
  private func readOnce() {
    var descriptor = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
    guard poll(&descriptor, 1, 20) > 0 else { return }
    var bytes = [UInt8](repeating: 0, count: 65536)
    let count = Darwin.read(master, &bytes, bytes.count)
    if count > 0 {
      ingest(bytes.prefix(count))
    }
  }

  private func ingest(_ bytes: ArraySlice<UInt8>) {
    // State predicates must observe a complete synchronized terminal frame, not
    // new content paired with the previous frame's footer or interaction state.
    let prefix: [UInt8] = [27, 91, 63, 50, 48, 50, 54]
    for byte in bytes {
      if synchronizationPrefix == prefix.count {
        if byte == 104 {
          isSynchronizedOutput = true
        }
        if byte == 108 {
          isSynchronizedOutput = false
        }
        synchronizationPrefix = byte == 27 ? 1 : 0
      } else if byte == prefix[synchronizationPrefix] {
        synchronizationPrefix += 1
      } else {
        synchronizationPrefix = byte == 27 ? 1 : 0
      }
    }
    raw.append(contentsOf: bytes)
    terminal.feed(buffer: bytes)
  }

  func wait(_ value: String, timeout: TimeInterval = 30) throws {
    try waitUntil(value, timeout: timeout) { self.text.contains(value) }
  }

  func waitUntil(_ label: String, timeout: TimeInterval = 30, _ condition: () -> Bool) throws {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    repeat {
      readOnce()
      if !isSynchronizedOutput, condition() {
        return
      }
    } while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline
    try snapshot("failure")
    throw SmokeError("Timed out waiting for \(label). See \(artifacts.path)/failure.txt")
  }

  func resize(columns: Int, rows: Int) {
    self.columns = columns
    self.rows = rows
    terminal.resize(cols: columns, rows: rows)
    var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(columns), ws_xpixel: 0, ws_ypixel: 0)
    _ = ioctl(master, TIOCSWINSZ, &size)
    _ = kill(pid, SIGWINCH)
    read(for: 0.1)
  }

  func mouse(column: Int, row: Int, pressed: Bool) {
    key("\u{1B}[<0;\(column);\(row)\(pressed ? "M" : "m")")
  }

  func wheel(column: Int, row: Int, down: Bool, count: Int = 1) {
    key(String(repeating: "\u{1B}[<\(down ? 65 : 64);\(column);\(row)M", count: count))
  }

  func click(_ label: String) throws {
    for row in 0 ..< rows {
      let value = line(row)
      if let range = value.range(of: label) {
        let column = value.distance(from: value.startIndex, to: range.lowerBound) + max(1, label.count / 2) + 1
        mouse(column: column, row: row + 1, pressed: true)
        mouse(column: column, row: row + 1, pressed: false)
        return
      }
    }
    throw SmokeError("Visible control not found: \(label)")
  }

  func activeBorder(_ pane: Int) -> Bool {
    let body = rows - 3
    let position = pane == 1 ? (0, 1) : pane == 2 ? (0, 1 + body / 2) : (min(44, columns / 3), 1)
    return terminal.getCharData(col: position.0, row: position.1)?.attribute.fg == .trueColor(red: 0xCB, green: 0xA6, blue: 0xF7)
  }

  func cursorLine() -> Int? {
    let expression = try! NSRegularExpression(pattern: #"▸\s+(\d+)"#)
    let value = text
    guard let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
          let range = Range(match.range(at: 1), in: value) else { return nil }
    return Int(value[range])
  }

  func snapshot(_ name: String) throws {
    try text.write(to: artifacts.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
    try raw.write(to: artifacts.appendingPathComponent(name + ".ansi"))
  }

  func finish() throws {
    try waitUntil("clean exit", timeout: 10) { !self.process.isRunning }
    try expect(process.terminationStatus == 0, "Application exited with status \(process.terminationStatus)")
    try expect(raw.range(of: Data("\u{1B}[?1049l".utf8)) != nil, "Alternate screen was not restored.")
  }

  func close() {
    if process.isRunning {
      _ = kill(pid, SIGINT)
      read(for: 0.3)
    }
    if process.isRunning {
      process.terminate()
      read(for: 0.3)
    }
    if process.isRunning {
      _ = kill(pid, SIGKILL)
    }
    process.waitUntilExit()
    if master >= 0 {
      _ = Darwin.close(master)
      master = -1
    }
  }
}
