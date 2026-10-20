// ReadWriterFixtures.swift - Shared fixtures of the read writer pins and fault tests
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import Synchronization
import XCTest
import LungfishCore
@testable import LungfishWorkflow

/// Fixtures shared by the read writer tests of Phase 2.10 lane S31.
enum ReadWriterFixtures {
    /// One four-line record per name, ACGT with quality IIII. Without
    /// `finalLineBreak` the last quality line ends the data.
    static func fastq(_ names: String..., finalLineBreak: Bool = true) -> Data {
        var text = names.map { "@\($0)\nACGT\n+\nIIII\n" }.joined()
        if !finalLineBreak { text.removeLast() }
        return Data(text.utf8)
    }

    /// `data` as one gzip member, through the system gzip.
    static func gzip(_ data: Data) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-n", "-c"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: data)
        try input.fileHandleForWriting.close()
        let compressed = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "gzip failed")
        return compressed
    }

    /// The text of a gzip file, read back through the system gzip, so a
    /// multi-member stream is checked by a reader other than ours.
    static func gunzip(_ url: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-dc", url.path]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let decoded = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "gzip -dc failed for \(url.lastPathComponent)")
        return String(decoding: decoded, as: UTF8.self)
    }

    /// One record per name, with `base` as its sequence and quality IIII.
    static func mates(_ names: [String], base: Character, finalLineBreak: Bool = true) -> Data {
        var text = names.map { "@\($0)\n\(base)\(base)\(base)\(base)\n+\nIIII\n" }.joined()
        if !finalLineBreak { text.removeLast() }
        return Data(text.utf8)
    }

    /// Writes `data` as `name` in `directory` and returns its URL.
    @discardableResult
    static func write(_ data: Data, named name: String, in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// Every name in `directory`, hidden stage files included, sorted.
    static func entries(of directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { !$0.hasPrefix("._") }
            .sorted()
    }

    /// The path a descriptor names, or an empty string.
    nonisolated static func path(of descriptor: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard Darwin.fcntl(descriptor, F_GETPATH, &buffer) != -1 else { return "" }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    // MARK: - Joins

    /// One join whose bytes are pinned for every writer that concatenates files.
    struct JoinCase {
        let name: String
        let members: [Data]
        let expected: Data
        /// The text the joined bytes decode to when the members are gzip.
        var decoded: String?
    }

    static func joinCases() throws -> [JoinCase] {
        let plainTwo = Data("@a1\nACGT\n+\nIIII\n@a2\nACGT\n+\nIIII\n@b1\nACGT\n+\nIIII\n".utf8)
        let plainThree = Data("@a1\nACGT\n+\nIIII\n@b1\nACGT\n+\nIIII\n@c1\nACGT\n+\nIIII\n".utf8)
        let gzipped = [
            try gzip(fastq("g1", "g2")),
            try gzip(fastq("g3")),
            try gzip(fastq("g4")),
        ]
        // The resolver reads in 1 MiB chunks and the materializer in 4 MiB chunks.
        let large = [
            Data(repeating: UInt8(ascii: "A"), count: (4 << 20) + 3),
            Data(repeating: UInt8(ascii: "C"), count: 1 << 20),
            Data(repeating: UInt8(ascii: "G"), count: (1 << 20) - 1),
        ]
        return [
            JoinCase(
                name: "two plain members, final line breaks",
                members: [fastq("a1", "a2"), fastq("b1")],
                expected: plainTwo
            ),
            JoinCase(
                name: "three plain members, final line breaks",
                members: [fastq("a1"), fastq("b1"), fastq("c1")],
                expected: plainThree
            ),
            // 2.13 lane 13.15, SW5. A member without its final line break gets one before the next member's record,
            // where the base gave `IIII@b1`. The last member keeps its bytes.
            JoinCase(
                name: "two plain members, the first lacks its final line break",
                members: [fastq("a1", finalLineBreak: false), fastq("b1")],
                expected: Data("@a1\nACGT\n+\nIIII\n@b1\nACGT\n+\nIIII\n".utf8)
            ),
            JoinCase(
                name: "three plain members, the last lacks its final line break",
                members: [fastq("a1"), fastq("b1"), fastq("c1", finalLineBreak: false)],
                expected: plainThree.dropLast()
            ),
            JoinCase(
                name: "three plain members, the middle one lacks its final line break",
                members: [fastq("a1"), fastq("b1", finalLineBreak: false), fastq("c1")],
                expected: plainThree
            ),
            JoinCase(
                name: "an empty member adds nothing",
                members: [fastq("a1"), Data(), fastq("c1")],
                expected: fastq("a1") + fastq("c1")
            ),
            JoinCase(
                name: "two gzip members",
                members: Array(gzipped[0..<2]),
                expected: gzipped[0] + gzipped[1],
                decoded: "@g1\nACGT\n+\nIIII\n@g2\nACGT\n+\nIIII\n@g3\nACGT\n+\nIIII\n"
            ),
            JoinCase(
                name: "three gzip members",
                members: gzipped,
                expected: gzipped[0] + gzipped[1] + gzipped[2],
                decoded: "@g1\nACGT\n+\nIIII\n@g2\nACGT\n+\nIIII\n@g3\nACGT\n+\nIIII\n@g4\nACGT\n+\nIIII\n"
            ),
            JoinCase(
                name: "members that end on and cross the chunk sizes",
                members: large,
                expected: large[0] + large[1] + large[2]
            ),
        ]
    }

    /// Writes the members of `joinCase` into `folder` and returns them with
    /// the destination they join into.
    static func stage(_ joinCase: JoinCase, in folder: URL) throws -> (sources: [URL], destination: URL) {
        let gzipped = joinCase.decoded != nil
        let sources = try joinCase.members.enumerated().map { index, data in
            try write(data, named: "m\(index).fastq" + (gzipped ? ".gz" : ""), in: folder)
        }
        return (sources, folder.appendingPathComponent("joined.fastq" + (gzipped ? ".gz" : "")))
    }

    static func check(
        _ joinCase: JoinCase,
        destination: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(try Data(contentsOf: destination), joinCase.expected, joinCase.name, file: file, line: line)
        if let decoded = joinCase.decoded {
            XCTAssertEqual(try gunzip(destination), decoded, joinCase.name, file: file, line: line)
        }
    }

    // MARK: - Kraken2 extraction outputs

    struct Extracted {
        let files: [KrakenResultReadSources.File]
        let outputs: [URL?]
        let pairs: Data
        let reads: Data
    }

    /// One sample's extraction: an interleaved output for the R1 and R2 files,
    /// then a reads file and a file of adjacent mates.
    static func extraction(_ label: String, folder: URL) throws -> Extracted {
        let pairs = mates(["\(label)p1/1", "\(label)p1/2", "\(label)p2/1", "\(label)p2/2"], base: "A")
        let reads = mates(["\(label)u1", "\(label)u2"], base: "G")
        let adjacent = mates(["\(label)m1/1", "\(label)m1/2"], base: "T")
        let outputs: [URL?] = [
            try write(pairs, named: "\(label)-pairs.fastq", in: folder),
            nil,
            try write(reads, named: "\(label)-reads.fastq", in: folder),
            try write(adjacent, named: "\(label)-adjacent.fastq", in: folder),
        ]
        let sources = folder.appendingPathComponent("sources")
        let files = [
            KrakenResultReadSources.File(url: sources.appendingPathComponent("\(label)_R1.fastq"), role: .r1),
            KrakenResultReadSources.File(url: sources.appendingPathComponent("\(label)_R2.fastq"), role: .r2),
            KrakenResultReadSources.File(url: sources.appendingPathComponent("\(label)_reads.fastq"), role: .reads),
            KrakenResultReadSources.File(url: sources.appendingPathComponent("\(label)_mates.fastq"), role: .adjacentMates),
        ]
        return Extracted(files: files, outputs: outputs, pairs: pairs, reads: reads + adjacent)
    }

    // MARK: - Faults

    /// `ENOSPC` on every write into a stage file after the first `allowed`
    /// ones. With `matching`, only a stage file whose path holds that text
    /// counts, such as `.kraken2-pairs.fastq.lungfish-stage-`, so a test can
    /// fail one writer of a route that publishes several files.
    static func fullDisk(afterWrites allowed: Int, matching: String? = nil, tally: Tally) -> DurableReplace.Operations {
        DurableReplace.Operations(writeBytes: { descriptor, bytes, count in
            let stagePath = path(of: descriptor)
            if stagePath.contains(DurableReplace.stageInfix), matching.map({ stagePath.contains($0) }) ?? true,
               tally.add("stageWrites") > allowed {
                errno = ENOSPC
                return -1
            }
            return Darwin.write(descriptor, bytes, count)
        })
    }

    /// The error `body` throws, or `nil`.
    static func capturedError(_ body: () async throws -> Void) async -> Error? {
        do {
            try await body()
            return nil
        } catch {
            return error
        }
    }

    static func assertFullDisk(_ error: Error?, file: StaticString = #filePath, line: UInt = #line) {
        guard case .systemFailure(_, let operation, let code)? = error as? DurableReplace.ReplaceError else {
            return XCTFail("expected a system failure, got \(String(describing: error))", file: file, line: line)
        }
        XCTAssertEqual(operation, "write the stage file", file: file, line: line)
        XCTAssertEqual(code, ENOSPC, file: file, line: line)
    }

    struct Refusal: Error {}

    /// Counts named events safely across the threads a seam closure can run on.
    final class Tally: Sendable {
        private let counts = Mutex<[String: Int]>([:])

        @discardableResult
        func add(_ key: String) -> Int {
            counts.withLock { counts in
                counts[key, default: 0] += 1
                return counts[key, default: 0]
            }
        }

        subscript(_ key: String) -> Int { counts.withLock { $0[key, default: 0] } }
    }
}
