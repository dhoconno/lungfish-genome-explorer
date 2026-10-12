// NextflowEngineLog.swift - A run's nextflow.log, written at its final name while the engine runs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import LungfishCore
import os.log

private let logger = Logger(subsystem: LogSubsystem.workflow, category: "NextflowEngineProcess")

/// A run's `nextflow.log`, written at its final name while the engine runs (N8).
///
/// The bytes are those TaxTriage wrote in one piece once its engine had returned. The preamble comes
/// first, then `\n--- stdout ---\n` and the stdout lines joined by line breaks, then
/// `\n--- stderr ---\n` and the stderr lines joined the same way. Stdout goes into the log line by
/// line. Stderr goes into a sidecar in the scratch and joins the log once the engine has ended, so a
/// KILL leaves no stderr in the log (API brief risk 3). A write that fails is logged, and the run goes
/// on, as it did when the log was written at the end with `try?`.
struct NextflowEngineLog: Sendable {
    /// The sidecar's name in the scratch's launch folder.
    static let stderrSidecarName = ".lungfish-engine-stderr.txt"

    let logFile: URL
    let stderrSidecar: URL
    private let logDescriptor: Int32
    private let sidecarDescriptor: Int32
    private let tailLineCount: Int

    private init(logFile: URL, stderrSidecar: URL, logDescriptor: Int32, sidecarDescriptor: Int32, tailLineCount: Int) {
        self.logFile = logFile
        self.stderrSidecar = stderrSidecar
        self.logDescriptor = logDescriptor
        self.sidecarDescriptor = sidecarDescriptor
        self.tailLineCount = max(0, tailLineCount)
    }

    /// Creates the log at its final name with the preamble, and the empty stderr sidecar.
    ///
    /// - Throws: ``NextflowEngineError/logNotWritable(path:reason:)`` when either file cannot be created.
    static func create(at logFile: URL, preamble: String, stderrSidecar: URL, tailLineCount: Int) throws -> NextflowEngineLog {
        let logDescriptor = Darwin.open(logFile.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
        guard logDescriptor >= 0 else {
            throw NextflowEngineError.logNotWritable(path: logFile.path, reason: String(cString: strerror(errno)))
        }
        let sidecarDescriptor = Darwin.open(stderrSidecar.path, O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        guard sidecarDescriptor >= 0 else {
            let reason = String(cString: strerror(errno))
            Darwin.close(logDescriptor)
            throw NextflowEngineError.logNotWritable(path: stderrSidecar.path, reason: reason)
        }
        let log = NextflowEngineLog(
            logFile: logFile,
            stderrSidecar: stderrSidecar,
            logDescriptor: logDescriptor,
            sidecarDescriptor: sidecarDescriptor,
            tailLineCount: tailLineCount
        )
        log.write(preamble, part: "preamble")
        return log
    }

    /// Writes the stdout heading, once the engine has launched.
    func beginStdout() {
        write("\n--- stdout ---\n", part: "stdout heading")
    }

    /// The part that writes stdout lines into the log.
    func stdoutStream() -> NextflowLogStream {
        NextflowLogStream(descriptor: logDescriptor, destination: logFile, tailLineCount: tailLineCount)
    }

    /// The part that writes stderr lines into the sidecar.
    func stderrStream() -> NextflowLogStream {
        NextflowLogStream(descriptor: sidecarDescriptor, destination: stderrSidecar, tailLineCount: tailLineCount)
    }

    /// Ends the log of a launch that failed with the launcher error part TaxTriage has written since
    /// before 2.9.
    func finish(launchFailure message: String) {
        write("\n--- launcher error ---\n" + message + "\n", part: "launcher error")
        synchronizeAndClose()
    }

    /// Ends the log once the engine's tree is gone. The stderr heading and the sidecar's bytes follow
    /// the stdout lines, then the log is synchronized at its final name, so the bytes a step hashes
    /// are on disk, and the sidecar goes.
    func finish(stdout: NextflowLogStream, stderr: NextflowLogStream) {
        stdout.reportWriteFailure()
        stderr.reportWriteFailure()
        write("\n--- stderr ---\n", part: "stderr heading")
        appendSidecar()
        synchronizeAndClose()
    }

    private func write(_ text: String, part: String) {
        guard let failure = Self.writeAll(text, to: logDescriptor) else { return }
        logger.warning(
            "Could not write the \(part, privacy: .public) of \(logFile.path, privacy: .public): \(String(cString: strerror(failure)), privacy: .public)"
        )
    }

    private func appendSidecar() {
        guard Darwin.lseek(sidecarDescriptor, 0, SEEK_SET) == 0 else {
            logger.warning("Could not read back \(stderrSidecar.path, privacy: .public): \(String(cString: strerror(errno)), privacy: .public)")
            return
        }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(sidecarDescriptor, $0.baseAddress, $0.count) }
            if count == 0 { return }
            if count < 0 {
                if errno == EINTR { continue }
                logger.warning("Could not read back \(stderrSidecar.path, privacy: .public): \(String(cString: strerror(errno)), privacy: .public)")
                return
            }
            let failure = buffer.withUnsafeBytes { Self.writeAll(UnsafeRawBufferPointer(rebasing: $0[..<count]), to: logDescriptor) }
            if let failure {
                logger.warning(
                    "Could not write the stderr part of \(logFile.path, privacy: .public): \(String(cString: strerror(failure)), privacy: .public)"
                )
                return
            }
        }
    }

    private func synchronizeAndClose() {
        if Darwin.fsync(logDescriptor) != 0 {
            logger.warning("Could not synchronize \(logFile.path, privacy: .public): \(String(cString: strerror(errno)), privacy: .public)")
        }
        Darwin.close(logDescriptor)
        Darwin.close(sidecarDescriptor)
        Darwin.unlink(stderrSidecar.path)
    }

    /// Writes every byte of `text` as UTF-8, going on after a short write or an interrupt.
    ///
    /// - Returns: The `errno` of a write that failed, or nil.
    static func writeAll(_ text: String, to descriptor: Int32) -> Int32? {
        var text = text
        return text.withUTF8 { writeAll(UnsafeRawBufferPointer($0), to: descriptor) }
    }

    static func writeAll(_ bytes: UnsafeRawBufferPointer, to descriptor: Int32) -> Int32? {
        var offset = 0
        while offset < bytes.count, let base = bytes.baseAddress {
            let written = Darwin.write(descriptor, base + offset, bytes.count - offset)
            if written < 0 {
                if errno == EINTR { continue }
                return errno
            }
            offset += written
        }
        return nil
    }
}

/// One stream's part of a run's log, written line by line as the engine prints, with a bounded tail.
struct NextflowLogStream: Sendable {
    private let descriptor: Int32
    private let destination: URL
    private let tailLineCount: Int
    private var lineCount = 0
    private var recent: [String] = []
    private var failedWrite: Int32?

    init(descriptor: Int32, destination: URL, tailLineCount: Int) {
        self.descriptor = descriptor
        self.destination = destination
        self.tailLineCount = tailLineCount
    }

    /// The last lines, at most the tail count.
    var tail: [String] { Array(recent.suffix(tailLineCount)) }

    /// Writes each line of `stream` as it arrives, with a line break before every line but the
    /// first, hands it to `onLine` once written, and returns the part once the stream ends.
    func drained(_ stream: AsyncStream<String>, onLine: (@Sendable (String) -> Void)?) async -> NextflowLogStream {
        var part = self
        for await line in stream {
            part.append(line)
            onLine?(line)
        }
        return part
    }

    /// Writes one line. Once a write has failed nothing more is written, so the part never has a gap.
    mutating func append(_ line: String) {
        if failedWrite == nil {
            failedWrite = NextflowEngineLog.writeAll(lineCount == 0 ? line : "\n" + line, to: descriptor)
        }
        lineCount += 1
        guard tailLineCount > 0 else { return }
        recent.append(line)
        if recent.count >= 2 * tailLineCount {
            recent.removeFirst(recent.count - tailLineCount)
        }
    }

    func reportWriteFailure() {
        guard let failedWrite else { return }
        logger.warning(
            "Could not write all Nextflow output to \(destination.path, privacy: .public): \(String(cString: strerror(failedWrite)), privacy: .public)"
        )
    }
}
