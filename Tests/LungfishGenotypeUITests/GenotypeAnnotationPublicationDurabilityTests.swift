// GenotypeAnnotationPublicationDurabilityTests.swift - annotations.json and its record publish through DurableReplace
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishGenotypeUI

/// `GenotypeAnnotationPublicationCoordinator` publishes `annotations.json` and
/// its provenance record through `DurableReplace`, inside one transaction
/// (plan decisions S1, V1, V2 and V3). Each name holds a complete old or new
/// file at every step, the pair rolls back together when either publication
/// fails, and one full flush follows the pair. Under
/// `exfat-tests.sh --simulate` every swap takes the ExFAT rotation, and the
/// real-volume test runs on the `exfat-tests.sh` image.
final class GenotypeAnnotationPublicationDurabilityTests: XCTestCase {
    private var root: URL!

    private static let annotationName = GenotypeAnnotationSidecar.filename
    /// The record name `ProvenanceRecorder.fileSidecarURL(for:)` gives `annotations.json`.
    private static let provenanceName = "\(GenotypeAnnotationSidecar.filename).lungfish-provenance.json"

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "genotype-durability")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - The adoption

    func testAPairRewriteIsStagedSyncedAndFlushedOnce() throws {
        let bundle = try seed(.rewrite)

        let counter = Counter()
        try withCountingOperations(counter) {
            try publish("new", in: bundle)
        }
        XCTAssertEqual(counter["stageSynced"], 2, "both staged files are fsynced")
        XCTAssertEqual(counter["published"], 2, "both staged files are swapped in")
        XCTAssertEqual(counter["fullFlush"], 1, "one full flush ends the pair")
        XCTAssertEqual(generations(in: bundle).annotation, "new")
        XCTAssertEqual(generations(in: bundle).provenance, "new")
        XCTAssertEqual(try names(in: bundle), [Self.annotationName, Self.provenanceName].sorted())
    }

    func testTheWrittenBytesAreThePayload() throws {
        let bundle = try seed(.rewrite)
        try publish("new", in: bundle)

        let payload = Self.payload("new")
        XCTAssertEqual(try Data(contentsOf: bundle.appendingPathComponent(Self.annotationName)), payload.annotationData)
        XCTAssertEqual(try Data(contentsOf: bundle.appendingPathComponent(Self.provenanceName)), payload.provenanceData)
    }

    func testSimulatedExFATPairRotatesAndLeavesNoTombstone() throws {
        let bundle = try seed(.rewrite)

        let events = Events()
        try DurableReplace.$overrideOperations.withValue(operations(events, simulated: true)) {
            try publish("new", in: bundle)
        }
        XCTAssertGreaterThan(events.count("reservation"), 0, "the ExFAT rotation reserves each destination first")
        XCTAssertEqual(generations(in: bundle).annotation, "new")
        XCTAssertEqual(generations(in: bundle).provenance, "new")
        XCTAssertEqual(try names(in: bundle), [Self.annotationName, Self.provenanceName].sorted())
    }

    func testTrustedGenerationLinksBecomeFilesWithTheNewBytes() throws {
        let bundle = try seed(.linked)
        let generation = bundle.appendingPathComponent("artifacts/genotype-annotations/generations/\(Self.generationID)")

        try publish("new", in: bundle)

        for name in [Self.annotationName, Self.provenanceName] {
            let values = try bundle.appendingPathComponent(name).resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            XCTAssertEqual(values.isRegularFile, true, name)
            XCTAssertEqual(values.isSymbolicLink, false, name)
        }
        XCTAssertEqual(generations(in: bundle).annotation, "new")
        XCTAssertEqual(generations(in: bundle).provenance, "new")
        XCTAssertEqual(try Data(contentsOf: generation.appendingPathComponent(Self.annotationName)), Self.payload("old").annotationData)
        XCTAssertEqual(try Data(contentsOf: generation.appendingPathComponent(Self.provenanceName)), Self.payload("old").provenanceData)
    }

    func testAMissingNameIsRestoredFromItsTombstoneBeforeTheSnapshotIsRead() throws {
        // An ExFAT swap that ended after its first rename leaves the old file
        // under a tombstone and nothing under the name. The snapshot must see
        // that file, or an edit built from nothing would replace it.
        let bundle = try seed(.rewrite)
        let record = bundle.appendingPathComponent(Self.annotationName)
        let tombstone = bundle.appendingPathComponent(".\(Self.annotationName)\(PortableRename.swapTombstoneInfix)\(UUID().uuidString)")
        XCTAssertEqual(Darwin.rename(record.path, tombstone.path), 0)

        var seen: GenotypeAnnotationPublicationSnapshot?
        let published = try coordinator(bundle).transact { snapshot in
            seen = snapshot
            return nil
        }

        XCTAssertNil(published)
        XCTAssertEqual(seen?.annotationData, Self.payload("old").annotationData)
        XCTAssertEqual(generations(in: bundle).annotation, "old")
    }

    func testALinkBelowTheProjectIsRefusedBeforeAnythingIsWritten() throws {
        // The folder opens the way DurableReplace opens it, anchored at the
        // outermost .lungfish component, so a link below the project is
        // refused where an open of the bundle alone would follow it (V3).
        let outside = try makeFolder("outside/Analyses/Result.lungfishgenotype")
        let project = try makeFolder("P.lungfish")
        try FileManager.default.createSymbolicLink(
            at: project.appendingPathComponent("planted", isDirectory: true),
            withDestinationURL: outside.deletingLastPathComponent().deletingLastPathComponent()
        )
        let planted = project.appendingPathComponent("planted/Analyses/Result.lungfishgenotype", isDirectory: true)

        XCTAssertThrowsError(try publish("planted", in: planted))
        XCTAssertEqual(try names(in: outside), [], "nothing is written through the link")
    }

    func testABundleThatIsALinkIsRefused() throws {
        let real = try makeFolder("Real.lungfishgenotype")
        let link = root.appendingPathComponent("Link.lungfishgenotype", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        XCTAssertThrowsError(try publish("planted", in: link))
        XCTAssertEqual(try names(in: real), [], "nothing is written through the link")
    }

    // MARK: - The fault matrix

    // Every event of one publication gets one fault, natively and as ExFAT
    // rotates: every DurableReplace step and every rename the swaps make, and
    // the coordinator's own two fault points. After each fault the pair must
    // be back at its old state, before any recovery on APFS and after recovery
    // on ExFAT, with no leftover, and the next publication must succeed.

    func testEveryThrownFaultRollsTheRewrittenPairBack() throws {
        try throwAtEveryEvent(.rewrite, simulating: [false, true])
    }

    func testEveryThrownFaultOnAFirstPublicationLeavesNeitherFile() throws {
        try throwAtEveryEvent(.firstWrite, simulating: [false, true])
    }

    func testEveryThrownFaultOnLinkedAnnotationsLeavesTheOldBytesUnderBothNames() throws {
        try throwAtEveryEvent(.linked, simulating: [false, true])
    }

    /// A fault that persists through the rollback leaves each name holding a
    /// complete old or new file, though the pair may be mixed.
    func testAFailureThatOutlastsTheRollbackLeavesWholeFiles() throws {
        for simulated in [false, true] {
            let events = try eventsOfOnePublication(.rewrite, simulated: simulated)
            for target in events.indices where events[target] != "reservation" {
                let bundle = try seed(.rewrite, label: "persist-\(simulated)-\(target)")
                let context = "\(simulated ? "ExFAT" : "APFS") failing from \(target) \(events[target])"
                let faults = Events(target: target, persists: true)
                XCTAssertThrowsError(try DurableReplace.$overrideOperations.withValue(operations(faults, simulated: simulated)) {
                    try coordinator(bundle, faultInjector: { faults.faultPoint($0) }).transact { _ in Self.payload("new") }
                }, context)
                if simulated {
                    try recover(bundle)
                }
                let found = generations(in: bundle)
                XCTAssertTrue(["old", "new"].contains(found.annotation), "\(context): annotation \(String(describing: found.annotation))")
                XCTAssertTrue(["old", "new"].contains(found.provenance), "\(context): provenance \(String(describing: found.provenance))")
            }
        }
    }

    /// The same matrix on a real ExFAT volume, where the native calls take
    /// the rotation. Run with `scripts/testing/exfat-tests.sh`.
    func testEveryFaultOnARealExFATVolumeLeavesADecodablePair() throws {
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
            .appendingPathComponent("genotype-durability-\(UUID().uuidString)", isDirectory: true)
        volumeRotates = true
        defer {
            try? FileManager.default.removeItem(at: root)
            root = local
            volumeRotates = false
        }

        let bundle = try seed(.rewrite)
        try publish("new", in: bundle)
        XCTAssertEqual(generations(in: bundle).annotation, "new")
        XCTAssertEqual(generations(in: bundle).provenance, "new")
        XCTAssertEqual(try names(in: bundle), [Self.annotationName, Self.provenanceName].sorted())

        try throwAtEveryEvent(.rewrite, simulating: [false])
        try throwAtEveryEvent(.firstWrite, simulating: [false])
        try throwAtEveryEvent(.linked, simulating: [false])
    }

    // MARK: - Matrix helpers

    /// True while the matrix runs on a real ExFAT volume.
    private var volumeRotates = false

    private struct Fault: Error {}

    /// What a bundle holds before a publication.
    private enum Scenario: String {
        /// Both files exist as regular files, as after an earlier edit.
        case rewrite
        /// Neither file exists, as at a bundle's first edit.
        case firstWrite
        /// Both names are the trusted generation links of an earlier store.
        case linked
    }

    /// Counts the events of one publication and fails one of them, or every
    /// event from it on.
    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [String] = []
        private let target: Int?
        private let persists: Bool

        init(target: Int? = nil, persists: Bool = false) {
            self.target = target
            self.persists = persists
        }

        var names: [String] { lock.withLock { seen } }

        func count(_ name: String) -> Int {
            lock.withLock { seen.filter { $0 == name }.count }
        }

        /// Counts `name` and says whether it fails.
        private func note(_ name: String) -> Bool {
            lock.withLock {
                seen.append(name)
                guard let target else { return false }
                return persists ? seen.count - 1 >= target : seen.count - 1 == target
            }
        }

        func step(_ step: DurableReplace.Step) throws {
            if note(step.rawValue) { throw Fault() }
        }

        func faultPoint(_ point: GenotypeAnnotationPublicationFaultPoint) -> Error? {
            note("\(point)") ? Fault() : nil
        }

        /// A refused rename fails with `EIO` and changes nothing.
        func rename(_ perform: () -> Int32) -> Int32 {
            let refused = lock.withLock { () -> Bool in
                guard let target else { return false }
                return persists ? seen.count >= target : seen.count == target
            }
            if refused {
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

    private func operations(_ events: Events, simulated: Bool) -> DurableReplace.Operations {
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

    /// The events one unfaulted publication passes through.
    private func eventsOfOnePublication(_ scenario: Scenario, simulated: Bool) throws -> [String] {
        let bundle = try seed(scenario, label: "dry-\(scenario.rawValue)-\(simulated)")
        let events = Events()
        try DurableReplace.$overrideOperations.withValue(operations(events, simulated: simulated)) {
            try coordinator(bundle, faultInjector: { events.faultPoint($0) }).transact { _ in Self.payload("new") }
        }
        let seen = Set(events.names)
        XCTAssertTrue(
            DurableReplace.Step.allCases.allSatisfy { seen.contains($0.rawValue) },
            "a publication passes through every durable step, saw \(events.names)"
        )
        XCTAssertTrue(seen.contains("rename"), "a publication swaps through the rename seam, saw \(events.names)")
        XCTAssertTrue(seen.contains("beforeProvenancePublication") && seen.contains("commitDirectorySync"), "\(events.names)")
        XCTAssertEqual(seen.contains("reservation"), simulated || volumeRotates, "only the ExFAT rotation reserves names")
        return events.names
    }

    private func throwAtEveryEvent(_ scenario: Scenario, simulating modes: [Bool]) throws {
        for simulated in modes {
            let events = try eventsOfOnePublication(scenario, simulated: simulated)
            for target in events.indices where events[target] != "reservation" {
                let bundle = try seed(scenario, label: "throw-\(scenario.rawValue)-\(simulated)-\(target)")
                let context = "\(scenario.rawValue) \(simulated || volumeRotates ? "ExFAT" : "APFS") throw at \(target) \(events[target])"
                let faults = Events(target: target)
                XCTAssertThrowsError(try DurableReplace.$overrideOperations.withValue(operations(faults, simulated: simulated)) {
                    try coordinator(bundle, faultInjector: { faults.faultPoint($0) }).transact { _ in Self.payload("new") }
                }, context)
                try assertRolledBack(scenario, bundle, rotates: simulated || volumeRotates, context: context)
            }
        }
    }

    /// The old state is back under both names, and nothing else is left.
    private func assertRolledBack(_ scenario: Scenario, _ bundle: URL, rotates: Bool, context: String) throws {
        let expected: String? = scenario == .firstWrite ? nil : "old"
        if !rotates {
            let found = generations(in: bundle)
            XCTAssertEqual(found.annotation, expected, "\(context): annotation, on APFS before any recovery")
            XCTAssertEqual(found.provenance, expected, "\(context): provenance, on APFS before any recovery")
        }
        // Opening a project recovers an interrupted ExFAT swap, and the next
        // publication recovers it before it reads its snapshot.
        try recover(bundle)
        let found = generations(in: bundle)
        XCTAssertEqual(found.annotation, expected, "\(context): annotation")
        XCTAssertEqual(found.provenance, expected, "\(context): provenance")
        let leftovers = try names(in: bundle).filter { $0.contains(DurableReplace.stageInfix) || $0.contains(PortableRename.swapTombstoneInfix) }
        XCTAssertEqual(leftovers, [], "\(context): no leftover")
        if scenario == .firstWrite {
            XCTAssertEqual(try names(in: bundle), [], "\(context): a bundle that held nothing holds nothing")
        }

        try publish("next", in: bundle)
        XCTAssertEqual(generations(in: bundle).annotation, "next", "\(context): the next publication succeeds")
        XCTAssertEqual(generations(in: bundle).provenance, "next", "\(context): the next publication succeeds")
    }

    private func recover(_ bundle: URL) throws {
        for name in [Self.annotationName, Self.provenanceName] {
            try DurableReplace.recover(named: name, in: bundle)
        }
    }

    // MARK: - Helpers

    private static let generationID = "46fc3db4-ea08-483d-9f6c-f67f4e2d6caa"

    private static func payload(_ generation: String) -> GenotypeAnnotationPublicationPayload {
        GenotypeAnnotationPublicationPayload(
            annotationData: Data(#"{"generation":"\#(generation)","file":"annotations"}"#.utf8),
            provenanceData: Data(#"{"generation":"\#(generation)","file":"provenance"}"#.utf8)
        )
    }

    private func coordinator(
        _ bundle: URL,
        faultInjector: GenotypeAnnotationPublicationFaultInjector? = nil
    ) -> GenotypeAnnotationPublicationCoordinator {
        GenotypeAnnotationPublicationCoordinator(
            bundleURL: bundle,
            annotationFilename: Self.annotationName,
            provenanceFilename: Self.provenanceName,
            faultInjector: faultInjector
        )
    }

    @discardableResult
    private func publish(_ generation: String, in bundle: URL) throws -> GenotypeAnnotationPublicationPayload? {
        try coordinator(bundle).transact { _ in Self.payload(generation) }
    }

    /// A genotype bundle in the state `scenario` names, holding the old pair.
    private func seed(_ scenario: Scenario, label: String = "bundle") throws -> URL {
        let bundle = try makeFolder("\(label)/P.lungfish/Analyses/Result.lungfishgenotype")
        switch scenario {
        case .firstWrite:
            break
        case .rewrite:
            let old = Self.payload("old")
            try old.annotationData.write(to: bundle.appendingPathComponent(Self.annotationName))
            try old.provenanceData.write(to: bundle.appendingPathComponent(Self.provenanceName))
        case .linked:
            let old = Self.payload("old")
            let annotationRoot = bundle.appendingPathComponent("artifacts/genotype-annotations", isDirectory: true)
            let generation = annotationRoot.appendingPathComponent("generations/\(Self.generationID)", isDirectory: true)
            try FileManager.default.createDirectory(at: generation, withIntermediateDirectories: true)
            try old.annotationData.write(to: generation.appendingPathComponent(Self.annotationName))
            try old.provenanceData.write(to: generation.appendingPathComponent(Self.provenanceName))
            try FileManager.default.createSymbolicLink(
                atPath: annotationRoot.appendingPathComponent("active").path,
                withDestinationPath: "generations/\(Self.generationID)"
            )
            for name in [Self.annotationName, Self.provenanceName] {
                try FileManager.default.createSymbolicLink(
                    atPath: bundle.appendingPathComponent(name).path,
                    withDestinationPath: "artifacts/genotype-annotations/active/\(name)"
                )
            }
        }
        return bundle
    }

    /// The generation each name holds, reading a trusted link as the
    /// coordinator does, or `nil` for a name that holds nothing readable.
    private func generations(in bundle: URL) -> (annotation: String?, provenance: String?) {
        func generation(_ name: String) -> String? {
            guard let data = (try? GenotypeAnnotationPublicationFileAccess.readFileIfPresent(named: name, inBundleAt: bundle)) ?? nil,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return object["generation"] as? String
        }
        return (generation(Self.annotationName), generation(Self.provenanceName))
    }

    private func makeFolder(_ relativePath: String) throws -> URL {
        let folder = root.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// The names of files and links in a folder, without folders and the
    /// `._` AppleDouble files macOS adds on ExFAT.
    private func names(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { !$0.hasPrefix("._") }
            .filter { name in
                var isDirectory: ObjCBool = false
                _ = FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path, isDirectory: &isDirectory)
                let isLink = (try? FileManager.default.destinationOfSymbolicLink(atPath: folder.appendingPathComponent(name).path)) != nil
                return isLink || !isDirectory.boolValue
            }
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
