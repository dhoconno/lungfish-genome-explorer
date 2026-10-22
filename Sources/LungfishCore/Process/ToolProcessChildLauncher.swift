// ToolProcessChildLauncher.swift - The Mac's launcher for the portable layer, over ToolProcess
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishPortable

/// Starts a child of the portable layer through ``ToolProcess``, so it keeps every guarantee of
/// `docs/contracts/RUNNING-A-TOOL.md`. Its stdout is a stream and its stderr is discarded.
package struct ToolProcessChildLauncher: PortableChildLauncher {
    package init() {}

    package func start(_ request: PortableChildRequest) throws -> any PortableChild {
        let run = try ToolProcess.start(ToolProcessSpec(
            executableURL: request.executableURL,
            arguments: request.arguments,
            environment: request.environment,
            stdout: .stream,
            stderr: .discard,
            label: request.label
        ))
        return ToolProcessChild(run: run)
    }
}

/// A ``ToolProcessRun`` seen as a ``PortableChild``.
private final class ToolProcessChild: PortableChild {
    private let run: ToolProcessRun

    init(run: ToolProcessRun) {
        self.run = run
    }

    func readStdout(filling count: Int) -> Data {
        run.stdout.readUntilFull(count)
    }

    func cancel() {
        run.cancel()
    }

    func waitForExit() throws -> PortableChildExit {
        let result = try run.waitBlocking()
        return PortableChildExit(status: result.status, isSuccess: result.isSuccess)
    }
}

extension ToolProcessOutputStream {
    /// Reads until `count` bytes arrived or the stream ended, as `FileHandle.readData(ofLength:)` does, so a
    /// caller that sized its chunks for a file handle sees the same chunks. Fewer than `count` bytes mean the
    /// end. Never call it on the main thread.
    package func readUntilFull(_ count: Int) -> Data {
        var data = Data()
        while data.count < count {
            let piece = read(upTo: count - data.count)
            if piece.isEmpty { break }
            data.append(piece)
        }
        return data
    }
}
