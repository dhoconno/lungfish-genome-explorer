// GzipChildStream.swift - One gzip child, read by a synchronous caller through ToolProcess
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

/// `gzip -dc` as a ``ToolProcessSpec``, and the words its failures give.
enum GzipTool {
    static let executableURL = URL(fileURLWithPath: "/usr/bin/gzip")

    /// The spec of `gzip -dc <url>`. The environment is the caller's, as `Process` gave it, and stderr keeps the
    /// default capture so a failure can report gzip's own message.
    static func spec(decompressing url: URL, stdout: ToolProcessOutput) -> ToolProcessSpec {
        spec(arguments: ["-dc", url.path], stdout: stdout, executableURL: executableURL)
    }

    static func spec(arguments: [String], stdout: ToolProcessOutput, executableURL: URL) -> ToolProcessSpec {
        ToolProcessSpec(
            executableURL: executableURL,
            arguments: arguments,
            environment: ToolProcessSpec.inheritedEnvironment(),
            stdout: stdout,
            label: "gzip"
        )
    }

    /// The error of a run that did not succeed. gzip's own message when it wrote one, else the reason its output
    /// is incomplete, else its exit code.
    static func failure(of result: ToolProcessResult) -> GzipError {
        let text = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return .decompressionFailed(text) }
        if result.termination == .exited(code: 0), let reason = result.incompleteOutputReason {
            return .decompressionFailed(reason)
        }
        return .decompressionFailed("gzip exited with code \(result.status)")
    }

    /// The error of a run that could not start, stopped or timed out.
    static func launchFailure(_ error: ToolProcessError) -> GzipError {
        if case .launchFailed(_, let reason, _) = error {
            return .decompressionFailed("Failed to launch gzip: \(reason)")
        }
        return .decompressionFailed("Failed to launch gzip: \(error.localizedDescription)")
    }

    /// The whole decompressed content of `url`, held in memory, for a caller that needs all of it.
    static func decompressedData(of url: URL) throws -> Data {
        let result: ToolProcessResult
        do throws(ToolProcessError) {
            result = try ToolProcess.runBlocking(spec(decompressing: url, stdout: .capture(limit: nil)))
        } catch {
            throw launchFailure(error)
        }
        guard result.isSuccess else { throw failure(of: result) }
        return result.stdout
    }
}

/// A running `gzip -dc` whose standard output a synchronous caller pulls with ``readChunk(upTo:)``.
///
/// The child runs on ``ToolProcess/start(_:onEvent:onLaunch:)`` with a streamed stdout, so the pipe holds gzip back
/// while the caller is slower, memory stays at one chunk, and nothing blocks except the caller's own thread. Read to
/// end of file and call ``finish()``, or stop early and call ``close()``, which cancels the run, so ToolProcess ends
/// the process group and tree and reaps it before ``close()`` returns. Used from one thread at a time.
final class GzipChildStream {
    private let run: ToolProcessRun

    /// Starts gzip with `arguments`. Throws a ``GzipError`` when the executable cannot start.
    init(arguments: [String], executableURL: URL = GzipTool.executableURL) throws {
        let started: ToolProcessRun
        do throws(ToolProcessError) {
            started = try ToolProcess.start(GzipTool.spec(arguments: arguments, stdout: .stream, executableURL: executableURL))
        } catch {
            throw GzipTool.launchFailure(error)
        }
        if started.pid == nil {
            // The spawn failed, which `Process.run()` reported here and ToolProcess reports at the first wait.
            do throws(ToolProcessError) {
                _ = try started.waitBlocking()
            } catch {
                throw GzipTool.launchFailure(error)
            }
            throw GzipError.decompressionFailed("Failed to launch gzip")
        }
        run = started
    }

    convenience init(decompressing url: URL) throws {
        try self.init(arguments: ["-dc", url.path])
    }

    /// The process ID of gzip.
    var pid: Int32? { run.pid }

    /// Up to `count` bytes, waiting until gzip has written that many or closed its output. Empty at end of file.
    func readChunk(upTo count: Int) -> Data {
        var chunk = run.stdout.read(upTo: count)
        while !chunk.isEmpty, chunk.count < count {
            let more = run.stdout.read(upTo: count - chunk.count)
            if more.isEmpty { break }
            chunk.append(more)
        }
        return chunk
    }

    /// Waits for gzip to exit once ``readChunk(upTo:)`` has returned empty, and throws gzip's own message when it
    /// failed or its output is incomplete.
    func finish() throws {
        let result: ToolProcessResult
        do throws(ToolProcessError) {
            result = try run.waitBlocking()
        } catch {
            throw GzipTool.launchFailure(error)
        }
        guard result.isSuccess else { throw GzipTool.failure(of: result) }
    }

    /// Stops gzip when it still runs and waits until it is reaped. Safe to call again and after ``finish()``.
    func close() {
        run.cancel()
        _ = try? run.waitBlocking()
    }
}
