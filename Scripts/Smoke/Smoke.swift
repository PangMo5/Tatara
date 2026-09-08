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
      if args.contains("--features") {
        try features(binary, artifacts: artifacts.appendingPathComponent("features"))
      } else if let index = args.firstIndex(of: "--live-navigation"), args.indices.contains(index + 1) {
        let label = args.firstIndex(of: "--label").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } ?? "current"
        let output = artifacts.appendingPathComponent("navigation-live-" + label)
        let t = try PTY(
          binary: binary,
          arguments: ["--language", "en", "--theme", "mocha"],
          columns: size("--columns", 320),
          rows: size("--rows", 64),
          environment: ["SWIFTTUI_DIAGNOSTICS": output.appendingPathComponent("diagnostics.tsv").path,
                        "TATARA_INPUT_TRACE": output.appendingPathComponent("input.tsv").path],
          cwd: URL(fileURLWithPath: args[index + 1]),
          artifacts: output,
        )
        defer { t.close() }
        try t.wait("1 · Pull requests")
        let expression = try NSRegularExpression(pattern: #"#(\d+) "#)
        func itemIDs() -> [String] {
          var ids: [String] = []
          for row in 0 ..< t.rows / 2 {
            let line = String(t.line(row).prefix(44))
            if let match = expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
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
      } else if let index = args.firstIndex(of: "--live"), args.indices.contains(index + 1),
                let itemIndex = args.firstIndex(of: "--item"), args.indices.contains(itemIndex + 1)
      {
        try live(
          binary,
          directory: URL(fileURLWithPath: args[index + 1]),
          item: args[itemIndex + 1],
          artifacts: artifacts.appendingPathComponent("live"),
          columns: size("--columns", 176), rows: size("--rows", 40),
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
    try terminal.wait("Scroll main pane down")
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
    try terminal.wait("1 · Pull requests")
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
    try t.wait("ReviewQueue.swift")
    try t.wait("Ready")
    t.key("2")
    try t.wait("Normal · Files")
    try expect(t.activeBorder(2), "The active file pane border is not accented.")
    t.key("h")
    t.read(for: 0.1)
    t.key("\r")
    try t.waitUntil("collapsed source folder") { !t.text.contains("ReviewQueue.swift") }
    t.key("\r")
    try t.wait("ReviewQueue.swift")
    t.key("l")
    try t.wait("guard files.indices.contains")
    t.key("3")
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
    try t.wait("ReviewQueue.swift:5–6")
    try t.click("Preview")
    try t.wait("This will be posted to GitHub.")
    try t.wait("Check this range.")
    try t.snapshot("range-preview")
    t.key("\u{1B}")
    try t.wait("Normal · Diff")
    t.key("h")
    t.read(for: 0.1)
    t.key("r")
    try t.wait("Write your review")
    try t.wait("LEFT ·")
    t.key("Old source context.")
    try t.wait("Old source context.")
    try t.click("Add comment to review")
    try t.wait("ReviewQueue.swift:5")
    t.key("\u{1B}")
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
    try reopened.wait("Sources/ReviewQueue.swift")
    try expect(!reopened.text.contains("▾ Sources"), "List configuration still rendered a directory tree.")
    reopened.key("f")
    try reopened.wait("My review queue")
    try reopened.click("My review queue")
    try reopened.wait("▸ My review queue")
    try reopened.click("Apply")
    try reopened.wait("Normal · Pull requests")
    reopened.key("q")
    try reopened.finish()
    print(
      "Swift PTY: tree/list configuration, active borders, Shift-V ranges, both source sides, review preview and persistent presets passed; no forge writes.",
    )
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
    try t.wait("1 · Pull requests")
    t.read(for: 1)
    t.key("/\(item)\r")
    try t.wait("#\(item)")
    t.key("\u{1B}")
    try t.wait("Normal · Pull requests")
    var times: [Double] = []
    func exerciseFocus(_ labels: [(String, String)]) throws {
      let deadline = ProcessInfo.processInfo.systemUptime + 4
      repeat {
        for (key, label) in labels {
          let start = ProcessInfo.processInfo.systemUptime
          t.key(key)
          try t.wait(label)
          times.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        }
      } while ProcessInfo.processInfo.systemUptime < deadline
    }
    try exerciseFocus([("2", "Normal · Files"), ("1", "Normal · Pull requests")])
    try t.wait("Ready")
    try bounds(t)
    try t.snapshot("overview")
    t.key("2\r")
    try t.wait("Normal · Diff")
    try exerciseFocus([("1", "Normal · Pull requests"), ("2", "Normal · Files"), ("3", "Normal · Diff")])
    try t.wait("Ready", timeout: 60)
    try t.snapshot("diff")
    t.key("[")
    t.key("3")
    try t.wait("Normal · Overview")
    t.key("\u{6}")
    try t.waitUntil("main paging") { position(t) > 1 }
    t.key("?")
    try t.wait("Previous pane")
    t.key("/ctrl-f\r")
    try t.wait("Scroll main pane down")
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
    try fm.createDirectory(at: fixture, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: fixture) }
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    try fm.createSymbolicLink(at: fixture.appendingPathComponent("gh"), withDestinationURL: executable)
    if stress {
      try fm.createSymbolicLink(at: fixture.appendingPathComponent("difft"), withDestinationURL: executable)
    }
    var env = ["PATH": fixture.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? ""),
               "TATARA_SMOKE_FIXTURE": fixture.path, "TATARA_SMOKE_STRESS": stress ? "1" : "0",
               "TATARA_SMOKE_WIDE": CommandLine.arguments.contains("--wide-lines") ? "1" : "0",
               "XDG_DATA_HOME": fixture.appendingPathComponent("data").path,
               "XDG_CACHE_HOME": fixture.appendingPathComponent("cache").path]
    if profile {
      env["SWIFTTUI_DIAGNOSTICS"] = artifacts.appendingPathComponent("diagnostics.tsv").path
      env["TATARA_INPUT_TRACE"] = artifacts.appendingPathComponent("input.tsv").path
    }
    let t = try PTY(
      binary: binary,
      arguments: ["--repo", "example/reviews", "--language", "en"],
      columns: columns,
      rows: rows,
      environment: env,
      artifacts: artifacts,
    )
    defer { t.close() }
    try t.wait("1 · Pull requests")
    try t.wait("Long overview")
    if navigation {
      try profileNavigation(t, binary: binary, artifacts: artifacts)
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
      var times: [Double] = []
      let focusDeadline = ProcessInfo.processInfo.systemUptime + 7
      repeat {
        for (key, label) in [("2", "Normal · Files"), ("1", "Normal · Pull requests")] {
          let start = ProcessInfo.processInfo.systemUptime
          t.key(key)
          try t.wait(label)
          times.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        }
      } while ProcessInfo.processInfo.systemUptime < focusDeadline
      try t.wait("Ready", timeout: 60)
      t.key("2\r")
      try t.wait("Loading diff")
      if !profile {
        try t.snapshot("loading-diff")
      }
      let diffDeadline = ProcessInfo.processInfo.systemUptime + 6
      repeat {
        for (key, label) in [("1", "Normal · Pull requests"), ("2", "Normal · Files"), ("3", "Normal · Diff")] {
          let start = ProcessInfo.processInfo.systemUptime
          t.key(key)
          try t.wait(label)
          times.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        }
      } while ProcessInfo.processInfo.systemUptime < diffDeadline
      try t.wait("Ready", timeout: 60)
      t.key("2")
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
        "columns": columns, "rows": rows,
        "cpu_sampling": sampling,
        "binary_sha256": SHA256.hash(data: Data(contentsOf: binary, options: .mappedIfSafe))
          .map { String(format: "%02x", $0) }.joined(),
        "os": ProcessInfo.processInfo.operatingSystemVersionString,
      ]
      if profile {
        t.key("3")
        try t.wait("Normal · Diff")
        try t.waitUntil("settled diff viewport", timeout: 60) {
          t.line(-2).contains("Ready") && t.text.contains("let value = 2") && position(t) == 1
        }
        var scrollTimes: [Double] = []
        try t.snapshot("before-scroll")
        for step in 0 ..< 20 {
          for (key, moved) in [("\u{6}", true), ("\u{2}", false)] {
            let start = ProcessInfo.processInfo.systemUptime
            t.key(key)
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
      if profile {
        try summarizeFrames(artifacts)
      }
      print("Swift PTY: focus during large PR preparation and an in-flight diff passed.")
      return
    }
    try t.wait("BODY 0000")
    try t.wait("Ready")
    try bounds(t)
    t.wheel(column: 100, row: 10, down: true, count: 3)
    try t.waitUntil("main wheel scrolling") { position(t) > 1 }
    try expect(t.text.contains("Normal · Pull requests"), "Wheel scrolling stole keyboard focus.")
    t.wheel(column: 100, row: 10, down: false, count: 3)
    try t.waitUntil("main wheel top boundary") { position(t) == 1 }
    t.wheel(column: 10, row: 7, down: true)
    try t.wait("Short.")
    t.wheel(column: 10, row: 7, down: false)
    try t.wait("BODY 0000")
    t.wheel(column: 10, row: 25, down: true)
    try t.wait("let value = 2")
    try expect(t.text.contains("Normal · Pull requests"), "File wheel scrolling stole keyboard focus.")
    t.wheel(column: 10, row: 25, down: false)
    try t.wait("Ready")
    t.key("[")
    try t.wait("BODY 0000")
    t.key("\u{6}")
    try t.waitUntil("sidebar paging") { position(t) > 1 }
    t.key("\u{2}")
    try t.waitUntil("first page") { position(t) == 1 }
    t.key("/Long\r")
    try t.wait("Filter · Pull requests")
    t.key("\u{1B}")
    try t.wait("Normal · Pull requests")
    t.key("2/Tests\r")
    try t.wait("Filter · Files")
    try t.wait("6/12")
    try t.wait("Ready")
    t.key("\u{1B}")
    try t.wait("Normal · Files")
    t.key("[")
    try t.wait("BODY 0000")
    t.key("3/TARGET\r")
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
    try t.wait("Scroll main pane down")
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
      try String(contentsOf: log, encoding: .utf8).split(separator: "\n").filter { $0.hasPrefix("gh repos/") }.count
    }
    let before = try repositoryRequests()
    let warm = try PTY(
      binary: binary,
      arguments: ["--repo", "example/reviews", "--language", "en"],
      environment: env,
      artifacts: artifacts.appendingPathComponent("warm"),
    )
    defer { warm.close() }
    try warm.wait("BODY 0000")
    try warm.wait("Ready")
    warm.key("2/Tests\r")
    try warm.wait("Filter · Files")
    try warm.wait("let value = 2")
    try expect(try repositoryRequests() == before, "Warm restart repeated repository API calls.")
    warm.key("q")
    try warm.finish()
    print("Swift PTY: pane search, popup, mouse wheel, scrollbar, paging, resize and Escape passed.")
    print("Swift PTY: persistent cache reused metadata, snapshots and diff across processes.")
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

  static func profileNavigation(_ t: PTY, binary: URL, artifacts: URL, itemNumbers: [String] = ["1", "2"]) throws {
    var observations: [[String: Any]] = []
    let origin = ProcessInfo.processInfo.systemUptime
    let sampler = Process()
    let sampling = CommandLine.arguments.contains("--sample")
    func settled() throws {
      try t.waitUntil("settled selected document", timeout: 60) { t.line(-2).contains("Ready") && position(t) > 0 }
    }
    func select(_ key: String, stage: String, _ selected: () -> Bool) throws {
      let start = ProcessInfo.processInfo.systemUptime
      t.key(key)
      try t.waitUntil("\(stage) selection \(key)", selected)
      observations.append(["stage": stage, "key": key, "at_ms": (start - origin) * 1000,
                           "latency_ms": (ProcessInfo.processInfo.systemUptime - start) * 1000,
                           "status": t.line(-2).trimmingCharacters(in: .whitespaces)])
    }
    func bursts(_ stage: String, scope: String) throws {
      guard CommandLine.arguments.contains("--burst") else { return }
      for interval in [0.025, 0.12] {
        for _ in 0 ..< 3 {
          let sent = try t.replay(Array(repeating: ["j", "k"], count: 8).flatMap(\.self) + ["?"], interval: interval)
          if !t.hasCompletedFrame(containing: "Previous pane") {
            try t.wait("Previous pane")
          }
          observations.append(["stage": "\(stage)-burst-\(Int(interval * 1000))ms", "key": "?",
                               "at_ms": (sent - origin) * 1000,
                               "latency_ms": (ProcessInfo.processInfo.systemUptime - sent) * 1000])
          t.key("\u{1B}")
          try t.wait("Normal · \(scope)")
        }
      }
    }
    try settled()
    try select("j", stage: "pr-warmup") { t.text.contains("▸ #\(itemNumbers[1]) ") }
    try settled()
    try select("k", stage: "pr-warmup") { t.text.contains("▸ #\(itemNumbers[0]) ") }
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
      try select("j", stage: "pr-settled") { t.text.contains("▸ #\(itemNumbers[1]) ") }
      try settled()
      try select("k", stage: "pr-settled") { t.text.contains("▸ #\(itemNumbers[0]) ") }
      try settled()
    }
    for _ in 0 ..< 12 {
      try select("j", stage: "pr-inflight") { t.text.contains("▸ #\(itemNumbers[1]) ") }
      t.read(for: 0.15)
      try select("k", stage: "pr-inflight") { t.text.contains("▸ #\(itemNumbers[0]) ") }
      t.read(for: 0.15)
    }
    try bursts("pr", scope: "Pull requests")
    try settled()
    t.key("2")
    try t.wait("Normal · Files")
    t.key("\r")
    try t.wait("Normal · Diff")
    try settled()
    t.key("2")
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
    t.key("q")
    try t.finish()
    if sampling {
      sampler.waitUntilExit()
      try expect(sampler.terminationStatus == 0, "CPU sampling failed.")
    }
    var result: [String: Any] = try ["samples": observations, "cpu_sampling": sampling, "columns": t.columns, "rows": t.rows,
                                     "binary_sha256": SHA256.hash(data: Data(contentsOf: binary))
                                       .map { String(format: "%02x", $0) }.joined()]
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
    try summarizeFrames(artifacts)
    result["samples"] = observations.count
    try print(String(decoding: JSONSerialization.data(withJSONObject: result, options: .sortedKeys), as: UTF8.self))
  }

  static func summarizeFrames(_ directory: URL) throws {
    let rows = try String(contentsOf: directory.appendingPathComponent("diagnostics.tsv"), encoding: .utf8)
      .split(separator: "\n").map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
    guard let header = rows.first, rows.count > 1 else { throw SmokeError("No frame diagnostics were recorded.") }
    var metrics: [String: Any] = [:]
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

  static func bounds(_ t: PTY) throws {
    try expect(t.line(-1).contains("Help"), "Footer left the viewport.")
    try expect(t.text.contains("2 · Files"), "Files pane left the viewport.")
  }

  static func fixtureTool(_ name: String) throws {
    let env = ProcessInfo.processInfo.environment
    guard let folder = env["TATARA_SMOKE_FIXTURE"] else { throw SmokeError("Missing fixture directory.") }
    let stress = env["TATARA_SMOKE_STRESS"] == "1"
    let args = Array(CommandLine.arguments.dropFirst())
    let endpoint = args.first { $0.hasPrefix("repos/") || $0 == "search/issues" } ?? "user"
    let log = URL(fileURLWithPath: folder).appendingPathComponent("requests.log")
    let fd = Darwin.open(log.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
    if fd >= 0 {
      let text = Data("\(name) \(endpoint)\n".utf8)
      text.withUnsafeBytes { _ = Darwin.write(fd, $0.baseAddress, $0.count) }
      _ = Darwin.close(fd)
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
      var changes: [[String: Any]] = []
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
    let body = stress ? String(repeating: "A large paragraph with source coordinates and searchable text. ", count: 40000) :
      (0 ..< 400).map { "BODY \(String(format: "%04d", $0)) \(($0 == 250 || $0 == 350) ? "TARGET" : "") · 한국어 문서 😀 · " + String(
        repeating: "Keep the viewport bounded. ",
        count: 5,
      ) }.joined(separator: "\n")
    let base = String(repeating: "a", count: 40), head = String(repeating: "b", count: 40)
    let items: [[String: Any]] = (1 ... 2).map { [
      "number": $0,
      "title": $0 == 1 ? "Long overview" : "Short overview",
      "user": ["login": "author"],
      "body": $0 == 1 ? body : "Short.",
      "html_url": "https://github.com/example/reviews/pull/\($0)",
      "state": "open",
      "labels": [],
      "draft": false,
    ] }
    let files: [[String: Any]] = (0 ..< 12).map { [
      "filename": "\($0 % 2 == 0 ? "Sources" : "Tests")/File\($0).swift",
      "status": "modified",
      "additions": 1,
      "deletions": 1,
      "patch": "@@ -1 +1 @@\n-let value = 1\n+let value = 2",
    ] }
    let result: Any
    if endpoint.contains("/contents/") {
      print("// \(endpoint.components(separatedBy: "/contents/").last!.components(separatedBy: "?").first!)")
      let value = endpoint.contains(base) ? 1 : 2
      if stress, env["TATARA_SMOKE_WIDE"] == "1" {
        print(String(repeating: String(repeating: "source ", count: 3000) + "\(value)\n", count: 8), terminator: "")
      } else if stress {
        print(String(repeating: "let value = \(value)\n", count: 25000), terminator: "")
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
    } else if endpoint.contains("/comments?") || endpoint.contains("/reviews?") {
      result = [[]] as [[String]]
    } else if endpoint.contains("/pulls?") {
      result = items
    } else if let number = Int(endpoint.components(separatedBy: "/").last ?? ""), (1 ... 2).contains(number) {
      if stress {
        Thread.sleep(forTimeInterval: 2)
      }
      var pr = items[number - 1]
      pr.merge([
        "merged": false,
        "changed_files": 12,
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
