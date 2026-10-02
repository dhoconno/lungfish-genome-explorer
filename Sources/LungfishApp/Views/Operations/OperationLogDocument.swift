// OperationLogDocument.swift - Writes the text log file for one operation
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import Combine
import LungfishCore
import LungfishKit

// MARK: - Local Operation Log Documents

enum OperationLogDocument {
    static func write(item: OperationCenter.Item) throws -> URL {
        let url = fileURL(for: item)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try render(item: item).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func fileURL(for item: OperationCenter.Item) -> URL {
        let logsDirectory = defaultLogsDirectory()

        let datePrefix = fileTimestamp(item.startedAt)
        let titleSlug = slug(item.title)
        let idPrefix = String(item.id.uuidString.prefix(8)).lowercased()
        return logsDirectory.appendingPathComponent("\(datePrefix)-\(titleSlug)-\(idPrefix).log")
    }

    static func defaultLogsDirectory(
        appIdentity: LungfishAppIdentity = .current,
        libraryDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> URL {
        let library = libraryDirectory
            ?? fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(
                "Library",
                isDirectory: true
            )
        return library
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent(appIdentity.logDirectoryName, isDirectory: true)
            .appendingPathComponent("Operations", isDirectory: true)
    }

    private static func render(item: OperationCenter.Item) -> String {
        var lines: [String] = []
        lines.append("Lungfish Operation Log")
        lines.append("Operation: \(item.title)")
        lines.append("Operation ID: \(item.id.uuidString)")
        lines.append("Type: \(item.operationType.rawValue)")
        lines.append("State: \(item.displayStateLabel)")
        lines.append("Started: \(displayTimestamp(item.startedAt))")
        if let finishedAt = item.finishedAt {
            lines.append("Finished: \(displayTimestamp(finishedAt))")
        }
        lines.append("Progress: \(item.displayProgressLabel)")
        lines.append("Log scope: bounded captured preview; exported snapshot includes retained entries only.")

        if !item.detail.isEmpty {
            lines.append("")
            lines.append("Detail:")
            lines.append(item.detail)
        }

        if let cliCommand = item.cliCommand {
            lines.append("")
            lines.append("CLI Command:")
            lines.append(cliCommand)
        }

        if !item.outputURLs.isEmpty {
            lines.append("")
            lines.append("Output Files:")
            item.outputURLs.forEach { lines.append($0.path) }
        }

        if let errorMessage = item.errorMessage {
            lines.append("")
            lines.append("Error:")
            lines.append(errorMessage)
        }

        if let errorDetail = item.errorDetail {
            lines.append("")
            lines.append("Error Detail:")
            lines.append(errorDetail)
        }

        if !item.logEntries.isEmpty {
            lines.append("")
            lines.append("Log Entries:")
            item.logEntries.forEach { entry in
                lines.append("[\(displayTimestamp(entry.timestamp))] [\(entry.level.rawValue.uppercased())] \(entry.message)")
            }
        }

        if !item.retryEvents.isEmpty {
            lines.append("")
            lines.append("Retry Metadata:")
            item.retryEvents.forEach { retry in
                lines.append(
                    "[\(displayTimestamp(retry.timestamp))] HTTP \(retry.statusCode) attempt \(retry.attempt)/\(retry.maxRetries); next retry in \(retry.delaySeconds)s"
                )
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private static func slug(_ value: String) -> String {
        let slug = value
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return String((slug.isEmpty ? "operation" : slug).prefix(48))
    }

    private static func displayTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"
        return formatter.string(from: date)
    }

    private static func fileTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
