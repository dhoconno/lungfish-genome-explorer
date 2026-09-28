// BAMHeaderPathSanitizer.swift - Keep private paths out of BAM headers LGE writes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import os.log

private let bamHeaderSanitizerLogger = Logger(subsystem: LogSubsystem.workflow, category: "BAMHeaderPathSanitizer")

/// Rewrites the private paths aligners and samtools leave in a BAM header.
///
/// minimap2, bwa and every samtools subcommand record their command line in
/// an `@PG CL:` field, naming the executable by its managed conda path and
/// every input and output by its absolute path. A BAM written into a project
/// or bundle keeps those lines, so LGE rewrites them with `PortablePath`
/// (project-relative, `<tool-root>`, `<workspace>`, `<external>` forms) and
/// reheaders the file. The program chain (`ID`, `PN`, `PP`, `VN`) and the
/// command shape survive; only the paths change.
public enum BAMHeaderPathSanitizer {
    /// The header with every line's private paths rewritten, or nil when no
    /// line changes.
    public static func sanitizedHeader(_ header: String, context: PortablePath.Context) -> String? {
        var changed = false
        let lines = header.split(separator: "\n", omittingEmptySubsequences: false).map { raw -> String in
            let line = String(raw)
            guard line.hasPrefix("@"), line.contains("/") else { return line }
            let sanitized = PortablePath.sanitize(text: line, context: context)
            if sanitized != line { changed = true }
            return sanitized
        }
        return changed ? lines.joined(separator: "\n") : nil
    }

    /// Rewrites the header of the BAM at `bamURL` in place when it lies in a
    /// project and names a private path. Returns true when the file
    /// changed; any index beside it is then stale and must be rebuilt.
    ///
    /// The rewrite uses `samtools reheader --no-PG`, which copies the record
    /// blocks unchanged and adds no `@PG` line of its own.
    @discardableResult
    public static func sanitizeInPlace(
        bamURL: URL,
        workspaceURLs: [URL] = [],
        runner: NativeToolRunner = .shared
    ) async throws -> Bool {
        guard let context = PortablePath.Context.forWriting(at: bamURL, workspaceURLs: workspaceURLs) else {
            return false
        }
        let headerResult = try await runner.run(
            .samtools,
            arguments: ["view", "-H", "--no-PG", bamURL.path],
            timeout: 300
        )
        guard headerResult.isSuccess else {
            throw BAMHeaderPathSanitizerError.headerReadFailed(bamURL, headerResult.stderr)
        }
        guard let sanitized = sanitizedHeader(headerResult.stdout, context: context) else {
            return false
        }

        let directory = bamURL.deletingLastPathComponent()
        let token = UUID().uuidString
        let headerURL = directory.appendingPathComponent(".\(bamURL.lastPathComponent).\(token).header.sam")
        let rewrittenURL = directory.appendingPathComponent(".\(bamURL.lastPathComponent).\(token).reheader.bam")
        defer {
            try? FileManager.default.removeItem(at: headerURL)
            try? FileManager.default.removeItem(at: rewrittenURL)
        }
        try sanitized.write(to: headerURL, atomically: true, encoding: .utf8)
        let reheaderResult = try await runner.runWithFileOutput(
            .samtools,
            arguments: ["reheader", "--no-PG", headerURL.path, bamURL.path],
            outputFile: rewrittenURL,
            workingDirectory: directory,
            timeout: 3_600
        )
        guard reheaderResult.isSuccess else {
            throw BAMHeaderPathSanitizerError.reheaderFailed(bamURL, reheaderResult.stderr)
        }
        _ = try FileManager.default.replaceItemAt(bamURL, withItemAt: rewrittenURL)
        bamHeaderSanitizerLogger.info("Rewrote private paths in the header of \(bamURL.lastPathComponent, privacy: .public)")
        return true
    }

    /// `sanitizeInPlace`, then rebuilds the `.bai` index at `indexURL` when
    /// the header changed. Failures are logged and leave the BAM as it was:
    /// an unreadable header or a missing samtools must not fail the caller.
    @discardableResult
    public static func sanitizeAndReindexIfNeeded(
        bamURL: URL,
        indexURL: URL,
        workspaceURLs: [URL] = [],
        runner: NativeToolRunner = .shared
    ) async -> Bool {
        guard PortablePath.Context.forWriting(at: bamURL, workspaceURLs: workspaceURLs) != nil else { return false }
        do {
            guard try await sanitizeInPlace(bamURL: bamURL, workspaceURLs: workspaceURLs, runner: runner) else {
                return false
            }
            let isCSI = indexURL.pathExtension.lowercased() == "csi"
            let temporaryIndex = indexURL.deletingLastPathComponent()
                .appendingPathComponent(".\(indexURL.lastPathComponent).\(UUID().uuidString).\(isCSI ? "csi" : "bai")")
            defer { try? FileManager.default.removeItem(at: temporaryIndex) }
            let indexResult = try await runner.run(
                .samtools,
                arguments: ["index", isCSI ? "-c" : "-b", "-o", temporaryIndex.path, bamURL.path],
                workingDirectory: bamURL.deletingLastPathComponent(),
                timeout: 3_600
            )
            guard indexResult.isSuccess else {
                throw BAMHeaderPathSanitizerError.reindexFailed(bamURL, indexResult.stderr)
            }
            _ = try FileManager.default.replaceItemAt(indexURL, withItemAt: temporaryIndex)
            return true
        } catch {
            bamHeaderSanitizerLogger.error("Could not rewrite BAM header paths in \(bamURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}

public enum BAMHeaderPathSanitizerError: Error, LocalizedError {
    case headerReadFailed(URL, String)
    case reheaderFailed(URL, String)
    case reindexFailed(URL, String)

    public var errorDescription: String? {
        switch self {
        case .headerReadFailed(let url, let stderr):
            return "Could not read the header of \(url.lastPathComponent): \(stderr)"
        case .reheaderFailed(let url, let stderr):
            return "Could not rewrite the header of \(url.lastPathComponent): \(stderr)"
        case .reindexFailed(let url, let stderr):
            return "Could not index \(url.lastPathComponent) after rewriting its header: \(stderr)"
        }
    }
}
