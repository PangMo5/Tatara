// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TataraCore

struct Localization {
  let language: Language

  func callAsFunction(_ key: String) -> String {
    LocalizedStrings.values[language.rawValue]?[key] ?? key
  }

  func error(_ error: TataraError) -> String {
    let key = switch error.code {
    case .authentication: "Sign in with gh auth login, then refresh."
    case .revisionChanged: "This pull request changed. Refresh before submitting your review."
    case .emptyReview: "Write a comment before continuing."
    case .invalidLine: "Choose a source line included in this file's patch."
    case .timedOut: "The request timed out. Try again."
    case .incompleteResponse: "The response is incomplete. Open the original on GitHub."
    case .configuration: "Check your configuration."
    case .invalidRepository: "Use a repository in OWNER/REPO format."
    case .unavailable: "This action is unavailable for this item."
    case .commandFailed, .invalidResponse: "Could not load the data. Check the details and try again."
    }
    return self(key) + (error.detail.isEmpty ? "" : "\n\(TerminalText.sanitize(error.detail))")
  }
}
