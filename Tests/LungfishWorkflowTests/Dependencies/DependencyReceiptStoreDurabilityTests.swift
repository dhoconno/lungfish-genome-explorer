// DependencyReceiptStoreDurabilityTests.swift - dependency-receipt.json publishes through DurableReplace
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import XCTest
import LungfishCore
import LungfishTestSupport
@testable import LungfishWorkflow

/// `DependencyReceiptStore.save(_:)` replaces `dependency-receipt.json` through
/// `DurableReplace` (plan decisions S1, V1, V2 and V3), so the name holds a
/// complete old or new receipt at every step, the bytes and the folder are
/// synced, and one full flush follows. Under `exfat-tests.sh --simulate` every
/// swap takes the ExFAT rotation, and the real-volume test runs on the
/// `exfat-tests.sh` image.
final class DependencyReceiptStoreDurabilityTests: XCTestCase {
    private var root: URL!

    private static let filename = "dependency-receipt.json"

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "receipt-durability")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - The adoption

    func testARewriteIsStagedSyncedAndFlushedOnce() throws {
        let store = try makeStore()
        try store.save(Self.receipt("old"))

        let counter = Counter()
        try withCountingOperations(counter) {
            try store.save(Self.receipt("new"))
        }
        XCTAssertEqual(counter["stageSynced"], 1, "the staged receipt is fsynced")
        XCTAssertEqual(counter["published"], 1, "the staged receipt is swapped in")
        XCTAssertEqual(counter["folderSynced"], 1, "its folder is fsynced after the swap")
        XCTAssertEqual(counter["fullFlush"], 1, "one full flush ends the save")
        XCTAssertEqual(try store.load()?.dependencySet, "new")
        XCTAssertEqual(try names(in: store.storageRoot), [Self.filename])
    }

    func testTheSavedBytesAreWhatTheEncoderWrites() throws {
        let store = try makeStore()
        try store.save(Self.receipt("old"))
        let written = try store.save(Self.receipt("pinned"))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        XCTAssertEqual(try Data(contentsOf: store.receiptURL), try encoder.encode(written))
    }

    func testSimulatedExFATRewriteRotatesAndLeavesNoTombstone() throws {
        let store = try makeStore()
        try store.save(Self.receipt("old"))

        let events = SaveEvents()
        try DurableReplace.$overrideOperations.withValue(operations(events, simulated: true)) {
            try store.save(Self.receipt("new"))
        }
        XCTAssertGreaterThan(events.count("reservation"), 0, "the ExFAT rotation reserves each destination first")
        XCTAssertEqual(try store.load()?.dependencySet, "new")
        XCTAssertEqual(try names(in: store.storageRoot), [Self.filename])
    }

    func testASaveThroughALinkedStorageRootStillPublishes() throws {
        // Outside every project the storage folder is the user's own layout,
        // such as a root moved to an external drive and linked back (V3).
        let real = root.appendingPathComponent("external/storage", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("storage", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let store = DependencyReceiptStore(storageRoot: link)

        try store.save(Self.receipt("old"))
        try store.save(Self.receipt("new"))

        XCTAssertEqual(try store.load()?.dependencySet, "new")
        XCTAssertEqual(try names(in: real), [Self.filename])
    }

    // MARK: - The fault matrix

    // Every event of one rewrite gets one fault, natively and as ExFAT rotates:
    // every DurableReplace step and every rename the swap makes. After each
    // fault the name must hold the old or the new receipt, before any recovery
    // on APFS and after recovery on ExFAT, with no leftover, and the next save
    // must succeed.

    func testEveryThrownFaultLeavesTheOldOrNewReceipt() throws {
        try throwAtEveryEvent(simulating: [false, true])
    }

    /// The same matrix on a real ExFAT volume, where the native calls take
    /// the rotation. Run with `scripts/testing/exfat-tests.sh`.
    func testEveryFaultOnARealExFATVolumeLeavesADecodableReceipt() throws {
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
            .appendingPathComponent("receipt-durability-\(UUID().uuidString)", isDirectory: true)
        volumeRotates = true
        defer {
            try? FileManager.default.removeItem(at: root)
            root = local
            volumeRotates = false
        }

        let store = try makeStore()
        try store.save(Self.receipt("old"))
        try store.save(Self.receipt("new"))
        XCTAssertEqual(try store.load()?.dependencySet, "new")
        XCTAssertEqual(try names(in: store.storageRoot), [Self.filename])

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
        let store = try makeStore("dry-\(simulated)")
        try store.save(Self.receipt("old"))
        let events = SaveEvents()
        try DurableReplace.$overrideOperations.withValue(operations(events, simulated: simulated)) {
            try store.save(Self.receipt("new"))
        }
        let seen = Set(events.names)
        XCTAssertTrue(
            DurableReplace.Step.allCases.allSatisfy { seen.contains($0.rawValue) },
            "a rewrite passes through every durable step, saw \(events.names)"
        )
        XCTAssertEqual(seen.contains("reservation"), simulated || volumeRotates, "only the ExFAT rotation reserves names")
        return events.names
    }

    private func throwAtEveryEvent(simulating modes: [Bool]) throws {
        for simulated in modes {
            let events = try eventsOfOneRewrite(simulated: simulated)
            for target in events.indices where events[target] != "reservation" {
                let store = try makeStore("throw-\(simulated)-\(target)")
                try store.save(Self.receipt("old"))
                let context = "\(simulated || volumeRotates ? "ExFAT" : "APFS") throw at \(target) \(events[target])"
                let faults = SaveEvents(target: target)
                XCTAssertThrowsError(try DurableReplace.$overrideOperations.withValue(operations(faults, simulated: simulated)) {
                    try store.save(Self.receipt("new"))
                }, context)
                try assertOldOrNew(store, rotates: simulated || volumeRotates, context: context)
            }
        }
    }

    private func assertOldOrNew(_ store: DependencyReceiptStore, rotates: Bool, context: String) throws {
        let name = Self.filename
        if !rotates {
            XCTAssertTrue(["old", "new"].contains(try? store.load()?.dependencySet), "\(context): on APFS the name holds a receipt before any recovery")
        }
        // The next save recovers an interrupted ExFAT swap before it stages.
        try DurableReplace.recover(named: name, in: store.storageRoot)
        let loaded = try? store.load()?.dependencySet
        XCTAssertTrue(["old", "new"].contains(loaded), "\(context): \(String(describing: loaded))")
        XCTAssertEqual(try names(in: store.storageRoot), [name], "\(context): no leftover")

        try store.save(Self.receipt("next"))
        XCTAssertEqual(try store.load()?.dependencySet, "next", "\(context): the next save succeeds")
    }

    // MARK: - Helpers

    private static func receipt(_ dependencySet: String) -> DependencyReceipt {
        var receipt = DependencyReceipt.empty()
        receipt.dependencySet = dependencySet
        receipt.environments["samtools"] = .init(
            packageSpec: "bioconda::samtools=1.23.1=hc612e98_0",
            packID: "lungfish-tools",
            installedAt: Date(timeIntervalSince1970: 1_700_000_000),
            state: .installed
        )
        return receipt
    }

    private func makeStore(_ relativePath: String = "storage") throws -> DependencyReceiptStore {
        let folder = root.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return DependencyReceiptStore(storageRoot: folder)
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
