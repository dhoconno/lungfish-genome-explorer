// SequenceExportCompressor.swift - Compress an exported sequence file with gzip or zstd and name the result only when it is whole
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import os

/// The one place a sequence export is compressed (Phase 2.11 lane A49 M3), for `lungfish-cli convert --compress`
/// and for the Import Center's export of a captured selection, which has no file for `convert` to read.
///
/// gzip goes through ``DurableGzip``, the gzip helper of lane S62. zstd follows the same rule on ``ToolProcess``.
/// The compressor's standard output streams into a hidden part file in the destination's folder, which
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

    /// Why ``compress(source:to:kind:)`` published no file.
    package enum CompressionError: Error, LocalizedError, Sendable, Equatable {
        /// No zstd binary sits in any place that ``zstdCandidates`` lists.
        case compressorNotFound(searched: [String])
        /// zstd ended with a nonzero status, or a signal ended it.
        case compressorFailed(exitCode: Int32, stderr: String)
        /// zstd exited with status 0, but a process it started kept the output open, so the bytes may be short.
        case incompleteOutput(String)

        package var errorDescription: String? {
            switch self {
            case .compressorNotFound(let searched):
                return "zstd is not installed. macOS does not ship it. Install it with Homebrew (brew install zstd) "
                    + "or export with gzip. Looked in \(searched.joined(separator: ", "))."
            case .compressorFailed(let exitCode, let stderr):
                let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return detail.isEmpty ? "zstd failed with exit code \(exitCode)" : "zstd failed with exit code \(exitCode): \(detail)"
            case .incompleteOutput(let reason):
                return reason
            }
        }
    }

    /// Where zstd is looked for, in this order. macOS ships none in /usr/bin, which is the only place the export
    /// looked before this lane, so the places Homebrew installs it follow. `/usr/local/bin` is Homebrew's folder on
    /// an Intel Mac. The folder of a Homebrew on Apple silicon comes from the `HOMEBREW_PREFIX` variable when the
    /// environment carries it (`brew shellenv` sets it), because no source file names that prefix
    /// (ReleaseBuildConfigurationTests polices it). A zstd that only the PATH holds is not found. This is a
    /// stopgap until zstd is a managed tool.
    package static var zstdCandidates: [String] {
        zstdSearchList(homebrewPrefix: getenv("HOMEBREW_PREFIX").map { String(cString: $0) })
    }

    /// The places ``zstdCandidates`` lists for a given value of `HOMEBREW_PREFIX`, with the environment left out so
    /// a test can drive it. A value that is not an absolute path is ignored.
    package static func zstdSearchList(homebrewPrefix: String?) -> [String] {
        var paths = ["/usr/bin/zstd"]
        if var prefix = homebrewPrefix, prefix.hasPrefix("/") {
            while prefix.count > 1, prefix.hasSuffix("/") { prefix.removeLast() }
            paths.append(prefix == "/" ? "/bin/zstd" : prefix + "/bin/zstd")
        }
        paths.append("/usr/local/bin/zstd")
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    /// The first zstd in `candidates` that can run, or nil.
    package static func zstdExecutable(candidates: [String] = zstdCandidates) -> URL? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// Writes `source` compressed as `destination`, swapping out a regular file the name holds. `source` stays.
    /// A cancel of the calling task stops the compressor and throws `CancellationError`.
    ///
    /// - Throws: ``DurableGzipError`` or ``CompressionError`` when the compressor fails,
    ///   ``DurableReplace/ReplaceError`` when the part file cannot be written or published.
    @concurrent
    package static func compress(source: URL, to destination: URL, kind: Kind) async throws {
        let relay = CancelRelay()
        do {
            try await withTaskCancellationHandler {
                switch kind {
                case .gzip:
                    let cancellation = ToolProcessCancellation()
                    relay.attach { cancellation.cancel() }
                    try DurableGzip.compress(source: source, to: destination, cancellation: cancellation)
                case .zstd:
                    try compressWithZstd(source: source, to: destination, relay: relay)
                }
            } onCancel: {
                relay.cancel()
            }
        } catch let error as ToolProcessError {
            if case .cancelled = error { throw CancellationError() }
            throw error
        }
    }

    private static func compressWithZstd(source: URL, to destination: URL, relay: CancelRelay) throws {
        guard let executable = zstdExecutable() else {
            throw CompressionError.compressorNotFound(searched: zstdCandidates)
        }
        let spec = ToolProcessSpec(
            executableURL: executable,
            arguments: ["-c", source.path],
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
