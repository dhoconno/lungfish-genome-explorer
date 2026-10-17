// KrakenCompactionBytePinTests.swift - The bytes and the recorded commands of the Kraken2 compaction, pinned
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane S62, M1 (memo objections OB1 and OB2, owner ruling O6). Three routes compact the per-read
// Kraken2 output into a gzip copy and an index. The classify route has its own gzip copy, `build-db kraken2`
// and the importers go through `KrakenOutputCompactor`, and the Kraken2 record holds the digest of the gzip
// copy and the command `/bin/sh -c '/usr/bin/gzip -c <raw> > <gz>'` that replays it. The lane moves the bytes
// onto disk through one durable helper and changes nothing the record states, so these pins hold at the base
// and again at every later commit: the gzip bytes of one fixture, the rows of its index, and the recorded
// commands of the classify route and of `build-db`.
//
// gzip stores the name and the modification time of its input in the header, so the fixture fixes both.
// The index file holds a `created_at` row, so its bytes differ from run to run, and the pin holds its rows.

import CryptoKit
import Foundation
import XCTest
import LungfishCore
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishIO
@testable import LungfishWorkflow

final class KrakenCompactionBytePinTests: XCTestCase {
    private static let fixtureName = "classification.kraken"
    private static let fixtureModified = Date(timeIntervalSince1970: 1_700_000_000)
    private static let fixtureText = "C\tread-1\t562\t100\t562:70 0:30\n"
        + "C\tread-2\t562\t120\t562:90 0:30\n"
        + "U\tread-3\t0\t80\t0:50\n"
        + "C\tread-4\t9606\t150\t9606:116\n"
        + "C\tread-5\t562\t90\t562:60\n"

    /// `gzip -c classification.kraken` of the fixture, 120 bytes, with the name and the time of the fixture in
    /// its header. The digest is what the Kraken2 record states for the gzip copy.
    private static let gzipDigest = "4f6454a3801d563a2c2793c64172767e3ae6199fbacac62507edd699fd51cd9b"
    private static let gzipLength = 120
    private static let taxCounts: [Int: Int] = [562: 3, 9606: 1]

    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "kraken-compaction-byte-pin")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - Fixture

    /// The fixture in a folder whose name holds a space, so the recorded command shows its quoting.
    private func makeRaw(in folderName: String) throws -> URL {
        let folder = root.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let raw = folder.appendingPathComponent(Self.fixtureName)
        try Data(Self.fixtureText.utf8).write(to: raw)
        try FileManager.default.setAttributes([.modificationDate: Self.fixtureModified], ofItemAtPath: raw.path)
        return raw
    }

    private static func sha256(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private func assertPinnedGzip(_ url: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let bytes = try Data(contentsOf: url)
        XCTAssertEqual(bytes.count, Self.gzipLength, file: file, line: line)
        XCTAssertEqual(Self.sha256(bytes), Self.gzipDigest, file: file, line: line)
        // Magic, deflate, the file name flag, the modification time 1_700_000_000, the default level, Unix,
        // then the name of the input.
        let header: [UInt8] = [0x1f, 0x8b, 0x08, 0x08, 0x00, 0xf1, 0x53, 0x65, 0x00, 0x03]
        XCTAssertEqual(Array(bytes.prefix(10)), header, file: file, line: line)
        XCTAssertEqual(
            Array(bytes.dropFirst(10).prefix(Self.fixtureName.utf8.count + 1)),
            Array((Self.fixtureName + "\0").utf8),
            file: file, line: line
        )
        let decoded = try ToolProcess.runBlocking(ToolProcessSpec(
            executableURL: URL(fileURLWithPath: "/usr/bin/gzip"),
            arguments: ["-dc", url.path],
            environment: [:]
        ))
        XCTAssertTrue(decoded.isSuccess, file: file, line: line)
        XCTAssertEqual(decoded.stdout, Data(Self.fixtureText.utf8), file: file, line: line)
    }

    private func assertPinnedIndex(_ url: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(url.lastPathComponent, "classification.kraken.gz.idx.sqlite", file: file, line: line)
        let database = try KrakenIndexDatabase(url: url)
        defer { database.close() }
        XCTAssertTrue(database.isClassifiedOnly, file: file, line: line)
        XCTAssertEqual(database.allTaxCounts(), Self.taxCounts, file: file, line: line)
        XCTAssertEqual(try database.readIds(forTaxIds: [562]), ["read-1", "read-2", "read-5"], file: file, line: line)
        XCTAssertEqual(try database.readIds(forTaxIds: [9606]), ["read-4"], file: file, line: line)
    }

    // MARK: - The copy in LungfishIO

    func testTheIOGzipCopyWritesThePinnedBytes() throws {
        let raw = try makeRaw(in: "io copy")
        let gz = raw.deletingLastPathComponent().appendingPathComponent("classification.kraken.gz")

        try KrakenOutputCompactor.gzipCopy(source: raw, destination: gz)

        try assertPinnedGzip(gz)
        XCTAssertTrue(FileManager.default.fileExists(atPath: raw.path), "the copy leaves its source")
    }

    func testTheIOGzipCopyReplacesAnOlderFileWithTheSameBytes() throws {
        let raw = try makeRaw(in: "io copy replace")
        let gz = raw.deletingLastPathComponent().appendingPathComponent("classification.kraken.gz")
        try Data("an older gzip copy".utf8).write(to: gz)

        try KrakenOutputCompactor.gzipCopy(source: raw, destination: gz)

        try assertPinnedGzip(gz)
    }

    // MARK: - The copy of the classify route

    func testTheClassifierCopyWritesThePinnedBytesAndRecordsThePinnedCommands() async throws {
        let raw = try makeRaw(in: "classifier copy")
        let gz = raw.appendingPathExtension("gz")
        let index = KrakenIndexDatabase.indexURL(for: gz)
        let recorder = ProvenanceRecorder(signingProvider: nil)
        let runID = await recorder.beginRun(name: "Kraken2 compaction pin")

        let compaction = await ClassificationPipeline().compactKrakenOutputIfPossible(
            rawURL: raw, provenanceRecorder: recorder, runID: runID, dependsOn: []
        )
        let indexBytes = try Data(contentsOf: index)

        XCTAssertEqual(try XCTUnwrap(compaction).url, gz)
        try assertPinnedGzip(gz)
        XCTAssertFalse(FileManager.default.fileExists(atPath: raw.path), "the raw output goes after both copies exist")

        let run = await recorder.findRun(runID)
        let steps = try XCTUnwrap(run).steps
        let gzipStep = try XCTUnwrap(steps.first { $0.toolName == "gzip" })
        XCTAssertEqual(gzipStep.toolVersion, "system")
        XCTAssertEqual(gzipStep.argv, ["/bin/sh", "-c", "/usr/bin/gzip -c '\(raw.path)' > '\(gz.path)'"])
        XCTAssertEqual(gzipStep.outputs.map(\.path), [gz.path])
        XCTAssertEqual(gzipStep.outputs.map(\.checksumSHA256), [Self.gzipDigest], "the record states the digest of the bytes on disk")
        XCTAssertEqual(gzipStep.inputs.map(\.checksumSHA256), [Self.sha256(Data(Self.fixtureText.utf8))])
        let indexStep = try XCTUnwrap(steps.first { $0.toolName == "lungfish-kraken2-index" })
        XCTAssertEqual(indexStep.argv, [
            CLICommandIdentity.executableName, "internal", "kraken2-index", "--classified-only", raw.path, index.path,
        ])
        XCTAssertEqual(indexStep.outputs.map(\.path), [index.path])
        XCTAssertEqual(indexStep.outputs.map(\.checksumSHA256), [Self.sha256(indexBytes)], "the record states the digest of the index on disk")
        try assertPinnedIndex(index)
    }

    // MARK: - build-db and the importers

    func testBuildDbCompactionWritesThePinnedBytesAndRecordsTheSameCommands() throws {
        let raw = try makeRaw(in: "build-db copy")
        let descriptor = try ProvenanceFileDescriptor.file(url: raw, format: .text, role: .input)
        let gz = raw.appendingPathExtension("gz")
        let index = KrakenIndexDatabase.indexURL(for: gz)

        _ = try KrakenOutputCompactor.compact(rawURL: raw, includeUnclassifiedInIndex: false, removeRawOnSuccess: false)
        let indexBytes = try Data(contentsOf: index)

        try assertPinnedGzip(gz)
        let steps = BuildDbCommand.Kraken2Subcommand.compactionSteps(raw: descriptor, compressed: gz, clock: ProvenanceRunClock())
        XCTAssertEqual(steps.map(\.toolName), ["lungfish-kraken2-index", "gzip"])
        XCTAssertEqual(steps[0].argv, [
            CLICommandIdentity.executableName, "internal", "kraken2-index", "--classified-only", descriptor.path, index.path,
        ])
        XCTAssertEqual(steps[1].argv, ["/bin/sh", "-c", "/usr/bin/gzip -c '\(descriptor.path)' > '\(gz.path)'"])
        XCTAssertEqual(steps[1].outputs.map(\.checksumSHA256), [Self.gzipDigest], "the record states the digest of the bytes on disk")
        XCTAssertEqual(steps[0].outputs.map(\.checksumSHA256), [Self.sha256(indexBytes)], "the record states the digest of the index on disk")
        XCTAssertEqual(steps[1].inputs, [descriptor])
        try assertPinnedIndex(index)
    }

    func testTheCompactionRemovesTheRawOutputOnlyAfterBothCopiesExist() throws {
        let raw = try makeRaw(in: "compact removes raw")

        _ = try KrakenOutputCompactor.compact(rawURL: raw, includeUnclassifiedInIndex: false, removeRawOnSuccess: true)

        let gz = raw.appendingPathExtension("gz")
        XCTAssertFalse(FileManager.default.fileExists(atPath: raw.path))
        try assertPinnedGzip(gz)
        try assertPinnedIndex(KrakenIndexDatabase.indexURL(for: gz))
    }
}
