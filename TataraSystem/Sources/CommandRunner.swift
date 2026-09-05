// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Subprocess
import TataraCore

public struct CommandResult: Sendable {
  public var output: Data
  public var error: String
  public var status: Int32
  public var text: String {
    String(decoding: output, as: UTF8.self)
  }

  public init(output: Data = Data(), error: String = "", status: Int32 = 0) {
    self.output = output
    self.error = error
    self.status = status
  }
}

public struct CommandRunner: Sendable {
  public var run: @Sendable (String, [String], String?) async throws -> CommandResult
  public init(run: @escaping @Sendable (String, [String], String?) async throws -> CommandResult) {
    self.run = run
  }

  public static let live = Self { executable, arguments, input in
    try await withThrowingTaskGroup(of: CommandResult.self) { group in
      group.addTask {
        var options = PlatformOptions()
        options.createSession = true
        options.teardownSequence = [.gracefulShutDown(toProcessGroup: true, allowedDurationToNextStep: .milliseconds(250))]
        let result = try await Subprocess.run(
          .name(executable), arguments: Arguments(arguments),
          environment: .inherit.updating([
            "GH_PROMPT_DISABLED": "1", "GH_PAGER": "cat", "PAGER": "cat",
            "DFT_EXIT_CODE": "false", "DFT_IGNORE_COMMENTS": "false", "DFT_SKIP_UNCHANGED": "false",
          ]),
          platformOptions: options, input: .string(input ?? ""),
          output: .bytes(limit: 16 * 1024 * 1024), error: .string(limit: 65536),
        )
        try Task.checkCancellation()
        let status: Int32 = switch result.terminationStatus {
        case let .exited(code): code
        case let .signaled(signal): 128 + signal
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

  public func checked(_ executable: String, _ arguments: [String], input: String? = nil) async throws -> CommandResult {
    let result = try await run(executable, arguments, input)
    guard result.status == 0 else {
      let code: TataraError.Code = result.error.contains("gh auth login") || result.error
        .contains("HTTP 401") ? .authentication : .commandFailed
      throw TataraError(code, detail: TerminalText.sanitize("\(executable): \(result.error)"))
    }
    return result
  }
}
