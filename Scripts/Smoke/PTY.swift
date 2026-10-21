// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
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
  var onCompletedFrame: ((TimeInterval) -> Void)?
  private let recordPreview: Bool
  private var previewFrames: [[String: Any]] = []
  private var previewTextBytes = 0
  private var previewLimitExceeded = false
  private var inputError: String?

  init(
    binary: URL,
    arguments: [String],
    columns: Int = 176,
    rows: Int = 40,
    environment: [String: String] = [:],
    cwd: URL? = nil,
    artifacts: URL,
    recordPreview: Bool = false,
  ) throws {
    self.columns = columns
    self.rows = rows
    self.artifacts = artifacts
    self.recordPreview = recordPreview
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

  var keyboardPane: Int? {
    let status = line(-2)
    if status.contains("· Pull requests") || status.contains("· Issues") {
      return 1
    }
    if status.contains("· Files") {
      return 2
    }
    if ["Overview", "Diff", "Discussion", "Checks"].contains(where: { status.contains("· " + $0) }) {
      return 3
    }
    return nil
  }

  var sidebarWidth: Int {
    guard columns >= 100 else { return 0 }
    let border = line(1)
    guard let corner = border.dropFirst().firstIndex(where: { $0 == "┌" || $0 == "╭" || $0 == "+" }) else { return 0 }
    return border.distance(from: border.startIndex, to: corner)
  }

  func focusPane(_ pane: Int) throws {
    try waitUntil("keyboard pane status") { self.keyboardPane != nil }
    let selecting = line(2).prefix(sidebarWidth).contains("Pull requests") || line(2).prefix(sidebarWidth).contains("Issues")
    if pane == 1, !selecting {
      key("\u{1B}")
      try wait("Normal · Pull requests")
      return
    }
    if pane == 2, selecting {
      if keyboardPane == 3 {
        key("\t")
        try waitUntil("selection pane") { self.keyboardPane == 1 }
      }
      key("\r")
      try wait("Normal · Files")
      return
    }
    for _ in 0 ..< 3 {
      guard keyboardPane != pane else { return }
      let previous = keyboardPane
      key("\t")
      try waitUntil("Tab focus change") { self.keyboardPane != previous }
    }
    try expect(keyboardPane == pane, "Tab could not focus pane \(pane).")
  }

  func navigationKey(_ value: String) throws {
    if let pane = Int(value), (1 ... 3).contains(pane) {
      try focusPane(pane)
    } else {
      key(value)
    }
  }

  func selectedFileRow(_ index: Int) -> Bool {
    for row in 0 ..< rows where line(row).prefix(sidebarWidth).contains("Files ·") {
      return terminal.getCharData(col: 2, row: row + index + 1)?.attribute.bg == .trueColor(red: 0x37, green: 0x38, blue: 0x48)
    }
    return false
  }

  func selectedFixtureIndex(files: Bool) -> Int? {
    if !files {
      let expression = try! NSRegularExpression(pattern: #"▸[^#\n]*#(\d+) "#)
      let value = (0 ..< rows).map { String(line($0).prefix(sidebarWidth)) }.joined(separator: "\n")
      guard let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
            let range = Range(match.range(at: 1), in: value), let number = Int(value[range]) else { return nil }
      return number - 1
    }
    guard let heading = (0 ..< rows).first(where: { line($0).prefix(sidebarWidth).contains("Files ·") }) else { return nil }
    let expression = try! NSRegularExpression(pattern: #"File(\d+)\.swift"#)
    for row in (heading + 1) ..< rows {
      guard terminal.getCharData(col: 2, row: row)?.attribute.bg == .trueColor(red: 0x37, green: 0x38, blue: 0x48)
      else { continue }
      let value = String(line(row).prefix(sidebarWidth))
      if let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
         let range = Range(match.range(at: 1), in: value)
      {
        return Int(value[range])
      }
    }
    return nil
  }

  func requireSelectionContext(files: Bool, selected: Int) throws {
    let values = visibleFixtureIndices(files: files)
    let maximum = files ? 119 : 99
    for index in max(0, selected - 2) ... min(maximum, selected + 2) {
      try expect(values.contains(index), "Missing sidebar context row \(index) around \(selected).")
    }
  }

  func visibleFixtureIndices(files: Bool) -> [Int] {
    let pattern = files ? #"File(\d+)\.swift"# : #"#(\d+) "#
    let expression = try! NSRegularExpression(pattern: pattern)
    return (0 ..< rows).compactMap { row in
      let value = String(line(row).prefix(sidebarWidth))
      guard let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
            let range = Range(match.range(at: 1), in: value), let number = Int(value[range]) else { return nil }
      return files ? number : number - 1
    }
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
      var offset = 0
      let deadline = ProcessInfo.processInfo.systemUptime + 5
      while offset < buffer.count {
        let count = Darwin.write(master, address.advanced(by: offset), buffer.count - offset)
        if count > 0 {
          offset += count
          continue
        }
        if count < 0, errno == EINTR {
          continue
        }
        if count < 0, errno == EAGAIN || errno == EWOULDBLOCK,
           process.isRunning, ProcessInfo.processInfo.systemUptime < deadline
        {
          var descriptor = pollfd(fd: master, events: Int16(POLLIN | POLLOUT), revents: 0)
          if poll(&descriptor, 1, 100) > 0, descriptor.revents & Int16(POLLIN) != 0 {
            // The child can redraw before reading the rest of a paste. Drain both PTY directions.
            readOnce()
          }
          continue
        }
        inputError = "PTY input stopped after \(offset)/\(buffer.count) bytes (errno \(errno))."
        return
      }
    }
  }

  func key(_ value: String) {
    write(Data(value.utf8))
  }

  private(set) var lastReplayInputTimes: [TimeInterval] = []

  func replay(_ keys: [String], interval: TimeInterval) throws -> TimeInterval {
    let descriptor = master
    let payloads = keys.map { Data($0.utf8) }
    let result = Mutex((lastSent: 0.0, failed: false, times: [TimeInterval]()))
    let group = DispatchGroup()
    let queue = DispatchQueue(label: "tatara-smoke.input", qos: .userInitiated)
    // Input cadence must not wait for a rendered frame or for emulator parsing.
    queue.async(group: group) {
      for (index, payload) in payloads.enumerated() {
        let time = ProcessInfo.processInfo.systemUptime
        let sent = payload.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        result.withLock { $0.lastSent = time
          $0.failed = $0.failed || sent != payload.count
          $0.times.append(time)
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
    lastReplayInputTimes = receipt.times
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
    var segmentStart = bytes.startIndex
    for index in bytes.indices {
      let byte = bytes[index]
      if synchronizationPrefix == prefix.count {
        if byte == 104 {
          isSynchronizedOutput = true
        }
        if byte == 108 {
          isSynchronizedOutput = false
          if onCompletedFrame != nil || recordPreview {
            terminal.feed(buffer: bytes[segmentStart ... index])
            segmentStart = index + 1
            let completedAt = ProcessInfo.processInfo.systemUptime
            onCompletedFrame?(completedAt)
            if recordPreview, !previewLimitExceeded {
              let frameText = text
              previewTextBytes += frameText.utf8.count
              if previewFrames.count >= 5000 || previewTextBytes > 32 * 1024 * 1024 {
                previewLimitExceeded = true
              } else {
                previewFrames.append([
                  "uptime_ms": completedAt * 1000,
                  "text": frameText,
                  "columns": columns,
                  "rows": rows,
                  "pr_index": selectedFixtureIndex(files: false) as Any? ?? NSNull(),
                  "file_index": selectedFixtureIndex(files: true) as Any? ?? NSNull(),
                ])
              }
            }
          }
        }
        synchronizationPrefix = byte == 27 ? 1 : 0
      } else if byte == prefix[synchronizationPrefix] {
        synchronizationPrefix += 1
      } else {
        synchronizationPrefix = byte == 27 ? 1 : 0
      }
    }
    raw.append(contentsOf: bytes)
    if segmentStart < bytes.endIndex {
      terminal.feed(buffer: bytes[segmentStart...])
    }
  }

  func wait(_ value: String, timeout: TimeInterval = 30) throws {
    try waitUntil(value, timeout: timeout) { self.text.contains(value) }
  }

  func waitUntil(_ label: String, timeout: TimeInterval = 30, _ condition: () -> Bool) throws {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    repeat {
      if let inputError {
        throw SmokeError(inputError)
      }
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

  func selectedLabelHasBackground(_ label: String) -> Bool {
    for row in 0 ..< rows {
      let value = line(row)
      if let range = value.range(of: label) {
        let column = value.distance(from: value.startIndex, to: range.lowerBound)
        return terminal.getCharData(col: column, row: row)?.attribute.bg == .trueColor(red: 0x37, green: 0x38, blue: 0x48)
      }
    }
    return false
  }

  func activeBorder(_ pane: Int, color: UInt32 = 0xB4BEFE) -> Bool {
    let files = (0 ..< rows).first { line($0).prefix(sidebarWidth).contains("Files ·") }.map { $0 - 1 } ?? 1
    let position = pane == 1 ? (0, 1) : pane == 2 ? (0, files) : (sidebarWidth, 1)
    return terminal.getCharData(col: position.0, row: position.1)?.attribute.fg == .trueColor(
      red: UInt8(truncatingIfNeeded: color >> 16),
      green: UInt8(truncatingIfNeeded: color >> 8),
      blue: UInt8(truncatingIfNeeded: color),
    )
  }

  func hasBackground(_ color: UInt32) -> Bool {
    for row in 0 ..< rows {
      for column in 0 ..< columns {
        if terminal.getCharData(col: column, row: row)?.attribute.bg == .trueColor(
          red: UInt8(truncatingIfNeeded: color >> 16),
          green: UInt8(truncatingIfNeeded: color >> 8),
          blue: UInt8(truncatingIfNeeded: color),
        ) {
          return true
        }
      }
    }
    return false
  }

  func hasANSIToken(_ token: String, color: UInt8, bold: Bool) -> Bool {
    for row in 0 ..< rows {
      let text = line(row)
      guard let range = text.range(of: token) else { continue }
      let column = text.distance(from: text.startIndex, to: range.lowerBound)
      guard let cell = terminal.getCharData(col: column, row: row) else { continue }
      if cell.attribute.fg == .ansi256(code: color), cell.attribute.style.contains(.bold) == bold,
         !cell.attribute.style.contains(.underline)
      {
        return true
      }
    }
    return false
  }

  func hasDefaultBackground(column: Int, row: Int) -> Bool {
    terminal.getCharData(col: column, row: row)?.attribute.bg == .defaultColor
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

  /// Render actual emulator cells; this is a visual artifact, never a timing sample.
  func screenshot(_ name: String) throws {
    let cellWidth = 9, cellHeight = 20, padding = 16
    let width = columns * cellWidth + padding * 2, height = rows * cellHeight + padding * 2
    guard let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: width,
      pixelsHigh: height,
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0,
    ),
      let context = NSGraphicsContext(bitmapImageRep: bitmap)
    else { throw SmokeError("Could not create terminal preview bitmap.") }
    func color(_ value: Attribute.Color, background: Bool = false) throws -> NSColor {
      switch value {
      case let .trueColor(red, green, blue): return NSColor(
          srgbRed: Double(red) / 255,
          green: Double(green) / 255,
          blue: Double(blue) / 255,
          alpha: 1,
        )
      case .defaultColor, .defaultInvertedColor:
        let source = (value == .defaultInvertedColor) != background ? terminal.backgroundColor : terminal.foregroundColor
        return NSColor(
          srgbRed: Double(source.red) / 65535,
          green: Double(source.green) / 65535,
          blue: Double(source.blue) / 65535,
          alpha: 1,
        )
      case let .ansi256(code):
        let colors = SwiftTerm.Color.defaultInstalledColors
        guard colors.indices.contains(Int(code)) else { throw SmokeError("Unexpected extended ANSI palette index.") }
        let value = colors[Int(code)]
        return NSColor(
          srgbRed: Double(value.red) / 65535,
          green: Double(value.green) / 65535,
          blue: Double(value.blue) / 65535,
          alpha: 1,
        )
      }
    }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context
    try color(terminal.getCharData(col: 0, row: 0)?.attribute.bg ?? .defaultColor, background: true).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    for row in 0 ..< rows {
      for column in 0 ..< columns {
        guard let cell = terminal.getCharData(col: column, row: row) else { continue }
        let x = padding + column * cellWidth, y = height - padding - (row + 1) * cellHeight
        let inverted = cell.attribute.style.contains(.inverse)
        try color(inverted ? cell.attribute.fg : cell.attribute.bg, background: !inverted).setFill()
        NSRect(x: x, y: y, width: cellWidth, height: cellHeight).fill()
      }
      for column in 0 ..< columns {
        guard let cell = terminal.getCharData(col: column, row: row), cell.width > 0,
              !cell.attribute.style.contains(.invisible) else { continue }
        let bold = cell.attribute.style.contains(.bold), italic = cell.attribute.style.contains(.italic)
        let name = bold ? (italic ? "Menlo-BoldItalic" : "Menlo-Bold") : (italic ? "Menlo-Italic" : "Menlo-Regular")
        guard let font = NSFont(name: name, size: 14) else { throw SmokeError("Missing preview font: \(name)") }
        var attributes: [NSAttributedString.Key: Any] = try [
          .font: font,
          .foregroundColor: color(
            cell.attribute.style.contains(.inverse) ? cell.attribute.bg : cell.attribute.fg,
            background: cell.attribute.style.contains(.inverse),
          ),
        ]
        if cell.attribute.style.contains(.underline) {
          attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if cell.attribute.style.contains(.crossedOut) {
          attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        String(cell.getCharacter()).draw(
          at: NSPoint(x: padding + column * cellWidth, y: height - padding - (row + 1) * cellHeight + 1),
          withAttributes: attributes,
        )
      }
    }
    guard let data = bitmap.representation(using: .png, properties: [:])
    else { throw SmokeError("Could not encode terminal preview.") }
    try data.write(to: artifacts.appendingPathComponent(name + ".png"))
    try snapshot(name)
  }

  func finish() throws {
    try waitUntil("clean exit", timeout: 10) { !self.process.isRunning }
    try expect(process.terminationStatus == 0, "Application exited with status \(process.terminationStatus)")
    try expect(raw.range(of: Data("\u{1B}[?1049l".utf8)) != nil, "Alternate screen was not restored.")
    if recordPreview {
      try expect(!previewLimitExceeded, "Preview exceeded the 5000-frame or 32 MiB text limit.")
      let recording: [String: Any] = [
        "format": "tatara-terminal-text-preview-v1",
        "performance_measurement": false,
        "description": "Actual completed terminal-cell text; styling is omitted. Recording overhead is included.",
        "frames": previewFrames,
      ]
      try JSONSerialization.data(withJSONObject: recording, options: [.sortedKeys])
        .write(to: artifacts.appendingPathComponent("preview.json"), options: .atomic)
    }
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
