// ArchiveRequestFailure.swift - One-line descriptions of failed archive requests
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// A failed request to a public archive such as ENA or NCBI, told in one
/// line that is safe to show in the window or on the command line.
///
/// Archive servers answer some failures with a whole HTML error page. On
/// 2026-10-04 ENA's portal API did so for every request, and the SRA Runs
/// search showed the page's markup as its error. The service that receives
/// such a page logs its full body and keeps only the status in its error,
/// and this type turns the error into a line such as
/// "ENA returned HTTP 500 (server error)".
public struct ArchiveRequestFailure: Error, LocalizedError, Sendable, Equatable {
    /// The archive's short name, such as "ENA" or "NCBI".
    public let archive: String

    /// The HTTP status the archive answered with, or nil when no status
    /// arrived, as when the host could not be reached.
    public let statusCode: Int?

    /// What went wrong, without the archive's name, such as
    /// "returned HTTP 500 (server error)".
    public let reason: String

    /// Describes `error`, which a request to `archive` threw.
    public init(archive: String, error: any Error) {
        self.archive = archive
        if let failure = error as? ArchiveRequestFailure {
            statusCode = failure.statusCode
            reason = failure.reason
        } else if let status = (error as? DatabaseServiceError)?.httpStatusCode {
            statusCode = status
            reason = "returned HTTP \(status)\(Self.statusPhrase(status))"
        } else if let urlError = error as? URLError {
            statusCode = nil
            let detail = Self.displayLine(urlError.localizedDescription)
            reason = detail.isEmpty ? "could not be reached" : "could not be reached (\(Self.droppingFinalPeriod(detail)))"
        } else {
            statusCode = nil
            let detail = Self.displayLine(error.localizedDescription)
            reason = detail.isEmpty ? "failed" : "failed (\(Self.droppingFinalPeriod(detail)))"
        }
    }

    /// The whole line, such as "ENA returned HTTP 500 (server error)".
    public var message: String {
        "\(archive) \(reason)"
    }

    public var errorDescription: String? {
        message
    }

    /// Text fit for one line of a message. Markup and everything after its
    /// first tag is dropped, so an HTML error page yields an empty string.
    /// Otherwise the first non-blank line is kept, cut to `limit`
    /// characters with a trailing ellipsis.
    public static func displayLine(_ text: String, limit: Int = 120) -> String {
        var kept = text
        if let markupStart = Self.firstMarkupIndex(in: kept) {
            kept = String(kept[..<markupStart])
        }
        let firstLine = kept
            .split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        let trimmed = firstLine.trimmingCharacters(in: CharacterSet(charactersIn: ": ").union(.whitespaces))
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(max(limit - 1, 0))).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Where the first HTML tag or document type declaration starts, if any.
    private static func firstMarkupIndex(in text: String) -> String.Index? {
        var searchStart = text.startIndex
        while let open = text[searchStart...].firstIndex(of: "<") {
            let next = text.index(after: open)
            if next < text.endIndex, let character = text[next...].first,
               character.isLetter || character == "!" || character == "/" || character == "?" {
                return open
            }
            searchStart = next
        }
        return nil
    }

    private static func droppingFinalPeriod(_ text: String) -> String {
        text.hasSuffix(".") ? String(text.dropLast()) : text
    }

    private static func statusPhrase(_ status: Int) -> String {
        switch status {
        case 429: return " (too many requests)"
        case 500...599: return " (server error)"
        case 400...499: return " (request refused)"
        default: return ""
        }
    }
}

public extension DatabaseServiceError {
    /// The HTTP status behind this error, when a server answered with one.
    var httpStatusCode: Int? {
        switch self {
        case .invalidResponse(let statusCode):
            return statusCode
        case .rateLimitExceeded:
            return 429
        case .serverError(let message):
            // Services report a status as "HTTP 500", optionally followed
            // by ": " and a one-line excerpt of the body.
            let trimmed = message.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("HTTP ") else { return nil }
            let afterPrefix = trimmed.dropFirst("HTTP ".count)
            let digits = afterPrefix.prefix(while: \.isNumber)
            let rest = afterPrefix.dropFirst(digits.count)
            guard digits.count == 3, rest.isEmpty || rest.hasPrefix(":") || rest.hasPrefix(" "),
                  let status = Int(digits) else { return nil }
            return status
        default:
            return nil
        }
    }
}

/// Whether `error` reports a cancelled task or request rather than a failure.
func isArchiveRequestCancellation(_ error: any Error) -> Bool {
    if error is CancellationError {
        return true
    }
    if let urlError = error as? URLError {
        return urlError.code == .cancelled
    }
    if let databaseError = error as? DatabaseServiceError, case .cancelled = databaseError {
        return true
    }
    return false
}
