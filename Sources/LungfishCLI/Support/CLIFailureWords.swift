// CLIFailureWords.swift - the words a failed command puts in its `failed` event
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation

/// The reason a failed `lungfish-cli` command gives (Phase 2.11 lane A69, carry-in row SW11).
///
/// A command that catches an error ends its event stream with `emitFailed`, and the app shows that
/// text in the Operations row and in the alert. ArgumentParser's `ValidationError` conforms to neither
/// `LocalizedError` nor `CustomNSError`, so its `localizedDescription` is the system's "The operation
/// couldn't be completed. (ArgumentParser.ValidationError error 1.)" and the refusal itself is lost.
/// Every catch asks this type for the text, so a refusal reads as its own words wherever it is thrown.
/// The human lines that repeat the reason use it too, so the two never differ.
enum CLIFailureWords {
    /// The words of `error`.
    ///
    /// - A `ValidationError` gives its message.
    /// - A `LocalizedError` gives its description, or the system's text when it has none.
    /// - Any other error gives its `localizedDescription`.
    static func describe(_ error: any Error) -> String {
        if let refusal = error as? ValidationError {
            return refusal.message
        }
        if let localized = error as? any LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}
