// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Subprocess
import TataraCore

// MARK: - CommandResult

public struct CommandResult: Sendable {
  public init(output: Data = Data(), error: String = "", status: Int32 = 0) {
    self.output = output
    self.error = error
    self.status = status
  }

  public var output: Data
  public var error: String
  public var status: Int32

  public var text: String {
    String(decoding: output, as: UTF8.self)
  }
}

// MARK: - CommandRunner

public struct CommandRunner: Sendable {

  // MARK: Lifecycle

  public init(run: @escaping @Sendable (String, [String], String?) async throws -> CommandResult) {
    self.run = run
  }

  // MARK: Public

  public static let live = Self { executable, arguments, input in
    try Task.checkCancellation()
    return try await withThrowingTaskGroup(of: CommandResult.self) { group in
      group.addTask {
        try Task.checkCancellation()
        var options = PlatformOptions()
        options.createSession = true
        options.qualityOfService = .utility
        options.teardownSequence = [.gracefulShutDown(toProcessGroup: true, allowedDurationToNextStep: .milliseconds(250))]
        let command: Executable = executable.contains("/") ? .path(.init(executable)) : .name(executable)
        let result = try await Subprocess.run(
          command,
          arguments: Arguments(arguments),
          environment: .inherit.updating([
            "GH_PROMPT_DISABLED": "1",
            "GH_PAGER": "cat",
            "PAGER": "cat",
            "DFT_EXIT_CODE": "false",
            "DFT_IGNORE_COMMENTS": "false",
            "DFT_SKIP_UNCHANGED": "false",
            "DFT_UNSTABLE": "yes",
          ]),
          platformOptions: options,
          input: .string(input ?? ""),
          output: .bytes(limit: 16 * 1024 * 1024),
          error: .string(limit: 65536),
        )
        try Task.checkCancellation()
        let status: Int32 =
          switch result.terminationStatus {
          case .exited(let code): code
          case .signaled(let signal): 128 + signal
          }
        let output = Data(result.standardOutput)
        guard output.count < 16 * 1024 * 1024 else {
          throw TataraError(.incompleteResponse, detail: "Command output exceeds 16 MiB.")
        }
        return CommandResult(output: output, error: result.standardError, status: status)
      }
      group.addTask {
        try await Task.sleep(for: .seconds(60))
        throw TataraError(.timedOut, detail: executable)
      }
      defer { group.cancelAll() }
      guard let result = try await group.next() else { throw CancellationError() }
      return result
    }
  }

  public var run: @Sendable (String, [String], String?) async throws -> CommandResult

  public func checked(_ executable: String, _ arguments: [String], input: String? = nil) async throws -> CommandResult {
    try Task.checkCancellation()
    let result = try await run(executable, arguments, input)
    guard result.status == 0 else {
      let code: TataraError.Code = result.error.contains("gh auth login") || result.error
        .contains("HTTP 401") ? .authentication : .commandFailed
      throw TataraError(code, detail: TerminalText.sanitize("\(executable): \(result.error)"))
    }
    return result
  }

}
