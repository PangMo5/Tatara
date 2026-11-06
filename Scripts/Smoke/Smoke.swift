// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CryptoKit
import Darwin
import Foundation

@main
struct Smoke {
  static func main() {
    do {
      let name = URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent
      if name == "gh" || name == "difft" {
        try fixtureTool(name)
        return
      }
      let args = Array(CommandLine.arguments.dropFirst())
      guard let value = args.first
      else { throw SmokeError("Usage: tatara-smoke BINARY [--workspace|--stress|--live DIRECTORY --item NUMBER]") }
      let binary = URL(fileURLWithPath: value)
      let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      let artifacts = root.appendingPathComponent(".artifacts/swift-pty")
      func size(_ flag: String, _ fallback: Int) -> Int {
        guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1) else { return fallback }
        return Int(args[i + 1]) ?? fallback
      }
      if
        let index = args.firstIndex(of: "--read-probe"),
        args.indices.contains(index + 1),
        let repoIndex = args.firstIndex(of: "--repo"),
        args.indices.contains(repoIndex + 1)
      {
        let label = args.firstIndex(of: "--label").map { args.indices.contains($0 + 1) ? args[$0 + 1] : "current" } ?? "current"
        try readProbe(
          binary,
          directory: URL(fileURLWithPath: args[index + 1]),
          repository: args[repoIndex + 1],
          artifacts: artifacts.appendingPathComponent("read-probe-" + label),
        )
      } else if let index = args.firstIndex(of: "--metadata-live"), args.indices.contains(index + 1) {
        let t = try PTY(
          binary: binary,
          arguments: ["--repo", args[index + 1], "--language", "en"],
          columns: 176,
          rows: 48,
          artifacts: artifacts.appendingPathComponent("metadata-live"),
        )
        defer { t.close() }
        try t.wait("Updated", timeout: 60)
        try t.waitUntil("finished live detail", timeout: 60) {
          let status = t.line(-2)
          return !status.contains("Loading") && !status.contains("Preparing") && !status.contains("Error") && t.line(2)
            .contains("#")
        }
        try expect(!t.text.contains("Could not load"), "Live metadata failed.")
        try t.screenshot("overview")
        t.key("q")
        try t.finish()
        print("Swift PTY: live GitHub list and rich detail metadata passed; no forge writes.")
      } else if args.contains("--loading") {
        try loading(binary, artifacts: artifacts.appendingPathComponent("loading"))
      } else if args.contains("--picker-benchmark") {
        try pickerBenchmark(binary, artifacts: artifacts.appendingPathComponent("picker-benchmark"))
      } else if args.contains("--reading-workspace") {
        try readingWorkspace(binary, artifacts: artifacts.appendingPathComponent("reading-workspace"))
      } else if args.contains("--diff-layout") {
        try diffLayout(binary, artifacts: artifacts.appendingPathComponent("diff-layout"))
      } else if args.contains("--presentation") {
        try presentation(binary, artifacts: artifacts.appendingPathComponent("presentation"))
      } else if let index = args.firstIndex(of: "--wheel-boundary"), args.indices.contains(index + 1) {
        try workspace(
          binary,
          stress: true,
          artifacts: artifacts.appendingPathComponent("wheel-boundary-" + args[index + 1]),
          columns: size("--columns", 320),
          rows: size("--rows", 64),
        )
      } else if let index = args.firstIndex(of: "--wheel-reversal"), args.indices.contains(index + 1) {
        try workspace(
          binary,
          stress: true,
          artifacts: artifacts.appendingPathComponent("wheel-reversal-" + args[index + 1]),
          columns: size("--columns", 320),
          rows: size("--rows", 64),
        )
      } else if args.contains("--wheel") {
        try workspace(binary, stress: true, artifacts: artifacts.appendingPathComponent("wheel"))
      } else if args.contains("--vim") {
        try vim(binary, artifacts: artifacts.appendingPathComponent("vim"))
      } else if args.contains("--search-review") {
        try searchReview(binary, artifacts: artifacts.appendingPathComponent("search-review"))
      } else if args.contains("--editors") {
        try editors(binary, artifacts: artifacts.appendingPathComponent("editors"))
      } else if args.contains("--stacked") {
        try stackedWorkspace(binary, artifacts: artifacts.appendingPathComponent("stacked"))
      } else if args.contains("--draft-review") {
        try draftReview(binary, artifacts: artifacts.appendingPathComponent("draft-review"))
      } else if args.contains("--review-experience") {
        try reviewExperience(binary, artifacts: artifacts.appendingPathComponent("review-experience"))
      } else if args.contains("--features") {
        try features(binary, artifacts: artifacts.appendingPathComponent("features"))
      } else if let index = args.firstIndex(of: "--live-navigation"), args.indices.contains(index + 1) {
        let label = args.firstIndex(of: "--label").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } ?? "current"
        let output = artifacts.appendingPathComponent("navigation-live-" + label)
        let t = try PTY(
          binary: binary,
          arguments: ["--language", "en", "--theme", "mocha"],
          columns: size("--columns", 320),
          rows: size("--rows", 64),
          environment: profilingEnvironment(output),
          cwd: URL(fileURLWithPath: args[index + 1]),
          artifacts: output,
        )
        defer { t.close() }
        try t.wait("Pull requests")
        let expression = try NSRegularExpression(pattern: #"#(\d+) "#)
        func itemIDs() -> [String] {
          var ids = [String]()
          for row in 0 ..< t.rows / 2 {
            let line = String(t.line(row).prefix(t.sidebarWidth))
            if
              let match = expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line),
              !ids.contains(String(line[range]))
            {
              ids.append(String(line[range]))
            }
          }
          return ids
        }
        try t.waitUntil("two open pull requests") { itemIDs().count >= 2 }
        try profileNavigation(t, binary: binary, artifacts: output, itemNumbers: Array(itemIDs().prefix(2)))
      } else if
        let index = args.firstIndex(of: "--live"),
        args.indices.contains(index + 1),
        let itemIndex = args.firstIndex(of: "--item"),
        args.indices.contains(itemIndex + 1)
      {
        try live(
          binary,
          directory: URL(fileURLWithPath: args[index + 1]),
          item: args[itemIndex + 1],
          artifacts: artifacts.appendingPathComponent("live"),
          columns: size("--columns", 176),
          rows: size("--rows", 40),
        )
      } else if args.contains("--list-search") {
        try workspace(
          binary,
          stress: true,
          artifacts: artifacts.appendingPathComponent("list-search"),
          profile: true,
          columns: 320,
          rows: 64,
        )
      } else if let index = args.firstIndex(of: "--navigation"), args.indices.contains(index + 1) {
        try workspace(
          binary,
          stress: true,
          artifacts: artifacts.appendingPathComponent("navigation-" + args[index + 1]),
          profile: true,
          columns: size("--columns", 320),
          rows: size("--rows", 64),
          navigation: true,
        )
      } else if let index = args.firstIndex(of: "--profile"), args.indices.contains(index + 1) {
        try workspace(
          binary,
          stress: true,
          artifacts: artifacts.appendingPathComponent("profile-" + args[index + 1]),
          profile: true,
          columns: size("--columns", 320),
          rows: size("--rows", 64),
        )
      } else if args.contains("--workspace") || args.contains("--stress") {
        try workspace(
          binary,
          stress: args.contains("--stress"),
          artifacts: artifacts.appendingPathComponent(args.contains("--stress") ? "stress" : "workspace"),
        )
      } else {
        try demo(binary, artifacts: artifacts.appendingPathComponent("demo"))
      }
    } catch {
      FileHandle.standardError.write(Data("\(error)\n".utf8))
      exit(1)
    }
  }

  static func waitForFixtureResponse(in directory: URL) throws {
    let released = directory.appendingPathComponent("released")
    if FileManager.default.fileExists(atPath: released.path) {
      return
    }
    // Each request owns a FIFO; the release latch also covers replacement requests.
    let pipe = directory.appendingPathComponent("\(getpid()).fifo")
    try expect(mkfifo(pipe.path, 0o600) == 0, "Could not create fixture response pipe.")
    let descriptor = Darwin.open(pipe.path, O_RDWR | O_NONBLOCK)
    try expect(descriptor >= 0, "Could not open fixture response pipe.")
    defer { Darwin.close(descriptor) }
    try Data().write(to: directory.appendingPathComponent("waiting"))
    if !FileManager.default.fileExists(atPath: released.path) {
      var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
      try expect(
        Darwin.poll(&event, 1, 30_000) > 0 && event.revents & Int16(POLLIN) != 0,
        "Fixture response was not released before its deadline.",
      )
      var token: UInt8 = 0
      try expect(Darwin.read(descriptor, &token, 1) == 1, "Fixture response gate was not released.")
    }
  }

  static func loading(_ binary: URL, artifacts: URL) throws {
    let fm = FileManager.default
    let fixture = fm.temporaryDirectory.appendingPathComponent("tatara-loading-\(UUID())")
    try fm.createDirectory(at: fixture, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: fixture) }
    try fm.createSymbolicLink(
      at: fixture.appendingPathComponent("gh"),
      withDestinationURL: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL,
    )
    try fm.createSymbolicLink(
      at: fixture.appendingPathComponent("difft"),
      withDestinationURL: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL,
    )
    let variants: [(name: String, arguments: [String], stage: String, animated: Bool)] = [
      ("bootstrap", [], "bootstrap", true),
      ("items", [], "items", true),
      ("diff", [], "diff", true),
      ("reduce-motion", ["--reduce-motion"], "items", false),
      ("stable", ["--stable-output"], "items", false),
      ("accessible", ["--accessible"], "items", false),
      ("ascii", ["--ascii", "--no-color"], "items", true),
    ]
    var inputTimes = [Double]()
    for variant in variants {
      let gate = fixture.appendingPathComponent(variant.name)
      try fm.createDirectory(at: gate, withIntermediateDirectories: false)
      let t = try PTY(
        binary: binary,
        arguments: ["--repo", "example/reviews", "--language", "en"] + variant.arguments,
        columns: variant.stage == "diff" ? 176 : 90,
        rows: variant.stage == "diff" ? 40 : 28,
        environment: [
          "PATH": fixture.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? ""),
          "TATARA_SMOKE_FIXTURE": fixture.path,
          "TATARA_SMOKE_LOADING_GATE": gate.path,
          "TATARA_SMOKE_LOADING_STAGE": variant.stage,
          "XDG_DATA_HOME": gate.appendingPathComponent("data").path,
          "XDG_CACHE_HOME": gate.appendingPathComponent("cache").path,
        ],
        artifacts: artifacts.appendingPathComponent(variant.name),
        animated: true,
      )
      defer { t.close() }
      let hasArtwork: (String) -> Bool = { text in
        if variant.stage != "diff", !text.contains("t a t a r a") {
          return false
        }
        if variant.name == "ascii" {
          return text.contains("#####")
        }
        let range = 0x2580 ... 0x259F
        let artwork = variant.stage == "diff"
          ? (2 ..< 9).map { String(t.line($0).dropFirst(t.columns - 1 - 18).prefix(18)) }.joined()
          : text
        return artwork.unicodeScalars.contains { range.contains(Int($0.value)) }
      }
      if variant.stage == "diff" {
        try t.wait("Long overview")
        try t.wait("Ready")
        t.key("\r")
        try t.wait("Normal · Files")
      }
      try t.waitUntil("held loading request") { fm.fileExists(atPath: gate.appendingPathComponent("waiting").path) }
      try t.waitUntil("forge artwork") { hasArtwork(t.text) }
      try t.wait("Loading")
      if variant.stage == "diff" {
        try expect(
          t.text.contains("Preview") && t.text.contains("Created"),
          "Diff loading replaced its identified overview preview.",
        )
      }
      if variant.animated {
        var pictures = Set<String>()
        var previous = ""
        var captures = [[String: Any]]()
        for index in 0 ..< 8 {
          try t.waitUntil("hammer pose \(index)") { t.text != previous }
          previous = t.text
          pictures.insert(t.text)
          if variant.name == "items" || variant.stage == "diff" {
            try t.screenshot("frame-\(index)")
            captures.append(["file": "frame-\(index).png", "uptime": ProcessInfo.processInfo.systemUptime])
          }
        }
        try expect(pictures.count >= (variant.stage == "diff" ? 4 : 5), "Loading hammer did not animate.")
        if !captures.isEmpty {
          try JSONSerialization.data(withJSONObject: captures, options: [.prettyPrinted, .sortedKeys])
            .write(to: artifacts.appendingPathComponent(variant.name).appendingPathComponent("frames.json"), options: .atomic)
        }
      } else {
        let picture = t.text
        t.read(for: 0.6)
        try expect(t.text == picture, "Motion suppression did not hold the hammer still.")
      }
      try t.screenshot("loading")
      if variant.stage == "bootstrap" {
        t.key("q")
        try t.finish()
        continue
      }
      if variant.animated {
        for _ in 0 ..< 12 {
          let start = ProcessInfo.processInfo.systemUptime
          t.key(variant.stage == "diff" ? "\t" : "/")
          try t.wait(variant.stage == "diff" ? "Normal · Diff" : "Find loaded items (regex)")
          inputTimes.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
          t.key(variant.stage == "diff" ? "\u{1B}[Z" : "\u{1B}")
          try t.wait(variant.stage == "diff" ? "Normal · Files" : "Normal · Pull requests")
        }
        t.resize(columns: variant.stage == "diff" ? 180 : 104, rows: 32)
        try t.waitUntil("forge artwork") { hasArtwork(t.text) }
      }
      try Data([1]).write(to: gate.appendingPathComponent("released"), options: .atomic)
      for pipe in try fm.contentsOfDirectory(at: gate, includingPropertiesForKeys: nil) where pipe.pathExtension == "fifo" {
        let descriptor = Darwin.open(pipe.path, O_RDWR | O_NONBLOCK)
        try expect(descriptor >= 0, "Could not open loading response pipe.")
        var token: UInt8 = 1
        let count = Darwin.write(descriptor, &token, 1)
        Darwin.close(descriptor)
        try expect(count == 1, "Could not release loading response.")
      }
      try t.wait("Long overview")
      try t.wait("Ready")
      try expect(!hasArtwork(t.text), "Loading artwork outlived its request.")
      var idleFrames = 0
      t.onCompletedFrame = { _ in idleFrames += 1 }
      t.read(for: 0.6)
      t.onCompletedFrame = nil
      try expect(idleFrames == 0, "Loading animation continued redrawing while idle.")
      try t.screenshot("ready")
      t.key("q")
      try t.finish()
    }
    let sorted = inputTimes.sorted()
    let latency: [String: Any] = [
      "samples": sorted.count,
      "median_ms": sorted[sorted.count / 2],
      "p95_ms": sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))],
      "max_ms": sorted.last!,
      "fixture": "Held PR-list and diff responses; query entry/tab focus, Unicode/ASCII/no-color, 90x28 and 176x40.",
    ]
    try JSONSerialization.data(withJSONObject: latency, options: [.prettyPrinted, .sortedKeys])
      .write(to: artifacts.appendingPathComponent("latency.json"), options: .atomic)
    print(
      "Swift PTY: forge loading animation, bootstrap cancellation, motion suppression, ASCII, completion and idle redraw stop passed."
    )
  }

  static func demo(_ binary: URL, artifacts: URL) throws {
    let terminal = try PTY(binary: binary, arguments: ["--demo", "--language", "en"], artifacts: artifacts)
    defer { terminal.close() }
    try terminal.wait("Keep review navigation within bounds")
    terminal.key("]")
    try terminal.wait("guard files.indices.contains")
    for theme in ["latte", "frappe", "macchiato", "mocha"] {
      terminal.key("T")
      try terminal.wait(theme)
      try terminal.wait("guard files.indices.contains")
      try terminal.snapshot("diff-\(theme)")
    }
    terminal.key("?")
    try terminal.wait("Previous pane")
    terminal.key("/ctrl-f\r")
    try terminal.wait("Page down in content")
    terminal.key("\u{1B}")
    try terminal.wait("Normal · Help")
    terminal.key("\u{1B}")
    try terminal.wait("Normal · Pull requests")
    terminal.key("/q")
    try terminal.wait("/q")
    terminal.key("\u{1B}")
    try terminal.wait("Normal · Pull requests")
    terminal.key("I")
    try terminal.wait("Remember the last reviewed file")
    terminal.key("I")
    try terminal.wait("Sources/ReviewQueue.swift")
    try terminal.wait("Ready")
    terminal.key("R")
    try terminal.wait("Write your review")
    terminal.key("\u{1B}")
    try terminal.wait("Normal · Pull requests")
    terminal.key("c")
    try terminal.wait("Choose a source line")
    terminal.key("\u{1B}")
    try terminal.wait("Normal · Pull requests")
    terminal.key("q")
    try terminal.finish()
    for (language, expected) in [
      ("en", "Pull requests"),
      ("ko", "PR"),
      ("ja", "プルリクエスト"),
      ("zh-Hans", "拉取请求"),
      ("zh-Hant", "提取要求"),
    ] {
      let t = try PTY(
        binary: binary,
        arguments: ["--demo", "--language", language],
        columns: 90,
        rows: 28,
        artifacts: artifacts.appendingPathComponent(language),
      )
      defer { t.close() }
      try t.wait(expected)
      try t.wait("#42")
      try t.snapshot("compact")
      t.key("q")
      try t.finish()
    }
    print("Swift PTY: demo, real difftastic, four themes, five languages and terminal restoration passed.")
  }

  static func pickerBenchmark(_ binary: URL, artifacts: URL) throws {
    let t = try PTY(binary: binary, arguments: ["--demo", "--language", "en", "--theme", "mocha"], rows: 48, artifacts: artifacts)
    defer { t.close() }
    try t.wait("Ready")
    t.key("\r")
    try t.wait("Current pull request")
    try t.wait("Ready")
    var samples = [Double]()
    for index in 0 ..< 24 {
      let number = index.isMultiple(of: 2) ? 43 : 42
      let start = ProcessInfo.processInfo.systemUptime
      t.key("\u{10}/\(number)\r")
      try t.waitUntil("quick picker burst accepted") {
        t.line(3).contains("#\(number) ") && t.line(-2).contains("Ready")
          && !t.line(2 + ((t.rows - 3) - 26) / 2).contains("Switch pull request")
      }
      if index >= 4 {
        samples.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
      }
    }
    samples.sort()
    let result: [String: Any] = try [
      "samples": samples,
      "count": samples.count,
      "median_ms": samples[samples.count / 2],
      "p95_ms": samples[Int(Double(samples.count) * 0.95)],
      "maximum_ms": samples.last!,
      "columns": t.columns,
      "rows": t.rows,
      "workload": "warm demo PRs; Ctrl-p + / + number + Enter delivered in one burst; complete Ready frame",
      "binary_sha256": SHA256.hash(data: Data(contentsOf: binary))
        .map { String(format: "%02x", $0) }.joined(),
    ]
    let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: artifacts.appendingPathComponent("latency.json"))
    print(String(decoding: data, as: UTF8.self))
    t.key("q")
    try t.finish()
  }

  static func readingWorkspace(_ binary: URL, artifacts: URL) throws {
    let t = try PTY(
      binary: binary,
      arguments: ["--demo", "--language", "en", "--theme", "mocha", "--files-view", "tree"],
      rows: 48,
      artifacts: artifacts,
    )
    defer { t.close() }
    try t.wait("Ready")
    try t.wait("Requested reviewers")
    try expect(!t.text.contains("Files · 2/2"), "PR selection must use its own full metadata screen.")
    try t.screenshot("select-pr")
    t.key("\r")
    try t.wait("Normal · Files")
    try t.wait("Current pull request")
    try t.wait("Files · 2/2")
    try t.wait("Ready")
    guard let filesHeading = (0 ..< t.rows).first(where: { t.line($0).prefix(t.sidebarWidth).contains("Files ·") })
    else { throw SmokeError("Missing Files heading") }
    try expect(filesHeading < t.rows / 3, "Files did not receive the tall review sidebar.")
    t.key("\u{10}")
    try t.waitUntil("quick picker visible") { t.line(2 + ((t.rows - 3) - 26) / 2).contains("Switch pull request") }
    try t.wait("[Normal]")
    for (keys, number) in [("j", 43), ("k", 42), ("G", 44), ("gg", 42), ("\u{6}", 44), ("\u{2}", 42)] {
      t.key(keys)
      try t.waitUntil("Vim picker movement") { t.text.contains("▸ #\(number) ") }
      try expect(t.text.contains("[Normal] / "), "Normal motion changed the picker query.")
    }
    try t.click("Half page")
    try t.screenshot("picker-vim-normal")
    t.key("/43")
    try t.waitUntil("filtered quick picker") { t.text.contains("/ 43") && t.text.contains("#43") }
    t.key("\r")
    try t
      .waitUntil("quick picker accepted") {
        !t.line(2 + ((t.rows - 3) - 26) / 2).contains("Switch pull request") && t.line(3).contains("#43") && t.line(-2)
          .contains("Ready")
      }
    t.key("\u{10}")
    try t.waitUntil("quick picker visible") { t.line(2 + ((t.rows - 3) - 26) / 2).contains("Switch pull request") }
    t.key("/42\r")
    try t
      .waitUntil("return to first PR") {
        t.line(3).contains("#42") && !t.line(2 + ((t.rows - 3) - 26) / 2).contains("Switch pull request") && t.line(-2)
          .contains("Ready")
      }
    t.key("gg")
    try t.wait("Sources/ReviewQueue.swift")
    try t.wait("Sources/Selection.swift")
    try t.wait("Ready")
    try t.screenshot("review-root")
    try t.verifyScreenshotBorders("review-root")
    let beforePage = position(t)
    t.key("\u{6}")
    try t.waitUntil("Files page controls content") { position(t) > beforePage }
    try expect(t.keyboardPane == 2, "Paging content stole Files focus.")
    t.key("\u{2}")
    try t.waitUntil("page back") { position(t) == 1 }
    t.key("j")
    t.key("j")
    try t.wait("Ready")
    t.key("\r")
    try t.wait("Normal · Diff")
    try t.wait("Wrap")
    t.key("w")
    try t.wait("No wrap")
    try t.wait("Ready")
    t.key("zL")
    try t
      .waitUntil("horizontal source scroll") {
        t.line(-2).contains("↔") && !t.line(-2).contains("↔0") && t.line(-2).contains("Ready")
      }
    try t.screenshot("horizontal-scroll")
    t.key("w")
    try t.waitUntil("wrapping restored") { !t.line(-2).contains("No wrap") && t.line(-2).contains("Ready") }
    t.key("gc")
    try t.wait("Reply")
    try t.screenshot("focused-comment")
    t.key("c")
    try t.wait("@demo")
    let popupX = (t.columns - 96) / 2
    let popupY = 1 + ((t.rows - 3) - 26) / 2
    t.mouse(column: popupX + 4, row: popupY + 10, pressed: true)
    t.mouse(column: popupX + 4, row: popupY + 10, pressed: false)
    t.key("**A focused reply**")
    try t.wait("A focused reply")
    try t.click("Preview")
    try t.wait("Confirm")
    try expect(!t.text.contains("**A focused reply**"), "Comment preview did not render Markdown.")
    try t.screenshot("reply-preview")
    t.key("\u{1B}")
    try t.waitUntil("reply dialog closed") { !t.text.contains("@demo") }
    try t.wait("Normal · Diff")
    for key in ["e", "D", "a", "s"] {
      t.key(key)
      try t.wait("@demo")
      if key == "a" {
        try t.click("Heart")
      }
      try t.click("Preview")
      try t.wait("Confirm")
      try t.screenshot("comment-action-" + key)
      t.key("\u{1B}")
      try t.waitUntil("comment dialog closed") { !t.text.contains("@demo") }
      try t.wait("Normal · Diff")
    }
    t.key("gc")
    t.resize(columns: 104, rows: 40)
    try t.wait("Ready")
    try t.screenshot("narrow-wrapped")
    t.key("V")
    try t.wait("Visual")
    t.key("\u{10}")
    try t.wait("[Normal]")
    t.key("/")
    try t.wait("[Insert]")
    t.key("\u{1B}")
    try t.wait("[Normal]")
    t.key("\u{1B}")
    try t.waitUntil("picker closed over visual selection") {
      !t.line(2 + ((t.rows - 3) - 26) / 2).contains("Switch pull request") && t.line(-2).contains("Visual")
    }
    t.key("\u{1B}")
    try t.wait("Normal · Diff")
    t.key("q")
    try t.finish()
    print(
      "Swift PTY: rich PR selection, modal Vim picker, tall Files, wrap and horizontal scrolling, source paging, comment focus and all comment previews passed; no forge writes."
    )
  }

  static func diffLayout(_ binary: URL, artifacts: URL) throws {
    let t = try PTY(
      binary: binary,
      arguments: ["--demo", "--language", "en", "--theme", "mocha", "--files-view", "tree"],
      rows: 40,
      artifacts: artifacts,
    )
    defer { t.close() }
    try t.wait("Ready")
    t.key("\r")
    try t.wait("Normal · Files")
    try t.wait("+2 −1")
    try t.wait("c2 +2 −1")
    t.key("j")
    try t.waitUntil("second file ready") { t.line(2).contains("Sources/Selection.swift") && t.line(-2).contains("Ready") }
    t.key("\r")
    try t.wait("Normal · Diff")
    t.key("/files\\[index \\+ 1\\]\r")
    try t.wait("1/2")
    try t.wait("LEFT · 5")
    t.key("\u{1B}")
    try t.wait("Normal · Diff")
    try t.screenshot("wide-mocha")
    for (index, theme) in ["mocha", "latte", "frappe", "macchiato"].enumerated() {
      if index > 0 {
        t.key("T")
        try t.wait(theme)
      }
      t.resize(columns: 104, rows: 40)
      try t.waitUntil("unified deletion and addition") {
        t.text.contains("5    -") && t.text.contains("6+") && t.line(-2).contains("Ready")
      }
      try expect(t.line(-2).contains("LEFT · 5"), "Resize changed the removed source cursor.")
      try expect(
        t.hasANSIToken("guard", color: theme == "latte" ? 2 : 10, bold: true),
        "Changed keywords must use difftastic ANSI color and bold without underline.",
      )
      for (column, row) in [(0, 0), (0, 1), (2, 12), (t.sidebarWidth + 2, 12), (0, t.rows - 2)] {
        try expect(t.hasDefaultBackground(column: column, row: row), "Ordinary surfaces must inherit the terminal background.")
      }
      try t.screenshot("unified-" + theme)
      t.resize(columns: 176, rows: 40)
      try t.waitUntil("wide source alignment") { !t.text.contains("5    -") && t.line(-2).contains("Ready") }
      try expect(t.line(-2).contains("LEFT · 5"), "Expanding the viewport changed the source cursor.")
      try t.screenshot("wide-" + theme)
    }
    t.resize(columns: 104, rows: 40)
    try t.waitUntil("unified source") { t.text.contains("5    -") && t.line(-2).contains("Ready") }
    t.key("c")
    try t.wait("Write your review")
    try t.screenshot("removed-line-review")
    t.key("\u{1B}")
    try t.wait("Normal · Diff")
    t.key("Vj")
    try t.wait("LEFT · 5–6")
    t.key("c")
    try t.wait("Write your review")
    try t.screenshot("removed-range-review")
    t.key("\u{1B}")
    try t.wait("Normal · Diff")
    t.resize(columns: 176, rows: 40)
    try t.focusPane(2)
    t.key("gg")
    try t.waitUntil("root combined diff") {
      t.line(2).contains(" · /") && t.text.contains("Sources/ReviewQueue.swift")
        && t.text.contains("Sources/Selection.swift") && t.line(-2).contains("Ready")
    }
    try t.screenshot("root-all-files")
    t.key("\r")
    try t.waitUntil("collapsed root") {
      !(t.rows / 2 ..< t.rows - 2).contains { String(t.line($0).prefix(t.sidebarWidth)).contains(".swift") }
    }
    try expect(
      t.text.contains("Sources/ReviewQueue.swift") && t.text.contains("Sources/Selection.swift"),
      "Collapsing the root lost the combined diff.",
    )
    t.key("l")
    try t.waitUntil("expanded root") {
      (t.rows / 2 ..< t.rows - 2).contains { String(t.line($0).prefix(t.sidebarWidth)).contains("ReviewQueue.swift") }
    }
    t.key("q")
    try t.finish()
    print(
      "Swift PTY: difftastic JSON, directional ANSI highlighting across all four themes, unified deletions/additions, resize source identity, LEFT review entry and root all-files diff passed; no forge writes."
    )
  }

  static func presentation(_ binary: URL, artifacts: URL) throws {
    let t = try PTY(
      binary: binary,
      arguments: ["--demo", "--language", "en", "--theme", "mocha", "--files-view", "tree"],
      rows: 48,
      artifacts: artifacts,
    )
    defer { t.close() }
    try t.wait("Ready")
    try expect(t.sidebarWidth >= 52, "PR selector did not reserve metadata space.")
    try t.wait("Approved")
    try t.screenshot("overview-selection")
    try t.wait("Milestone")
    try t.wait("Requested reviewers")
    try expect(t.line(4).contains("@contributor"), "Rich PR row did not show its author on the second line.")
    try t.screenshot("overview-rich")
    t.key("\r")
    try t.wait("Normal · Files")
    t.key("\r")
    try t.wait("Normal · Diff")
    try t.wait("Boundary case checked.")
    try expect(t.activeBorder(3), "Enter did not visibly focus Diff.")
    try expect(!t.text.contains("**Keep the empty"), "Comment markdown delimiters were displayed literally.")
    try t.screenshot("inline-comments")
    t.key("/return\r")
    try t.wait("1/2")
    t.key("\u{1B}")
    try t.wait("Normal · Diff")
    t.key("c")
    try t.wait("Write your review")
    t.key("The selection stays responsive while the next file loads.")
    try t.wait("The selection stays responsive while the next file loads.")
    try t.screenshot("inline-composer")
    t.key("\u{1B}")
    try t.wait("Normal · Diff")
    t.key("]")
    try t.wait("#42 · Discussion")
    try t.wait("Ready")
    try t.wait("Boundary case checked.")
    for theme in ["latte", "frappe", "macchiato", "mocha"] {
      t.key("T")
      try t.wait(theme)
      try t.screenshot("discussion-" + theme)
    }
    t.key("R")
    try t.wait("Write your review")
    try t.screenshot("review")
    t.key("\u{1B}")
    try t.wait("Normal · Discussion")
    t.key("f")
    try t.wait("Preset name")
    try t.screenshot("filters")
    t.key("\u{1B}")
    try t.wait("Normal · Discussion")
    t.key("?")
    try t.wait("Previous pane")
    try t.screenshot("help")
    t.key("\u{1B}")
    try t.wait("Normal · Discussion")
    t.resize(columns: 104, rows: 32)
    try t.wait("Ready")
    try expect(t.sidebarWidth == 44, "Narrow sidebar does not preserve 60 content columns.")
    try t.screenshot("compact")
    t.key("q")
    try t.finish()
    let config = artifacts.appendingPathComponent("config.toml")
    try "sidebar_width = 64\n".write(to: config, atomically: true, encoding: .utf8)
    for override in [false, true] {
      let custom = try PTY(
        binary: binary,
        arguments: ["--demo", "--language", "en", "--config", config.path] + (override ? ["--sidebar-width", "44"] : []),
        artifacts: artifacts.appendingPathComponent(override ? "override" : "configured"),
      )
      defer { custom.close() }
      try custom.wait("Ready")
      try expect(custom.sidebarWidth == (override ? 44 : 64), "Sidebar configuration precedence is wrong.")
      custom.key("q")
      try custom.finish()
    }
    print(
      "Swift PTY: Enter progression, configured sidebar width, comment Markdown, all themes, forms and compact presentation passed; no forge writes."
    )
  }

  static func vim(_ binary: URL, artifacts: URL) throws {
    let t = try PTY(
      binary: binary,
      arguments: ["--demo", "--language", "en", "--theme", "mocha", "--files-view", "tree"],
      artifacts: artifacts,
    )
    defer { t.close() }
    try t.wait("Ready")
    t.key("]")
    try t.wait("guard files.indices.contains")
    try t.wait("Ready")
    try t.focusPane(2)
    t.key("h")
    try t.wait("Sources/Selection.swift")
    try t.wait("Ready")
    try t.focusPane(3)
    for (theme, added, removed) in [
      ("latte", UInt32(0xD0E2D1), UInt32(0xEAC8D3)),
      ("frappe", 0x455052, 0x514251),
      ("macchiato", 0x3B474A, 0x48384B),
      ("mocha", 0x364143, 0x443244),
    ] {
      t.key("T")
      try t.wait(theme)
      try expect(!t.hasBackground(added) && !t.hasBackground(removed), "Added or removed source acquired a diff background.")
    }
    try t.snapshot("native-diff-background")
    t.key("/return\r")
    try t.waitUntil("forward regex result") { t.cursorLine() == 5 && t.text.contains("Find · Diff") }
    t.key("#")
    try t.wait("(?<!\\w)return(?!\\w)")
    try t.waitUntil("backward word wraps to previous match") { t.cursorLine() == 6 }
    t.key("n")
    try t.waitUntil("n follows backward direction") { t.cursorLine() == 5 }
    t.key("N")
    try t.waitUntil("N reverses backward direction") { t.cursorLine() == 6 }
    t.key("*")
    try t.waitUntil("star searches forward") { t.cursorLine() == 5 }
    t.key("g*")
    try t.waitUntil("partial word forward") { t.cursorLine() == 6 && t.line(-2).contains("/return ") }
    t.key("g#")
    try t.waitUntil("partial word backward") { t.cursorLine() == 5 }
    try t.snapshot("word-search")
    t.key("\u{1B}")
    try t.wait("Normal · Diff")
    t.resize(columns: 176, rows: 16)
    try t.wait("Ready")
    t.key("zt")
    try t.waitUntil("source at top") { t.line(3).contains("guard files.indices.contains") }
    try expect(t.cursorLine() == 5, "zt changed the source cursor.")
    t.key("zz")
    try t.waitUntil("source at center") { t.line(8).contains("guard files.indices.contains") }
    t.key("zb")
    try t.waitUntil("bottom command completed") { !t.line(-1).contains("z…") }
    try expect(t.cursorLine() == 5 && t.keyboardPane == 3, "Viewport command moved source or pane focus.")
    t.key("?")
    try t.wait("Previous pane")
    t.key("/Search word")
    try t.wait("Search word backward")
    try t.snapshot("word-command-help")
    t.key("\u{1B}")
    try t.wait("Previous pane")
    t.key("\u{1B}")
    try t.wait("Normal · Diff")
    t.key("q")
    try t.finish()
    print(
      "Swift PTY: #/* and g#/g*, direction-preserving n/N, zt/zz/zb, generated help and no added diff backgrounds passed; no forge writes."
    )
  }

  static func searchReview(_ binary: URL, artifacts: URL) throws {
    let t = try PTY(
      binary: binary,
      arguments: ["--demo", "--language", "en", "--files-view", "tree", "--theme", "mocha"],
      artifacts: artifacts,
    )
    defer { t.close() }
    try t.wait("Ready")
    t.key("/label:bug\r")
    try t.wait("No matches.")
    try t.wait("Find · Pull requests")
    t.key("\u{1B}")
    try t.wait("Normal · Pull requests")
    try t.wait("Keep review navigation")
    try t.wait("Ready")
    t.key("f")
    try t.wait("Filters and presets")
    try t.click("Labels")
    try t.wait("[ ] bug")
    try t.click("[ ] bug")
    try t.wait("label:\"bug\"")
    try t.wait("[x] bug")
    try t.click("[x] bug")
    try t.wait("[ ] bug")
    try t.click("good first issue")
    try t.wait("label:\"good first issue\"")
    try t.snapshot("label-picker")
    t.key("\u{1B}")
    try t.wait("Normal · Pull requests")
    try t.focusPane(2)
    t.key("g/^struct Selection\r")
    try t.wait("Search file contents")
    try t.wait("Sources/Selection.swift:1")
    try t.wait("1/1")
    try expect(t.text.contains("Files · 2/2"), "Content search filtered the Files tree.")
    try t.snapshot("file-content-search")
    try t.screenshot("file-content-search")
    t.resize(columns: 96, rows: 28)
    try t.wait("Sources/Selection.swift:1")
    try t.wait("Open match")
    try t.screenshot("file-content-search-narrow")
    t.resize(columns: 176, rows: 40)
    try t.wait("Sources/Selection.swift:1")
    t.key("\r")
    try t.wait("Normal · Diff")
    try t.wait("Ready")
    try expect(t.cursorLine() == 1, "Content search opened the wrong source line.")
    try t.focusPane(2)
    t.key("h")
    try t.wait("Sources/ReviewQueue.swift")
    t.wheel(column: 100, row: 15, down: true, count: 8)
    try t.wait("Sources/Selection.swift")
    t.wheel(column: 100, row: 15, down: false, count: 8)
    try t.waitUntil("combined diff returned to top") { position(t) == 1 }
    try t.wait("Boundary case checked.")
    try t.wait("Outdated")
    try t.wait("Ready")
    try t.focusPane(3)
    t.key("/return\r")
    try t.wait("Find · Diff")
    try t.wait("Ready")
    try expect(t.cursorLine() == 5, "Search did not select the first matching source line.")
    t.key("n")
    try t.waitUntil("next occurrence") { t.cursorLine() == 6 }
    t.key("N")
    try t.waitUntil("previous occurrence") { t.cursorLine() == 5 }
    for (theme, border, search) in [
      ("latte", UInt32(0x7287FD), UInt32(0xE6ADBD)),
      ("frappe", 0xBABBF1, 0x674B59),
      ("macchiato", 0xB7BDF8, 0x604456),
      ("mocha", 0xB4BEFE, 0x5E3F53),
    ] {
      t.key("T")
      try t.wait(theme)
      try expect(t.activeBorder(3, color: border), "Incorrect active border for \(theme).")
      try expect(t.hasBackground(search), "Missing active search background for \(theme).")
      try t.snapshot("search-" + theme)
    }
    t.key("\u{1B}")
    try t.wait("Normal · Diff")
    t.key("Vj")
    try t.wait("Visual · Diff")
    try t.waitUntil("visual range ends on line 6") { t.cursorLine() == 6 }
    t.key("c")
    try t.wait("RIGHT · 5–6")
    t.key("In-place draft.")
    try t.wait("In-place draft.")
    try expect(t.text.contains("Keep review navigation"), "Inline editor replaced the PR pane.")
    try expect(t.text.contains("return files[index + 1]"), "Inline editor removed the selected source.")
    try t.snapshot("inline-expanded")
    t.resize(columns: 96, rows: 28)
    try t.wait("RIGHT · 5–6")
    try t.wait("In-place draft.")
    try t.wait("return files[index + 1]")
    try t.snapshot("inline-compact")
    t.resize(columns: 176, rows: 40)
    try t.wait("RIGHT · 5–6")
    try t.wait("Ready")
    try t.click("Add comment to review")
    try t.wait("Normal · Diff")
    try t.wait("Pending review · RIGHT:5–6")
    t.key("R")
    try t.wait("Write your review")
    try t.click("Preview")
    try t.wait("This will be posted to GitHub.")
    try t.wait("In-place draft.")
    try expect(t.text.contains("Files") && t.text.contains("Current pull request"), "Review preview lost the workspace context.")
    try t.snapshot("inline-preview")
    t.key("\u{1B}")
    try t.wait("Normal · Diff")
    try t.wait("Ready")
    try t.wait("Pending review · RIGHT:5–6")
    try expect(t.cursorLine() == 6, "Adding a comment changed the source cursor.")
    t.key("q")
    try t.finish()
    print(
      "Swift PTY: loaded-item search, label toggles, content results with exact-line jump, folder diff, existing comments, regex n/N, four palettes, inline editing and resized preview passed; no forge writes."
    )
  }

  static func editors(_ binary: URL, artifacts: URL) throws {
    let t = try PTY(
      binary: binary,
      arguments: ["--demo", "--language", "en", "--ascii", "--no-color", "--accessible"],
      artifacts: artifacts,
    )
    defer { t.close() }
    try t.wait("Ready")
    t.key("R")
    try t.wait("Write your review")
    let original = "Alpha 한글 👩🏽‍💻 → ▸\nBeta end."
    t.key("\u{1B}[200~" + original + "\u{1B}[201~")
    try t.wait("Beta end.")
    try t.wait("Alpha 한글")
    try t.wait("→ ▸")
    // SwiftTerm 1.20 drops this ZWJ grapheme from translated cell text; verify the emitted sequence separately.
    try expect(t.raw.contains(Data("👩🏽‍💻".utf8)), "The editor dropped the ZWJ grapheme from terminal output.")
    t.key("\u{1A}")
    try t.waitUntil("paste undo") { !t.text.contains("Beta end.") }
    t.key("\u{1B}[122;6u")
    try t.wait("Beta end.")
    t.mouse(column: 3, row: 10, pressed: true)
    t.mouse(column: 3, row: 10, pressed: false)
    t.key("X")
    try t.wait("XBeta end.")
    try t.click("[  Preview  ]")
    try t.wait("This will be posted to GitHub.")
    try t.wait("Alpha 한글")
    try t.wait("→ ▸")
    // SwiftTerm 1.20 drops this ZWJ grapheme from translated cell text; verify the emitted sequence separately.
    try expect(t.raw.contains(Data("👩🏽‍💻".utf8)), "The editor dropped the ZWJ grapheme from terminal output.")
    try t.wait("XBeta end.")
    try t.click("Edit")
    try t.wait("Preview")
    t.mouse(column: 3, row: 9, pressed: true)
    t.mouse(column: 3, row: 9, pressed: false)
    t.key("\u{1B}[97;9u")
    let long = (0 ..< 120).lazy.map { "Preview row \($0) " + String(
      repeating: "한글 word ",
      count: 30,
    ) }.joined(separator: "\n") + "\nPREVIEW_END"
    t.key("\u{1B}[200~" + long + "\u{1B}[201~")
    try t.wait("PREVIEW_END")
    try t.click("[  Preview  ]")
    try t.wait("This will be posted to GitHub.")
    try t.wait("Preview row 0")
    t.key("\u{1B}[F")
    try t.wait("PREVIEW_END")
    t.resize(columns: 100, rows: 30)
    try t.wait("This will be posted to GitHub.")
    t.key("\u{1B}[F")
    try t.wait("PREVIEW_END")
    try t.snapshot("multiline-preview")
    try expect(!t.raw.contains(Data(";2;203;166;247".utf8)), "--no-color emitted the accent RGB color.")
    t.key("\u{1B}")
    try t.wait("Normal ·")
    t.key("q")
    try t.finish()
    print(
      "Swift PTY: multiline Unicode paste, undo/redo, mouse cursor, ASCII source preservation, no color and complete resized preview passed; no forge writes."
    )
  }

  static func stackedWorkspace(_ binary: URL, artifacts: URL) throws {
    let t = try PTY(
      binary: binary,
      arguments: ["--demo", "--language", "en", "--theme", "mocha", "--files-view", "tree"],
      columns: 80,
      rows: 30,
      environment: profilingEnvironment(artifacts),
      artifacts: artifacts,
    )
    defer { t.close() }
    try t.wait("Normal · Pull requests")
    try t.wait("Ready")
    let preparationStart = ProcessInfo.processInfo.systemUptime
    try t.focusPane(2)
    try t.wait("Normal · Files")
    try t.wait("Ready")
    let firstFileReady = (ProcessInfo.processInfo.systemUptime - preparationStart) * 1000
    var focusTimes = [Double]()
    func contentTop() -> Int {
      1 + (t.rows - 3) / 2
    }
    func bothPanels() -> Bool {
      t.line(1).contains("Files") && t.line(contentTop()).contains("Diff")
    }
    for (columns, rows) in [(80, 30), (96, 28), (60, 16), (99, 40)] {
      t.resize(columns: columns, rows: rows)
      try t.waitUntil("equal stacked panels") { bothPanels() }
      try t.focusPane(2)
      try expect(t.activeBorder(2), "Files focus is missing from the upper panel.")
      try t.focusPane(3)
      try expect(t.activeBorder(3) && bothPanels(), "Changing focus replaced a stacked panel.")
      try t.click("ReviewQueue.swift")
      try t.wait("Normal · Files")
      try expect(bothPanels(), "Clicking Files replaced the Diff panel.")
      t.key("\r")
      try t.wait("Normal · Diff")
      try t.wait("Ready")
      try expect(bothPanels(), "Opening a file hid the Files panel.")
      try t.screenshot("\(columns)x\(rows)")
    }
    for _ in 0..<24 {
      let next = t.keyboardPane == 3 ? 2 : 3
      let start = ProcessInfo.processInfo.systemUptime
      t.key("\t")
      try t.waitUntil("stacked focus feedback") { t.keyboardPane == next && bothPanels() }
      focusTimes.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
    }
    t.resize(columns: 96, rows: 28)
    try t.waitUntil("resized stacked content") { bothPanels() }
    try t.wait("Ready")
    t.key("gg")
    try t.waitUntil("first source line") { t.cursorLine() == 2 }
    func sourceIdentity() -> String? {
      let text = t.line(-2)
      let pattern = try! NSRegularExpression(pattern: #"(?:LEFT|RIGHT) · [0-9]+"#)
      guard let match = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let range = Range(
        match.range,
        in: text,
      ) else { return nil }
      return String(text[range])
    }
    let source = sourceIdentity()
    try expect(source != nil, "Source identity is missing before the wheel input.")
    t.wheel(column: 20, row: contentTop() + 4, down: true, count: 4)
    try t.waitUntil("Diff wheel moved its viewport") { position(t) > 1 }
    try t.snapshot("after-diff-wheel")
    try expect(sourceIdentity() == source && t.keyboardPane == 3 && bothPanels(), "Diff wheel changed source identity or focus.")
    t.wheel(column: 20, row: 4, down: true, count: 2)
    t.read(for: 0.1)
    try expect(
      sourceIdentity() == source && t.keyboardPane == 3 && bothPanels(),
      "Files wheel changed Diff focus or source cursor.",
    )
    t.key("gg")
    try t.waitUntil("source cursor restored") { t.cursorLine() == 2 }
    for _ in 0..<6 {
      guard let line = t.cursorLine(), line != 4 else { break }
      t.key("j")
      try t.waitUntil("review line") { t.cursorLine() != line }
    }
    try expect(t.cursorLine() == 4, "Could not reach the reviewable context line.")
    t.key("c")
    try t.wait("Write your review")
    t.key("Stacked layout draft.")
    try t.wait("Stacked layout draft.")
    t.resize(columns: 80, rows: 20)
    try t.wait("Stacked layout draft.")
    try t.wait("Add comment to review")
    try t.screenshot("small-composer")
    try t.click("Add comment to review")
    try t.wait("Normal · Diff")
    try t.waitUntil("stacked workspace restored") { bothPanels() }
    t.resize(columns: 176, rows: 40)
    try t.wait("Current pull request")
    try t.wait("Ready")
    try expect(t.cursorLine() == 4, "Wide resize changed the source cursor.")
    t.key("q")
    try t.finish()
    let sorted = focusTimes.sorted()
    let report: [String: Any] = try [
      "samples_ms": focusTimes,
      "p95_ms": sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1],
      "max_ms": sorted.last!,
      "first_file_ready_ms": firstFileReady,
      "binary_sha256": SHA256.hash(data: Data(contentsOf: binary)).map { String(format: "%02x", $0) }.joined(),
    ]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(
      to: artifacts.appendingPathComponent("latency.json"),
      options: .atomic,
    )
    print(
      "Swift PTY: equal stacked Files/Diff, focus, mouse, wheel ownership, minimum size, composer resize and wide restoration passed; no forge writes."
    )
  }

  static func draftReview(_ binary: URL, artifacts: URL) throws {
    let fm = FileManager.default
    let fixture = fm.temporaryDirectory.appendingPathComponent("tatara-draft-review-\(UUID())")
    try fm.createDirectory(at: fixture, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: fixture) }
    let tool = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    for name in ["gh", "difft"] { try fm.createSymbolicLink(at: fixture.appendingPathComponent(name), withDestinationURL: tool) }
    let t = try PTY(
      binary: binary,
      arguments: ["--repo", "example/reviews", "--files-view", "tree", "--language", "en"],
      environment: [
        "PATH": fixture.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? ""),
        "TATARA_SMOKE_FIXTURE": fixture.path,
        "TATARA_SMOKE_DRAFT": "1",
        "XDG_DATA_HOME": fixture.appendingPathComponent("data").path,
        "XDG_CACHE_HOME": fixture.appendingPathComponent("cache").path,
      ],
      artifacts: artifacts,
    )
    defer { t.close() }
    try t.wait("Ready")
    try t.focusPane(2)
    t.key("gg")
    try t.waitUntil("root cursor") { t.line(-2).contains("Normal · Files") }
    t.key("c")
    try t.wait("Select a file and press Enter to open Diff.")
    t.key("G")
    try t.wait("File11.swift")
    t.key("\r")
    try t.wait("Normal · Diff")
    try t.wait("Ready")
    for _ in 0..<4 {
      guard let line = t.cursorLine(), line != 2 else { break }
      t.key(line < 2 ? "j" : "k")
      try t.waitUntil("review source line") { t.cursorLine() != line }
    }
    try expect(t.cursorLine() == 2, "Draft fixture did not select its forge patch line.")
    t.key("c")
    try t.wait("Write your review")
    t.key("Draft PR inline comment.")
    try t.wait("Draft PR inline comment.")
    try t.screenshot("composer")
    try t.click("Add comment to review")
    try t.wait("Normal · Diff")
    try t.wait("Draft PR inline comment.")
    t.key("R")
    try t.wait("Write your review")
    try t.click("Preview")
    try t.wait("This will be posted to GitHub.")
    try t.wait("Draft PR inline comment.")
    try t.screenshot("preview")
    t.key("\u{1B}")
    try t.wait("Normal · Diff")
    t.key("q")
    try t.finish()
    print("Swift PTY: draft PR inline entry, pending comment, review preview and visible folder hint passed; no forge writes.")
  }

  static func reviewExperience(_ binary: URL, artifacts: URL) throws {
    let t = try PTY(
      binary: binary,
      arguments: ["--demo", "--current", "--language", "en", "--theme", "mocha"],
      artifacts: artifacts,
    )
    defer { t.close() }
    try t.wait("Normal · Files")
    try t.wait("Ready")
    try t.screenshot("summary")
    try expect(!t.text.contains("Pull requests ·"), "Current PR startup remained on the selection screen.")
    try t.focusPane(3)
    t.key("gc")
    try t.wait("Comment")
    t.key("\r")
    try t.waitUntil("conversation reader") { t.line(-2).contains("Conversation · #") }
    try t.wait("Reply")
    try t.wait("Previous implementation discussion.")
    try t.screenshot("conversation")
    t.key("c")
    try t.waitUntil("reply composer") { t.line(-2).contains("Reply · #") }
    t.key("A reply still in progress.")
    try t.wait("A reply still in progress.")
    t.key("\u{1B}")
    try t.waitUntil("conversation reader") { t.line(-2).contains("Conversation · #") }
    t.key("c")
    try t.waitUntil("reply composer") { t.line(-2).contains("Reply · #") }
    try t.wait("A reply still in progress.")
    t.key("\u{1B}")
    try t.waitUntil("conversation reader") { t.line(-2).contains("Conversation · #") }
    t.key("\u{1B}")
    try t.wait("Normal · Diff")
    t.key("gc")
    try t.waitUntil("returned to source") { !t.line(-2).contains("@reviewer") }
    t.key("l")
    try t.wait("RIGHT ·")
    for _ in 0..<20 {
      guard let line = t.cursorLine(), line != 5 else { break }
      t.key(line < 5 ? "j" : "k")
      try t.waitUntil("source cursor") { t.cursorLine() != line }
    }
    try t.wait("RIGHT · 5")
    t.key("c")
    try t.wait("Write your review")
    t.key("Pending review comment.")
    try t.wait("Pending review comment.")
    try t.click("Add comment to review")
    try t.wait("Normal · Diff")
    try t.wait("Pending review · RIGHT:5")
    try t.wait("Finish review (1)")
    try t.screenshot("pending-comment")
    t.key("R")
    try t.wait("Write your review")
    try t.click("Edit")
    try t.wait("Pending review comment.")
    t.key(" Updated draft.")
    try t.wait("Updated draft.")
    try t.click("Add comment to review")
    try t.wait("Normal · Diff")
    try t.wait("Finish review (1)")
    try t.wait("Updated draft.")
    t.resize(columns: 96, rows: 28)
    try t.wait("ReviewQueue.swift")
    try t.screenshot("sticky-narrow")
    t.resize(columns: 176, rows: 40)
    try t.wait("Ready")
    t.key("R")
    try t.wait("Write your review")
    try t.click("Preview")
    try t.wait("This will be posted to GitHub.")
    try t.wait("Updated draft.")
    try expect(t.text.contains("Files"), "Final review hid the file context.")
    try t.screenshot("finish-review")
    t.key("\u{1B}")
    try t.wait("Normal · Diff")
    t.key("q")
    try t.finish()
    print(
      "Swift PTY: current-PR startup, comment reader/reply draft, pending edit, sticky header, compact borders and final review preview passed; no forge writes."
    )
  }

  static func features(_ binary: URL, artifacts: URL) throws {
    let state = FileManager.default.temporaryDirectory.appendingPathComponent("tatara-feature-state-\(UUID())")
    defer { try? FileManager.default.removeItem(at: state) }
    let env = ["XDG_DATA_HOME": state.path]
    let t = try PTY(
      binary: binary,
      arguments: ["--demo", "--language", "en", "--theme", "mocha", "--files-view", "tree"],
      environment: env,
      artifacts: artifacts,
    )
    defer { t.close() }
    try t.wait("Normal · Pull requests")
    try t.wait("Ready")
    try expect(t.selectedLabelHasBackground("Keep review"), "Selected PR text lost the row background.")
    try t.focusPane(2)
    try t.wait("Normal · Files")
    try t.wait("ReviewQueue.swift")
    try expect(t.activeBorder(2), "The active file pane border is not accented.")
    try expect(t.selectedLabelHasBackground("ReviewQueue.swift"), "Selected file text lost the row background.")
    t.key("h")
    t.read(for: 0.1)
    t.key("\r")
    try t.waitUntil("collapsed source folder") { t.text.contains("▸ Sources") }
    t.key("\r")
    try t.wait("ReviewQueue.swift")
    t.key("l")
    try t.wait("guard files.indices.contains")
    try t.focusPane(3)
    try t.wait("Normal · Diff")
    try expect(t.activeBorder(3), "The active diff pane border is not accented.")
    try t.waitUntil("diff cursor") { t.cursorLine() != nil }
    for _ in 0 ..< 12 {
      guard let line = t.cursorLine(), line != 5 else { break }
      t.key(line < 5 ? "j" : "k")
      try t.waitUntil("source cursor movement") { t.cursorLine() != line }
    }
    try expect(t.cursorLine() == 5, "Cursor did not reach source line 5.")
    t.key("\u{1B}[118;2u")
    try t.wait("Visual · Diff")
    t.key("j")
    try t.waitUntil("visual line extension") { t.cursorLine() == 6 }
    try t.snapshot("visual-selection")
    t.key("c")
    try t.wait("Write your review")
    try t.wait("RIGHT · 5–6")
    t.key("Check this range.")
    try t.wait("Check this range.")
    try t.click("Add comment to review")
    try t.wait("Normal · Diff")
    try t.wait("Pending review · RIGHT:5–6")
    t.key("R")
    try t.wait("ReviewQueue.swift:5–6")
    try t.click("Preview")
    try t.wait("This will be posted to GitHub.")
    try t.wait("Check this range.")
    try t.snapshot("range-preview")
    t.key("\u{1B}")
    try t.wait("Normal · Diff")
    try t.wait("Ready")
    t.key("h")
    try t.wait("LEFT ·")
    t.key("r")
    try t.wait("Write your review")
    try t.wait("LEFT ·")
    t.key("Old source context.")
    try t.wait("Old source context.")
    try t.click("Add comment to review")
    try t.wait("Normal · Diff")
    try t.wait("Pending review · LEFT:5")
    try t.wait("Normal · Diff")
    t.key("f")
    try t.wait("Filters and presets")
    try t.wait("review-requested:@me")
    t.key("is:open")
    try t.click("Preset name")
    t.key("My review queue")
    try t.click("Save preset")
    try t.wait("▸ My review queue")
    try t.snapshot("presets")
    try t.click("Apply")
    try t.wait("Normal · Diff")
    t.key("q")
    try t.finish()

    let reopened = try PTY(
      binary: binary,
      arguments: ["--demo", "--language", "en", "--files-view", "list"],
      environment: env,
      artifacts: artifacts.appendingPathComponent("reopened"),
    )
    defer { reopened.close() }
    try reopened.wait("Normal · Pull requests")
    try reopened.wait("Ready")
    try reopened.focusPane(2)
    try reopened.wait("Sources/ReviewQueue.swift")
    try expect(!reopened.text.contains("▾ Sources"), "List configuration still rendered a directory tree.")
    try reopened.focusPane(1)
    reopened.key("f")
    try reopened.wait("My review queue")
    try reopened.click("My review queue")
    try reopened.wait("▸ My review queue")
    try reopened.click("Apply")
    try reopened.wait("Normal · Pull requests")
    reopened.key("q")
    try reopened.finish()
    print(
      "Swift PTY: tree/list configuration, active borders, Shift-V ranges, both source sides, review preview and persistent presets passed; no forge writes."
    )
  }

  static func readProbe(_ binary: URL, directory: URL, repository: String, artifacts: URL) throws {
    let fm = FileManager.default
    let isolated = fm.temporaryDirectory.appendingPathComponent("tatara-read-probe-\(UUID())")
    try fm.createDirectory(at: isolated, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: isolated) }
    let start = ProcessInfo.processInfo.systemUptime
    let t = try PTY(
      binary: binary,
      arguments: ["--repo", repository, "--language", "en", "--wrap", "on"],
      columns: 176,
      rows: 40,
      environment: [
        "XDG_DATA_HOME": isolated.appendingPathComponent("data").path,
        "XDG_CACHE_HOME": isolated.appendingPathComponent("cache").path,
      ],
      cwd: directory,
      artifacts: artifacts,
      animated: true,
    )
    defer { t.close() }
    var events = [[String: Any]]()
    try t.waitUntil("populated live PR list", timeout: 60) {
      t.line(2).contains("Pull requests ·") && !t.line(2).contains("0/0")
    }
    events.append(["stage": "list", "ms": (ProcessInfo.processInfo.systemUptime - start) * 1000])
    try t.waitUntil("initial live overview", timeout: 60) { t.line(-2).contains("Ready") || t.line(-2).contains("L · Load more") }
    events.append(["stage": "overview", "ms": (ProcessInfo.processInfo.systemUptime - start) * 1000])
    if
      let index = CommandLine.arguments.firstIndex(of: "--item"),
      CommandLine.arguments.indices.contains(index + 1),
      let number = Int(CommandLine.arguments[index + 1])
    {
      t.key("gg")
      for _ in 0 ..< 100 {
        if t.selectedFixtureIndex(files: false) == number - 1 {
          break
        }
        let previous = t.selectedFixtureIndex(files: false)
        t.key("j")
        try t.waitUntil("next live PR selection") { t.selectedFixtureIndex(files: false) != previous }
      }
      try expect(t.selectedFixtureIndex(files: false) == number - 1, "The pinned live PR was not in the loaded page.")
      try t.waitUntil("pinned live PR overview", timeout: 60) {
        t.line(-2).contains("Ready") || t.line(-2).contains("L · Load more")
      }
    }
    func select(_ key: String, name: String, expectedRow: Int?) throws {
      let previous = t.line(2)
      let sent = ProcessInfo.processInfo.systemUptime
      t.key(key)
      try t.waitUntil(name, timeout: 90) {
        t.line(2) != previous && (t.line(-2).contains("Ready") || t.line(-2).contains("L · Load more"))
          && t.line(-2).contains("· Wrap")
          && (expectedRow.map(t.selectedFileRow) ?? true)
      }
      events.append(["stage": name, "ms": (ProcessInfo.processInfo.systemUptime - sent) * 1000])
    }
    try select("\r", name: "first-diff", expectedRow: nil)
    try select("j", name: "second-diff", expectedRow: 1)
    try select("k", name: "cached-first-diff", expectedRow: 0)
    t.key("q")
    try t.finish()
    let report: [String: Any] = try [
      "binary_sha256": SHA256.hash(data: Data(contentsOf: binary)).map { String(format: "%02x", $0) }.joined(),
      "events": events,
      "isolated_cache": true,
      "columns": 176,
      "rows": 40,
    ]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      .write(to: artifacts.appendingPathComponent("latency.json"), options: .atomic)
    print(String(decoding: try JSONSerialization.data(withJSONObject: events, options: [.sortedKeys]), as: UTF8.self))
    print("Swift PTY: live cold-cache list, overview, two immutable file diffs and cached revisit passed; no forge writes.")
  }

  static func live(_ binary: URL, directory: URL, item: String, artifacts: URL, columns: Int = 176, rows: Int = 40) throws {
    let t = try PTY(
      binary: binary,
      arguments: ["--language", "en"],
      columns: columns,
      rows: rows,
      cwd: directory,
      artifacts: artifacts,
    )
    defer { t.close() }
    try t.wait("Pull requests")
    t.read(for: 1)
    t.key("/\(item)\r")
    try t.wait("#\(item)")
    t.key("\u{1B}")
    try t.wait("Normal · Pull requests")
    var times = [Double]()
    func exerciseFocus(_ labels: [(String, String)]) throws {
      let deadline = ProcessInfo.processInfo.systemUptime + 4
      repeat {
        for (key, label) in labels {
          let start = ProcessInfo.processInfo.systemUptime
          try t.navigationKey(key)
          try t.wait(label)
          times.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        }
      } while ProcessInfo.processInfo.systemUptime < deadline
    }
    try exerciseFocus([("2", "Normal · Files"), ("1", "Normal · Pull requests")])
    try t.wait("Ready")
    try bounds(t, sidebar: "Pull requests ·")
    try t.snapshot("overview")
    try t.focusPane(2)
    t.key("\r")
    try t.focusPane(3)
    try t.wait("Normal · Diff")
    try exerciseFocus([("1", "Normal · Pull requests"), ("2", "Normal · Files"), ("3", "Normal · Diff")])
    try t.wait("Ready", timeout: 60)
    try t.snapshot("diff")
    t.key("[")
    try t.focusPane(3)
    try t.wait("Normal · Overview")
    t.key("\u{6}")
    try t.waitUntil("main paging") { position(t) > 1 }
    t.key("?")
    try t.wait("Previous pane")
    t.key("/ctrl-f\r")
    try t.wait("Page down in content")
    try t.snapshot("help")
    t.key("\u{1B}")
    try t.wait("Normal · Help")
    t.key("\u{1B}")
    try t.wait("Normal · Overview")
    t.key("q")
    try t.finish()
    let sorted = times.sorted()
    let metrics: [String: Any] = [
      "focus_median_ms": sorted[sorted.count / 2],
      "focus_max_ms": sorted.last!,
      "samples": times.count,
    ]
    let data = try JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys])
    try data.write(to: artifacts.appendingPathComponent("latency.json"))
    print(String(decoding: data, as: UTF8.self))
    print("Swift PTY: live repository detection, overview, diff, focus, paging and help passed; no writes.")
  }

  static func listSearch(_ t: PTY, artifacts: URL, requests: URL) throws {
    try t.wait("Ready")
    var samples = [[String: Any]]()
    func typeQuery(_ query: String, files: Bool, expected: Int) throws {
      let before = try String(contentsOf: requests, encoding: .utf8)
      t.key("/")
      try t.wait(files ? "Find file paths (regex)" : "Find loaded items (regex)")
      var typed = ""
      var lastInputAt = ProcessInfo.processInfo.systemUptime
      for character in query {
        typed.append(character)
        let start = ProcessInfo.processInfo.systemUptime
        lastInputAt = start
        t.key(String(character))
        try t.waitUntil("incremental query feedback") { t.line(-2).contains("/" + typed + "▏") }
        samples.append([
          "stage": files ? "file-query" : "pr-query",
          "latency_ms": (ProcessInfo.processInfo.systemUptime - start) * 1000,
        ])
      }
      try t
        .waitUntil("incremental match selection") { t.selectedFixtureIndex(files: files) == expected && t.line(-2).contains("/3")
        }
      samples.append([
        "stage": files ? "file-result-ready" : "pr-result-ready",
        "latency_ms": (ProcessInfo.processInfo.systemUptime - lastInputAt) * 1000,
      ])
      try expect(try String(contentsOf: requests, encoding: .utf8) == before, "Incremental list search started provider work.")
      try expect(t.text.contains(files ? "Files · 120/120" : "Pull requests · 100/100"), "Incremental search filtered its list.")
      try t.screenshot(files ? "file-preview" : "pr-preview")
    }
    try typeQuery("#(10|30|50) ", files: false, expected: 9)
    t.key("\u{1B}")
    try t.waitUntil("cancel restores PR cursor") { t.selectedFixtureIndex(files: false) == 0 && t.line(-2).contains("Normal") }
    try t.focusPane(2)
    let preparationStart = ProcessInfo.processInfo.systemUptime
    t.key("\r")
    try t.wait("Normal · Diff")
    try t.focusPane(2)
    try t.wait("Ready", timeout: 60)
    samples.append(["stage": "first-file-ready", "latency_ms": (ProcessInfo.processInfo.systemUptime - preparationStart) * 1000])
    try typeQuery("File(10|30|50)[.]swift$", files: true, expected: 10)
    t.resize(columns: 240, rows: 48)
    try t.waitUntil("search survives resize") { t.selectedFixtureIndex(files: true) == 10 && t.line(-2).contains("/3") }
    t.key("\r")
    try t.waitUntil("search confirmed") { !t.line(-2).contains("▏") && t.line(-2).contains("Find · Files") }
    try t.wait("Ready", timeout: 60)
    for _ in 0..<8 {
      for (key, expected) in [("n", 30), ("n", 50), ("n", 10), ("N", 50), ("N", 30), ("N", 10)] {
        let start = ProcessInfo.processInfo.systemUptime
        t.key(key)
        try t.waitUntil("search navigation") { t.selectedFixtureIndex(files: true) == expected }
        samples.append(["stage": "file-next-previous", "latency_ms": (ProcessInfo.processInfo.systemUptime - start) * 1000])
      }
    }
    let finalPreparationStart = ProcessInfo.processInfo.systemUptime
    try t.wait("Ready", timeout: 60)
    samples.append([
      "stage": "final-file-ready-tail",
      "latency_ms": (ProcessInfo.processInfo.systemUptime - finalPreparationStart) * 1000,
    ])
    t.key("\u{1B}")
    try t.wait("Normal · Files")
    t.key("q")
    try t.finish()
    var report: [String: Any] = [
      "samples": samples,
      "fixture": "100 loaded PRs, 120 files, 320x64 then 240x48; no preview requests during incremental typing; repeated file n/N with normal provider preparation and caches.",
    ]
    for stage in Set(samples.compactMap { $0["stage"] as? String }) {
      let values = samples.filter { $0["stage"] as? String == stage }.compactMap { $0["latency_ms"] as? Double }.sorted()
      report[stage] = [
        "count": values.count,
        "p95_ms": values[Int(ceil(Double(values.count) * 0.95)) - 1],
        "max_ms": values.last!,
      ]
    }
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(
      to: artifacts.appendingPathComponent("latency.json"),
      options: .atomic,
    )
    print(
      "Swift PTY: incremental PR/file search, complete lists, cancellation, resize, wrapping n/N and provider isolation passed."
    )
  }

  static func workspace(
    _ binary: URL,
    stress: Bool,
    artifacts: URL,
    profile: Bool = false,
    columns: Int = 176,
    rows: Int = 40,
    navigation: Bool = false,
  ) throws {
    let fm = FileManager.default
    let fixture = fm.temporaryDirectory.appendingPathComponent("tatara-smoke-\(UUID())")
    let initialSnapshotGate = fixture.appendingPathComponent("initial-snapshot.gate")
    try fm.createDirectory(at: fixture, withIntermediateDirectories: false)
    defer {
      do {
        let log = fixture.appendingPathComponent("requests.log")
        if fm.fileExists(atPath: log.path) {
          try fm.createDirectory(at: artifacts, withIntermediateDirectories: true)
          try Data(contentsOf: log).write(to: artifacts.appendingPathComponent("requests.log"), options: .atomic)
        }
      } catch {
        FileHandle.standardError.write(Data("Could not preserve fixture request log: \(error)\n".utf8))
      }
      try? fm.removeItem(at: fixture)
    }
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    try fm.createSymbolicLink(at: fixture.appendingPathComponent("gh"), withDestinationURL: executable)
    if stress {
      try fm.createSymbolicLink(at: fixture.appendingPathComponent("difft"), withDestinationURL: executable)
    }
    var env = [
      "PATH": fixture.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? ""),
      "TATARA_SMOKE_FIXTURE": fixture.path,
      "TATARA_SMOKE_STRESS": stress ? "1" : "0",
      "TATARA_SMOKE_INITIAL_SNAPSHOT_GATE": stress ? "" : initialSnapshotGate.path,
      "TATARA_SMOKE_WIDE": CommandLine.arguments.contains("--wide-lines") ? "1" : "0",
      "TATARA_SMOKE_SHORT_SOURCE": CommandLine.arguments.contains("--wheel-boundary") ? "1" : "0",
      "TATARA_SMOKE_DENSE": CommandLine.arguments.contains("--dense-navigation") || CommandLine.arguments
        .contains("--wheel") ? "1" : "0",
      "XDG_DATA_HOME": fixture.appendingPathComponent("data").path,
      "XDG_CACHE_HOME": fixture.appendingPathComponent("cache").path,
    ]
    if profile {
      env.merge(profilingEnvironment(artifacts)) { _, new in new }
    }
    if !stress {
      try fm.createDirectory(at: initialSnapshotGate, withIntermediateDirectories: false)
    }
    let t = try PTY(
      binary: binary,
      arguments: ["--repo", "example/reviews", "--language", "en"],
      columns: columns,
      rows: rows,
      environment: env,
      artifacts: artifacts,
      recordPreview: CommandLine.arguments.contains("--record-preview"),
    )
    defer { t.close() }
    try t.wait("Pull requests")
    try t.wait("Long overview")
    if CommandLine.arguments.contains("--list-search") {
      try listSearch(t, artifacts: artifacts, requests: fixture.appendingPathComponent("requests.log"))
      return
    }
    if CommandLine.arguments.contains("--wheel-boundary") {
      try wheelBoundary(t, binary: binary, artifacts: artifacts)
      return
    }
    if CommandLine.arguments.contains("--wheel-reversal") {
      try wheelReversal(t, binary: binary, artifacts: artifacts)
      return
    }
    if CommandLine.arguments.contains("--wheel") {
      try wheelAxes(t)
      return
    }
    if navigation {
      try profileNavigation(t, binary: binary, artifacts: artifacts, requestLog: fixture.appendingPathComponent("requests.log"))
      return
    }
    if stress {
      try t.wait("Loading details")
      let sampler = Process()
      let sampling = profile && CommandLine.arguments.contains("--sample")
      if sampling {
        sampler.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        sampler.arguments = [String(t.pid), "12", "1", "-file", artifacts.appendingPathComponent("cpu.sample.txt").path]
        sampler.standardOutput = FileHandle.nullDevice
        sampler.standardError = FileHandle.nullDevice
        try sampler.run()
      }
      defer {
        if sampling {
          sampler.waitUntilExit()
        }
      }
      var times = [Double]()
      let focusDeadline = ProcessInfo.processInfo.systemUptime + 7
      repeat {
        for (key, label) in [("2", "Normal · Files"), ("1", "Normal · Pull requests")] {
          let start = ProcessInfo.processInfo.systemUptime
          try t.navigationKey(key)
          try t.wait(label)
          times.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        }
      } while
        ProcessInfo.processInfo.systemUptime < focusDeadline
      try t.wait("Ready", timeout: 60)
      try t.focusPane(2)
      t.key("\r")
      try t.focusPane(3)
      try t.wait("Loading diff")
      if !profile {
        try t.snapshot("loading-diff")
      }
      let diffDeadline = ProcessInfo.processInfo.systemUptime + 6
      repeat {
        for (key, label) in [("1", "Normal · Pull requests"), ("2", "Normal · Files"), ("3", "Normal · Diff")] {
          let start = ProcessInfo.processInfo.systemUptime
          try t.navigationKey(key)
          try t.wait(label)
          times.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        }
      } while
        ProcessInfo.processInfo.systemUptime < diffDeadline
      try t.wait("Ready", timeout: 60)
      try t.focusPane(2)
      try t.wait("Normal · Files")
      t.key("j")
      try t.wait("Loading diff")
      try t.wait("Ready", timeout: 60)
      let sorted = times.sorted()
      var result: [String: Any] = try [
        "focus_median_ms": sorted[sorted.count / 2],
        "focus_max_ms": sorted.last!,
        "focus_p95_ms": sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))],
        "samples": times.count,
        "columns": columns,
        "rows": rows,
        "cpu_sampling": sampling,
        "diagnostics": env["TATARA_INPUT_TRACE"] != nil,
        "binary_sha256": SHA256.hash(data: Data(contentsOf: binary, options: .mappedIfSafe))
          .map { String(format: "%02x", $0) }.joined(),
        "os": ProcessInfo.processInfo.operatingSystemVersionString,
      ]
      if profile {
        try t.focusPane(3)
        try t.wait("Normal · Diff")
        try t.waitUntil("settled diff viewport", timeout: 60) {
          t.line(-2).contains("Ready") && t.text.contains("let value = 2") && position(t) == 1
        }
        var scrollTimes = [Double]()
        try t.snapshot("before-scroll")
        for step in 0 ..< 20 {
          for (key, moved) in [("\u{6}", true), ("\u{2}", false)] {
            let start = ProcessInfo.processInfo.systemUptime
            try t.navigationKey(key)
            try t
              .waitUntil("profile main scrolling \(moved ? "down" : "up") \(step)") { moved ? position(t) > 1 : position(t) == 1 }
            scrollTimes.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
          }
        }
        let sorted = scrollTimes.sorted()
        result["scroll_median_ms"] = sorted[sorted.count / 2]
        result["scroll_p95_ms"] = sorted[Int(Double(sorted.count) * 0.95)]
        result["scroll_max_ms"] = sorted.last!
        result["scroll_samples"] = sorted.count
      }
      try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
        .write(to: artifacts.appendingPathComponent("latency.json"))
      try print(String(decoding: JSONSerialization.data(withJSONObject: result, options: .sortedKeys), as: UTF8.self))
      try bounds(t)
      t.key("q")
      try t.finish()
      if sampling {
        sampler.waitUntilExit()
        try expect(sampler.terminationStatus == 0, "CPU sampling failed.")
        try expect(
          fm.fileExists(atPath: artifacts.appendingPathComponent("cpu.sample.txt").path),
          "CPU sample output is missing.",
        )
      }
      if profile, env["SWIFTTUI_DIAGNOSTICS"] != nil {
        try summarizeFrames(artifacts)
      }
      print("Swift PTY: focus during large PR preparation and an in-flight diff passed.")
      return
    }
    try t.wait("BODY 0000")
    try t.wait("Ready")
    try bounds(t, sidebar: "Pull requests ·")
    t.wheel(column: 100, row: 10, down: true, count: 3)
    try t.waitUntil("main wheel scrolling") { position(t) > 1 }
    try expect(t.text.contains("Normal · Pull requests"), "Wheel scrolling stole keyboard focus.")
    t.wheel(column: 100, row: 10, down: false, count: 3)
    try t.waitUntil("main wheel top boundary") { position(t) == 1 }
    let overviewTitle = t.line(2)
    t.wheel(column: 10, row: 7, down: true)
    t.wheel(column: 10, row: 25, down: true)
    t.read(for: 0.2)
    try expect(t.line(2) == overviewTitle && t.text.contains("BODY 0000"), "Sidebar wheel changed the selected PR or file.")
    try expect(t.text.contains("Normal · Pull requests"), "Sidebar wheel stole keyboard focus.")
    t.key("\u{6}")
    try t.waitUntil("sidebar paging") { position(t) > 1 }
    t.key("\u{2}")
    try t.waitUntil("first page") { position(t) == 1 }
    t.key("/Long\r")
    try t.wait("Find · Pull requests")
    t.key("\u{1B}")
    try t.wait("Normal · Pull requests")
    func waitForPreparedDiff(_ terminal: PTY, path: String) throws {
      try terminal.waitUntil("prepared immutable diff for \(path)") {
        String(terminal.line(2).dropFirst(terminal.sidebarWidth + 1)).contains(path)
          && terminal.line(-2).contains("Ready") && terminal.text.contains("let value = 2")
      }
    }
    try t.focusPane(2)
    try t.waitUntil("initial file row selected") { t.selectedFixtureIndex(files: true) == 0 }
    t.key("\r")
    try t.focusPane(2)
    try t.waitUntil("initial snapshot request started") {
      fm.fileExists(atPath: initialSnapshotGate.appendingPathComponent("waiting").path)
    }
    // Latch release before waking readers so a canceled/replaced producer cannot miss it.
    try Data([1]).write(to: initialSnapshotGate.appendingPathComponent("released"), options: .atomic)
    for pipe in try fm.contentsOfDirectory(at: initialSnapshotGate, includingPropertiesForKeys: nil)
      where pipe.pathExtension == "fifo"
    {
      let release = Darwin.open(pipe.path, O_RDWR | O_NONBLOCK)
      try expect(release >= 0, "Could not release initial snapshot response.")
      var token: UInt8 = 1
      let released = Darwin.write(release, &token, 1)
      Darwin.close(release)
      try expect(released == 1, "Initial snapshot response was not released.")
    }
    try waitForPreparedDiff(t, path: "Sources/File0.swift")
    t.key("/Tests/File1[.]swift$\r")
    try t.wait("Find · Files")
    try t.wait("Files · 12/12")
    try waitForPreparedDiff(t, path: "Tests/File1.swift")
    t.key("\u{1B}")
    try t.wait("Normal · Files")
    t.key("[")
    try t.wait("BODY 0000")
    try t.focusPane(3)
    t.key("/TARGET\r")
    try t.wait("Find · Overview")
    try t.wait("BODY 0250")
    t.key("n")
    try t.wait("BODY 0350")
    t.key("N")
    try t.wait("BODY 0250")
    t.key("\u{1B}")
    try t.wait("Normal · Overview")
    t.key("?")
    try t.wait("Previous pane")
    try bounds(t)
    t.wheel(column: 80, row: 15, down: true, count: 12)
    try t.waitUntil("help wheel scrolling") { !t.text.contains("Previous pane") }
    t.wheel(column: 80, row: 15, down: false, count: 12)
    try t.wait("Previous pane")
    try t.snapshot("help")
    t.key("/ctrl-f\r")
    try t.wait("Page down in content")
    t.key("\u{1B}")
    try t.wait("Normal · Help")
    t.key("\u{1B}")
    try t.wait("Normal · Overview")
    try t.snapshot("overview")
    // The content indicator occupies the trailing border, away from the corners.
    t.mouse(column: 176, row: 35, pressed: true)
    t.mouse(column: 176, row: 35, pressed: false)
    try t.waitUntil("scrollbar navigation") { position(t) > 500 }
    t.resize(columns: 90, rows: 28)
    try t.wait("Normal · Overview")
    try t.snapshot("compact")
    t.key("q")
    try t.finish()
    let log = fixture.appendingPathComponent("requests.log")
    func repositoryRequests() throws -> Int {
      try String(contentsOf: log, encoding: .utf8).split(separator: "\n").count(where: { $0.hasPrefix("gh repos/") })
    }
    let before = try repositoryRequests()
    let coldRequests = try String(contentsOf: log, encoding: .utf8)
    try coldRequests.write(to: artifacts.appendingPathComponent("requests-cold.log"), atomically: true, encoding: .utf8)
    let warm = try PTY(
      binary: binary,
      arguments: ["--repo", "example/reviews", "--language", "en"],
      environment: env,
      artifacts: artifacts.appendingPathComponent("warm"),
    )
    defer { warm.close() }
    try warm.wait("BODY 0000")
    try warm.wait("Ready")
    try warm.focusPane(2)
    try warm.waitUntil("warm initial file row selected") { warm.selectedFixtureIndex(files: true) == 0 }
    warm.key("\r")
    try warm.focusPane(2)
    try waitForPreparedDiff(warm, path: "Sources/File0.swift")
    warm.key("/Tests/File1[.]swift$\r")
    try warm.wait("Find · Files")
    try waitForPreparedDiff(warm, path: "Tests/File1.swift")
    let warmRequests = try String(contentsOf: log, encoding: .utf8)
    try warmRequests.write(to: artifacts.appendingPathComponent("requests-warm.log"), atomically: true, encoding: .utf8)
    let additional = warmRequests.dropFirst(coldRequests.count)
    try expect(
      try repositoryRequests() == before,
      "Warm restart repeated repository API calls (before=\(before)):\n\(additional)",
    )
    warm.key("q")
    try warm.finish()
    print("Swift PTY: pane search, popup, mouse wheel, scrollbar, paging, resize and Escape passed.")
    print("Swift PTY: persistent cache reused metadata, snapshots and diff across processes.")
  }

  static func wheelBoundary(_ t: PTY, binary: URL, artifacts: URL) throws {
    try t.wait("File0.swift", timeout: 60)
    try t.focusPane(2)
    t.key("\r")
    try t.focusPane(3)
    try t.waitUntil("short diff prepared", timeout: 60) {
      t.line(2).contains("Diff") && t.line(-2).contains("/81") && t.line(-2).contains("Ready")
    }
    let bottom = max(1, 81 - (t.rows - 6) + 1)
    func cursorStatus() -> String? {
      t.line(-2).components(separatedBy: "RIGHT · ").dropFirst().first?.split(separator: " ").first.map(String.init)
    }
    guard let originalCursor = cursorStatus() else { throw SmokeError("Missing source cursor status.") }
    var measurements = [[String: Any]]()
    for downFirst in [true, false] {
      var frames = [(time: Double, offset: Int)]()
      t.onCompletedFrame = { frames.append(($0, position(t))) }
      let down = "\u{1B}[<65;100;10M"
      let up = "\u{1B}[<64;100;10M"
      let count = 240
      let start = ProcessInfo.processInfo.systemUptime
      let lastInput = try t.replay(
        Array(repeating: downFirst ? down : up, count: count)
          + Array(repeating: downFirst ? up : down, count: 6),
        interval: 0.001,
      )
      let reversed = t.lastReplayInputTimes[count]
      let boundary = downFirst ? bottom : 1
      let expected = downFirst ? max(1, bottom - 18) : min(bottom, 19)
      try t.waitUntil("reversed away from boundary", timeout: 60) { position(t) == expected }
      t.onCompletedFrame = nil
      guard
        let reached = frames.first(where: { $0.offset == boundary }),
        reached.time <= reversed,
        let firstReverse = frames.first(where: { $0.time >= reversed && (downFirst ? $0.offset < bottom : $0.offset > 1) })
      else { throw SmokeError("The wheel replay did not reach its boundary before reversal.") }
      measurements.append([
        "boundary": downFirst ? "bottom" : "top",
        "initial_direction_events": count,
        "boundary_before_reverse_ms": (reversed - reached.time) * 1000,
        "first_reverse_frame_ms": (firstReverse.time - reversed) * 1000,
        "tail_after_last_input_ms": max(0, ((frames.last?.time ?? lastInput) - lastInput) * 1000),
        "frames": frames.map { ["at_ms": ($0.time - start) * 1000, "offset": Double($0.offset)] },
      ])
      try expect(t.keyboardPane == 3 && cursorStatus() == originalCursor, "Boundary wheel changed focus or source cursor.")
    }
    let result: [String: Any] = try [
      "binary_sha256": SHA256.hash(data: Data(contentsOf: binary)).map { String(format: "%02x", $0) }.joined(),
      "columns": t.columns,
      "rows": t.rows,
      "measurements": measurements,
    ]
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
      .write(to: artifacts.appendingPathComponent("boundary.json"))
    for var m in measurements {
      m["frames"] = nil
      try print(String(decoding: JSONSerialization.data(withJSONObject: m, options: [.sortedKeys]), as: UTF8.self))
    }
    t.key("q")
    try t.finish()
  }

  static func wheelReversal(_ t: PTY, binary: URL, artifacts: URL) throws {
    try t.wait("File0.swift", timeout: 60)
    try t.focusPane(2)
    t.key("\r")
    try t.focusPane(3)
    try t.wait("25001", timeout: 60)
    try t
      .waitUntil("prepared reversal document", timeout: 60) {
        position(t) == 1 && (t.line(-2).contains("Ready") || t.line(-2).contains("L · Load more"))
      }
    var measurements = [[String: Any]]()
    let repetitions = CommandLine.arguments.firstIndex(of: "--reversal-repetitions").flatMap { index in
      CommandLine.arguments.indices.contains(index + 1) ? Int(CommandLine.arguments[index + 1]) : nil
    } ?? 1
    try expect((1 ... 10).contains(repetitions), "Reversal repetitions must be between 1 and 10.")
    for (trial, interval) in (0 ..< repetitions).flatMap({ trial in [0.001, 0.004, 0.012].map { (trial, $0) } }) {
      var frames = [(time: Double, offset: Int)]()
      t.onCompletedFrame = { time in frames.append((time, position(t))) }
      let count = 60
      let down = "\u{1B}[<65;100;10M"
      let up = "\u{1B}[<64;100;10M"
      let initial = ProcessInfo.processInfo.systemUptime
      let lastSent = try t.replay(Array(repeating: down, count: count) + Array(repeating: up, count: count), interval: interval)
      let reversed = t.lastReplayInputTimes[count]
      try t.waitUntil("reversal returned to top", timeout: 60) { position(t) == 1 }
      t.onCompletedFrame = nil
      let atReversal = frames.last(where: { $0.time <= reversed })?.offset ?? 1
      var previous = atReversal
      var firstReverse: Double?
      var wrongDirectionFrames = 0
      for frame in frames where frame.time >= reversed {
        if frame.offset > previous {
          wrongDirectionFrames += 1
        }
        if firstReverse == nil, frame.offset < previous {
          firstReverse = frame.time
        }
        previous = frame.offset
      }
      guard let firstReverse else { throw SmokeError("No reversed scrolling frame was observed.") }
      measurements.append([
        "trial": trial + 1,
        "interval_ms": interval * 1000,
        "events_each_direction": count,
        "offset_when_reversed": atReversal,
        "first_reverse_frame_ms": (firstReverse - reversed) * 1000,
        "old_direction_frames_after_reversal": wrongDirectionFrames,
        "tail_after_last_input_ms": max(0, ((frames.last?.time ?? lastSent) - lastSent) * 1000),
        "frames": frames.map { ["at_ms": ($0.time - initial) * 1000, "offset": Double($0.offset)] },
        "reverse_input_at_ms": (reversed - initial) * 1000,
      ])
      try expect(t.keyboardPane == 3, "Wheel reversal changed focus.")
    }
    let result: [String: Any] = try [
      "binary_sha256": SHA256.hash(data: Data(contentsOf: binary)).map { String(format: "%02x", $0) }.joined(),
      "columns": t.columns,
      "rows": t.rows,
      "measurements": measurements,
    ]
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
      .write(to: artifacts.appendingPathComponent("reversal.json"))
    for var measurement in measurements {
      measurement["frames"] = nil
      try print(String(decoding: JSONSerialization.data(withJSONObject: measurement, options: [.sortedKeys]), as: UTF8.self))
    }
    let down = "\u{1B}[<65;100;10M"
    let up = "\u{1B}[<64;100;10M"
    t.key(String(repeating: down, count: 60) + "\t" + String(repeating: up, count: 60))
    try t.waitUntil("wheel and keyboard barrier preserved") { t.keyboardPane == 1 && position(t) == 1 }
    t.key("q")
    try t.finish()
  }

  static func wheelAxes(_ t: PTY) throws {
    try t.wait("Pull requests · 100/100", timeout: 60)
    try t.wait("A large paragraph")
    var failures = [String]()
    for pane in 1 ... 3 {
      try t.focusPane(pane)
      if pane == 3 {
        try t.wait("25001")
      }
      let column = pane == 3 ? 100 : 10
      let row = pane == 2 ? 25 : 10
      func current() -> Int? {
        pane == 3 ? position(t) : t.visibleFixtureIndices(files: pane == 2).first
      }
      if pane == 2 {
        try t.waitUntil("file list after PR reversal") { current() != nil && t.text.contains("Files · 120/120") }
      }
      try t.waitUntil("prepared wheel target", timeout: 60) {
        !t.line(-2).contains("Loading") && !t.line(-2).contains("Preparing")
      }
      let focusedPane = t.keyboardPane
      func documentHeader() -> String {
        String(t.line(2).dropFirst(t.sidebarWidth + 1).dropLast())
      }
      let documentTitle = documentHeader()
      let cursorStatus = t.line(-2).components(separatedBy: "RIGHT · ").dropFirst().first?.split(separator: " ").first
        .map(String.init)
      t.wheel(column: column, row: row, down: true, count: 4)
      try t.waitUntil("wheel baseline in pane \(pane)") { (current() ?? 0) >= 12 }
      for slow in [true, false] {
        let before = current()
        // SGR 66/67 are horizontal wheel buttons; modifiers must retain that axis.
        for code in [66, 67, 70, 71, 82, 83] {
          t.key("\u{1B}[<\(code);\(column);\(row)M")
          if slow {
            t.read(for: 0.12)
          }
          if slow, current() != before {
            failures
              .append("pane \(pane), horizontal code \(code): \(String(describing: before)) -> \(String(describing: current()))")
          }
        }
        t.read(for: 0.2)
        if current() != before {
          failures.append("pane \(pane), horizontal burst changed position")
        }
        let start = current()!
        for _ in 0 ..< 4 {
          t.key("\u{1B}[<65;\(column);\(row)M\u{1B}[<66;\(column);\(row)M")
          if slow {
            t.read(for: 0.12)
          }
        }
        t.read(for: 0.2)
        if
          current() != start +
          12
        {
          failures.append("pane \(pane), mixed downward wheel: expected \(start + 12), got \(String(describing: current()))")
        }
        t.wheel(column: column, row: row, down: false, count: 4)
        t.read(for: 0.2)
        if current() != start {
          failures.append("pane \(pane), upward wheel did not return to baseline")
        }
      }
      try expect(t.keyboardPane == focusedPane, "Wheel input changed keyboard focus.")
      try expect(documentHeader() == documentTitle, "Wheel input changed the selected PR/file or prepared document.")
      if pane == 3 {
        let currentCursor = t.line(-2).components(separatedBy: "RIGHT · ").dropFirst().first?.split(separator: " ").first
          .map(String.init)
        try expect(currentCursor == cursorStatus, "Wheel input moved the Diff source cursor.")
      }
      if pane < 3 {
        let files = pane == 2
        let baseline = files ? 60 : 20
        t.key("gg" + String(repeating: "j", count: baseline))
        try t.waitUntil("sidebar reversal baseline") { t.selectedFixtureIndex(files: files) == baseline }
        let first = t.visibleFixtureIndices(files: files).min()!
        try expect(first > 0, "Sidebar reversal must start away from the top boundary.")
        for selected in stride(from: baseline - 1, through: first + 2, by: -1) {
          t.key("k")
          try t.waitUntil("sidebar upward selection \(selected)") { t.selectedFixtureIndex(files: files) == selected }
          if t.visibleFixtureIndices(files: files).min() != first {
            failures.append("pane \(pane), viewport moved before the upper context margin")
          }
        }
        t.key("k")
        try t.waitUntil("sidebar upper margin crossed") { t.selectedFixtureIndex(files: files) == first + 1 }
        if t.visibleFixtureIndices(files: files).min() != first - 1 {
          failures.append("pane \(pane), crossing upper margin did not scroll one row")
        }
        t.key("j")
        try t.waitUntil("sidebar downward reversal") { t.selectedFixtureIndex(files: files) == first + 2 }
        if t.visibleFixtureIndices(files: files).min() != first - 1 {
          failures.append("pane \(pane), downward reversal moved the viewport inside its margins")
        }
      }
      try t.snapshot("pane-\(pane)")
    }
    try expect(failures.isEmpty, failures.joined(separator: "\n"))
    t.key("q")
    try t.finish()
    print(
      "Swift PTY: independent viewport scrolling, preserved pane focus and source cursor, wheel axes, and keyboard selection margins passed."
    )
  }

  static func position(_ t: PTY) -> Int {
    let pattern = try! NSRegularExpression(pattern: #"(\d+)–\d+/\d+"#)
    let text = t.line(-2)
    guard let match = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let range = Range(
      match.range(at: 1),
      in: text,
    ) else { return 0 }
    return Int(text[range]) ?? 0
  }

  static func profilingEnvironment(_ directory: URL) -> [String: String] {
    guard !CommandLine.arguments.contains("--no-diagnostics") else { return [:] }
    var environment = ["TATARA_INPUT_TRACE": directory.appendingPathComponent("input.tsv").path]
    // Retained only for comparisons against archived SwiftTUI executables.
    if CommandLine.arguments.contains("--legacy-frame-diagnostics") {
      environment["SWIFTTUI_DIAGNOSTICS"] = directory.appendingPathComponent("diagnostics.tsv").path
    }
    return environment
  }

  static func profileNavigation(
    _ t: PTY,
    binary: URL,
    artifacts: URL,
    itemNumbers: [String] = ["1", "2"],
    requestLog: URL? = nil,
  ) throws {
    var observations = [[String: Any]]()
    var skippedMeasurements = [String]()
    let rendererProbe = CommandLine.arguments.contains("--renderer-probe")
    try expect(
      !rendererProbe || requestLog != nil && ["--loading-burst", "--dense-navigation", "--directional-burst"]
        .allSatisfy(CommandLine.arguments.contains),
      "Renderer probe requires the dense directional loading fixture.",
    )
    func selectedPR(_ number: String) -> Bool {
      (0 ..< t.rows / 2).contains { row in
        let sidebar = String(t.line(row).prefix(t.sidebarWidth))
        return sidebar.dropFirst().hasPrefix("▸") && sidebar.contains("#\(number) ")
      }
    }
    let origin = ProcessInfo.processInfo.systemUptime
    let sampler = Process()
    let sampling = CommandLine.arguments.contains("--sample")
    func settled() throws {
      try t.waitUntil("settled selected document", timeout: 60) {
        (t.line(-2).contains("Ready") || t.line(-2).contains("L · Load more")) && position(t) > 0
      }
      try validateDocumentViewport(t, fixture: requestLog != nil)
    }
    func select(_ key: String, stage: String, _ selected: () -> Bool) throws {
      let start = ProcessInfo.processInfo.systemUptime
      try t.navigationKey(key)
      try t.waitUntil("\(stage) selection \(key)", selected)
      observations.append([
        "stage": stage,
        "key": key,
        "at_ms": (start - origin) * 1000,
        "latency_ms": (ProcessInfo.processInfo.systemUptime - start) * 1000,
        "status": t.line(-2).trimmingCharacters(in: .whitespaces),
      ])
      if stage.hasSuffix("warmup") {
        try settled()
        observations.append([
          "stage": stage + "-ready",
          "key": key,
          "at_ms": (start - origin) * 1000,
          "latency_ms": (ProcessInfo.processInfo.systemUptime - start) * 1000,
        ])
      }
    }
    func bursts(_ stage: String, scope: String) throws {
      guard CommandLine.arguments.contains("--burst") else { return }
      for interval in [0.025, 0.12] {
        for _ in 0 ..< 3 {
          let sent = try t.replay(Array(repeating: ["j", "k"], count: 8).flatMap(\.self) + ["?"], interval: interval)
          if !t.hasCompletedFrame(containing: "Previous pane") {
            try t.wait("Previous pane")
          }
          observations.append([
            "stage": "\(stage)-burst-\(Int(interval * 1000))ms",
            "key": "?",
            "at_ms": (sent - origin) * 1000,
            "latency_ms": (ProcessInfo.processInfo.systemUptime - sent) * 1000,
          ])
          t.key("\u{1B}")
          try t.wait("Normal · \(scope)")
        }
      }
    }
    func loadingBursts(_ stage: String, scope: String) throws {
      guard CommandLine.arguments.contains("--loading-burst") else { return }
      let directional = CommandLine.arguments.contains("--directional-burst")
      try expect(
        !directional || requestLog != nil && CommandLine.arguments.contains("--dense-navigation"),
        "Directional replay requires the dense synthetic fixture.",
      )
      for count in [8, 32, 64] {
        let start = ProcessInfo.processInfo.systemUptime
        let initialStatus = t.line(-2).trimmingCharacters(in: .whitespaces)
        var frames = [[String: Any]]()
        t.onCompletedFrame = { time in
          let selected: Int? =
            if requestLog != nil {
              t.selectedFixtureIndex(files: stage == "file")
            } else if stage == "pr" {
              itemNumbers.firstIndex { selectedPR($0) }
            } else {
              (0 ..< 2).first { t.selectedFileRow($0) }
            }
          frames.append([
            "at_ms": (time - start) * 1000,
            "selected_index": selected ?? -1,
          ])
        }
        let keys = directional
          ? Array(repeating: "j", count: count)
          : Array(repeating: ["j", "k"], count: count / 2).flatMap(\.self) + ["?"]
        let sent = try t.replay(keys, interval: 0.025)
        if directional {
          try t.waitUntil("all \(count) navigation inputs reflected") { t.selectedFixtureIndex(files: stage == "file") == count }
        } else if !t.hasCompletedFrame(containing: "Previous pane") {
          try t.wait("Previous pane")
        }
        let completed = ProcessInfo.processInfo.systemUptime
        t.onCompletedFrame = nil
        if directional {
          try t.requireSelectionContext(files: stage == "file", selected: count)
        }
        observations.append([
          "stage": "\(stage)-loading-burst-\(count)",
          "key": directional ? "j" : "?",
          "at_ms": (start - origin) * 1000,
          "sent_uptime_ms": sent * 1000,
          "input_count": count,
          "interval_ms": 25,
          "input_sent_ms": t.lastReplayInputTimes.map { ($0 - start) * 1000 },
          "replay_ms": (sent - start) * 1000,
          "total_ms": (completed - start) * 1000,
          "latency_ms": (completed - sent) * 1000,
          "initial_status": initialStatus,
          "frames": frames,
        ])
        if !directional {
          t.key("\u{1B}")
          try t.wait("Normal · \(scope)")
        }
        observations[observations.count - 1]["final_status"] = t.line(-2).trimmingCharacters(in: .whitespaces)
        try t.snapshot("\(stage)-loading-burst-\(count)")
        if directional {
          t.key("gg")
          try t.waitUntil("reset selection after directional replay") { t.selectedFixtureIndex(files: stage == "file") == 0 }
        }
      }
    }
    if CommandLine.arguments.contains("--viewport-check") {
      try settled()
      try t.focusPane(3)
      try t.wait("Normal · Overview")
      for size in [(80, 30), (160, 42), (104, 56)] {
        t.resize(columns: size.0, rows: size.1)
        try t.waitUntil("resized document and rendered viewport agree", timeout: 30) {
          let ready = t.line(-2).contains("Ready") || t.line(-2).contains("L · Load more")
          guard ready, position(t) > 0 else { return false }
          return (try? validateDocumentViewport(t, fixture: requestLog != nil)) != nil
        }
        try t.snapshot("viewport-\(size.0)x\(size.1)")
      }
      t.key("q")
      try t.finish()
      print("Verified initial viewport, resized document ranges, and continuous source text.")
      return
    }
    try loadingBursts("pr", scope: "Pull requests")
    if !rendererProbe {
      if CommandLine.arguments.contains("--cold-navigation") {
        for _ in 0 ..< 10 {
          try select("j", stage: "pr-cold") { selectedPR(itemNumbers[1]) }
          try select("k", stage: "pr-cold") { selectedPR(itemNumbers[0]) }
        }
      }
      try settled()
      try select("j", stage: "pr-warmup") { selectedPR(itemNumbers[1]) }
      try settled()
      try select("k", stage: "pr-warmup") { selectedPR(itemNumbers[0]) }
      try settled()
      if sampling {
        sampler.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        sampler.arguments = [String(t.pid), "20", "1", "-file", artifacts.appendingPathComponent("cpu.sample.txt").path]
        sampler.standardOutput = FileHandle.nullDevice
        sampler.standardError = FileHandle.nullDevice
        try sampler.run()
      }
      defer {
        if sampling {
          sampler.waitUntilExit()
        }
      }
      for _ in 0 ..< 4 {
        try select("j", stage: "pr-settled") { selectedPR(itemNumbers[1]) }
        try settled()
        try select("k", stage: "pr-settled") { selectedPR(itemNumbers[0]) }
        try settled()
      }
      for _ in 0 ..< 12 {
        try select("j", stage: "pr-inflight") { selectedPR(itemNumbers[1]) }
        t.read(for: 0.15)
        try select("k", stage: "pr-inflight") { selectedPR(itemNumbers[0]) }
        t.read(for: 0.15)
      }
      try bursts("pr", scope: "Pull requests")
    }
    try settled()
    if rendererProbe {
      try t.snapshot("settled-overview")
    }
    try t.focusPane(2)
    try t.wait("Normal · Files")
    t.key("\r")
    try t.focusPane(3)
    try t.wait("Normal · Diff")
    if CommandLine.arguments.contains("--loading-burst") {
      try t.focusPane(2)
      try t.wait("Normal · Files")
      try loadingBursts("file", scope: "Files")
      try t.focusPane(3)
      try t.wait("Normal · Diff")
    }
    if !rendererProbe {
      if CommandLine.arguments.contains("--cold-navigation") {
        try t.focusPane(2)
        try t.wait("Normal · Files")
        for _ in 0 ..< 10 {
          try select("j", stage: "file-cold") { t.selectedFileRow(1) }
          try select("k", stage: "file-cold") { t.selectedFileRow(0) }
        }
        try t.focusPane(3)
        try t.wait("Normal · Diff")
      }
      try settled()
      try t.focusPane(2)
      try t.wait("Normal · Files")
      try select("j", stage: "file-warmup") { t.selectedFileRow(1) }
      try settled()
      try select("k", stage: "file-warmup") { t.selectedFileRow(0) }
      try settled()
      for _ in 0 ..< 8 {
        try select("j", stage: "file-settled") { t.selectedFileRow(1) }
        try settled()
        try select("k", stage: "file-settled") { t.selectedFileRow(0) }
        try settled()
      }
      for _ in 0 ..< 12 {
        try select("j", stage: "file-inflight") { t.selectedFileRow(1) }
        t.read(for: 0.15)
        try select("k", stage: "file-inflight") { t.selectedFileRow(0) }
        t.read(for: 0.15)
      }
      try bursts("file", scope: "Files")
      try settled()
      if requestLog != nil {
        try t.focusPane(3)
        try t.wait("Normal · Diff")
        for _ in 0 ..< 8 {
          for key in ["j", "k"] {
            let previous = t.cursorLine()
            try select(key, stage: "diff-cursor") { t.cursorLine() != previous }
          }
        }
        let query = CommandLine.arguments.contains("--wide-lines") ? "source" : "value"
        for _ in 0 ..< 6 {
          try select("/" + query + "\r", stage: "diff-search") {
            t.line(-2).contains("Find · Diff") && t.line(-2).contains("1/") && !t.line(-2).contains("Finding")
          }
          t.key("\u{1B}")
          try t.wait("Normal · Diff")
        }
      }
    }
    try settled()
    if rendererProbe {
      let footer = t.line(-2)
      guard let rowCount = footer.split(separator: "/").last.flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) })
      else { throw SmokeError("Cannot read the document row count before paging.") }
      if rowCount > t.rows - 6 {
        for _ in 0 ..< 8 {
          let start = position(t)
          try select("\u{6}", stage: "diff-page") { position(t) > start }
          try select("\u{2}", stage: "diff-page") { position(t) == start }
        }
      } else {
        skippedMeasurements.append("diff-page: all \(rowCount) source rows fit in the viewport")
      }
      try t.snapshot("settled-diff")
    }
    t.key("q")
    try t.finish()
    if sampling {
      sampler.waitUntilExit()
      try expect(sampler.terminationStatus == 0, "CPU sampling failed.")
    }
    var result: [String: Any] = try [
      "samples": observations,
      "cpu_sampling": sampling,
      "columns": t.columns,
      "rows": t.rows,
      "preview_recording": CommandLine.arguments.contains("--record-preview"),
      "skipped_measurements": skippedMeasurements,
      "renderer": ProcessInfo.processInfo.environment["TATARA_PROBE_RENDERER"] ?? "termloom",
      "binary_sha256": SHA256.hash(data: Data(contentsOf: binary))
        .map { String(format: "%02x", $0) }.joined(),
    ]
    if let requestLog {
      let requests = try String(contentsOf: requestLog, encoding: .utf8)
      try requests.write(to: artifacts.appendingPathComponent("requests.log"), atomically: true, encoding: .utf8)
      result["requests"] = Dictionary(grouping: requests.split(separator: "\n").map(String.init), by: { $0 })
        .mapValues(\.count)
    }
    for stage in Set(observations.compactMap { $0["stage"] as? String }) {
      let values = observations.filter { $0["stage"] as? String == stage }.compactMap { $0["latency_ms"] as? Double }.sorted()
      result[stage] = [
        "median_ms": values[values.count / 2],
        "p95_ms": values[Int(Double(values.count) * 0.95)],
        "maximum_ms": values.last!,
      ]
    }
    let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: artifacts.appendingPathComponent("navigation.json"))
    if CommandLine.arguments.contains("--legacy-frame-diagnostics") {
      try summarizeFrames(artifacts)
    }
    result["samples"] = observations.count
    try print(String(decoding: JSONSerialization.data(withJSONObject: result, options: .sortedKeys), as: UTF8.self))
  }

  static func validateDocumentViewport(_ t: PTY, fixture: Bool) throws {
    let footer = t.line(-2)
    let expression = try NSRegularExpression(pattern: #"(\d+)–(\d+)/(\d+)"#)
    guard let match = expression.firstMatch(in: footer, range: NSRange(footer.startIndex..., in: footer)) else {
      throw SmokeError("Missing document range in the completed frame.")
    }
    let values = (1 ... 3).map { Int(footer[Range(match.range(at: $0), in: footer)!])! }
    let expectedEnd = min(values[2], values[0] + max(1, t.rows - 6) - 1)
    try expect(values[1] == expectedEnd, "Document model height does not match the rendered viewport.")
    guard fixture else { return }

    // Synthetic sidebar labels are ASCII, so these offsets also name terminal cells.
    let sidebarWidth = t.sidebarWidth
    let contentWidth = max(1, t.columns - sidebarWidth - 2)
    func content(_ row: Int) -> String {
      String(t.line(row).dropFirst(sidebarWidth + 1).prefix(contentWidth))
    }
    guard let paragraph = (0 ..< max(0, t.rows - 3)).first(where: {
      content($0).trimmingCharacters(in: .whitespaces).hasPrefix("A large paragraph with")
    }) else { return }
    let displayed = (paragraph ..< min(paragraph + 3, t.rows - 3)).map(content)
      .joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    let expected = String(repeating: "A large paragraph with source coordinates and searchable text. ", count: 16)
      .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    try expect(expected.hasPrefix(displayed), "The visible paragraph loses source text between wrapped rows.")
  }

  static func summarizeFrames(_ directory: URL) throws {
    let rows = try String(contentsOf: directory.appendingPathComponent("diagnostics.tsv"), encoding: .utf8)
      .split(separator: "\n").map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
    guard let header = rows.first, rows.count > 1 else { throw SmokeError("No frame diagnostics were recorded.") }
    var metrics = [String: Any]()
    for name in ["resolve_ms", "raster_ms", "pipeline_ms", "main_actor_blocked_ms", "input_to_commit_first_ms", "damage_rows"] {
      guard let index = header.firstIndex(of: name) else { throw SmokeError("Missing frame metric: \(name)") }
      let values = rows.dropFirst().compactMap { $0.indices.contains(index) ? Double($0[index]) : nil }.sorted()
      guard !values.isEmpty else { continue }
      metrics[name] = [
        "median": values[values.count / 2],
        "p95": values[Int(Double(values.count) * 0.95)],
        "maximum": values.last!,
      ]
    }
    try JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys])
      .write(to: directory.appendingPathComponent("frames-summary.json"))
  }

  static func bounds(_ t: PTY, sidebar: String = "Files ·") throws {
    try expect(t.line(-1).contains("Help"), "Footer left the viewport.")
    try expect(t.text.contains(sidebar), "Expected sidebar left the viewport: \(sidebar)")
  }

  static func fixtureTool(_ name: String) throws {
    let env = ProcessInfo.processInfo.environment
    guard let folder = env["TATARA_SMOKE_FIXTURE"] else { throw SmokeError("Missing fixture directory.") }
    let stress = env["TATARA_SMOKE_STRESS"] == "1"
    let args = Array(CommandLine.arguments.dropFirst())
    let endpoint = args.first { $0.hasPrefix("repos/") || $0 == "search/issues" || $0 == "graphql" } ?? "user"
    let log = URL(fileURLWithPath: folder).appendingPathComponent("requests.log")
    let fd = Darwin.open(log.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
    if fd >= 0 {
      let command = name == "difft" ? (args.contains("--version") ? "version" : "render") : endpoint
      let text = Data("\(name) \(command)\n".utf8)
      text.withUnsafeBytes { _ = Darwin.write(fd, $0.baseAddress, $0.count) }
      _ = Darwin.close(fd)
    }
    if
      let gate = env["TATARA_SMOKE_LOADING_GATE"],
      (env["TATARA_SMOKE_LOADING_STAGE"] == "bootstrap" && name == "gh" && endpoint == "user")
      || (env["TATARA_SMOKE_LOADING_STAGE"] == "items" && endpoint.contains("/pulls?"))
      || (env["TATARA_SMOKE_LOADING_STAGE"] == "diff" && name == "difft" && !args.contains("--version"))
    {
      try waitForFixtureResponse(in: URL(fileURLWithPath: gate))
    }
    if name == "difft" {
      if args.contains("--version") {
        print("difft-smoke 1")
        return
      }
      Thread.sleep(forTimeInterval: 4)
      let old = try String(contentsOfFile: args[args.count - 2], encoding: .utf8).split(
        separator: "\n",
        omittingEmptySubsequences: false,
      ).dropLast().map(String.init)
      let new = try String(contentsOfFile: args.last!, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
        .dropLast().map(String.init)
      try expect(old.count == new.count, "Fixture sources must have equal row counts.")
      var changes = [[String: Any]]()
      for index in old.indices where old[index] != new[index] {
        changes.append([
          "lhs": [
            "line_number": index,
            "changes": [[
              "start": old[index].utf8.count - 1,
              "end": old[index].utf8.count,
              "content": String(old[index].suffix(1)),
              "highlight": "normal",
            ]],
          ],
          "rhs": [
            "line_number": index,
            "changes": [[
              "start": new[index].utf8.count - 1,
              "end": new[index].utf8.count,
              "content": String(new[index].suffix(1)),
              "highlight": "normal",
            ]],
          ],
        ])
      }
      let output: [String: Any] = [
        "language": "Swift",
        "status": "changed",
        "aligned_lines": old.indices.map { [$0, $0] },
        "chunks": [changes],
      ]
      try FileHandle.standardOutput.write(JSONSerialization.data(withJSONObject: output))
      return
    }
    try expect(!args.contains("POST"), "Smoke tests must never write to a forge.")
    if endpoint == "user" {
      print("12345")
      return
    }
    let body = stress
      ? String(repeating: "A large paragraph with source coordinates and searchable text. ", count: 40000)
      : (0 ..< 400).lazy
        .map { "BODY \(String(format: "%04d", $0)) \(($0 == 250 || $0 == 350) ? "TARGET" : "") · 한국어 문서 😀 · " + String(
          repeating: "Keep the viewport bounded. ",
          count: 5,
        ) }.joined(separator: "\n")
    let base = String(repeating: "a", count: 40)
    let head = String(repeating: "b", count: 40)
    let itemCount = env["TATARA_SMOKE_DENSE"] == "1" ? 100 : 2
    let fileCount = env["TATARA_SMOKE_DENSE"] == "1" ? 120 : 12
    let draft = env["TATARA_SMOKE_DRAFT"] == "1"
    let items: [[String: Any]] = (1 ... itemCount).map { [
      "number": $0,
      "title": $0 == 1 ? "Long overview" : "Short overview",
      "user": ["login": "author"],
      "body": $0 == 1 ? body : "Short.",
      "html_url": "https://github.com/example/reviews/pull/\($0)",
      "state": "open",
      "labels": [],
      "draft": draft,
    ] }
    if endpoint == "graphql" {
      let input = try JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile()) as? [String: Any]
      let query = input?["query"] as? String ?? ""
      let firstPage = query.contains("pullRequests(first:")
      if firstPage, env["TATARA_SMOKE_LOADING_STAGE"] == "items", let gate = env["TATARA_SMOKE_LOADING_GATE"] {
        try waitForFixtureResponse(in: URL(fileURLWithPath: gate))
      }
      var nodes = [String: Any]()
      for (index, item) in items.enumerated() where firstPage || query.contains("p\(index + 1): pullRequest") {
        nodes["p\(index + 1)"] = [
          "number": index + 1,
          "url": item["html_url"]!,
          "state": "OPEN",
          "isDraft": draft,
          "title": item["title"]!,
          "body": item["body"]!,
          "author": ["login": "author"],
          "createdAt": "2026-09-08T00:00:00Z",
          "updatedAt": "2026-09-10T00:00:00Z",
          "headRefOid": head,
          "headRefName": "feature",
          "baseRefName": "main",
          "reviewDecision": "REVIEW_REQUIRED",
          "statusCheckRollup": ["state": "SUCCESS"],
          "totalCommentsCount": 0,
          "additions": fileCount,
          "deletions": fileCount,
          "changedFiles": fileCount,
          "commits": ["totalCount": 1],
        ]
      }
      if firstPage {
        let values = items.indices.map { index -> [String: Any] in
          var value = nodes["p\(index + 1)"] as! [String: Any]
          value["author"] = ["login": "author"]
          value["labels"] = ["nodes": [], "pageInfo": ["hasNextPage": false]]
          value["assignees"] = ["nodes": [], "pageInfo": ["hasNextPage": false]]
          value["reviewRequests"] = ["nodes": [], "pageInfo": ["hasNextPage": false]]
          return value
        }
        try FileHandle.standardOutput.write(JSONSerialization.data(withJSONObject: ["data": ["repository": ["pullRequests": [
          "nodes": values,
          "pageInfo": ["hasNextPage": false],
        ]]]]))
      } else {
        try FileHandle.standardOutput.write(JSONSerialization.data(withJSONObject: ["data": ["repository": nodes]]))
      }
      return
    }
    let files: [[String: Any]] = (0 ..< fileCount).map { [
      "filename": "\($0 % 2 == 0 ? "Sources" : "Tests")/File\($0).swift",
      "status": "modified",
      "additions": 1,
      "deletions": 1,
      "patch": draft ? "@@ -2 +2 @@\n-let value = 1\n+let value = 2" : "@@ -1 +1 @@\n-let value = 1\n+let value = 2",
    ] }
    let result: Any
    if endpoint.contains("/contents/") {
      if
        let gate = env["TATARA_SMOKE_INITIAL_SNAPSHOT_GATE"],
        !gate.isEmpty,
        endpoint.contains("Sources/File0%2Eswift"),
        endpoint.contains(base)
      {
        try waitForFixtureResponse(in: URL(fileURLWithPath: gate))
      }
      print("// \(endpoint.components(separatedBy: "/contents/").last!.components(separatedBy: "?").first!)")
      let value = endpoint.contains(base) ? 1 : 2
      if stress, env["TATARA_SMOKE_WIDE"] == "1" {
        print(String(repeating: String(repeating: "source ", count: 3000) + "\(value)\n", count: 8), terminator: "")
      } else if stress {
        print(
          String(repeating: "let value = \(value)\n", count: env["TATARA_SMOKE_SHORT_SOURCE"] == "1" ? 80 : 25000),
          terminator: "",
        )
      } else {
        print("let value = \(value)")
      }
      return
    } else if endpoint == "search/issues" {
      let found = args.contains(where: { $0.contains("is:closed") }) ? [] : items
      result = ["total_count": found.count, "incomplete_results": false, "items": found]
    } else if endpoint.contains("/compare/") {
      result = ["merge_base_commit": ["sha": base]]
    } else if endpoint.contains("/files?") {
      result = [files]
    } else if endpoint.contains("/check-runs?") {
      result = [["check_runs": []]]
    } else if endpoint.hasSuffix("/status") {
      result = ["statuses": []]
    } else if endpoint.contains("/labels?") {
      result = [[["name": "bug"], ["name": "enhancement"]]]
    } else if endpoint.contains("/comments?") || endpoint.contains("/reviews?") {
      result = [[]] as [[String]]
    } else if endpoint.contains("/pulls?") {
      result = items
    } else if let number = Int(endpoint.components(separatedBy: "/").last ?? ""), (1 ... itemCount).contains(number) {
      if stress {
        Thread.sleep(forTimeInterval: 2)
      }
      var pr = items[number - 1]
      pr.merge([
        "merged": false,
        "changed_files": fileCount,
        "mergeable_state": "clean",
        "base": ["sha": base, "ref": "main", "label": "example:main"],
        "head": ["sha": head, "ref": "feature", "label": "example:feature"],
      ]) { _, value in value }
      result = pr
    } else {
      throw SmokeError("Unexpected endpoint: \(endpoint)")
    }
    try FileHandle.standardOutput.write(JSONSerialization.data(withJSONObject: result))
  }
}
