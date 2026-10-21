// DurableGzip.swift - Compress a file with the system gzip and name the result only when it is whole
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Why ``DurableGzip/compress(source:to:cancellation:)`` published no file.
public enum DurableGzipError: Error, LocalizedError, Sendable, Equatable {
    /// gzip ended with a nonzero status, or a signal ended it, in which case `exitCode` is the signal number, as
    /// `Process.terminationStatus` reports it. `stderr` is what gzip printed, the last 4 MB at most.
    case gzipFailed(exitCode: Int32, stderr: String)
    /// gzip exited with status 0, but a process it started kept the output open or reading it failed, so the
    /// bytes may be short and are not published.
    case incompleteOutput(String)

    public var errorDescription: String? {
        switch self {
        case .gzipFailed(let exitCode, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.isEmpty {
                return "gzip failed with exit code \(exitCode)"
            }
            return "gzip failed with exit code \(exitCode): \(detail)"
        case .incompleteOutput(let reason):
            return reason
        }
    }
}

/// Compresses a file with `/usr/bin/gzip -c` and names the `.gz` only when it is whole and synced.
///
/// This is the one gzip helper of the app (Phase 2.11 lane S62, SWIFT R12). The bytes that gzip writes to its
/// standard output stream through ``ToolProcess`` into a hidden part file in the destination's folder, which
/// ``DurableReplace`` syncs and publishes under the destination name. So a gzip that dies, a cancel, a full disk
/// and a crash of the app all leave the destination as it was, the old file or none, and never a cut `.gz` under
/// a name a reader trusts. A failed run removes its part file, and a crash leaves it under its hidden name.
///
/// The bytes are those of `gzip -c <source>`, which records the name and the modification time of `source` in
/// its header, so a record that replays `/usr/bin/gzip -c <source> > <destination>` states the same digest.
/// gzip reads its default options from the `GZIP` variable, so the child gets an empty environment and the
/// bytes never depend on the user's shell. ``ToolProcess`` drains standard error while gzip runs, so a gzip that
/// logs more than a pipe holds never blocks on it.
///
/// The call blocks the calling thread until gzip has ended, so never call it on the main thread.
public enum DurableGzip {
    /// The system gzip.
    public static let executableURL = URL(fileURLWithPath: "/usr/bin/gzip")

    /// The most bytes one read takes from gzip.
    static let chunkSize = 1 << 20

    /// Writes `source` compressed as `destination`, swapping out a regular file the name holds.
    ///
    /// - Parameters:
    ///   - source: The file to compress, which stays.
    ///   - destination: The `.gz` to publish. Its folder must exist.
    ///   - cancellation: Stops gzip from another thread, as task cancellation stops ``ToolProcess/run(_:onEvent:onLaunch:)``.
    /// - Throws: ``DurableGzipError`` when gzip fails, ``ToolProcessError`` when it cannot run or is cancelled,
    ///   and ``DurableReplace/ReplaceError`` when the part file cannot be written or published.
    public static func compress(
        source: URL,
        to destination: URL,
        cancellation: ToolProcessCancellation? = nil
    ) throws {
        try compress(source: source, to: destination, using: executableURL, cancellation: cancellation)
    }

    /// The same with another executable that follows gzip's command line, for a test that needs a gzip which
    /// logs, fails or hangs.
    package static func compress(
        source: URL,
        to destination: URL,
        using executable: URL,
        cancellation: ToolProcessCancellation?
    ) throws {
        let spec = ToolProcessSpec(
            executableURL: executable,
            arguments: ["-c", source.path],
            environment: [:],
            stdout: .stream,
            label: "gzip"
        )
        try DurableReplace.replace(
            named: destination.lastPathComponent,
            in: destination.deletingLastPathComponent(),
            recovery: .none
        ) { stage in
            try stream(spec, into: stage, cancellation: cancellation)
        }
    }

    /// Runs `spec` and writes its standard output into `stage`, or throws and leaves the stage to be removed.
    private static func stream(
        _ spec: ToolProcessSpec,
        into stage: DurableReplace.StageWriter,
        cancellation: ToolProcessCancellation?
    ) throws {
        let run = try ToolProcess.start(spec)
        let token = cancellation?.register { run.cancel() }
        defer {
            if let token { cancellation?.unregister(token) }
        }
        var writeFailure: (any Error)?
        while true {
            let chunk = run.stdout.read(upTo: chunkSize)
            if chunk.isEmpty { break }
            do {
                try stage.write(chunk)
            } catch {
                // A full disk ends the copy. gzip would block on the full pipe, so it is stopped before the wait.
                writeFailure = error
                run.cancel()
                break
            }
        }
        let result: ToolProcessResult
        do {
            result = try run.waitBlocking()
        } catch {
            throw writeFailure ?? error
        }
        if let writeFailure { throw writeFailure }
        guard result.isSuccess else {
            if result.termination == .exited(code: 0), let reason = result.incompleteOutputReason {
                throw DurableGzipError.incompleteOutput(reason)
            }
            throw DurableGzipError.gzipFailed(exitCode: result.status, stderr: result.stderrText)
        }
    }
}
