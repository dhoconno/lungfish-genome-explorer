// FASTQRawLineReaderLauncherTests.swift - the byte line reader starts its decompressor through the launcher it is given
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
@testable import LungfishWorkflow
import XCTest

/// `FASTQRawLineReader` takes a ``PortableChildLauncher`` in place of `ToolProcess.start`, so the portable layer can
/// hold it and the Linux executor can hand it its own launcher. These tests give it a recording launcher whose child
/// plays back fixed bytes, and read what the reader asked for, the lines it returned and the errors it threw.
final class FASTQRawLineReaderLauncherTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("raw-line-reader-launcher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private let record = "@read1\nACGT\n+\nIIII\n"

    /// A file whose first two bytes are the gzip magic. The reader hands the decompressing to its child, so the
    /// rest of the file is never read here.
    private func gzipMagicFile() throws -> URL {
        let url = scratch.appendingPathComponent("reads.fastq.gz")
        try Data([0x1F, 0x8B, 0x08, 0x00]).write(to: url)
        return url
    }

    func testGzipInputAsksTheLauncherForGzipAndReadsTheChildsStdout() throws {
        let url = try gzipMagicFile()
        let launcher = RecordingLauncher(output: Data(record.utf8), exit: PortableChildExit(status: 0, isSuccess: true))
        let reader = try FASTQRawLineReader(url: url, launcher: launcher)

        var lines: [String] = []
        while let line = try reader.nextLine() { lines.append(String(decoding: line, as: UTF8.self)) }
        reader.close()

        XCTAssertEqual(lines, ["@read1", "ACGT", "+", "IIII"])
        XCTAssertEqual(launcher.requests, [PortableChildRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/gzip"),
            arguments: ["-dc", url.path],
            environment: ["PATH": "/usr/bin:/bin"],
            label: "gzip -dc"
        )])
        XCTAssertEqual(launcher.child?.waits, 1, "the end of input waits for the child once")
        XCTAssertEqual(launcher.child?.cancels, 1, "close stops the child")
    }

    func testPlainInputStartsNoChild() throws {
        let url = scratch.appendingPathComponent("reads.fastq")
        try Data(record.utf8).write(to: url)
        let launcher = RecordingLauncher(output: Data(), exit: PortableChildExit(status: 0, isSuccess: true))
        let reader = try FASTQRawLineReader(url: url, launcher: launcher)

        let chunk = try XCTUnwrap(reader.readChunk())
        reader.close()

        XCTAssertEqual(String(decoding: chunk, as: UTF8.self), record)
        XCTAssertEqual(launcher.requests, [])
    }

    func testFailedChildExitThrowsUnreadableInputWithTheStatus() throws {
        let url = try gzipMagicFile()
        let launcher = RecordingLauncher(output: Data(record.utf8), exit: PortableChildExit(status: 3, isSuccess: false))
        let reader = try FASTQRawLineReader(url: url, launcher: launcher)
        defer { reader.close() }

        XCTAssertThrowsError(try { while try reader.nextLine() != nil {} }()) { error in
            XCTAssertEqual(
                error as? FASTQPairInterleaver.InterleaveError,
                .unreadableInput(file: "reads.fastq.gz", reason: "gzip decompression failed (exit 3)")
            )
        }
    }

    func testFailedWaitThrowsUnreadableInputWithTheWaitError() throws {
        let url = try gzipMagicFile()
        let waitError = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "the wait broke"])
        let launcher = RecordingLauncher(output: Data(record.utf8), exit: nil, waitError: waitError)
        let reader = try FASTQRawLineReader(url: url, launcher: launcher)
        defer { reader.close() }

        XCTAssertThrowsError(try reader.readChunk().map { _ in try reader.readChunk() }) { error in
            XCTAssertEqual(
                error as? FASTQPairInterleaver.InterleaveError,
                .unreadableInput(file: "reads.fastq.gz", reason: "gzip decompression failed (the wait broke)")
            )
        }
    }

    func testLauncherStartFailureReachesTheCaller() throws {
        let url = try gzipMagicFile()
        let startError = NSError(domain: "test", code: 2)
        let launcher = RecordingLauncher(output: Data(), exit: nil, startError: startError)

        XCTAssertThrowsError(try FASTQRawLineReader(url: url, launcher: launcher)) { error in
            XCTAssertEqual(error as NSError, startError)
        }
    }

    func testCountRecordsReadsThroughTheGivenLauncher() throws {
        let url = try gzipMagicFile()
        let twoRecords = Data((record + record.replacingOccurrences(of: "read1", with: "read2")).utf8)
        let launcher = RecordingLauncher(output: twoRecords, exit: PortableChildExit(status: 0, isSuccess: true))

        XCTAssertEqual(try FASTQPairInterleaver.countRecords(in: url, launcher: launcher), 2)
        XCTAssertEqual(launcher.requests.map(\.arguments), [["-dc", url.path]])
    }
}

/// A launcher that records each request and starts a ``PlaybackChild``.
private final class RecordingLauncher: PortableChildLauncher, @unchecked Sendable {
    private let output: Data
    private let exit: PortableChildExit?
    private let waitError: Error?
    private let startError: Error?
    private(set) var requests: [PortableChildRequest] = []
    private(set) var child: PlaybackChild?

    init(output: Data, exit: PortableChildExit?, waitError: Error? = nil, startError: Error? = nil) {
        self.output = output
        self.exit = exit
        self.waitError = waitError
        self.startError = startError
    }

    func start(_ request: PortableChildRequest) throws -> any PortableChild {
        requests.append(request)
        if let startError { throw startError }
        let child = PlaybackChild(output: output, exit: exit, waitError: waitError)
        self.child = child
        return child
    }
}

/// A child whose stdout plays back fixed bytes, then ends with a fixed exit or a failed wait.
private final class PlaybackChild: PortableChild {
    private var remaining: Data
    private let exit: PortableChildExit?
    private let waitError: Error?
    private(set) var waits = 0
    private(set) var cancels = 0

    init(output: Data, exit: PortableChildExit?, waitError: Error?) {
        self.remaining = output
        self.exit = exit
        self.waitError = waitError
    }

    func readStdout(filling count: Int) -> Data {
        let piece = remaining.prefix(count)
        remaining = remaining.dropFirst(piece.count)
        return Data(piece)
    }

    func cancel() {
        cancels += 1
    }

    func waitForExit() throws -> PortableChildExit {
        waits += 1
        if let waitError { throw waitError }
        return exit ?? PortableChildExit(status: 0, isSuccess: true)
    }
}
