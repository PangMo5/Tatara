#!/usr/bin/env swift
// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Darwin
import Foundation

// MARK: - TestFailure

struct TestFailure: Error, CustomStringConvertible {
  var description: String
}

func execute(_ executable: String, _ arguments: [String], environment: [String: String]) throws -> (Int32, String) {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: executable)
  process.arguments = arguments
  process.environment = environment
  let output = Pipe()
  process.standardOutput = output
  process.standardError = output
  try process.run()
  let data = output.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

do {
  let environment = ProcessInfo.processInfo.environment
  let (status, compilerPath) = try execute("/usr/bin/xcrun", ["--find", "swift"], environment: environment)
  guard status == 0 else { throw TestFailure(description: "Could not locate the real Swift interpreter.") }
  let compiler = compilerPath.trimmingCharacters(in: .whitespacesAndNewlines)
  let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  let script = root.appendingPathComponent("Scripts/Tatara.swift").path
  let fixtures = FileManager.default.temporaryDirectory.appendingPathComponent("tatara-toolchain-\(UUID())")
  try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: fixtures) }

  struct Scenario {
    var name: String
    var xcode = "27.2"
    var build = "27B48"
    var swift = "6.4.2"
    var sdk = "27.2"
    var command = "toolchain"
    var error: String?
  }
  let scenarios = [
    Scenario(name: "matching RC compiler and SDK"),
    Scenario(name: "stable Xcode", build: "27B52"),
    Scenario(name: "wrong Xcode", xcode: "27.1", error: "Tatara requires Xcode 27.2"),
    Scenario(name: "wrong compiler", swift: "6.3.3", error: "Swift 6.4.2 compiler"),
    Scenario(name: "wrong SDK", sdk: "27.1", error: "macOS 27.2 SDK"),
    Scenario(name: "RC release validation", command: "validate-release", error: "Binary releases require the stable Xcode"),
    Scenario(name: "RC release build", command: "release-build", error: "Binary releases require the stable Xcode"),
  ]
  for scenario in scenarios {
    let tools = [
      "xcodebuild": "Xcode \(scenario.xcode)\nBuild version \(scenario.build)",
      "swift": "Apple Swift version \(scenario.swift)",
      "xcrun": scenario.sdk,
    ]
    for (name, value) in tools {
      let executable = fixtures.appendingPathComponent(name)
      // These constant-output executable fixtures never run build, signing or forge commands.
      let source = name == "xcrun"
        ? "#!/bin/sh\ncase \"$3\" in --show-sdk-path) printf '%s\\n' '/SDKs/MacOSX\(scenario.sdk).sdk' ;; *) printf '%s\\n' '\(value)' ;; esac\n"
        : "#!/bin/sh\nprintf '%s\\n' '\(value)'\n"
      try source.write(to: executable, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }
    var childEnvironment = environment
    childEnvironment["PATH"] = fixtures.path + ":/usr/bin:/bin"
    let (status, output) = try execute(compiler, [script, scenario.command], environment: childEnvironment)
    if let error = scenario.error {
      guard status != 0, output.contains(error) else {
        throw TestFailure(description: "\(scenario.name) did not reject the invalid contract: \(output)")
      }
    } else if status != 0 {
      throw TestFailure(description: "\(scenario.name) failed: \(output)")
    }
    print("Passed: \(scenario.name)")
  }
  print("Verified \(scenarios.count) toolchain contracts.")
} catch {
  FileHandle.standardError.write(Data("\(error)\n".utf8))
  exit(1)
}
