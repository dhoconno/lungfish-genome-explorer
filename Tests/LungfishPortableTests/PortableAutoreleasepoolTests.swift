import Foundation
import XCTest
@testable import LungfishPortable

/// The portable code drains a pool per chunk with `autoreleasepool`, which the Foundation of the Static Linux SDK lacks.
/// These tests run on the Linux tier, where the calls resolve to the pass-through in `Autoreleasepool.swift`, and on the
/// Mac, where they resolve to the Objective-C runtime's.
final class PortableAutoreleasepoolTests: XCTestCase {
    private struct Planted: Error, Equatable {}

    /// Refuses every start, so a test on a plain file proves the reader never starts a child for it.
    private struct RefusingLauncher: PortableChildLauncher {
        func start(_ request: PortableChildRequest) throws -> any PortableChild { throw Planted() }
    }

    private func scratchFile(_ text: String) throws -> URL {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("portable-pool-\(UUID().uuidString).fastq")
        try Data(text.utf8).write(to: file)
        return file
    }

    func testPoolReturnsTheBodysValueAndRethrowsItsError() {
        XCTAssertEqual(autoreleasepool(invoking: { 42 }), 42)
        XCTAssertThrowsError(try autoreleasepool(invoking: { () throws -> Int in throw Planted() })) { error in
            XCTAssertEqual(error as? Planted, Planted())
        }
    }

    func testFileDigestHashesAFileOneByteAChunk() throws {
        let file = try scratchFile("abc")
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(
            try FileDigest.sha256(of: file, chunkSize: 1),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testRawLineReaderReadsAndCountsAPlainFASTQ() throws {
        let file = try scratchFile("@r1\nACGT\n+\nIIII\n@r2\nGG\n+\nII")
        defer { try? FileManager.default.removeItem(at: file) }

        let reader = try FASTQRawLineReader(url: file, launcher: RefusingLauncher())
        var lines: [String] = []
        while let line = try reader.nextLine() { lines.append(String(decoding: line, as: UTF8.self)) }
        reader.close()
        XCTAssertEqual(lines, ["@r1", "ACGT", "+", "IIII", "@r2", "GG", "+", "II"])

        XCTAssertEqual(try FASTQPairInterleaver.countRecords(in: file, launcher: RefusingLauncher()), 2)
    }
}
