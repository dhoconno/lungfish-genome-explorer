// ProvenanceWriterDurabilityTests.swift - Durable record replacement, its flush and its recovery
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import XCTest
import LungfishCore
@testable import LungfishWorkflow

/// `DurableReplace` and the provenance writer that publishes through it
/// (plan decisions S1, V1, V2 and V3). Under `exfat-tests.sh --simulate`
/// every swap takes the ExFAT rotation.
final class ProvenanceWriterDurabilityTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("durability-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - The helper

    func testReplaceSwapsInTheNewBytesAndRemovesTheRetiredCopy() throws {
        let folder = try makeFolder("P.lungfish/run")
        let record = folder.appendingPathComponent("record.json")
        try Data("old".utf8).write(to: record)
        let oldInode = try inode(of: record)
        var retiredText: String?
        var retiredInode: UInt64?

        let publication = try DurableReplace.replace(Data("new".utf8), named: "record.json", in: folder, observe: {
            retiredText = try? self.text(at: XCTUnwrap($0.retiredURL))
            retiredInode = try? self.inode(of: XCTUnwrap($0.retiredURL))
        })

        XCTAssertEqual(try text(at: record), "new")
        XCTAssertEqual(retiredText, "old", "the observer sees the old file under the stage name")
        XCTAssertEqual(retiredInode, oldInode, "the swap keeps the old file's inode")
        XCTAssertEqual(publication.mechanism, Self.simulated ? .rotationFallback : .nativeSwap)
        XCTAssertEqual(try names(in: folder), ["record.json"])
    }

    func testReplaceIntoAnEmptyNamePublishesExclusively() throws {
        let folder = try makeFolder("P.lungfish/run")
        let publication = try DurableReplace.replace(Data("new".utf8), named: "record.json", in: folder)

        XCTAssertNil(publication.retiredURL)
        XCTAssertEqual(publication.mechanism, Self.simulated ? .reservationFallback : .nativeExclusive)
        XCTAssertEqual(try text(at: folder.appendingPathComponent("record.json")), "new")
        XCTAssertEqual(try names(in: folder), ["record.json"])
    }

    func testStageNameKeepsItsUUIDTailAndHoldsTheSyncedBytes() throws {
        let folder = try makeFolder("P.lungfish/run")
        var stageName: String?
        var stagedText: String?
        try DurableReplace.replace(Data("new".utf8), named: "record.json", in: folder, beforePublish: {
            stageName = $0.lastPathComponent
            stagedText = try self.text(at: $0)
        })
        XCTAssertEqual(stagedText, "new")
        XCTAssertTrue(Self.keepsUUIDTail(try XCTUnwrap(stageName), name: "record.json", infix: ".lungfish-stage-"))
    }

    func testRefusedPublicationPutsTheOldFileBackWithItsInode() throws {
        let folder = try makeFolder("P.lungfish/run")
        let record = folder.appendingPathComponent("record.json")
        try Data("old".utf8).write(to: record)
        let oldInode = try inode(of: record)

        XCTAssertThrowsError(try DurableReplace.replace(Data("new".utf8), named: "record.json", in: folder, observe: { _ in
            throw Refusal()
        })) { XCTAssertTrue($0 is Refusal, "\($0)") }

        XCTAssertEqual(try text(at: record), "old")
        XCTAssertEqual(try inode(of: record), oldInode)
        XCTAssertEqual(try names(in: folder), ["record.json"])
    }

    func testRefusedFirstPublicationLeavesTheNameEmpty() throws {
        let folder = try makeFolder("P.lungfish/run")
        XCTAssertThrowsError(try DurableReplace.replace(Data("new".utf8), named: "record.json", in: folder, observe: { _ in
            throw Refusal()
        }))
        XCTAssertEqual(try names(in: folder), [])
    }

    func testAcceptedFailureKeepsTheNewFileAndRethrowsTheUnderlyingError() throws {
        let folder = try makeFolder("P.lungfish/run")
        let record = folder.appendingPathComponent("record.json")
        try Data("old".utf8).write(to: record)

        XCTAssertThrowsError(try DurableReplace.replace(Data("new".utf8), named: "record.json", in: folder, observe: { _ in
            throw DurableReplace.AcceptedFailure(Refusal())
        })) { XCTAssertTrue($0 is Refusal, "\($0)") }

        XCTAssertEqual(try text(at: record), "new")
        XCTAssertEqual(try names(in: folder), ["record.json"])
    }

    func testANameHoldingAFolderOrALinkIsNeverReplaced() throws {
        let folder = try makeFolder("P.lungfish/run")
        let directory = folder.appendingPathComponent("record.json", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let link = folder.appendingPathComponent("linked.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)

        for name in ["record.json", "linked.json"] {
            XCTAssertThrowsError(try DurableReplace.replace(Data("new".utf8), named: name, in: folder)) {
                guard case .unsafeExistingEntry = $0 as? DurableReplace.ReplaceError else {
                    return XCTFail("\(name): \($0)")
                }
            }
        }
        XCTAssertEqual(try names(in: folder), ["linked.json", "record.json"])
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), root.path)
    }

    func testLinksBelowAProjectAreRefusedAndLinksAboveAFolderAreFollowed() throws {
        let outside = try makeFolder("outside")
        let project = try makeFolder("P.lungfish")
        let planted = project.appendingPathComponent("planted", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: planted, withDestinationURL: outside)
        XCTAssertThrowsError(try DurableReplace.replace(Data("x".utf8), named: "record.json", in: planted)) {
            XCTAssertEqual($0 as? DurableReplace.ReplaceError, .unsafeDirectory(planted.path))
        }
        XCTAssertEqual(try names(in: outside), [])

        // Outside every project the folder itself is the anchor (V3).
        let real = try makeFolder("real/conda")
        let link = root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real.deletingLastPathComponent())
        try DurableReplace.replace(Data("x".utf8), named: "record.json", in: link.appendingPathComponent("conda"))
        XCTAssertEqual(try text(at: real.appendingPathComponent("record.json")), "x")
    }

    func testATransactionIssuesOneFullFlushAndFallsBackToFsync() throws {
        let first = try makeFolder("P.lungfish/a")
        let second = try makeFolder("P.lungfish/b")
        let counter = Counter()
        try withCountingOperations(counter) {
            try DurableReplace.transaction {
                for folder in [first, second, first] {
                    try DurableReplace.replace(Data(UUID().uuidString.utf8), named: "record.json", in: folder)
                }
            }
        }
        XCTAssertEqual(counter["fullFlush"], 1, "one flush covers every publication on the volume")
        XCTAssertEqual(counter["flushed"], 1)

        let refusing = Counter()
        try withCountingOperations(refusing, fullFlushStatus: -1) {
            try DurableReplace.replace(Data("x".utf8), named: "record.json", in: first)
        }
        XCTAssertEqual(refusing["fullFlush"], 1)
        XCTAssertEqual(refusing["syncDirectory"], 2, "the folder sync, then the fsync that replaces a refused full flush")
    }

    func testRecoveryRestoresTheNewestLeftoverOnlyWhenTheNameIsMissing() throws {
        let folder = try makeFolder("outside/conda")
        let tombstone = folder.appendingPathComponent(".record.json.lungfish-swap-\(UUID().uuidString)")
        let displaced = folder.appendingPathComponent(".record.json.provenance-displaced-\(UUID().uuidString)")
        try Data("older".utf8).write(to: tombstone)
        try Data("newer".utf8).write(to: displaced)
        try setModificationDate(Date(timeIntervalSince1970: 1_000), of: tombstone)
        try setModificationDate(Date(timeIntervalSince1970: 2_000), of: displaced)
        let record = folder.appendingPathComponent("record.json")

        XCTAssertEqual(try DurableReplace.recover(named: "record.json", in: folder), record)
        XCTAssertEqual(try text(at: record), "older", "without the aside infix only the tombstone counts")
        XCTAssertNil(try DurableReplace.recover(named: "record.json", in: folder, asideInfixes: [".provenance-displaced-"]))
        XCTAssertEqual(try text(at: record), "older", "a leftover beside a present name is never touched")

        try FileManager.default.removeItem(at: record)
        try Data("older".utf8).write(to: tombstone)
        try setModificationDate(Date(timeIntervalSince1970: 1_000), of: tombstone)
        XCTAssertEqual(try DurableReplace.recover(named: "record.json", in: folder, asideInfixes: [".provenance-displaced-"]), record)
        XCTAssertEqual(try text(at: record), "newer", "the newest leftover wins")
        XCTAssertEqual(try names(in: folder), [tombstone.lastPathComponent, "record.json"].sorted())
    }

    func testReplaceRecoversBeforeItSwapsUnlessToldNotTo() throws {
        let folder = try makeFolder("outside/conda")
        let tombstone = folder.appendingPathComponent(".record.json.lungfish-swap-\(UUID().uuidString)")
        try Data("old".utf8).write(to: tombstone)

        try DurableReplace.replace(Data("first".utf8), named: "record.json", in: folder, recovery: .none)
        XCTAssertEqual(try names(in: folder), [tombstone.lastPathComponent, "record.json"].sorted())

        try FileManager.default.removeItem(at: folder.appendingPathComponent("record.json"))
        let publication = try DurableReplace.replace(Data("new".utf8), named: "record.json", in: folder)
        XCTAssertNotNil(publication.retiredURL, "the restored tombstone is swapped out, not overwritten")
        XCTAssertEqual(try text(at: folder.appendingPathComponent("record.json")), "new")
        XCTAssertEqual(try names(in: folder), ["record.json"])
    }

    func testSimulatedExFATRotatesAndLeavesNoTombstone() throws {
        let folder = try makeFolder("P.lungfish/run")
        let record = folder.appendingPathComponent("record.json")
        try Data("old".utf8).write(to: record)
        let publication = try PortableRename.simulatingUnsupportedFlags {
            try DurableReplace.replace(Data("new".utf8), named: "record.json", in: folder)
        }
        XCTAssertEqual(publication.mechanism, .rotationFallback)
        XCTAssertEqual(try text(at: record), "new")
        XCTAssertEqual(try names(in: folder), ["record.json"])
    }

    // MARK: - Helpers

    static let simulated = PortableRename.Operations.processSimulatesUnsupportedFlags

    struct Refusal: Error {}

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [String: Int] = [:]

        func add(_ key: String) {
            lock.withLock { counts[key, default: 0] += 1 }
        }

        subscript(_ key: String) -> Int {
            lock.withLock { counts[key, default: 0] }
        }
    }

    func withCountingOperations<Value>(
        _ counter: Counter,
        fullFlushStatus: Int32? = nil,
        _ body: () throws -> Value
    ) throws -> Value {
        let operations = DurableReplace.Operations(
            syncDirectory: { counter.add("syncDirectory"); return Darwin.fsync($0) },
            fullFlush: { descriptor in
                counter.add("fullFlush")
                return fullFlushStatus ?? Darwin.fcntl(descriptor, F_FULLFSYNC)
            },
            checkpoint: { counter.add($0.rawValue) }
        )
        return try DurableReplace.$overrideOperations.withValue(operations) { try body() }
    }

    static func keepsUUIDTail(_ entry: String, name: String, infix: String) -> Bool {
        let prefix = ".\(name)\(infix)"
        return entry.hasPrefix(prefix) && UUID(uuidString: String(entry.dropFirst(prefix.count))) != nil
    }

    func makeFolder(_ relativePath: String) throws -> URL {
        let folder = root.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func text(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    func inode(of url: URL) throws -> UInt64 {
        var information = stat()
        guard lstat(url.path, &information) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return UInt64(information.st_ino)
    }

    func names(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { !$0.hasPrefix("._") }
            .sorted()
    }

    func setModificationDate(_ date: Date, of url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }
}
