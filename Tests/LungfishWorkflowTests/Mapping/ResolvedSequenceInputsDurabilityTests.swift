// ResolvedSequenceInputsDurabilityTests.swift - Joined reads and their sidecar reach disk whole or not at all
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import Synchronization
import XCTest
import LungfishCore
import LungfishTestSupport
@testable import LungfishIO
@testable import LungfishWorkflow

/// Phase 2.9 row 259 (lane S12). The files a join writes, the joined reads
/// and the `.sources.json` sidecar that names their members, are inputs that
/// provenance records name with digests. The byte pins hold before and after
/// the writer moved onto `DurableReplace`. The fault tests hold that no
/// reader ever finds a partial joined file under its final name.
///
/// The class name holds `Durability`, so `exfat-tests.sh --simulate` runs it
/// with every rename taking its ExFAT fallback.
final class ResolvedSequenceInputsDurabilityTests: XCTestCase {
    private var root: URL!
    private var joinDirectory: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "joined-reads-durability")
        joinDirectory = root.appendingPathComponent("analysis/.lungfish-map-inputs", isDirectory: true)
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - Byte pins

    func testTwoPlainMembersWithFinalLineBreaksJoinByteForByte() throws {
        let joined = try join([Self.text("a1", "a2"), Self.text("b1")], gzipped: false)

        XCTAssertEqual(
            try String(contentsOf: joined.output, encoding: .utf8),
            "@a1\nACGT\n+\nIIII\n@a2\nACGT\n+\nIIII\n@b1\nACGT\n+\nIIII\n"
        )
        XCTAssertEqual(joined.output.pathExtension, "fastq")
    }

    func testThreePlainMembersGetALineBreakOnlyWhereTheyLackOne() throws {
        let members = [
            Self.text("a1", finalLineBreak: false),
            Self.text("b1"),
            Self.text("c1", finalLineBreak: false),
        ]

        let joined = try join(members, gzipped: false)

        XCTAssertEqual(
            try String(contentsOf: joined.output, encoding: .utf8),
            "@a1\nACGT\n+\nIIII\n@b1\nACGT\n+\nIIII\n@c1\nACGT\n+\nIIII\n"
        )
    }

    func testAnEmptyMemberAddsNothingAndKeepsTheRecordsApart() throws {
        let members = [Self.text("a1", finalLineBreak: false), Data(), Self.text("c1")]

        let joined = try join(members, gzipped: false)

        XCTAssertEqual(
            try String(contentsOf: joined.output, encoding: .utf8),
            "@a1\nACGT\n+\nIIII\n@c1\nACGT\n+\nIIII\n"
        )
    }

    func testTwoGzipMembersJoinByteForByteWithNoLineBreakAdded() throws {
        let members = [try Self.gzip(Self.text("g1", "g2")), try Self.gzip(Self.text("g3"))]
        XCTAssertNotEqual(members[0].last, UInt8(ascii: "\n"), "the fixture must tempt a line break")

        let joined = try join(members, gzipped: true)

        XCTAssertEqual(try Data(contentsOf: joined.output), members[0] + members[1])
        XCTAssertEqual(joined.output.lastPathComponent.hasSuffix(".fastq.gz"), true)
        XCTAssertEqual(
            try Self.gunzip(joined.output),
            "@g1\nACGT\n+\nIIII\n@g2\nACGT\n+\nIIII\n@g3\nACGT\n+\nIIII\n"
        )
    }

    func testThreeGzipMembersJoinByteForByte() throws {
        let members = [
            try Self.gzip(Self.text("g1")),
            try Self.gzip(Self.text("g2")),
            try Self.gzip(Self.text("g3")),
        ]

        let joined = try join(members, gzipped: true)

        XCTAssertEqual(try Data(contentsOf: joined.output), members.reduce(Data(), +))
    }

    func testMembersLargerThanOneChunkJoinByteForByteAcrossTheChunkBoundary() throws {
        let chunk = 4 * 1024 * 1024
        // One member ends exactly on a chunk boundary with a line break, the next
        // spans a boundary and lacks one, so the writer adds exactly one.
        let first = Data(repeating: UInt8(ascii: "A"), count: chunk - 1) + Data([UInt8(ascii: "\n")])
        let second = Data(repeating: UInt8(ascii: "C"), count: chunk + 1)
        let third = Self.text("t1")

        let joined = try join([first, second, third], gzipped: false)

        XCTAssertEqual(try Data(contentsOf: joined.output), first + second + Data([UInt8(ascii: "\n")]) + third)
    }

    func testTheSidecarHoldsTheExactBytesOfAPrettyPrintedSortedRecord() throws {
        let joined = try join([Self.text("a1"), Self.text("b1"), Self.text("c1")], gzipped: false)

        let sidecar = SequenceInputConcatenation.sidecarURL(for: joined.output)
        let escaped = { (path: String) in "\"" + path.replacingOccurrences(of: "/", with: "\\/") + "\"" }
        let expected = """
            {
              "bundlePath" : \(escaped(joined.bundle.standardizedFileURL.path)),
              "memberPaths" : [
                \(joined.members.map { escaped($0.standardizedFileURL.path) }.joined(separator: ",\n    "))
              ],
              "outputPath" : \(escaped(joined.output.path))
            }
            """
        XCTAssertEqual(try String(contentsOf: sidecar, encoding: .utf8), expected)
        XCTAssertEqual(sidecar.lastPathComponent, joined.output.lastPathComponent + ".sources.json")
        XCTAssertEqual(SequenceInputConcatenation.load(for: joined.output), joined.concatenation)
    }

    func testTheFolderHoldsTheJoinedFileAndItsSidecarAndNothingElse() throws {
        let joined = try join([Self.text("a1"), Self.text("b1")], gzipped: false)

        XCTAssertEqual(
            try folderEntries(),
            [joined.output.lastPathComponent, joined.output.lastPathComponent + ".sources.json"].sorted()
        )
    }

    func testTheSameJoinUnderSimulatedExFATRenamesLeavesTheSameBytesAndEntries() throws {
        let members = [Self.text("a1", finalLineBreak: false), Self.text("b1")]

        let joined = try PortableRename.simulatingUnsupportedFlags {
            try join(members, gzipped: false)
        }

        XCTAssertEqual(
            try String(contentsOf: joined.output, encoding: .utf8),
            "@a1\nACGT\n+\nIIII\n@b1\nACGT\n+\nIIII\n"
        )
        XCTAssertEqual(
            try folderEntries(),
            [joined.output.lastPathComponent, joined.output.lastPathComponent + ".sources.json"].sorted()
        )
    }

    func testResolvingForAMapperJoinsTheSameBytes() async throws {
        let (bundle, _) = try makeMultiFileBundle([Self.text("a1", finalLineBreak: false), Self.text("b1")], gzipped: false)

        let resolved = try await ResolvedSequenceInputs.resolve(
            inputURLs: [bundle],
            materializationDirectory: joinDirectory,
            materializer: FASTQCLIMaterializer(runner: .shared),
            concatenateUnpairedFiles: true
        )

        let output = try XCTUnwrap(resolved.executionInputURLs.first)
        XCTAssertEqual(
            try String(contentsOf: output, encoding: .utf8),
            "@a1\nACGT\n+\nIIII\n@b1\nACGT\n+\nIIII\n"
        )
        XCTAssertEqual(try folderEntries().count, 2)
    }

    // MARK: - The failure at the base

    /// The base opened the final name first and streamed into it, so a member
    /// that could not be read after the first one left the first member's bytes
    /// under a name that looked like a complete joined file, with no sidecar.
    /// (An I/O error in the write itself never reached Swift at the base,
    /// because `FileHandle.write(_:)` raises an Objective-C exception.)
    func testAnErrorAfterTheFirstMemberLeavesNothingUnderTheFinalName() throws {
        try XCTSkipIf(getuid() == 0, "root reads a file whatever its mode")
        let (bundle, members) = try makeMultiFileBundle([Self.text("a1"), Self.text("b1")], gzipped: false)
        XCTAssertEqual(chmod(members[1].path, 0o000), 0)
        defer { chmod(members[1].path, 0o644) }

        XCTAssertThrowsError(try ResolvedSequenceInputs.concatenateMultiFileBundle(bundle, into: joinDirectory))

        XCTAssertEqual(try folderEntries(), [], "a failed join leaves no file behind")
    }

    // MARK: - Faults

    /// `ENOSPC` on the second write into a joined file's stage, after its
    /// first member went out. The base raised an Objective-C exception here.
    func testAWriteErrorMidStreamThrowsAndLeavesNothingBehind() throws {
        let (bundle, _) = try makeMultiFileBundle([Self.text("a1"), Self.text("b1"), Self.text("c1")], gzipped: false)
        let tally = Tally()
        let operations = DurableReplace.Operations(writeBytes: { descriptor, bytes, count in
            if Self.path(of: descriptor).contains(".fastq.lungfish-stage-"), tally.add("joinedWrites") == 2 {
                errno = ENOSPC
                return -1
            }
            return Darwin.write(descriptor, bytes, count)
        })

        XCTAssertThrowsError(
            try DurableReplace.$overrideOperations.withValue(operations) {
                try ResolvedSequenceInputs.concatenateMultiFileBundle(bundle, into: joinDirectory)
            }
        ) { error in
            guard case .systemFailure(_, let operation, let code)? = error as? DurableReplace.ReplaceError else {
                return XCTFail("expected a system failure, got \(error)")
            }
            XCTAssertEqual(operation, "write the stage file")
            XCTAssertEqual(code, ENOSPC)
        }
        XCTAssertEqual(tally["joinedWrites"], 2, "the write after the failure never ran")
        XCTAssertEqual(try folderEntries(), [], "neither the file, its sidecar nor a stage file is left")
    }

    func testNoJoinedFileIsVisibleUnderItsFinalNameWhileMembersAreStillStreaming() throws {
        let (bundle, _) = try makeMultiFileBundle([Self.text("a1"), Self.text("b1"), Self.text("c1")], gzipped: false)
        let tally = Tally()
        let directory = joinDirectory.path
        let operations = DurableReplace.Operations(writeBytes: { descriptor, bytes, count in
            if Self.path(of: descriptor).contains(".fastq.lungfish-stage-"), tally.add("joinedWrites") == 2 {
                tally.note((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [])
            }
            return Darwin.write(descriptor, bytes, count)
        })

        let output = try DurableReplace.$overrideOperations.withValue(operations) {
            try XCTUnwrap(ResolvedSequenceInputs.concatenateMultiFileBundle(bundle, into: joinDirectory))
        }.outputURL

        let during = tally.noted
        XCTAssertFalse(during.contains(output.lastPathComponent), "the final name appears only when the file is whole")
        XCTAssertTrue(during.contains { $0.hasPrefix(".") && $0.contains(DurableReplace.stageInfix) }, "the bytes stream into a hidden stage")
        XCTAssertTrue(during.contains(output.lastPathComponent + ".sources.json"), "the sidecar is published first")
    }

    func testAFaultAtAnyStepOfEitherPublicationLeavesNoFileAndNoSidecar() throws {
        let (bundle, _) = try makeMultiFileBundle([Self.text("a1"), Self.text("b1")], gzipped: false)
        for step in DurableReplace.Step.allCases {
            // The sidecar is the first publication and the joined file the second.
            // One flush follows the pair.
            for occurrence in (step == .flushed ? [1] : [1, 2]) {
                let tally = Tally()
                let operations = DurableReplace.Operations(checkpoint: { reached in
                    if reached == step, tally.add("reached") == occurrence { throw Refusal() }
                })

                XCTAssertThrowsError(
                    try DurableReplace.$overrideOperations.withValue(operations) {
                        try ResolvedSequenceInputs.concatenateMultiFileBundle(bundle, into: joinDirectory)
                    },
                    "\(step) #\(occurrence)"
                ) { XCTAssertTrue($0 is Refusal, "\(step) #\(occurrence): \($0)") }
                XCTAssertEqual(try folderEntries(), [], "\(step) #\(occurrence)")
            }
        }
    }

    func testAJoinPublishesTheSidecarAndTheFileInOneTransactionWithOneFlush() throws {
        let (bundle, _) = try makeMultiFileBundle([Self.text("a1"), Self.text("b1")], gzipped: false)
        let tally = Tally()
        let operations = DurableReplace.Operations(
            syncFile: { tally.add("syncFile"); return Darwin.fsync($0) },
            fullFlush: { tally.add("fullFlush"); return Darwin.fcntl($0, F_FULLFSYNC) },
            checkpoint: { tally.add($0.rawValue) }
        )

        _ = try DurableReplace.$overrideOperations.withValue(operations) {
            try ResolvedSequenceInputs.concatenateMultiFileBundle(bundle, into: joinDirectory)
        }

        XCTAssertEqual(tally["published"], 2, "the sidecar and the joined file")
        XCTAssertEqual(tally["syncFile"], 2, "both are synced before they are published")
        XCTAssertEqual(tally["folderSynced"], 2)
        XCTAssertEqual(tally["flushed"], 1)
        XCTAssertEqual(tally["fullFlush"], 1, "one full flush for the volume")
    }

    func testSavingASidecarAgainReplacesTheEarlierRecordWithoutALeftover() throws {
        try FileManager.default.createDirectory(at: joinDirectory, withIntermediateDirectories: true)
        let output = joinDirectory.appendingPathComponent("concatenated-fixed.fastq")
        let bundle = root.appendingPathComponent("b.lungfishfastq")
        let first = SequenceInputConcatenation(
            bundleURL: bundle,
            memberURLs: [root.appendingPathComponent("m1.fastq")],
            outputURL: output
        )
        let second = SequenceInputConcatenation(
            bundleURL: bundle,
            memberURLs: [root.appendingPathComponent("m1.fastq"), root.appendingPathComponent("m2.fastq")],
            outputURL: output
        )

        try first.save()
        try PortableRename.simulatingUnsupportedFlags { try second.save() }

        XCTAssertEqual(SequenceInputConcatenation.load(for: output), second)
        XCTAssertEqual(try folderEntries(), ["concatenated-fixed.fastq.sources.json"])
    }

    // MARK: - Fixtures

    private struct Join {
        let bundle: URL
        let members: [URL]
        let concatenation: SequenceInputConcatenation
        var output: URL { concatenation.outputURL }
    }

    private func join(_ members: [Data], gzipped: Bool) throws -> Join {
        let (bundle, memberURLs) = try makeMultiFileBundle(members, gzipped: gzipped)
        let concatenation = try XCTUnwrap(
            try ResolvedSequenceInputs.concatenateMultiFileBundle(bundle, into: joinDirectory)
        )
        return Join(bundle: bundle, members: memberURLs, concatenation: concatenation)
    }

    private func folderEntries() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: joinDirectory.path)
            .filter { !$0.hasPrefix("._") }
            .sorted()
    }

    /// A root bundle whose `source-files.json` lists one chunk file per member.
    private func makeMultiFileBundle(_ members: [Data], gzipped: Bool) throws -> (bundle: URL, members: [URL]) {
        let bundle = root.appendingPathComponent("Project.lungfish/Imports/multi.lungfishfastq", isDirectory: true)
        let chunkDirectory = bundle.appendingPathComponent("chunks", isDirectory: true)
        try FileManager.default.createDirectory(at: chunkDirectory, withIntermediateDirectories: true)
        var urls: [URL] = []
        var entries: [FASTQSourceFileManifest.SourceFileEntry] = []
        for (index, data) in members.enumerated() {
            let name = "run_\(index).fastq" + (gzipped ? ".gz" : "")
            let url = chunkDirectory.appendingPathComponent(name)
            try data.write(to: url)
            urls.append(url)
            entries.append(.init(
                filename: "chunks/\(name)",
                originalPath: "/orig/\(name)",
                sizeBytes: Int64(data.count),
                isSymlink: false
            ))
        }
        try Self.text("preview").write(to: bundle.appendingPathComponent("preview.fastq"))
        try FASTQSourceFileManifest(files: entries).save(to: bundle)
        return (bundle, urls)
    }

    private struct Refusal: Error {}

    /// Counts named events and keeps one directory listing, safely across the
    /// threads a seam closure can run on.
    private final class Tally: Sendable {
        private let state = Mutex<(counts: [String: Int], noted: [String])>((counts: [:], noted: []))

        @discardableResult
        func add(_ key: String) -> Int {
            state.withLock { state in
                state.counts[key, default: 0] += 1
                return state.counts[key, default: 0]
            }
        }

        subscript(_ key: String) -> Int { state.withLock { $0.counts[key, default: 0] } }

        func note(_ names: [String]) { state.withLock { $0.noted = names } }

        var noted: [String] { state.withLock { $0.noted } }
    }

    /// The path a descriptor names, or an empty string.
    private nonisolated static func path(of descriptor: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard Darwin.fcntl(descriptor, F_GETPATH, &buffer) != -1 else { return "" }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    /// One four-line record per name, ACGT with quality IIII.
    private static func text(_ names: String..., finalLineBreak: Bool = true) -> Data {
        var text = names.map { "@\($0)\nACGT\n+\nIIII\n" }.joined()
        if !finalLineBreak { text.removeLast() }
        return Data(text.utf8)
    }

    /// `data` as one gzip member, through the system gzip.
    private static func gzip(_ data: Data) throws -> Data {
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
    private static func gunzip(_ url: URL) throws -> String {
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
}
