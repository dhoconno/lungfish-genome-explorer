// ToolProcessStdinFeed.swift - Lets a FileHandle writer feed the standard input of a ToolProcess run
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

/// Carries what code writes to a `FileHandle` into the standard input of a ``ToolProcessRun``.
///
/// ``FASTQPairInterleaver`` writes to a `FileHandle`, and a run started with ``ToolProcessInput/stream`` takes its
/// bytes through ``ToolProcessRun/stdin``. The feed gives the writer one end of a pipe and a thread copies the other
/// end into the stream, so the process still holds the writer back when it reads slower than the writer writes. A
/// process that stops reading, or a run that was cancelled, ends the copy early. The thread then drains the pipe and
/// drops the bytes, so the writer never blocks on a reader that is gone and never meets a closed pipe, and the
/// run's exit status says what happened. Call ``finish()`` exactly once, after the last write or after a failure.
struct ToolProcessStdinFeed {
    /// The end the producer writes to.
    let writer: FileHandle
    private let pipe = Pipe()
    private let finished = DispatchSemaphore(value: 0)

    init(stdin: ToolProcessInputStream) {
        writer = pipe.fileHandleForWriting
        let reader = pipe.fileHandleForReading
        let done = finished
        Thread.detachNewThread {
            var open = true
            while let chunk = try? reader.read(upToCount: 1 << 20), !chunk.isEmpty {
                guard open else { continue }
                do { try stdin.writeBlocking(chunk) } catch { open = false }
            }
            stdin.close()
            try? reader.close()
            done.signal()
        }
    }

    /// Closes the writer's end, which gives the process end of file once the thread has passed on every byte, and
    /// waits until the thread is done.
    func finish() {
        try? writer.close()
        finished.wait()
    }
}
