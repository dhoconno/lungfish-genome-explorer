// SequenceExportCompressor.swift - Compress an exported sequence file with gzip or zstd and name the result only when it is whole
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import os

/// The one place a sequence export is compressed (Phase 2.11 lane A49 M3), for `lungfish-cli convert --compress`
/// and for the Import Center's export of a captured selection, which has no file for `convert` to read.
///
/// gzip goes through ``DurableGzip``, the gzip helper of lane S62. zstd follows the same rule on ``ToolProcess``
/// and runs the zstd that Lungfish manages, found through ``NativeToolRunner`` (Phase 2.13 lane 13.17 M3). The
/// compressor's standard output streams into a hidden part file in the destination's folder, which
/// ``DurableReplace`` syncs and publishes under the destination name, so a compressor that dies, a cancel and a
/// full disk leave the destination as it was and never a cut file under a name a reader trusts. The child gets
/// an empty environment, so the bytes never depend on the user's shell, and ``ToolProcess`` drains standard
/// error while it runs.
///
/// A gzip header holds the name and the modification time of the file it compressed, so two runs differ in
/// those bytes. The text after decompression is what a reader compares.
package enum SequenceExportCompressor {
    /// The compressors a sequence export offers.
    package enum Kind: String, CaseIterable, Sendable {
        case gzip
        case zstd

        /// The file extension a compressed export carries.
        package var fileExtension: String {
            switch self {
            case .gzip: return "gz"
            case .zstd: return "zst"
            }
        }
    }

    /// What a compression ran, for the record of the command that asked for it (lane 13.17 M3, BIO 4). gzip runs
    /// the system tool and has no receipt. zstd names the executable of its managed environment and the arguments
    /// it ran with, so the step of the record reads the version from the environment that ran.
    package struct Receipt: Sendable, Equatable {
        /// The managed tool, which is also its lock entry, such as `zstd`.
        package let toolName: String
        /// The executable that ran, in the `bin` folder of its conda environment.
        package let executable: URL
        /// The arguments it ran with.
        package let arguments: [String]

        package init(toolName: String, executable: URL, arguments: [String]) {
            self.toolName = toolName
            self.executable = executable
            self.arguments = arguments
        }
    }

    /// Why ``compress(source:to:kind:runner:)`` published no file.
    package enum CompressionError: Error, LocalizedError, Sendable, Equatable {
        /// Lungfish has not installed the zstd it manages.
        case compressorNotFound
        /// zstd ended with a nonzero status, or a signal ended it.
        case compressorFailed(exitCode: Int32, stderr: String)
        /// zstd exited with status 0, but a process it started kept the output open, so the bytes may be short.
        case incompleteOutput(String)

        package var errorDescription: String? {
            switch self {
            case .compressorNotFound:
                return "zstd is not installed. macOS does not ship it, and Lungfish installs it with its Required Setup. "
                    + "In the app, open the Welcome window and click Install, or run "
                    + "lungfish-cli tools update --apply --yes --required-only. You can also export with gzip."
            case .compressorFailed(let exitCode, let stderr):
                let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return detail.isEmpty ? "zstd failed with exit code \(exitCode)" : "zstd failed with exit code \(exitCode): \(detail)"
            case .incompleteOutput(let reason):
                return reason
            }
        }
    }

    /// Writes `source` compressed as `destination`, swapping out a regular file the name holds. `source` stays.
    /// A cancel of the calling task stops the compressor and throws `CancellationError`.
    ///
    /// zstd is a managed tool of Lungfish, found through `runner`, and the receipt names the executable that ran.
    /// gzip stays on the system tool and returns nil.
    ///
    /// - Throws: ``DurableGzipError`` or ``CompressionError`` when the compressor fails or zstd is not installed,
    ///   ``DurableReplace/ReplaceError`` when the part file cannot be written or published.
    @concurrent
    @discardableResult
    package static func compress(
        source: URL,
        to destination: URL,
        kind: Kind,
        runner: NativeToolRunner = .shared
    ) async throws -> Receipt? {
        let relay = CancelRelay()
        do {
            return try await withTaskCancellationHandler { () async throws -> Receipt? in
                switch kind {
                case .gzip:
                    let cancellation = ToolProcessCancellation()
                    relay.attach { cancellation.cancel() }
                    try DurableGzip.compress(source: source, to: destination, cancellation: cancellation)
                    return nil
                case .zstd:
                    let executable = try await managedZstd(runner)
                    return try compressWithZstd(source: source, to: destination, executable: executable, relay: relay)
                }
            } onCancel: {
                relay.cancel()
            }
        } catch let error as ToolProcessError {
            if case .cancelled = error { throw CancellationError() }
            throw error
        }
    }

    /// The zstd of the managed environment, or ``CompressionError/compressorNotFound`` when it is not installed.
    private static func managedZstd(_ runner: NativeToolRunner) async throws -> URL {
        do {
            return try await runner.toolPath(for: .zstd)
        } catch let error as NativeToolError {
            if case .toolNotFound = error { throw CompressionError.compressorNotFound }
            throw error
        }
    }

    private static func compressWithZstd(
        source: URL,
        to destination: URL,
        executable: URL,
        relay: CancelRelay
    ) throws -> Receipt {
        let arguments = ["-c", source.path]
        let spec = ToolProcessSpec(
            executableURL: executable,
            arguments: arguments,
            environment: [:],
            stdout: .stream,
            label: "zstd"
        )
        try DurableReplace.replace(
            named: destination.lastPathComponent,
            in: destination.deletingLastPathComponent(),
            recovery: .none
        ) { stage in
            try streamZstd(spec, into: stage, relay: relay)
        }
        return Receipt(toolName: "zstd", executable: executable, arguments: arguments)
    }

    /// Runs `spec` and writes its standard output into `stage`, or throws and leaves the stage to be removed.
    private static func streamZstd(
        _ spec: ToolProcessSpec,
        into stage: DurableReplace.StageWriter,
        relay: CancelRelay
    ) throws {
        let run = try ToolProcess.start(spec)
        relay.attach { run.cancel() }
        var writeFailure: (any Error)?
        while true {
            let chunk = run.stdout.read(upTo: 1 << 20)
            if chunk.isEmpty { break }
            do {
                try stage.write(chunk)
            } catch {
                // A full disk ends the copy. zstd would block on the full pipe, so it is stopped before the wait.
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
                throw CompressionError.incompleteOutput(reason)
            }
            throw CompressionError.compressorFailed(exitCode: result.status, stderr: result.stderrText)
        }
    }

    /// Hands a cancel of the calling task to whichever compressor started, even one that starts afterwards.
    private final class CancelRelay: Sendable {
        private let state = OSAllocatedUnfairLock<(cancelled: Bool, handler: (@Sendable () -> Void)?)>(
            initialState: (false, nil)
        )

        func attach(_ handler: @escaping @Sendable () -> Void) {
            let alreadyCancelled = state.withLock { current -> Bool in
                current.handler = handler
                return current.cancelled
            }
            if alreadyCancelled { handler() }
        }

        func cancel() {
            let handler = state.withLock { current -> (@Sendable () -> Void)? in
                current.cancelled = true
                return current.handler
            }
            handler?()
        }
    }
}
