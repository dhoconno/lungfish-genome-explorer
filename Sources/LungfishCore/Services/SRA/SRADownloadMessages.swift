// SRADownloadMessages.swift - One-line reasons for SRA download failures and fallbacks
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// One-line reasons for what went wrong in an SRA download.
///
/// The window's SRA download and `lungfish-cli fetch sra download` show the
/// same reason for the same failure, in an Operations panel row or on the
/// command line. A reason never spans lines. A tool's whole standard error
/// goes to the log and to the tool's provenance step instead.
public enum SRADownloadMessages {
    /// The most characters a reason keeps.
    public static let reasonLimit = 300

    /// `error` told in one line, without the "Download failed:" that an
    /// enclosing error adds again.
    public static func reason(of error: any Error) -> String {
        let text: String
        switch error {
        case let failure as ENAFASTQDownloadFailure:
            text = failure.message
        case let failure as ArchiveRequestFailure:
            text = failure.message
        case SRAError.downloadFailed(let message):
            text = message
        default:
            text = error.localizedDescription
        }
        return oneLine(text)
    }

    /// `text` with every run of white space, line breaks included, made one
    /// space, and cut to `limit` characters.
    public static func oneLine(_ text: String, limit: Int = reasonLimit) -> String {
        let collapsed = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(max(limit - 1, 0))).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The line a failed SRA Toolkit tool leaves in an error. It names the
    /// tool and its exit status, then the first line of its standard error
    /// that reports an error, or its last line when none does. The time
    /// stamp sra-tools starts its lines with is dropped.
    public static func toolFailure(tool: String, exitCode: Int32, stderr: String) -> String {
        let lines = stderr
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let chosen = lines.first { $0.contains(" err: ") || $0.hasPrefix("err: ") } ?? lines.last
        var line = "\(tool) exited with status \(exitCode)"
        if let chosen {
            line += ". \(droppingTimeStamp(chosen))"
        }
        return oneLine(line)
    }

    /// `line` without a leading ISO 8601 time such as 2026-10-06T12:00:00.
    private static func droppingTimeStamp(_ line: String) -> String {
        guard let match = line.firstMatch(of: /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\S*\s+/) else {
            return line
        }
        return String(line[match.range.upperBound...])
    }
}

public extension SRAError {
    /// The one-line error of a run that neither archive could serve. The
    /// archive the download tried first is named first.
    static func bothArchivesFailed(toolkitFirst: Bool, enaReason: String, toolkitReason: String) -> SRAError {
        let ena = "ENA: \(SRADownloadMessages.oneLine(enaReason))"
        let toolkit = "Toolkit: \(SRADownloadMessages.oneLine(toolkitReason))"
        return .downloadFailed(toolkitFirst ? "\(toolkit); \(ena)" : "\(ena); \(toolkit)")
    }

    /// The one-line error of a run that neither archive could serve.
    static func bothArchivesFailed(toolkitFirst: Bool, enaError: any Error, toolkitError: any Error) -> SRAError {
        bothArchivesFailed(
            toolkitFirst: toolkitFirst,
            enaReason: SRADownloadMessages.reason(of: enaError),
            toolkitReason: SRADownloadMessages.reason(of: toolkitError)
        )
    }
}

public extension ENAFASTQDownloadFailure {
    /// How one file from ENA's mirror failed, with the source the SRA Toolkit
    /// fallback records, or nil for a cancellation, which stops the download.
    ///
    /// A file that fails `ENAFASTQDownloadValidator` names an incomplete
    /// mirror, and an HTTP error status or a broken transfer names a failed
    /// transfer. The window's download and `fetch sra download` both name a
    /// failed file this way, so they log and record the same line.
    static func mirrorFile(_ filename: String, failedWith error: any Error) -> ENAFASTQDownloadFailure? {
        if isArchiveRequestCancellation(error) {
            return nil
        }
        if let failure = error as? ENAFASTQDownloadFailure {
            return failure
        }
        if let failure = error as? ENAFASTQDownloadValidator.Failure {
            return ENAFASTQDownloadFailure(
                fallbackSource: .sraToolkitAfterIncompleteMirror,
                message: SRADownloadMessages.oneLine(failure.localizedDescription)
            )
        }
        if let status = (error as? DatabaseServiceError)?.httpStatusCode {
            return mirrorStatus(status, for: filename)
        }
        var detail = ArchiveRequestFailure.displayLine(error.localizedDescription)
        if detail.hasSuffix(".") {
            detail.removeLast()
        }
        return ENAFASTQDownloadFailure(
            fallbackSource: .sraToolkitAfterFailedTransfer,
            message: "The transfer of \(filename) from ENA's mirror failed" + (detail.isEmpty ? "" : " (\(detail))")
        )
    }

    /// ENA's mirror answered `status`, which is not a success, for `filename`.
    static func mirrorStatus(_ status: Int, for filename: String) -> ENAFASTQDownloadFailure {
        ENAFASTQDownloadFailure(
            fallbackSource: .sraToolkitAfterFailedTransfer,
            message: "ENA's mirror answered HTTP \(status) for \(filename)"
        )
    }
}
