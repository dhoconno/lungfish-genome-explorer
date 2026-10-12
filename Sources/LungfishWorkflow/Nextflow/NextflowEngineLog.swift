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
/// KILL leaves no stderr in the log (API brief risk 3). A write that fails is logged and the run goes
/// on, and ``finish(stdout:stderr:)`` returns the first failure, so the caller fails a run whose log
/// is incomplete or unsynchronized.
struct NextflowEngineLog: Sendable {
    /// The sidecar's name in the scratch's launch folder.
    static let stderrSidecarName = ".lungfish-engine-stderr.txt"

    let logFile: URL
    let stderrSidecar: URL
    private let logDescriptor: Int32
    private let sidecarDescriptor: Int32
    private let tailLineCount: Int
    /// The first failed write of the preamble or the stdout heading, or nil.
    private var openingFailure: String?

    private init(logFile: URL, stderrSidecar: URL, logDescriptor: Int32, sidecarDescriptor: Int32, tailLineCount: Int) {
        self.logFile = logFile
        self.stderrSidecar = stderrSidecar
        self.logDescriptor = logDescriptor
        self.sidecarDescriptor = sidecarDescriptor
        self.tailLineCount = max(0, tailLineCount)
    }

    /// Creates the log at its final name with the preamble, and the empty stderr sidecar.
    ///
    /// Each file is new. Whatever sits at its path goes first, so a symbolic or hard link left there,
    /// in a reused output folder or one copied from a bundle, is replaced and never written through,
    /// as the atomic write before 2.9 replaced it (SWIFT 6).
    ///
    /// - Throws: ``NextflowEngineError/logNotWritable(path:reason:)`` when either file cannot be created.
    static func create(at logFile: URL, preamble: String, stderrSidecar: URL, tailLineCount: Int) throws -> NextflowEngineLog {
        let logDescriptor = try openNewFile(at: logFile, access: O_WRONLY, mode: 0o644)
        let sidecarDescriptor: Int32
        do {
            sidecarDescriptor = try openNewFile(at: stderrSidecar, access: O_RDWR, mode: 0o600)
        } catch {
            Darwin.close(logDescriptor)
            throw error
        }
        var log = NextflowEngineLog(
            logFile: logFile,
            stderrSidecar: stderrSidecar,
            logDescriptor: logDescriptor,
            sidecarDescriptor: sidecarDescriptor,
            tailLineCount: tailLineCount
        )
        log.openingFailure = log.write(preamble, part: "preamble")
        return log
    }

    /// Removes whatever is at `url`, then creates a new file there that no link can redirect, the
    /// flags `DurableAtomicFileStore` creates its files with.
    private static func openNewFile(at url: URL, access: Int32, mode: mode_t) throws -> Int32 {
        if Darwin.unlink(url.path) != 0, errno != ENOENT {
            throw NextflowEngineError.logNotWritable(path: url.path, reason: String(cString: strerror(errno)))
        }
        let descriptor = Darwin.open(url.path, access | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard descriptor >= 0 else {
            throw NextflowEngineError.logNotWritable(path: url.path, reason: String(cString: strerror(errno)))
        }
        return descriptor
    }

    /// Writes the stdout heading, once the engine has launched.
    mutating func beginStdout() {
        let failure = write("\n--- stdout ---\n", part: "stdout heading")
        openingFailure = openingFailure ?? failure
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
    ///
    /// - Returns: Why the log is incomplete or unsynchronized, the first failure of the preamble and
    ///   the stdout heading, then of the stdout lines, then of the stderr lines, then of the stderr
    ///   heading, the sidecar's read-back and copy and the `fsync`, or nil when every byte is in place.
    func finish(stdout: NextflowLogStream, stderr: NextflowLogStream) -> String? {
        stdout.reportWriteFailure()
        stderr.reportWriteFailure()
        let heading = write("\n--- stderr ---\n", part: "stderr heading")
        let sidecar = appendSidecar()
        let synchronization = synchronizeAndClose()
        return openingFailure ?? stdout.writeFailure ?? stderr.writeFailure ?? heading ?? sidecar ?? synchronization
    }

    /// Writes `text` into the log, and returns why it could not, or nil.
    @discardableResult
    private func write(_ text: String, part: String) -> String? {
        guard let failure = Self.writeAll(text, to: logDescriptor) else { return nil }
        let reason = "Could not write the \(part) of \(logFile.path): \(String(cString: strerror(failure)))"
        logger.warning("\(reason, privacy: .public)")
        return reason
    }

    /// Copies the sidecar's bytes into the log, and returns why it could not, or nil.
    private func appendSidecar() -> String? {
        guard Darwin.lseek(sidecarDescriptor, 0, SEEK_SET) == 0 else {
            return Self.warn("Could not read back \(stderrSidecar.path): \(String(cString: strerror(errno)))")
        }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(sidecarDescriptor, $0.baseAddress, $0.count) }
            if count == 0 { return nil }
            if count < 0 {
                if errno == EINTR { continue }
                return Self.warn("Could not read back \(stderrSidecar.path): \(String(cString: strerror(errno)))")
            }
            let failure = buffer.withUnsafeBytes { Self.writeAll(UnsafeRawBufferPointer(rebasing: $0[..<count]), to: logDescriptor) }
            if let failure {
                return Self.warn("Could not write the stderr part of \(logFile.path): \(String(cString: strerror(failure)))")
            }
        }
    }

    /// Synchronizes and closes the log, closes and removes the sidecar, and returns why the log could
    /// not be synchronized, or nil.
    @discardableResult
    private func synchronizeAndClose() -> String? {
        var failure: String?
        if Darwin.fsync(logDescriptor) != 0 {
            failure = Self.warn("Could not synchronize \(logFile.path): \(String(cString: strerror(errno)))")
        }
        Darwin.close(logDescriptor)
        Darwin.close(sidecarDescriptor)
        Darwin.unlink(stderrSidecar.path)
        return failure
    }

    /// Logs `reason` as a warning and returns it.
    private static func warn(_ reason: String) -> String {
        logger.warning("\(reason, privacy: .public)")
        return reason
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
    /// The destination and the reason of the first write that failed, or nil.
    private(set) var writeFailure: String?

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

    /// Writes one line. Once a write has failed nothing more is written, so the part never has a gap,
    /// and the line still counts in the tail.
    mutating func append(_ line: String) {
        if writeFailure == nil, let failure = NextflowEngineLog.writeAll(lineCount == 0 ? line : "\n" + line, to: descriptor) {
            writeFailure = "Could not write all Nextflow output to \(destination.path): \(String(cString: strerror(failure)))"
        }
        lineCount += 1
        guard tailLineCount > 0 else { return }
        recent.append(line)
        if recent.count >= 2 * tailLineCount {
            recent.removeFirst(recent.count - tailLineCount)
        }
    }

    func reportWriteFailure() {
        guard let writeFailure else { return }
        logger.warning("\(writeFailure, privacy: .public)")
    }
}
