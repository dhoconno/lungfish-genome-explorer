// MappingProvenanceDurabilityTests.swift - mapping-provenance.json publishes through DurableReplace
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Darwin
import Foundation
import XCTest
import LungfishCore
import LungfishTestSupport
@testable import LungfishWorkflow

/// `MappingProvenance.save(to:)` replaces `mapping-provenance.json` through
/// `DurableReplace` (plan decisions S1, V1, V2 and V3), so the name holds a
/// complete old or new record at every step, the bytes and the folder are
/// synced, and one full flush follows. Under `exfat-tests.sh --simulate` every
/// swap takes the ExFAT rotation, and the real-volume test runs on the
/// `exfat-tests.sh` image.
final class MappingProvenanceDurabilityTests: XCTestCase {
    private var root: URL!

    /// The SHA-256 of the bytes `save(to:)` wrote for ``provenance(_:)`` before
    /// it published through `DurableReplace`.
    private static let pinnedDigest = "72c38e2fe9088d047430ad4e5a49c7ebaecd6895e8dcde184ac2f99e6291957a"

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "mapping-provenance-durability")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - The adoption

    func testARewriteIsStagedSyncedAndFlushedOnce() throws {
        let folder = try makeFolder("P.lungfish/Analyses/minimap2-1")
        try Self.provenance("old").save(to: folder)

        let counter = Counter()
        try withCountingOperations(counter) {
            try Self.provenance("new").save(to: folder)
        }
        XCTAssertEqual(counter["stageSynced"], 1, "the staged record is fsynced")
        XCTAssertEqual(counter["published"], 1, "the staged record is swapped in")
        XCTAssertEqual(counter["folderSynced"], 1, "its folder is fsynced after the swap")
        XCTAssertEqual(counter["fullFlush"], 1, "one full flush ends the save")
        XCTAssertEqual(Self.sampleName(in: folder), "new")
        XCTAssertEqual(try names(in: folder), [MappingProvenance.filename])
    }

    func testTheSavedBytesAreUnchanged() throws {
        let folder = try makeFolder("sample")
        try Self.provenance("old").save(to: folder)
        try Self.provenance("pinned").save(to: folder)

        let bytes = try Data(contentsOf: folder.appendingPathComponent(MappingProvenance.filename))
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, Self.pinnedDigest)
    }

    func testSimulatedExFATRewriteRotatesAndLeavesNoTombstone() throws {
        let folder = try makeFolder("P.lungfish/Analyses/minimap2-1")
        try Self.provenance("old").save(to: folder)

        let events = SaveEvents()
        try DurableReplace.$overrideOperations.withValue(operations(events, simulated: true)) {
            try Self.provenance("new").save(to: folder)
        }
        XCTAssertGreaterThan(events.count("reservation"), 0, "the ExFAT rotation reserves each destination first")
        XCTAssertEqual(Self.sampleName(in: folder), "new")
        XCTAssertEqual(try names(in: folder), [MappingProvenance.filename])
    }

    func testASaveIsRefusedThroughAFolderThatIsALinkBelowTheProject() throws {
        let outside = try makeFolder("outside")
        let analyses = try makeFolder("P.lungfish/Analyses")
        let planted = analyses.appendingPathComponent("minimap2-1", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: planted, withDestinationURL: outside)

        XCTAssertThrowsError(try Self.provenance("planted").save(to: planted))
        XCTAssertEqual(try names(in: outside), [], "nothing is written through the link")
    }

    // MARK: - The fault matrix

    // Every event of one rewrite gets one fault, natively and as ExFAT rotates:
    // every DurableReplace step and every rename the swap makes. After each
    // fault the name must hold the old or the new record, before any recovery
    // on APFS and after recovery on ExFAT, with no leftover, and the next save
    // must succeed.

    func testEveryThrownFaultLeavesTheOldOrNewRecord() throws {
        try throwAtEveryEvent(simulating: [false, true])
    }

    /// The same matrix on a real ExFAT volume, where the native calls take
    /// the rotation. Run with `scripts/testing/exfat-tests.sh`.
    func testEveryFaultOnARealExFATVolumeLeavesADecodableRecord() throws {
        guard let volume = ProcessInfo.processInfo.environment["LUNGFISH_EXFAT_TEST_ROOT"], !volume.isEmpty else {
            throw XCTSkip("Set LUNGFISH_EXFAT_TEST_ROOT to an ExFAT volume root to run this test.")
        }
        var information = statfs()
        guard statfs(volume, &information) == 0 else {
            throw XCTSkip("LUNGFISH_EXFAT_TEST_ROOT does not name a mounted volume.")
        }
        let typeName = withUnsafeBytes(of: information.f_fstypename) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        guard typeName == "exfat" else {
            throw XCTSkip("LUNGFISH_EXFAT_TEST_ROOT is \(typeName), not exfat.")
        }
        let local = root
        root = URL(fileURLWithPath: volume, isDirectory: true)
            .appendingPathComponent("mapping-provenance-durability-\(UUID().uuidString)", isDirectory: true)
        volumeRotates = true
        defer {
            try? FileManager.default.removeItem(at: root)
            root = local
            volumeRotates = false
        }

        let folder = try makeFolder("P.lungfish/Analyses/minimap2-1")
        try Self.provenance("old").save(to: folder)
        try Self.provenance("new").save(to: folder)
        XCTAssertEqual(Self.sampleName(in: folder), "new")
        XCTAssertEqual(try names(in: folder), [MappingProvenance.filename])

        try throwAtEveryEvent(simulating: [false])
    }

    // MARK: - Matrix helpers

    /// True while the matrix runs on a real ExFAT volume.
    private var volumeRotates = false

    private struct Fault: Error {}

    /// Counts the events of one save and fails one of them.
    private final class SaveEvents: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [String] = []
        private let target: Int?

        init(target: Int? = nil) {
            self.target = target
        }

        var names: [String] { lock.withLock { seen } }

        func count(_ name: String) -> Int {
            lock.withLock { seen.filter { $0 == name }.count }
        }

        /// Counts `name` and says whether it is the event to fail.
        private func note(_ name: String) -> Bool {
            lock.withLock {
                seen.append(name)
                return seen.count - 1 == target
            }
        }

        func step(_ step: DurableReplace.Step) throws {
            if note(step.rawValue) { throw Fault() }
        }

        /// A refused rename fails with `EIO` and changes nothing.
        func rename(_ perform: () -> Int32) -> Int32 {
            if lock.withLock({ seen.count == target }) {
                _ = note("rename refused")
                errno = EIO
                return -1
            }
            let status = perform()
            let code = errno
            if status == 0 { _ = note("rename") }
            errno = code
            return status
        }

        func reservation() {
            _ = note("reservation")
        }
    }

    private func operations(_ events: SaveEvents, simulated: Bool) -> DurableReplace.Operations {
        var rename = PortableRename.Operations()
        rename.nativeRename = { sourceParent, source, destinationParent, destination, flags in
            if simulated, flags != 0 {
                errno = ENOTSUP
                return -1
            }
            return events.rename { Darwin.renameatx_np(sourceParent, source, destinationParent, destination, flags) }
        }
        rename.ordinaryRename = { sourceParent, source, destinationParent, destination in
            events.rename { Darwin.renameat(sourceParent, source, destinationParent, destination) }
        }
        rename.afterReservationCreated = { events.reservation() }
        return DurableReplace.Operations(rename: rename, checkpoint: { try events.step($0) })
    }

    /// The events one unfaulted rewrite passes through.
    private func eventsOfOneRewrite(simulated: Bool) throws -> [String] {
        let folder = try makeFolder("dry-\(simulated)/P.lungfish/Analyses/minimap2-1")
        try Self.provenance("old").save(to: folder)
        let events = SaveEvents()
        try DurableReplace.$overrideOperations.withValue(operations(events, simulated: simulated)) {
            try Self.provenance("new").save(to: folder)
        }
        let seen = Set(events.names)
        XCTAssertTrue(
            DurableReplace.Step.allCases.allSatisfy { seen.contains($0.rawValue) },
            "a rewrite passes through every durable step, saw \(events.names)"
        )
        XCTAssertTrue(seen.contains("rename"), "a rewrite swaps through the rename seam, saw \(events.names)")
        XCTAssertEqual(seen.contains("reservation"), simulated || volumeRotates, "only the ExFAT rotation reserves names")
        return events.names
    }

    private func throwAtEveryEvent(simulating modes: [Bool]) throws {
        for simulated in modes {
            let events = try eventsOfOneRewrite(simulated: simulated)
            for target in events.indices where events[target] != "reservation" {
                let folder = try makeFolder("throw-\(simulated)-\(target)/P.lungfish/Analyses/minimap2-1")
                try Self.provenance("old").save(to: folder)
                let context = "\(simulated || volumeRotates ? "ExFAT" : "APFS") throw at \(target) \(events[target])"
                let faults = SaveEvents(target: target)
                XCTAssertThrowsError(try DurableReplace.$overrideOperations.withValue(operations(faults, simulated: simulated)) {
                    try Self.provenance("new").save(to: folder)
                }, context)
                try assertOldOrNew(in: folder, rotates: simulated || volumeRotates, context: context)
            }
        }
    }

    private func assertOldOrNew(in folder: URL, rotates: Bool, context: String) throws {
        if !rotates {
            XCTAssertTrue(["old", "new"].contains(Self.sampleName(in: folder)), "\(context): on APFS the name holds a record before any recovery")
        }
        // Opening a project recovers an interrupted ExFAT swap, and a save
        // recovers it before it stages.
        try DurableReplace.recover(named: MappingProvenance.filename, in: folder)
        let sampleName = Self.sampleName(in: folder)
        XCTAssertTrue(["old", "new"].contains(sampleName), "\(context): \(String(describing: sampleName))")
        XCTAssertEqual(try names(in: folder), [MappingProvenance.filename], "\(context): no leftover")

        try Self.provenance("next").save(to: folder)
        XCTAssertEqual(Self.sampleName(in: folder), "next", "\(context): the next save succeeds")
    }

    // MARK: - Helpers

    /// A record whose every field is fixed, so its bytes are the same on every run.
    private static func provenance(_ sampleName: String) -> MappingProvenance {
        let request = MappingRunRequest(
            tool: .minimap2,
            modeID: MappingMode.minimap2MapONT.id,
            inputFASTQURLs: [URL(fileURLWithPath: "/data/reads.fastq")],
            referenceFASTAURL: URL(fileURLWithPath: "/data/reference.fa"),
            outputDirectory: URL(fileURLWithPath: "/data/out"),
            sampleName: sampleName,
            pairedEnd: false,
            threads: 4
        )
        let result = MappingResult(
            mapper: .minimap2,
            modeID: request.modeID,
            bamURL: URL(fileURLWithPath: "/data/out/\(sampleName).sorted.bam"),
            baiURL: URL(fileURLWithPath: "/data/out/\(sampleName).sorted.bam.bai"),
            totalReads: 10,
            mappedReads: 9,
            unmappedReads: 1,
            wallClockSeconds: 1.0,
            contigs: []
        )
        return MappingProvenance.build(
            request: request,
            result: result,
            mapperInvocation: MappingCommandInvocation(label: "minimap2", argv: ["minimap2", "-a", "/data/reference.fa", "/data/reads.fastq"]),
            normalizationInvocations: [],
            mapperVersion: "2.26",
            samtoolsVersion: "1.21",
            recordedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    /// The sample the folder's record names, or `nil` when it does not decode.
    private static func sampleName(in folder: URL) -> String? {
        MappingProvenance.load(from: folder)?.sampleName
    }

    private func makeFolder(_ relativePath: String) throws -> URL {
        let folder = root.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Entry names, without the `._` AppleDouble files macOS adds on ExFAT.
    private func names(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { !$0.hasPrefix("._") }
            .sorted()
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [String: Int] = [:]

        func add(_ key: String) {
            lock.withLock { counts[key, default: 0] += 1 }
        }

        subscript(_ key: String) -> Int {
            lock.withLock { counts[key, default: 0] }
        }
    }

    private func withCountingOperations<Value>(_ counter: Counter, _ body: () throws -> Value) throws -> Value {
        let operations = DurableReplace.Operations(
            fullFlush: { descriptor in
                counter.add("fullFlush")
                return Darwin.fcntl(descriptor, F_FULLFSYNC)
            },
            checkpoint: { counter.add($0.rawValue) }
        )
        return try DurableReplace.$overrideOperations.withValue(operations) { try body() }
    }
}
