// PortableChildLauncher.swift - How the portable layer starts a child it reads
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// What a portable reader asks its launcher to start: one program with its arguments and its whole environment. The
/// launcher hands back the child's stdout as a stream and discards its stderr.
package struct PortableChildRequest: Sendable, Equatable {
    package var executableURL: URL
    package var arguments: [String]
    package var environment: [String: String]
    /// A short name for the launcher's log and errors.
    package var label: String

    package init(executableURL: URL, arguments: [String], environment: [String: String], label: String) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.label = label
    }
}

/// How a child ended, as its launcher reports it.
package struct PortableChildExit: Sendable, Equatable {
    /// The status the launcher reports, the exit code when the child exited.
    package let status: Int32
    /// Whether the launcher counts the run a success.
    package let isSuccess: Bool

    package init(status: Int32, isSuccess: Bool) {
        self.status = status
        self.isSuccess = isSuccess
    }
}

/// A started child whose stdout the caller reads.
package protocol PortableChild: AnyObject {
    /// Reads stdout until `count` bytes arrived or the stream ended, as `FileHandle.readData(ofLength:)` does. Fewer
    /// than `count` bytes mean the end. Never call it on the main thread.
    func readStdout(filling count: Int) -> Data
    /// Asks the child to stop and returns at once.
    func cancel()
    /// Waits for the child to end. Throws when the launcher could not wait for it. Never call it on the main thread.
    func waitForExit() throws -> PortableChildExit
}

/// Starts the children of the portable layer, so a type here never names the launcher of one platform. On the Mac the
/// launcher is `ToolProcessChildLauncher` in `Sources/LungfishCore/Process/`, which starts every child through
/// `ToolProcess` (`docs/contracts/RUNNING-A-TOOL.md`). The Linux executor brings its own.
package protocol PortableChildLauncher: Sendable {
    func start(_ request: PortableChildRequest) throws -> any PortableChild
}
