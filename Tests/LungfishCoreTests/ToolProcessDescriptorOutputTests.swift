// ToolProcessDescriptorOutputTests.swift - The output case that writes into a descriptor the caller owns
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishCore

/// `ToolProcessOutput.descriptor` is for a caller that created its output file itself, as
/// `GenotypeExcelExportService` does inside a no-follow opened directory (Phase 2.13 lane 13.10, MD28).
/// The child writes through a copy of the caller's descriptor, so the path is never opened again.
final class ToolProcessDescriptorOutputTests: XCTestCase {
    private typealias Fixtures = ToolProcessFixtures

    /// Creates `name` in `directory` the way the writer's witnessed create does, refusing a link.
    private func createWitnessed(_ name: String, in directory: URL) throws -> Int32 {
        let path = directory.appendingPathComponent(name).path
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return descriptor
    }

    func testTheChildWritesThroughTheGivenDescriptorsAndTheCallerKeepsThem() async throws {
        let directory = try makeToolProcessTempDirectory()
        let stdoutFD = try createWitnessed("out.txt", in: directory)
        let stderrFD = try createWitnessed("err.txt", in: directory)
        defer {
            close(stdoutFD)
            close(stderrFD)
        }
        let events = ToolProcessEventLog()
        let result = try await ToolProcess.run(
            Fixtures.shell(
                "printf 'abc\\ndef'; printf 'why' >&2",
                stdout: .descriptor(stdoutFD),
                stderr: .descriptor(stderrFD)
            )
        ) { events.append($0) }
        XCTAssertTrue(result.isSuccess)
        XCTAssertTrue(result.stdout.isEmpty)
        XCTAssertTrue(result.stderr.isEmpty)
        XCTAssertEqual(events.lines(.stdout) + events.lines(.stderr), [])
        let out = directory.appendingPathComponent("out.txt")
        XCTAssertEqual(try String(contentsOf: out, encoding: .utf8), "abc\ndef")
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("err.txt"), encoding: .utf8), "why")
        // The caller's descriptor is still open, is not truncated and shares the child's offset.
        XCTAssertNotEqual(fcntl(stdoutFD, F_GETFD), -1)
        XCTAssertEqual(Darwin.write(stdoutFD, "!", 1), 1)
        XCTAssertEqual(try String(contentsOf: out, encoding: .utf8), "abc\ndef!")
    }

    func testASymlinkPlantedAtThePathIsNotFollowed() async throws {
        let directory = try makeToolProcessTempDirectory()
        let victim = directory.appendingPathComponent("victim.txt")
        try Data("untouched".utf8).write(to: victim)
        let path = directory.appendingPathComponent("out.txt")
        let moved = directory.appendingPathComponent("moved.txt")
        let descriptor = try createWitnessed("out.txt", in: directory)
        defer { close(descriptor) }
        // The name is swapped after the witnessed create. The created file moves away and a link takes its name.
        try FileManager.default.moveItem(at: path, to: moved)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: victim)
        let result = try await ToolProcess.run(Fixtures.shell("printf 'payload'", stdout: .descriptor(descriptor)))
        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(try String(contentsOf: moved, encoding: .utf8), "payload")
        XCTAssertEqual(try String(contentsOf: victim, encoding: .utf8), "untouched")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: path.path), victim.path)
    }

    func testANegativeDescriptorIsAnInvalidSpec() async throws {
        do {
            _ = try await ToolProcess.run(Fixtures.shell("true", stdout: .descriptor(-1)))
            XCTFail("a negative descriptor was accepted")
        } catch ToolProcessError.invalidSpec(let message) {
            XCTAssertTrue(message.contains("descriptor"), message)
        }
    }
}
