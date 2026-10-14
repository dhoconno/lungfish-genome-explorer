// SystemToolProbe.swift - Runs and watches the real /usr/bin tools in tests
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import LungfishCore

/// Runs the real `/usr/bin` tools (gzip, zip, pgrep) for the tests that pin what a launch
/// produces or prove that a cancel stopped one. Nothing here is a stand-in, and every launch
/// goes through ``ToolProcess``.
public enum SystemToolProbe {
    /// The environment the tests give the tools, as the code under test gives its own.
    public static let environment = ["PATH": "/usr/bin:/bin"]

    /// Runs `/usr/bin/<tool>` to its end and returns the result. A nonzero exit is a result.
    @discardableResult
    public static func run(
        _ tool: String,
        _ arguments: [String],
        stdout: ToolProcessOutput = .discard
    ) async throws -> ToolProcessResult {
        try await ToolProcess.run(ToolProcessSpec(
            executableURL: URL(fileURLWithPath: "/usr/bin/\(tool)"),
            arguments: arguments,
            environment: environment,
            stdout: stdout,
            label: tool
        ))
    }

    /// Compresses `plain` into `gz` with the real gzip.
    public static func gzip(_ plain: URL, to gz: URL) async throws {
        let result = try await run("gzip", ["-c", plain.path], stdout: .file(gz))
        XCTAssertTrue(result.isSuccess, result.stderrText)
    }

    /// The pids of the children of this test process whose command line holds `fragment`.
    /// Looking at the children only keeps another test process of a parallel run out of the answer.
    public static func childPIDs(commandLineHolding fragment: String) async -> [Int32] {
        let pattern = NSRegularExpression.escapedPattern(for: fragment)
        guard let result = try? await run("pgrep", ["-f", "-P", "\(getpid())", pattern], stdout: .capture()) else {
            return []
        }
        return result.stdoutText.split(whereSeparator: \.isNewline).compactMap { Int32($0) }
    }

    /// Writes `leading` and then `block` `times` times to `url`, without holding the whole file in memory.
    public static func writeRepeating(_ block: Data, times: Int, leading: Data = Data(), to url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: leading)
        for _ in 0..<times {
            try handle.write(contentsOf: block)
        }
    }
}
