// ToolProcessRawStdout.swift - Reads a ToolProcess run's standard output as raw bytes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import LungfishCore
import Synchronization

/// Runs one process on ``ToolProcess`` and lets the caller read its standard
/// output as raw bytes while it runs.
///
/// ToolProcess hands over captured output whole once the process has exited,
/// or framed into lines that it cuts at 64 KB and splits at a lone CR. A
/// stream of gigabytes cannot be kept whole, and a SAM record of a long read
/// or a VCF line with a CR must reach its parser byte for byte. So standard
/// output goes into a pipe this type owns, handed to ToolProcess as
/// `/dev/fd/N`, and the caller reads it at its own pace, which holds the
/// process back when the caller is slower. ToolProcess still owns the launch,
/// standard error, the limits, cancellation, the termination of the process
/// group and tree, and reaping. Because the stream is a file to ToolProcess,
/// a descendant still holding it after the process exits is killed once the
/// drain grace period runs out, and the result says so.
///
/// Read from one thread at a time, then call ``finish()`` or
/// ``finishBlocking()`` once, which closes the read end.
final class ToolProcessRawStdout: Sendable {
    private let readFD: Int32
    private let run: Task<Result<ToolProcessResult, ToolProcessError>, Never>
    private let outcome: RunOutcome
    private let readEndClosed = Atomic<Bool>(false)
    private let readFailedFlag = Atomic<Bool>(false)

    /// Launches `spec` with its standard output replaced by the pipe.
    ///
    /// - Throws: ``ToolProcessError/launchFailed(label:reason:results:)`` when
    ///   the pipe cannot be created. A failure to launch the process itself
    ///   is reported by ``finish()``.
    init(_ spec: ToolProcessSpec, onLaunch: (@Sendable (Int32) -> Void)? = nil) throws(ToolProcessError) {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else {
            throw .launchFailed(label: spec.label, reason: "Could not create a pipe. \(String(cString: strerror(errno)))", results: [])
        }
        // Close-on-exec keeps a process launched elsewhere at the same moment
        // from inheriting either end and holding the pipe open.
        fds.forEach { _ = fcntl($0, F_SETFD, FD_CLOEXEC) }
        readFD = fds[0]
        let writeEnd = WriteEnd(fd: fds[1])
        var spec = spec
        spec.stdout = .file(URL(fileURLWithPath: "/dev/fd/\(fds[1])"))
        let outcome = RunOutcome()
        self.outcome = outcome
        run = Task.detached(priority: Task.currentPriority) {
            let result: Result<ToolProcessResult, ToolProcessError>
            do throws(ToolProcessError) {
                // ToolProcess opened its own copy of the write end before the
                // spawn, so once the child runs, the child's tree is the only
                // writer and end of file means it is done.
                result = .success(try await ToolProcess.run(spec, onLaunch: { pid in
                    writeEnd.close()
                    onLaunch?(pid)
                }))
            } catch {
                result = .failure(error)
            }
            writeEnd.close()
            outcome.store(result)
            return result
        }
    }

    /// True when a read failed with an error other than EINTR, so bytes after
    /// it are missing.
    var readFailed: Bool {
        readFailedFlag.load(ordering: .acquiring)
    }

    /// Reads up to `count` bytes, blocking until some arrive. Returns empty
    /// data at end of file or after a read error.
    func read(upTo count: Int) -> Data {
        var buffer = [UInt8](repeating: 0, count: count)
        while true {
            let got = buffer.withUnsafeMutableBytes { Darwin.read(readFD, $0.baseAddress, count) }
            if got > 0 { return Data(buffer[0..<got]) }
            if got == 0 { return Data() }
            if errno == EINTR { continue }
            readFailedFlag.store(true, ordering: .releasing)
            return Data()
        }
    }

    /// Reads on a GCD thread until end of file or until `consume` returns
    /// false, so an async caller never parks a cooperative thread on the pipe.
    func drain<State: Sendable>(
        _ initial: State,
        chunkSize: Int = 64 * 1024,
        _ consume: @escaping @Sendable (inout State, Data) -> Bool
    ) async -> State {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var state = initial
                while true {
                    let chunk = self.read(upTo: chunkSize)
                    if chunk.isEmpty || !consume(&state, chunk) { break }
                }
                continuation.resume(returning: state)
            }
        }
    }

    /// Ends the run early. ToolProcess terminates the process group and tree,
    /// and reads then reach end of file. Does nothing once the run has ended.
    func stop() {
        run.cancel()
    }

    /// Waits for the run to end and closes the read end.
    func finish() async -> Result<ToolProcessResult, ToolProcessError> {
        let result = await run.value
        closeReadEnd()
        return result
    }

    /// Waits for the run to end on the calling thread and closes the read
    /// end. For synchronous callers off the cooperative pool.
    func finishBlocking() -> Result<ToolProcessResult, ToolProcessError> {
        let result = outcome.wait()
        closeReadEnd()
        return result
    }

    deinit {
        closeReadEnd()
    }

    private func closeReadEnd() {
        if !readEndClosed.exchange(true, ordering: .acquiringAndReleasing) {
            close(readFD)
        }
    }
}

/// How the run ended, for a caller that waits on a thread.
private final class RunOutcome: Sendable {
    private let value = Mutex<Result<ToolProcessResult, ToolProcessError>?>(nil)
    private let ended = DispatchSemaphore(value: 0)

    func store(_ result: Result<ToolProcessResult, ToolProcessError>) {
        value.withLock { $0 = result }
        ended.signal()
    }

    func wait() -> Result<ToolProcessResult, ToolProcessError> {
        ended.wait()
        ended.signal()
        return value.withLock { $0! }
    }
}

/// The write end the caller keeps until ToolProcess has its own copy.
private final class WriteEnd: Sendable {
    private let fd: Int32
    private let closed = Atomic<Bool>(false)

    init(fd: Int32) {
        self.fd = fd
    }

    func close() {
        if !closed.exchange(true, ordering: .acquiringAndReleasing) {
            Darwin.close(fd)
        }
    }
}
