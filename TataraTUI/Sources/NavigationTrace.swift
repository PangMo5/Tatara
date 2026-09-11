// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import OSLog

actor NavigationTrace {
  static let shared = NavigationTrace()
  nonisolated static let destination = ProcessInfo.processInfo.environment["TATARA_INPUT_TRACE"]
  private var file: FileHandle?

  func start() throws {
    guard let destination = Self.destination else { return }
    let url = URL(fileURLWithPath: destination)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("started_ms\tsynchronous_ms\tframe_started_ms\n".utf8).write(to: url, options: .atomic)
    file = try FileHandle(forWritingTo: url)
    try file?.seekToEnd()
  }

  func record(start: Double, elapsed: Double, frameStart: Duration) {
    guard let file else { return }
    let components = frameStart.components
    let frameMilliseconds = Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    do { try file.write(contentsOf: Data("\(start * 1000)\t\(elapsed * 1000)\t\(frameMilliseconds)\n".utf8)) }
    catch {
      Logger(subsystem: "dev.PangMo5.tatara", category: "profiling")
        .error("Input trace failed: \(String(describing: error), privacy: .public)")
    }
  }
}
