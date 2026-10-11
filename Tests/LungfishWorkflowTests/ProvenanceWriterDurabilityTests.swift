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

    func testRecoveryReplacesAnEmptyReservationOnlyWithALeftoverThatHoldsBytes() throws {
        let folder = try makeFolder("outside/conda")
        let record = folder.appendingPathComponent("record.json")
        XCTAssertTrue(FileManager.default.createFile(atPath: record.path, contents: Data()))
        let emptyTombstone = folder.appendingPathComponent(".record.json.lungfish-swap-\(UUID().uuidString)")
        XCTAssertTrue(FileManager.default.createFile(atPath: emptyTombstone.path, contents: Data()))
        XCTAssertNil(try DurableReplace.recover(named: "record.json", in: folder), "an empty leftover restores nothing")

        let tombstone = folder.appendingPathComponent(".record.json.lungfish-swap-\(UUID().uuidString)")
        try Data("old".utf8).write(to: tombstone)
        XCTAssertEqual(try DurableReplace.recover(named: "record.json", in: folder), record)
        XCTAssertEqual(try text(at: record), "old", "the empty reservation gives way to the old record")
        XCTAssertNil(try DurableReplace.recover(named: "record.json", in: folder))
        XCTAssertEqual(try names(in: folder), [emptyTombstone.lastPathComponent, "record.json"].sorted())
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

    // MARK: - The writer

    func testARewriteIsStagedSyncedAndFlushedOnce() throws {
        let folder = try makeFolder("P.lungfish/Analyses/run-1")
        let record = folder.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        let writer = ProvenanceWriter(signingProvider: nil)
        try writer.write(Self.envelope("old"), toSidecar: record)

        let counter = Counter()
        try withCountingOperations(counter) {
            try writer.write(Self.envelope("new"), toSidecar: record)
        }
        XCTAssertEqual(counter["stageSynced"], 1, "the staged record is fsynced")
        XCTAssertEqual(counter["folderSynced"], 1, "its folder is fsynced after the swap")
        XCTAssertEqual(counter["fullFlush"], 1, "one full flush ends the write")
        XCTAssertEqual(try workflowName(at: record), "new")
        XCTAssertEqual(try names(in: folder), [record.lastPathComponent])
    }

    func testASignedWriteSwapsEachRewriteAndIssuesOneFullFlush() throws {
        let folder = try makeFolder("P.lungfish/Analyses/run-1")
        let record = folder.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        let writer = ProvenanceWriter(signingProvider: LocalProvenanceSigningProvider(privateKey: "durability-key"))
        try writer.write(Self.envelope("old"), toSidecar: record)

        let counter = Counter()
        try withCountingOperations(counter) {
            try writer.write(Self.envelope("new"), toSidecar: record)
        }
        // The record swaps in three times, unsigned, with the placeholder reference and final. Each
        // of the three signings publishes its signature and its key through DurableReplace as well,
        // inside the write's one transaction (Phase 2.7 lane S6b).
        XCTAssertEqual(counter["published"], 3 + 3 * 2, "three record swaps, and a signature and a key for each")
        XCTAssertEqual(counter["stageSynced"], 3 + 3 * 2, "every one of them is fsynced")
        XCTAssertEqual(counter["fullFlush"], 1)
        XCTAssertNoThrow(try ProvenanceSignatureVerifier.verify(provenanceURL: record))
        XCTAssertEqual(try workflowName(at: record), "new")
        let name = record.lastPathComponent
        XCTAssertEqual(try names(in: folder), [name, name + ".pub", name + ".signature.json"])
    }

    func testABundleWriteOf101RecordsIssuesOneFullFlush() throws {
        let bundle = try makeFolder("P.lungfish/Analyses/run-1/sample.lungfishfastq")
        let chunks = try makeFolder("P.lungfish/Analyses/run-1/sample.lungfishfastq/chunks")
        var outputs: [ProvenanceFileDescriptor] = []
        for index in 0..<ProvenanceWriter.maximumBundleOutputSidecars {
            let output = chunks.appendingPathComponent("chunk-\(index).fastq")
            try Data("@r\(index)\nACGT\n+\n!!!!\n".utf8).write(to: output)
            outputs.append(try ProvenanceFileDescriptor.file(url: output, format: .fastq, role: .output))
        }
        let envelope = try ProvenanceRunBuilder(
            workflowName: "bundle",
            workflowVersion: "2026.10",
            toolName: "lungfish-cli",
            toolVersion: "2026.10"
        )
        .argv(["lungfish-cli", "fastq", "import"])
        .runtime(ProvenanceRuntimeIdentity.fixture())
        .step(ProvenanceStep(toolName: "lungfish-cli", toolVersion: "2026.10", argv: ["lungfish-cli"], outputs: outputs, exitStatus: 0))
        .complete(exitStatus: 0, startedAt: Date(timeIntervalSince1970: 20), endedAt: Date(timeIntervalSince1970: 22))

        let counter = Counter()
        let written = try withCountingOperations(counter) {
            try ProvenanceWriter(signingProvider: nil).writeBundleProvenanceLayout(envelope, toBundleRoot: bundle)
        }
        XCTAssertEqual(written.count, 101)
        XCTAssertEqual(counter["fullFlush"], 1, "one full flush makes all 101 records durable")
    }

    func testAReleasedDisplacedRecordIsRestoredBeforeTheNextWrite() throws {
        let (folder, record) = try makeReleasedCrash()
        try ProvenanceWriter(signingProvider: nil).write(Self.envelope("new"), toSidecar: record)

        XCTAssertEqual(try workflowName(at: record), "new")
        XCTAssertEqual(try names(in: folder), [record.lastPathComponent, "other.lungfish-provenance.json"],
                       "the restored record is retired by the swap, never left aside")
    }

    func testAFailedWriteLeavesTheRestoredReleasedRecordUnderItsName() throws {
        let (folder, record) = try makeReleasedCrash()
        let failing = DurableReplace.Operations(checkpoint: { if $0 == .staged { throw Refusal() } })
        XCTAssertThrowsError(try DurableReplace.$overrideOperations.withValue(failing) {
            try ProvenanceWriter(signingProvider: nil).write(Self.envelope("new"), toSidecar: record)
        })

        let found = try XCTUnwrap(ProvenanceRecorder.findProvenanceEnvelope(for: folder))
        XCTAssertEqual(found.sidecarURL.lastPathComponent, record.lastPathComponent, "never the sibling's record")
        XCTAssertEqual(found.envelope.workflowName, "old")
    }

    func testAnObservedWriteLeavesAReleasedDisplacedRecordAlone() throws {
        let (folder, record) = try makeReleasedCrash()
        let displaced = try names(in: folder).filter { $0.contains(".provenance-displaced-") }
        let writer = ProvenanceWriter(publicationMutationDidOccur: { _ in }, signingProvider: nil)
        try writer.write(Self.envelope("new"), toSidecar: record)

        XCTAssertEqual(try workflowName(at: record), "new")
        XCTAssertEqual(displaced.count, 1)
        XCTAssertEqual(try names(in: folder), (displaced + [record.lastPathComponent, "other.lungfish-provenance.json"]).sorted(),
                       "the observer saw the name empty, so the old record stays aside")
    }

    // MARK: - The fault matrix

    // Every event of a write gets one fault: every DurableReplace step and
    // every rename or reservation the swap seam makes, natively and as ExFAT
    // rotates. A thrown fault fails that step, and an exit ends a child
    // process right after it, so nothing cleans up. Then the record name must
    // hold the old or the new record, before any recovery on APFS and after
    // it on ExFAT, the finder must return it and never the sibling's record,
    // and every leftover must keep its UUID tail.

    func testEveryThrownFaultLeavesTheOldOrNewSignedPair() throws {
        try throwAtEveryEvent(.signedPair)
    }

    func testEveryThrownFaultLeavesTheOldOrNewRecordOutsideAProject() throws {
        try throwAtEveryEvent(.outsideProject)
    }

    func testEveryThrownFaultInAnObservedPairRollsBackToTheVerifiedOldPair() throws {
        try throwAtEveryEvent(.observedPair)
    }

    func testEveryExitLeavesTheOldOrNewSignedPair() throws {
        try exitAtEveryEvent(.signedPair)
    }

    func testEveryExitLeavesTheOldOrNewRecordOutsideAProject() throws {
        try exitAtEveryEvent(.outsideProject)
    }

    /// The same matrix on a real ExFAT volume, where the native calls take
    /// the rotation. Run with `scripts/testing/exfat-tests.sh`.
    func testEveryFaultOnARealExFATVolumeLeavesADecodableRecord() throws {
        guard let volume = ProcessInfo.processInfo.environment["LUNGFISH_EXFAT_TEST_ROOT"], !volume.isEmpty else {
            throw XCTSkip("Set LUNGFISH_EXFAT_TEST_ROOT to an ExFAT volume root to run this test.")
        }
        let local = root
        root = URL(fileURLWithPath: volume, isDirectory: true)
            .appendingPathComponent("durability-\(UUID().uuidString)", isDirectory: true)
        volumeRotates = true
        defer {
            try? FileManager.default.removeItem(at: root)
            root = local
            volumeRotates = false
        }
        try throwAtEveryEvent(.signedPair, simulating: [false])
        try throwAtEveryEvent(.outsideProject, simulating: [false])
        try exitAtEveryEvent(.signedPair, simulating: [false])
        try exitAtEveryEvent(.outsideProject, simulating: [false])
    }

    func testTheFinderIgnoresStageTombstoneAndAsideNames() throws {
        let folder = try makeFolder("P.lungfish/Analyses/run-1")
        let name = ProvenanceWriter.provenanceFilename
        let writer = ProvenanceWriter(signingProvider: nil)
        for infix in Self.leftoverInfixes {
            let leftover = ".\(name)\(infix)\(UUID().uuidString)"
            XCTAssertTrue(Self.keepsUUIDTail(leftover, name: name, infix: infix))
            try writer.write(Self.envelope("leftover"), toSidecar: folder.appendingPathComponent(leftover))
        }
        XCTAssertNil(ProvenanceRecorder.findProvenanceEnvelope(for: folder), "no leftover stands in for the record")

        try writer.write(Self.envelope("sibling"), toSidecar: folder.appendingPathComponent("other.lungfish-provenance.json"))
        XCTAssertNil(ProvenanceRecorder.findProvenanceEnvelope(for: folder),
                     "beside the record's own leftovers no sibling stands in, because a read runs no recovery")
        try writer.write(Self.envelope("record"), toSidecar: folder.appendingPathComponent(name))
        XCTAssertEqual(ProvenanceRecorder.findProvenanceEnvelope(for: folder)?.envelope.workflowName, "record")
    }

    /// Runs only as a child of the fault matrix, which reads what the write
    /// left on disk after this process ends at one event.
    func testFaultMatrixChild() throws {
        guard let request = ProcessInfo.processInfo.environment[Self.childVariable] else {
            throw XCTSkip("Runs only as a child of the fault matrix")
        }
        let fields = request.split(separator: " ", maxSplits: 3).map(String.init)
        let scenario = try XCTUnwrap(Scenario(rawValue: fields[0]))
        let injector = FaultInjector(target: try XCTUnwrap(Int(fields[2])), exits: true)
        let record = URL(fileURLWithPath: fields[3], isDirectory: true)
            .appendingPathComponent(ProvenanceWriter.provenanceFilename)
        try DurableReplace.$overrideOperations.withValue(Self.operations(injector, simulated: fields[1] == "1")) {
            try Self.writer(for: scenario).write(Self.envelope("new"), toSidecar: record)
        }
        _exit(Self.targetNeverReached)
    }

    // MARK: - Matrix helpers

    enum Scenario: String, CaseIterable {
        /// A signed record pair inside a project.
        case signedPair
        /// An unsigned record outside every project, as an install writes one.
        case outsideProject
        /// A signed pair whose observer rolls a failed write back.
        case observedPair
    }

    struct MatrixRun {
        let scenario: Scenario
        let simulated: Bool
        let rotates: Bool
        let folder: URL
        var record: URL { folder.appendingPathComponent(ProvenanceWriter.provenanceFilename) }
        var mode: String { rotates ? (simulated ? "simulated ExFAT" : "ExFAT") : "APFS" }
    }

    /// True while the matrix runs on a real ExFAT volume.
    private var volumeRotates = false

    static let childVariable = "LUNGFISH_DURABILITY_MATRIX_CHILD"
    static let targetNeverReached: Int32 = 42
    static let leftoverInfixes = [DurableReplace.stageInfix, PortableRename.swapTombstoneInfix, ".provenance-displaced-"]

    /// Counts the events of one write and fires one fault at the target.
    final class FaultInjector: @unchecked Sendable {
        static let exitStatus: Int32 = 77
        private let lock = NSLock()
        private var names: [String] = []
        let target: Int?
        let exits: Bool

        init(target: Int? = nil, exits: Bool = false) {
            self.target = target
            self.exits = exits
        }

        var events: [String] { lock.withLock { names } }

        /// Counts `event` and says whether it is the target.
        private func count(_ event: String) -> Bool {
            lock.withLock {
                names.append(event)
                return names.count - 1 == target
            }
        }

        func checkpoint(_ step: DurableReplace.Step) throws {
            guard count(step.rawValue) else { return }
            if exits { _exit(Self.exitStatus) }
            throw Refusal()
        }

        /// A thrown fault refuses the rename. An exit follows it.
        func rename(_ perform: () -> Int32) -> Int32 {
            if !exits, lock.withLock({ names.count == target }) {
                _ = count("rename refused")
                errno = EIO
                return -1
            }
            let status = perform()
            let code = errno
            if status == 0, count("rename"), exits { _exit(Self.exitStatus) }
            errno = code
            return status
        }

        /// The empty file an ExFAT rename reserves its destination with. Only
        /// an exit can fault here.
        func reservation() {
            if count("reservation"), exits { _exit(Self.exitStatus) }
        }
    }

    static func operations(_ injector: FaultInjector, simulated: Bool) -> DurableReplace.Operations {
        var rename = PortableRename.Operations()
        rename.nativeRename = { sourceParent, source, destinationParent, destination, flags in
            if simulated, flags != 0 {
                errno = ENOTSUP
                return -1
            }
            return injector.rename { Darwin.renameatx_np(sourceParent, source, destinationParent, destination, flags) }
        }
        rename.ordinaryRename = { sourceParent, source, destinationParent, destination in
            injector.rename { Darwin.renameat(sourceParent, source, destinationParent, destination) }
        }
        rename.afterReservationCreated = { injector.reservation() }
        return DurableReplace.Operations(rename: rename, checkpoint: { try injector.checkpoint($0) })
    }

    static func writer(for scenario: Scenario, harness: ProvenanceRollbackHarness? = nil) -> ProvenanceWriter {
        guard scenario != .outsideProject else { return ProvenanceWriter(signingProvider: nil) }
        let signer = LocalProvenanceSigningProvider(privateKey: "durability-matrix-key")
        guard let harness else { return ProvenanceWriter(signingProvider: signer) }
        return ProvenanceWriter(publicationMutationDidOccur: harness.accept, signingProvider: signer)
    }

    /// A folder holding the old record and a sibling operation's record.
    func prepare(_ scenario: Scenario, simulated: Bool, label: String) throws -> MatrixRun {
        let relative = scenario == .outsideProject ? "conda" : "P.lungfish/Analyses/run-1"
        let folder = try makeFolder("\(label)/\(relative)")
        let run = MatrixRun(scenario: scenario, simulated: simulated, rotates: simulated || volumeRotates, folder: folder)
        let sibling = run.folder.appendingPathComponent("other.lungfish-provenance.json")
        try ProvenanceWriter(signingProvider: nil).write(Self.envelope("sibling"), toSidecar: sibling)
        try Self.writer(for: scenario).write(Self.envelope("old"), toSidecar: run.record)
        return run
    }

    /// The events one unfaulted write passes through.
    func events(of scenario: Scenario, simulated: Bool) throws -> [String] {
        let run = try prepare(scenario, simulated: simulated, label: "dry-\(scenario)-\(simulated)")
        let harness = scenario == .observedPair ? try ProvenanceRollbackHarness(urls: Self.pair(run.record)) : nil
        defer { _ = try? harness?.restore() }
        let injector = FaultInjector()
        try DurableReplace.$overrideOperations.withValue(Self.operations(injector, simulated: simulated)) {
            try Self.writer(for: scenario, harness: harness).write(Self.envelope("new"), toSidecar: run.record)
        }
        let seen = Set(injector.events)
        XCTAssertTrue(DurableReplace.Step.allCases.allSatisfy { seen.contains($0.rawValue) }, "\(injector.events)")
        XCTAssertEqual(seen.contains("reservation"), run.rotates, "only the ExFAT rotation reserves names")
        return injector.events
    }

    func throwAtEveryEvent(_ scenario: Scenario, simulating modes: [Bool] = [false, true]) throws {
        for simulated in modes {
            let events = try events(of: scenario, simulated: simulated)
            for target in events.indices where events[target] != "reservation" {
                let run = try prepare(scenario, simulated: simulated, label: "throw-\(simulated)-\(target)")
                let context = "\(scenario) \(run.mode) throw at \(target) \(events[target])"
                let harness = scenario == .observedPair ? try ProvenanceRollbackHarness(urls: Self.pair(run.record)) : nil
                let writer = Self.writer(for: scenario, harness: harness)
                let operations = Self.operations(FaultInjector(target: target), simulated: simulated)
                XCTAssertThrowsError(try DurableReplace.$overrideOperations.withValue(operations) {
                    try writer.write(Self.envelope("new"), toSidecar: run.record)
                }, context)
                if let harness {
                    XCTAssertEqual(try harness.restore(), [], context)
                    XCTAssertEqual(try workflowName(at: run.record), "old", context)
                }
                try assertOldOrNew(run, context: context, exited: false)
            }
        }
    }

    func exitAtEveryEvent(_ scenario: Scenario, simulating modes: [Bool] = [false, true]) throws {
        guard let xctest = ProcessInfo.processInfo.arguments.first, xctest.hasSuffix("xctest") else {
            throw XCTSkip("Needs xctest to start a child test process")
        }
        var runs: [(run: MatrixRun, target: Int, event: String)] = []
        for simulated in modes {
            let events = try events(of: scenario, simulated: simulated)
            for target in events.indices {
                let run = try prepare(scenario, simulated: simulated, label: "exit-\(simulated)-\(target)")
                runs.append((run, target, events[target]))
            }
        }
        for start in stride(from: 0, to: runs.count, by: 8) {
            let batch = runs[start ..< min(start + 8, runs.count)]
            let children = try batch.map { try startChild(xctest: xctest, run: $0.run, target: $0.target) }
            for (entry, child) in zip(batch, children) {
                let context = "\(scenario) \(entry.run.mode) exit at \(entry.target) \(entry.event)"
                XCTAssertEqual(Self.waitForExit(child), FaultInjector.exitStatus, context)
                try assertOldOrNew(entry.run, context: context, exited: true)
            }
        }
    }

    func startChild(xctest: String, run: MatrixRun, target: Int) throws -> Process {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: xctest)
        child.arguments = [
            "-XCTest", "LungfishWorkflowTests.ProvenanceWriterDurabilityTests/testFaultMatrixChild",
            Bundle(for: Self.self).bundlePath,
        ]
        // An IDE run hands this process its test session's variables, which
        // a plain xctest child must not join.
        var environment = ProcessInfo.processInfo.environment.filter { key, value in
            !(key.hasPrefix("XCTest") || key.hasPrefix("XCInject")
                || (key == "DYLD_INSERT_LIBRARIES" && value.contains("XCTest")))
        }
        environment[Self.childVariable] = "\(run.scenario.rawValue) \(run.simulated ? 1 : 0) \(target) \(run.folder.path)"
        child.environment = environment
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        return child
    }

    /// Waits for a child. One still running after three minutes is hung, so
    /// it is killed and reported, which no fault ever relies on.
    static func waitForExit(_ child: Process) -> Int32 {
        let deadline = Date().addingTimeInterval(180)
        while child.isRunning, Date() < deadline {
            usleep(20_000)
        }
        if child.isRunning {
            kill(child.processIdentifier, SIGKILL)
            child.waitUntilExit()
            return -1
        }
        return child.terminationStatus
    }

    func assertOldOrNew(_ run: MatrixRun, context: String, exited: Bool) throws {
        let name = ProvenanceWriter.provenanceFilename
        if !run.rotates {
            XCTAssertTrue(["old", "new"].contains(try? workflowName(at: run.record)),
                          "\(context): on APFS the name holds a record before any recovery")
        }
        if run.scenario == .outsideProject {
            // Outside a project only the next write of the record recovers it.
            try DurableReplace.recover(named: name, in: run.folder, asideInfixes: [ProvenanceWriter.releasedDisplacedInfix])
        } else {
            // Inside one, opening the project recovers it before any read.
            let project = run.folder.deletingLastPathComponent().deletingLastPathComponent()
            PortableRename.recoverInterruptedSwaps(underProject: project)
        }
        let found = try XCTUnwrap(ProvenanceRecorder.findProvenanceEnvelope(for: run.folder), context)
        XCTAssertEqual(found.sidecarURL.lastPathComponent, name, "\(context): never the sibling's record")
        XCTAssertTrue(["old", "new"].contains(found.envelope.workflowName), "\(context): \(found.envelope.workflowName)")
        if run.scenario != .outsideProject, found.envelope.workflowName == "old" {
            XCTAssertNoThrow(try ProvenanceSignatureVerifier.verify(provenanceURL: run.record), "\(context): the old pair verifies")
        }
        // The signature and the key publish the way the record does, so a leftover can belong to any of the three.
        let leftovers = try names(in: run.folder).filter { $0.hasPrefix(".\(name)") }
        XCTAssertLessThanOrEqual(leftovers.count, exited ? (run.rotates ? 2 : 1) : 0, "\(context): \(leftovers)")
        let owners = Self.pair(run.record).map(\.lastPathComponent)
        for leftover in leftovers {
            XCTAssertTrue(Self.leftoverInfixes.contains { infix in
                owners.contains { Self.keepsUUIDTail(leftover, name: $0, infix: infix) }
            }, "\(context): \(leftover)")
        }
        try Self.writer(for: run.scenario == .outsideProject ? .outsideProject : .signedPair)
            .write(Self.envelope("next"), toSidecar: run.record)
        XCTAssertEqual(try workflowName(at: run.record), "next", "\(context): the next write succeeds")
    }

    static func pair(_ record: URL) -> [URL] {
        [record, ProvenanceSigningConfiguration.signatureURL(for: record), ProvenanceSigningConfiguration.publicKeyURL(for: record)]
    }

    // MARK: - Helpers

    static let simulated = PortableRename.Operations.processSimulatesUnsupportedFlags

    static func envelope(_ workflowName: String) -> ProvenanceEnvelope {
        ProvenanceEnvelope.fixture(workflowName: workflowName)
    }

    func workflowName(at url: URL) throws -> String {
        try ProvenanceEnvelopeReader.decode(Data(contentsOf: url)).workflowName
    }

    /// A run folder as a released build left it after a crash between moving
    /// the old record aside and publishing the new one, beside a sibling
    /// operation's record that the finder's `-provenance.json` fallback reads.
    func makeReleasedCrash() throws -> (folder: URL, record: URL) {
        let folder = try makeFolder("P.lungfish/Analyses/run-1")
        let record = folder.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        let writer = ProvenanceWriter(signingProvider: nil)
        try writer.write(Self.envelope("sibling"), toSidecar: folder.appendingPathComponent("other.lungfish-provenance.json"))
        try writer.write(Self.envelope("old"), toSidecar: record)
        let displaced = folder.appendingPathComponent(".\(record.lastPathComponent).provenance-displaced-\(UUID().uuidString)")
        XCTAssertEqual(Darwin.rename(record.path, displaced.path), 0)
        return (folder, record)
    }

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
