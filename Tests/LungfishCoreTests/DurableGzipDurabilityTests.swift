// DurableGzipDurabilityTests.swift - The gzip helper names a copy only when gzip finished it
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane S62, M2 (SWIFT checks 4 and 5). `DurableGzip.compress` streams gzip's standard output into a
// hidden part file and publishes it with `DurableReplace`. A gzip that is killed mid-write, fails or is
// cancelled leaves the destination as it was and no part file. gzip's standard error is drained while it runs.
// The class name holds `Durability`, so `exfat-tests.sh --simulate` runs it with the ExFAT rename path.

import Darwin
import Foundation
import XCTest
import LungfishTestSupport
@testable import LungfishCore

/// The gzip processes that are children of this test process.
private func gzipChildren() -> [Int32] {
    ProcessTreeTerminator.descendantProcessIDs(of: getpid()).filter { pid in
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return false }
        return String(cString: path) == "/usr/bin/gzip"
    }
}

/// Whether some file in `folder` holds more than a kilobyte.
private func hasOutputBytes(in folder: URL) -> Bool {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    return names.contains { name in
        let attributes = try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path)
        return ((attributes?[.size] as? NSNumber)?.intValue ?? 0) > 1024
    }
}

final class DurableGzipDurabilityTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "durable-gzip-durability")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    private func entries(of folder: URL? = nil) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: (folder ?? root).path).sorted()
    }

    /// A shell script that follows gzip's command line, for the failures a real gzip does not produce on demand.
    private func fakeGzip(_ body: String) throws -> URL {
        let script = root.appendingPathComponent("fake-gzip.sh")
        try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    /// 24 MB of random bytes, which gzip needs most of a second to compress.
    private func makeRandomFile(named name: String, in folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var chunk = Data(count: 1 << 20)
        for _ in 0..<24 {
            chunk.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
            try handle.write(contentsOf: chunk)
        }
        return url
    }

    // MARK: - The bytes

    func testTheHelperWritesTheBytesOfGzipDashCUnderTheFinalName() throws {
        let source = root.appendingPathComponent("reads.txt")
        try Data("alpha\nbeta\ngamma\n".utf8).write(to: source)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: source.path
        )
        let destination = root.appendingPathComponent("reads.txt.gz")

        try DurableGzip.compress(source: source, to: destination)

        let direct = try ToolProcess.runBlocking(ToolProcessSpec(
            executableURL: DurableGzip.executableURL, arguments: ["-c", source.path], environment: [:]
        ))
        XCTAssertTrue(direct.isSuccess)
        XCTAssertEqual(try Data(contentsOf: destination), direct.stdout)
        XCTAssertEqual(try entries(), ["reads.txt", "reads.txt.gz"], "no part file stays")
    }

    func testAMissingSourceIsAnErrorThatNamesItAndLeavesNothing() throws {
        let destination = root.appendingPathComponent("missing.gz")

        XCTAssertThrowsError(try DurableGzip.compress(source: root.appendingPathComponent("missing"), to: destination)) { error in
            guard case DurableGzipError.gzipFailed(let exitCode, let stderr) = error else {
                return XCTFail("expected gzipFailed, got \(error)")
            }
            XCTAssertNotEqual(exitCode, 0)
            XCTAssertTrue(stderr.contains("missing"), stderr)
        }

        XCTAssertEqual(try entries(), [], "a failed copy names no file and leaves no part file")
    }

    // MARK: - Failures

    func testAGzipKilledMidWriteLeavesNothingUnderTheFinalName() async throws {
        let source = try makeRandomFile(named: "random.bin", in: root.appendingPathComponent("input", isDirectory: true))
        let output = root.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let destination = output.appendingPathComponent("random.bin.gz")
        let task = Task.detached { () -> Bool in
            do {
                try DurableGzip.compress(source: source, to: destination)
                return true
            } catch {
                return false
            }
        }

        let deadline = Date().addingTimeInterval(120)
        var gzip: Int32?
        while Date() < deadline {
            if hasOutputBytes(in: output) {
                gzip = gzipChildren().first
                break
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        guard let gzip else {
            _ = await task.value
            throw XCTSkip("gzip finished or never wrote before the test could freeze it")
        }
        kill(gzip, SIGSTOP)
        let existedMidWrite = FileManager.default.fileExists(atPath: destination.path)
        let namesMidWrite = try entries(of: output)
        kill(gzip, SIGKILL)
        let succeeded = await task.value

        XCTAssertFalse(existedMidWrite, "the final name stays empty while gzip writes: \(namesMidWrite)")
        XCTAssertEqual(namesMidWrite.count, 1, "the bytes sit in one hidden part file: \(namesMidWrite)")
        XCTAssertTrue(namesMidWrite.first?.hasPrefix(".random.bin.gz.lungfish-stage-") ?? false, "\(namesMidWrite)")
        XCTAssertFalse(succeeded, "a killed gzip is a failed copy")
        XCTAssertEqual(try entries(of: output), [], "neither the final name nor a part file stays")
    }

    func testAGzipThatFloodsStandardErrorIsDrainedAndReportsItsStatus() throws {
        let script = try fakeGzip("head -c 2097152 /dev/zero | tr '\\0' 'e' >&2\nprintf partial\nexit 3")
        let destination = root.appendingPathComponent("flood.gz")
        let cancellation = ToolProcessCancellation()
        // A gzip whose standard error is not drained blocks on a full pipe, and this ends the test instead.
        DispatchQueue.global().asyncAfter(deadline: .now() + 60) { cancellation.cancel() }

        XCTAssertThrowsError(
            try DurableGzip.compress(
                source: root.appendingPathComponent("unused"), to: destination, using: script, cancellation: cancellation
            )
        ) { error in
            guard case DurableGzipError.gzipFailed(let exitCode, let stderr) = error else {
                return XCTFail("expected gzipFailed, got \(error)")
            }
            XCTAssertEqual(exitCode, 3)
            XCTAssertEqual(stderr.utf8.count, 2_097_152, "all of standard error arrived")
        }

        XCTAssertEqual(try entries(), ["fake-gzip.sh"], "a failed copy names no file and leaves no part file")
    }

    func testAFailedCompressionKeepsTheOlderFileUnderTheName() throws {
        let script = try fakeGzip("printf cut\nexit 1")
        let destination = root.appendingPathComponent("older.gz")
        let older = Data("an older copy".utf8)
        try older.write(to: destination)

        XCTAssertThrowsError(
            try DurableGzip.compress(source: root.appendingPathComponent("unused"), to: destination, using: script, cancellation: nil)
        )

        XCTAssertEqual(try Data(contentsOf: destination), older)
        XCTAssertEqual(try entries(), ["fake-gzip.sh", "older.gz"])
    }

    func testACancelledCompressionLeavesNothingUnderTheName() throws {
        let script = try fakeGzip("printf cut\nexec sleep 30")
        let destination = root.appendingPathComponent("cancelled.gz")
        let cancellation = ToolProcessCancellation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { cancellation.cancel() }

        XCTAssertThrowsError(
            try DurableGzip.compress(source: root.appendingPathComponent("unused"), to: destination, using: script, cancellation: cancellation)
        ) { error in
            guard case ToolProcessError.cancelled = error else {
                return XCTFail("expected a cancelled run, got \(error)")
            }
        }

        XCTAssertEqual(try entries(), ["fake-gzip.sh"])
    }
}
