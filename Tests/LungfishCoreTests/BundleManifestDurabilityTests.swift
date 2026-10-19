// BundleManifestDurabilityTests.swift - BundleManifest.save publishes through DurableReplace
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import XCTest
import LungfishTestSupport
@testable import LungfishCore

/// `BundleManifest.save(to:)` replaces `manifest.json` through `DurableReplace`
/// (plan decisions S1, V1, V2 and V3), so the name holds a complete old or new
/// manifest at every step, the bytes and the folder are synced, and one full
/// flush follows. Under `exfat-tests.sh --simulate` every swap takes the ExFAT
/// rotation, and the real-volume test runs on the `exfat-tests.sh` disk image.
final class BundleManifestDurabilityTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "manifest-durability")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - The adoption

    func testARewriteIsStagedSyncedAndFlushedOnce() throws {
        let bundle = try makeBundle()
        try Self.manifest("old").save(to: bundle)

        let counter = Counter()
        try withCountingOperations(counter) {
            try Self.manifest("new").save(to: bundle)
        }
        XCTAssertEqual(counter["stageSynced"], 1, "the staged manifest is fsynced")
        XCTAssertEqual(counter["published"], 1, "the staged manifest is swapped in")
        XCTAssertEqual(counter["folderSynced"], 1, "its folder is fsynced after the swap")
        XCTAssertEqual(counter["fullFlush"], 1, "one full flush ends the save")
        XCTAssertEqual(try loadedName(of: bundle), "new")
        XCTAssertEqual(try names(in: bundle), [BundleManifest.filename])
    }

    func testTheSavedBytesAreWhatTheEncoderWrites() throws {
        let bundle = try makeBundle()
        let manifest = Self.manifest("pinned")
        try Self.manifest("old").save(to: bundle)
        try manifest.save(to: bundle)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let expected = try encoder.encode(manifest.storedForm)
        XCTAssertEqual(try Data(contentsOf: bundle.appendingPathComponent(BundleManifest.filename)), expected)
    }

    func testSimulatedExFATRewriteRotatesAndLeavesNoTombstone() throws {
        let bundle = try makeBundle()
        try Self.manifest("old").save(to: bundle)

        let events = SaveEvents()
        try DurableReplace.$overrideOperations.withValue(operations(events, simulated: true)) {
            try Self.manifest("new").save(to: bundle)
        }
        XCTAssertGreaterThan(events.count("reservation"), 0, "the ExFAT rotation reserves each destination first")
        XCTAssertEqual(try loadedName(of: bundle), "new")
        XCTAssertEqual(try names(in: bundle), [BundleManifest.filename])
    }

    func testSaveIsRefusedThroughABundleThatIsALink() throws {
        let real = try makeBundle("Real.lungfishref")
        let link = root.appendingPathComponent("Link.lungfishref", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        XCTAssertThrowsError(try Self.manifest("planted").save(to: link))
        XCTAssertEqual(try names(in: real), [], "nothing is written through the link")
    }

    // MARK: - The fault matrix

    // Every event of one rewrite gets one fault, natively and as ExFAT rotates:
    // every DurableReplace step and every rename the swap makes. After each
    // fault the name must hold the old or the new manifest, before any
    // recovery on APFS and after recovery on ExFAT, with no leftover, and the
    // next save must succeed.

    func testEveryThrownFaultLeavesTheOldOrNewManifest() throws {
        try throwAtEveryEvent(simulating: [false, true])
    }

    /// The same matrix on a real ExFAT volume, where the native calls take
    /// the rotation. Run with `scripts/testing/exfat-tests.sh`.
    func testEveryFaultOnARealExFATVolumeLeavesADecodableManifest() throws {
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
            .appendingPathComponent("manifest-durability-\(UUID().uuidString)", isDirectory: true)
        volumeRotates = true
        defer {
            try? FileManager.default.removeItem(at: root)
            root = local
            volumeRotates = false
        }

        let bundle = try makeBundle()
        try Self.manifest("old").save(to: bundle)
        try Self.manifest("new").save(to: bundle)
        XCTAssertEqual(try loadedName(of: bundle), "new")
        XCTAssertEqual(try names(in: bundle), [BundleManifest.filename])

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
        let bundle = try makeBundle("dry-\(simulated)")
        try Self.manifest("old").save(to: bundle)
        let events = SaveEvents()
        try DurableReplace.$overrideOperations.withValue(operations(events, simulated: simulated)) {
            try Self.manifest("new").save(to: bundle)
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
                let bundle = try makeBundle("throw-\(simulated)-\(target)")
                try Self.manifest("old").save(to: bundle)
                let context = "\(simulated || volumeRotates ? "ExFAT" : "APFS") throw at \(target) \(events[target])"
                let faults = SaveEvents(target: target)
                XCTAssertThrowsError(try DurableReplace.$overrideOperations.withValue(operations(faults, simulated: simulated)) {
                    try Self.manifest("new").save(to: bundle)
                }, context)
                try assertOldOrNew(in: bundle, rotates: simulated || volumeRotates, context: context)
            }
        }
    }

    private func assertOldOrNew(in bundle: URL, rotates: Bool, context: String) throws {
        if !rotates {
            XCTAssertTrue(["old", "new"].contains(try? loadedName(of: bundle)), "\(context): on APFS the name holds a manifest before any recovery")
        }
        // Opening a project recovers an interrupted ExFAT swap, and a save
        // recovers it before it stages.
        try DurableReplace.recover(named: BundleManifest.filename, in: bundle)
        let loaded = try? loadedName(of: bundle)
        XCTAssertTrue(["old", "new"].contains(loaded), "\(context): \(String(describing: loaded))")
        XCTAssertEqual(try names(in: bundle), [BundleManifest.filename], "\(context): no leftover")

        try Self.manifest("next").save(to: bundle)
        XCTAssertEqual(try loadedName(of: bundle), "next", "\(context): the next save succeeds")
    }

    // MARK: - Helpers

    private static func manifest(_ name: String) -> BundleManifest {
        BundleManifest(
            name: name,
            identifier: "test.durability",
            createdDate: Date(timeIntervalSince1970: 1_700_000_000),
            modifiedDate: Date(timeIntervalSince1970: 1_700_000_000),
            source: SourceInfo(organism: "Test organism", assembly: "TG1")
        )
    }

    private func loadedName(of bundle: URL) throws -> String {
        try BundleManifest.load(from: bundle).name
    }

    private func makeBundle(_ name: String = "Test.lungfishref") throws -> URL {
        let bundle = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        return bundle
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
