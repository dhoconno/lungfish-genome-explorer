// SRAToolkitRunner.swift - How an SRA Toolkit download runs prefetch and fasterq-dump
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Runs the SRA Toolkit's `prefetch` and `fasterq-dump` for
/// `SRAService.downloadFASTQ`.
///
/// By default the service runs the tools of the managed sra-tools
/// environment as subprocesses. A test passes a runner that writes the files
/// the tools would, so it spawns no tool and reaches no network.
public struct SRAToolkitRunner: Sendable {
    /// What one run of a tool returned.
    public struct Result: Sendable {
        public let exitCode: Int32
        public let stdout: String
        public let stderr: String

        public init(exitCode: Int32, stdout: String = "", stderr: String = "") {
            self.exitCode = exitCode
            self.stdout = stdout
            self.stderr = stderr
        }
    }

    /// The `prefetch` executable.
    public let prefetch: URL
    /// The `fasterq-dump` executable.
    public let fasterqDump: URL
    /// Runs one of the two executables with the given arguments.
    public let run: @Sendable (_ executable: URL, _ arguments: [String]) async throws -> Result

    public init(
        prefetch: URL,
        fasterqDump: URL,
        run: @escaping @Sendable (_ executable: URL, _ arguments: [String]) async throws -> Result
    ) {
        self.prefetch = prefetch
        self.fasterqDump = fasterqDump
        self.run = run
    }
}
