// ProvenanceDigestCacheTests.swift - One digest per file per import command (CHTC lane L7-HASHONCE)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import XCTest
@testable import LungfishWorkflow

private final class DiskReadLog: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0

    func record() { lock.withLock { reads += 1 } }
    var count: Int { lock.withLock { reads } }
}

final class ProvenanceDigestCacheTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProvenanceDigestCache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        try await super.tearDown()
    }

    private func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func write(_ text: String, to name: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    func testAFileAskedForThreeTimesIsReadOnce() throws {
        let file = try write("ACGT\n", to: "reads.fastq")
        let cache = ProvenanceDigestCache()

        let digests = try (0..<3).map { _ in try cache.sha256(of: file) }

        XCTAssertEqual(digests, Array(repeating: sha256Hex("ACGT\n"), count: 3))
        XCTAssertEqual(cache.readCount, 1)
        XCTAssertEqual(cache.readCount(of: file), 1)
    }

    func testAFileThatChangesBetweenTwoReadsIsReadAgain() throws {
        let file = try write("ACGT\n", to: "reads.fastq")
        let cache = ProvenanceDigestCache()
        XCTAssertEqual(try cache.sha256(of: file), sha256Hex("ACGT\n"))

        // Same size, new bytes, new modification time.
        try Data("ACGA\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: file.path)
        XCTAssertEqual(try cache.sha256(of: file), sha256Hex("ACGA\n"))
        XCTAssertEqual(cache.readCount(of: file), 2)

        // New size.
        try Data("ACGAT\n".utf8).write(to: file)
        XCTAssertEqual(try cache.sha256(of: file), sha256Hex("ACGAT\n"))
        XCTAssertEqual(cache.readCount(of: file), 3)
    }

    func testARenamedFileAndACopyAreEachReadForTheirOwnPath() throws {
        let file = try write("ACGT\n", to: "workspace.fastq")
        let cache = ProvenanceDigestCache()
        let digest = try cache.sha256(of: file)

        let moved = tempDir.appendingPathComponent("staged.fastq")
        try FileManager.default.moveItem(at: file, to: moved)
        XCTAssertEqual(try cache.sha256(of: moved), digest)
        XCTAssertEqual(cache.readCount, 2, "a file renamed inside the command is a new path and is read again")

        let copy = tempDir.appendingPathComponent("copy.fastq")
        try FileManager.default.copyItem(at: moved, to: copy)
        XCTAssertEqual(try cache.sha256(of: copy), digest)
        XCTAssertEqual(cache.readCount, 3, "a copy is another file, read for itself")
    }

    func testAFileThatChangesDuringTheReadIsNotKept() throws {
        let file = try write("ACGT\n", to: "growing.fastq")
        let cache = ProvenanceDigestCache(reader: { url, _ in
            try Data("ACGTACGT\n".utf8).write(to: url) // the writer is still going while the digest is taken
            return "digest-of-the-moment"
        })

        XCTAssertEqual(try cache.sha256(of: file), "digest-of-the-moment")
        XCTAssertEqual(try cache.sha256(of: file), "digest-of-the-moment")
        XCTAssertEqual(cache.readCount(of: file), 2, "a digest of a file that moved under the read is not reused")
    }

    func testAMissingFileStillThrows() {
        let cache = ProvenanceDigestCache()
        XCTAssertThrowsError(try cache.sha256(of: tempDir.appendingPathComponent("absent.fastq")))
    }

    func testRecordsInsideAScopeReadAFileOnceAndRecordsOutsideItDoNot() async throws {
        let file = try write("ACGT\n", to: "reads.fastq")
        let disk = DiskReadLog()

        let records = try await ProvenanceFileHasher.$readObserver.withValue({ _ in disk.record() }) {
            XCTAssertNil(ProvenanceDigestCache.current)
            let outside = (0..<2).map { _ in ProvenanceRecorder.fileRecord(url: file, format: .fastq, role: .input) }
            XCTAssertEqual(disk.count, 2, "no command scope, no cache: each record reads the file")
            let inside = try await ProvenanceDigestCache.scoped {
                XCTAssertNotNil(ProvenanceDigestCache.current)
                let first = ProvenanceRecorder.fileRecord(url: file, format: .fastq, role: .input)
                let second = ProvenanceRecorder.fileRecord(url: file, format: .fastq, role: .output)
                let descriptor = try ProvenanceFileDescriptor.file(url: file, format: .fastq, role: .input)
                XCTAssertEqual(first.sha256, descriptor.checksumSHA256)
                return [first, second]
            }
            XCTAssertEqual(disk.count, 3, "the scope read the file once for three records")
            return outside + inside
        }

        XCTAssertEqual(Set(records.compactMap(\.sha256)), [sha256Hex("ACGT\n")])
        XCTAssertEqual(records.map(\.sizeBytes), Array(repeating: 5, count: 4))
    }

    func testANestedScopeKeepsTheCacheOfTheCommand() async {
        let outer = ProvenanceDigestCache()
        await ProvenanceDigestCache.scoped(outer) {
            await ProvenanceDigestCache.scoped {
                XCTAssertTrue(ProvenanceDigestCache.current === outer)
            }
        }
        XCTAssertNil(ProvenanceDigestCache.current)
    }
}
