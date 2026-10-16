// FastqIngestRouteParityReplayTests.swift - The in-place FASTQ ingestion routes, on a stand-in clumpify
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A47 M3 (panel G1, C4 and C13, ARCH 2 and 3, BIO 1 and 4, UX 1 and 3, QA 1, 4 and
// 5, and the ruling on M3 section 3). Copying a FASTQ file into a project ingests it in place.
// Phase 2.11 (K3, E14) deleted the in-process route, so the ingestion runs on the CLI route only.
// The parity case runs one ingestion on the two sides of RouteParityHarness that are left.
//
// - Side C, the CLI route, `startInPlaceIngestionThroughCLI` on the built `lungfish-cli`.
// - Side C', the command side C's row recorded, rebased and run by the built CLI.
//
// C against C' declares nothing. The class also holds the row to a bar that only rises and to the
// slot wait it has always shown, and the cancel on both sides. The ruling's items (a) to (c), the
// order of the record and the removal, a clumping that resolves to none, and a sidecar that fails
// to write, are fixed on the leaf and shown there (`FastqIngestLeafDurabilityTests`).
//
// C's bar is the pipeline's fraction times 0.9, with the digest, sidecar, record and removal steps
// filling the rest, so it only rises.
//
// A stand-in clumpify answers both sides (G2). It copies the reads through gzip. Side C gets its
// conda root from LUNGFISH_CONDA_ROOT, which the test sets for its run, through the app's
// subprocess environment, and side C' gets it through the harness. The real clumpify stays in
// `FASTQIngestionInPlaceLiveConformanceTests` and `FastqIngestLiveConformanceTests`.
//
// It launches the built lungfish-cli, so its name ends in ReplayTests, which sends it to the
// integration tier (docs/contracts/CLI-EQUIVALENCE.md).

import Foundation
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
@testable import LungfishWorkflow

@MainActor
final class FastqIngestRouteParityReplayTests: XCTestCase {
    private var scratch: URL!
    private var cliBinary: URL!
    private var savedEnvironment: [String: String?] = [:]
    /// 2.11 S8. The command stages in the system temp folder, here a folder of this test's own that it inherits.
    private var systemTemp: URL!
    private var previousTMPDIR: String?

    override func setUp() async throws {
        try await super.setUp()
        scratch = try TestTempDirectory.make(prefix: "fastq-ingest-parity")
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        cliBinary = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH, so sides C and C' cannot run"
        )
        systemTemp = scratch.appendingPathComponent("T", isDirectory: true)
        try FileManager.default.createDirectory(at: systemTemp, withIntermediateDirectories: true)
        previousTMPDIR = ProcessInfo.processInfo.environment["TMPDIR"]
        setenv("TMPDIR", systemTemp.path, 1)
    }

    override func tearDown() async throws {
        for (key, value) in savedEnvironment {
            if let value { setenv(key, value, 1) } else { unsetenv(key) }
        }
        if !savedEnvironment.isEmpty {
            // The shared runner keeps the path it found for clumpify under the stand-in root.
            await NativeToolRunner.shared.clearCache()
        }
        savedEnvironment = [:]
        if let previousTMPDIR { setenv("TMPDIR", previousTMPDIR, 1) } else { unsetenv("TMPDIR") }
        TestTempDirectory.cleanup(scratch)
        try await super.tearDown()
    }

    // MARK: - C against C'

    func testTheRecordedCommandReproducesTheIngestionOnTheCLIRoute() async throws {
        let condaRoot = try installStandInClumpify(Self.copyingClumpify, at: scratch.appendingPathComponent("tools/conda"))
        let environment = Self.standInEnvironment(condaRoot: condaRoot.path)
        await useEnvironment(environment)
        let harness = RouteParityHarness(
            cliBinary: cliBinary, kind: .bundle, replayTimeout: .seconds(120), environment: { _ in environment }
        )
        var rowC: MappingRouteRow?
        let runs = try await ReadsRouteParity.runCAndCPrime(
            harness,
            in: scratch.appendingPathComponent("parity", isDirectory: true),
            fixture: Self.writeFixture,
            sideC: { root in
                let input = Self.input(in: root)
                let runner = CLIReadsRunner(cliURLOverride: self.cliBinary)
                let (row, item) = try await ReadsRouteParity.record(title: Self.title) {
                    FASTQIngestionService.startInPlaceIngestionThroughCLI(url: input, routeContext: nil, runner: runner)
                }
                rowC = ReadsRouteParity.rooted(row, root)
                return ReadsRouteParity.outcome(of: item, recordsCommand: true)
            }
        )

        let sides = [runs.c, runs.cPrime]
        XCTAssertEqual(sides.map(\.outcome.end), [.completed, .completed], sides.map(\.outcome.detail).joined(separator: "\n"))

        // C against C' declares nothing. The command the row recorded rebuilds the same project.
        let found = try harness.differences(runs.c, runs.cPrime)
        RouteParityHarness.assertNoFailures(found.map { "\($0.id): \($0.detail)" }, in: "copied in, C against C'")
        try assertEverySideRanThePinnedHeap(runs)

        // The final trees hold the same reads: the original is gone, and the gzip file and its sidecar stand.
        for side in sides {
            XCTAssertFalse(FileManager.default.fileExists(atPath: Self.input(in: side.root).path), "side \(side.side) removed the original")
            XCTAssertTrue(FileManager.default.fileExists(atPath: Self.output(in: side.root).path), "side \(side.side) published the output")
            XCTAssertNotNil(FASTQMetadataStore.load(for: Self.output(in: side.root))?.ingestion, "side \(side.side) wrote the sidecar")
        }

        // UX 1 and 3. The row's bar only rises, and the slot wait is shown as before.
        let row = try XCTUnwrap(rowC)
        XCTAssertEqual(row.bar, row.bar.sorted(), "the CLI route's bar only rises")
        XCTAssertTrue(row.shown.contains("Waiting for available import slot\u{2026}"), "the slot wait is shown as before")

        // The row records the command the leaf ran (CLI-EQUIVALENCE, provenance names the command).
        let command = try XCTUnwrap(runs.c.outcome.recordedCommand)
        let argv = try RecordedCLICommand.arguments(of: command)
        XCTAssertTrue(argv.starts(with: ["fastq", "ingest", Self.input(in: runs.c.root).path]), "\(argv)")
        XCTAssertEqual(runs.cPrime.replayedArguments.count, 1, "C' replays the one command")
    }

    /// The records still name the `-Xmx` that ran, with no mask. Both sides were pinned to one heap through the hidden
    /// seam, so the clumpify step of each side's record names that heap in its argv: the CLI child on side C, and the
    /// replayed command on side C'.
    private func assertEverySideRanThePinnedHeap(_ runs: RouteParityRuns) throws {
        for run in [runs.c, runs.cPrime] {
            let record = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: Self.record(in: run.root)), "side \(run.side)'s record")
            let clumpify = try XCTUnwrap(record.steps.first { $0.toolName.contains("clumpify") }, "side \(run.side) has a clumpify step")
            XCTAssertTrue(
                clumpify.argv.contains("-Xmx\(Self.pinnedHeapGB)g"),
                "side \(run.side) ran with the pinned heap, its argv is \(clumpify.argv)"
            )
        }
    }

    // MARK: - Cancel

    /// The window's Cancel on both sides while the clumpify runs (QA 4, SWIFT 3). The leaf exits 125 inside the grace,
    /// its record reads cancelled and no process is left. The folder is a bundle that held no record, so the leaf
    /// writes its own `cancelled` one there, and the original stays as it was. Side C and side C' are cancelled at the
    /// same point.
    func testACancelEndsCancelledOnBothSides() async throws {
        let sides: [RouteParitySide] = [.c, .cPrime]
        let toolRoots = try Dictionary(uniqueKeysWithValues: sides.map { side -> (RouteParitySide, URL) in
            let root = scratch.appendingPathComponent("cancel-tools/\(side.folderName)/conda", isDirectory: true)
            return (side, try installStandInClumpify(Self.sleepingClumpify(pidFile: Self.pidFile(of: side, in: scratch)), at: root))
        })
        let harness = RouteParityHarness(
            cliBinary: cliBinary, kind: .bundle, replayTimeout: .seconds(60),
            environment: { root in
                let side = RouteParitySide.allCases.first { $0.folderName == root.lastPathComponent } ?? .c
                return Self.standInEnvironment(condaRoot: toolRoots[side]?.path ?? "")
            }
        )
        let scratch = self.scratch!
        let cancel = RouteParityCancel(
            when: { root in
                let side = RouteParitySide.allCases.first { $0.folderName == root.lastPathComponent } ?? .c
                return FileManager.default.fileExists(atPath: Self.pidFile(of: side, in: scratch).path)
            },
            record: { root in try ProvenanceEnvelopeReader.load(fromSidecar: Self.bundleRecord(in: root))?.status.rawValue }
        )

        // Root C holds the fixture and root C' starts as a copy of it, as the harness sets up a case.
        let caseRoot = scratch.appendingPathComponent("cancel", isDirectory: true)
        let rootC = RouteParityHarness.root(of: .c, in: caseRoot)
        let rootCPrime = RouteParityHarness.root(of: .cPrime, in: caseRoot)
        try FileManager.default.createDirectory(at: rootC, withIntermediateDirectories: true)
        try Self.writeBundleFixture(rootC)
        try FileManager.default.copyItem(at: rootC, to: rootCPrime)

        let arguments = try FASTQIngestionService.inPlaceIngestionCLIArguments(url: Self.bundleInput(in: rootC))
        let ran = await RouteParityHarness.runCLI(
            cliBinary, arguments: arguments, timeout: .seconds(60),
            environment: harness.environment(rootC), cancelWhen: { cancel.isReached(rootC) }
        )
        let runC = RouteParitySideRun(
            side: .c, root: rootC,
            outcome: RouteParitySideOutcome(
                end: ran.end, detail: ran.detail,
                recordedCommand: OperationCenter.buildCLICommand(subcommand: "", args: arguments), cancel: ran.cancel
            )
        )
        let runCPrime = await harness.replay(of: runC, in: rootCPrime, cancel: cancel)

        for run in [runC, runCPrime] {
            XCTAssertEqual(run.outcome.end, .cancelled, "side \(run.side): \(run.outcome.detail)")
            XCTAssertEqual(
                try String(contentsOf: Self.bundleInput(in: run.root), encoding: .utf8), Self.reads.joined(),
                "side \(run.side) leaves the original as it was"
            )
            await RouteParityHarness.assertCancelled(run, cancel)
        }
        let found = try harness.differences(runC, runCPrime)
        RouteParityHarness.assertNoFailures(found.map { "\($0.id): \($0.detail)" }, in: "cancel, C against C'")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: systemTemp.path), [],
            "a cancelled ingest leaves no staging folder"
        )
    }

    // MARK: - A failed clumpify (review A47 fix 6 (c), QC-2, UX 1)

    /// The stand-in clumpify answers the version probe and otherwise exits 1 with one line on standard error. Both
    /// sides end failed with the original as it was, and no output, sidecar, record or staging folder stays beside it
    /// or in the system temp folder. C against C' declares nothing, so the whole tree of each side is the original
    /// alone.
    func testAFailedClumpifyFailsOnBothSidesAndKeepsTheOriginal() async throws {
        let condaRoot = try installStandInClumpify(Self.failingClumpify, at: scratch.appendingPathComponent("tools/conda"))
        let environment = Self.standInEnvironment(condaRoot: condaRoot.path)
        await useEnvironment(environment)
        let harness = RouteParityHarness(
            cliBinary: cliBinary, kind: .bundle, replayTimeout: .seconds(120), environment: { _ in environment }
        )
        let runs = try await ReadsRouteParity.runCAndCPrime(
            harness,
            in: scratch.appendingPathComponent("failure", isDirectory: true),
            fixture: Self.writeFixture,
            sideC: { root in
                let input = Self.input(in: root)
                let runner = CLIReadsRunner(cliURLOverride: self.cliBinary)
                let (_, item) = try await ReadsRouteParity.record(title: Self.title) {
                    FASTQIngestionService.startInPlaceIngestionThroughCLI(url: input, routeContext: nil, runner: runner)
                }
                return ReadsRouteParity.outcome(of: item, recordsCommand: true)
            }
        )

        let found = try harness.differences(runs.c, runs.cPrime)
        RouteParityHarness.assertNoFailures(found.map { "\($0.id): \($0.detail)" }, in: "failure, C against C'")
        for run in [runs.c, runs.cPrime] {
            XCTAssertEqual(run.outcome.end, .failed, "side \(run.side): \(run.outcome.detail)")
            XCTAssertEqual(
                try Data(contentsOf: Self.input(in: run.root)), Data(Self.reads.joined().utf8),
                "side \(run.side) leaves the original byte for byte as it was"
            )
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(atPath: Self.input(in: run.root).deletingLastPathComponent().path),
                ["SRR9_1.fastq"],
                "side \(run.side) leaves no output, sidecar, record or staging folder beside the input"
            )
        }
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: systemTemp.path), [],
            "a failed ingest leaves no staging folder in the system temp folder"
        )
        XCTAssertTrue(runs.c.outcome.detail.contains("simulated failure"), "the tool's line reaches the row: \(runs.c.outcome.detail)")
    }

    // MARK: - The records, verified (review A47 fix 6 (b), ARCH 3, B-5)

    /// Where an ingest runs. The first is a loose file in a project folder, the second a bundle whose import
    /// record is signed, and the third the same bundle when the ingest runs with no key to sign with.
    private enum VerifyShape: String, CaseIterable {
        case projectFolder
        case bundleWithSignedImportRecord
        case bundleWithSignedImportRecordAndNoKeyForTheRun

        var folderName: String { self == .projectFolder ? "project" : "Sample.lungfishfastq" }
        /// Whether a signing key is set while the ingest runs.
        var runSigns: Bool { self != .bundleWithSignedImportRecordAndNoKeyForTheRun }

        func original(in root: URL) -> URL {
            root.appendingPathComponent(folderName, isDirectory: true).appendingPathComponent("SRR9_1.fastq")
        }

        func fixture(_ root: URL) throws {
            if self == .projectFolder {
                try FastqIngestRouteParityReplayTests.writeFixture(root)
            } else {
                try FastqIngestRouteParityReplayTests.writeBundleWithSignedImportRecord(root)
            }
        }
    }

    /// B-5 with a throwaway signing key in the environment, as `AlignmentWorkflowCLIGUIParityReplayTests` does it.
    /// Sides C and C' run for a project folder and for a bundle that holds a signed import record. Each root gets
    /// its own fixture, so the import record names that root's files. On each side every record the run wrote is
    /// signed and passes `provenance verify`, each output a record names exists with the digest it states, and the
    /// removed original is an input of the root record with its digest and an output of none. The last shape runs
    /// with no key and shows that a merged root record keeps no stale signature, since the writer removes the
    /// signature and key files of the record it replaces.
    func testEachCLISidesRecordsPassProvenanceVerify() async throws {
        let condaRoot = try installStandInClumpify(Self.copyingClumpify, at: scratch.appendingPathComponent("tools/conda"))
        let environment = Self.standInEnvironment(condaRoot: condaRoot.path)
        await useEnvironment(environment)
        let harness = RouteParityHarness(
            cliBinary: cliBinary, kind: .bundle, replayTimeout: .seconds(120), environment: { _ in environment }
        )
        let keyName = ProvenanceSigningConfiguration.signingKeyEnvironmentKey
        let keyFileName = ProvenanceSigningConfiguration.signingKeyFileEnvironmentKey
        for shape in VerifyShape.allCases {
            let keyed = ProcessEnvironmentOverride(set: [keyName: "fx47-throwaway-signing-key"], unset: [keyFileName])
            defer { keyed.restore() }
            let caseRoot = scratch.appendingPathComponent("verify-\(shape.rawValue)", isDirectory: true)
            try? FileManager.default.removeItem(at: caseRoot)
            let roots = [RouteParitySide.c, .cPrime].map { RouteParityHarness.root(of: $0, in: caseRoot) }
            for root in roots {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try shape.fixture(root)
            }
            let input = shape.original(in: roots[0])
            let originalDigest = try XCTUnwrap(ProvenanceRecorder.sha256(of: input))
            let held = roots.map { Self.digests(under: $0) }
            let unkeyed = shape.runSigns ? nil : ProcessEnvironmentOverride(set: [:], unset: [keyName, keyFileName])
            defer { unkeyed?.restore() }

            let runner = CLIReadsRunner(cliURLOverride: cliBinary)
            let (_, item) = try await ReadsRouteParity.record(title: Self.title) {
                FASTQIngestionService.startInPlaceIngestionThroughCLI(url: input, routeContext: nil, runner: runner)
            }
            let runC = RouteParitySideRun(
                side: .c, root: roots[0], outcome: ReadsRouteParity.outcome(of: item, recordsCommand: true)
            )
            let runCPrime = await harness.replay(of: runC, in: roots[1])
            for (run, before) in zip([runC, runCPrime], held) {
                await assertRecordsVerify(of: run, shape: shape, before: before, originalDigest: originalDigest)
            }
        }
    }

    private func assertRecordsVerify(
        of run: RouteParitySideRun, shape: VerifyShape, before: [String: String], originalDigest: String
    ) async {
        let label = "\(shape.rawValue) side \(run.side)"
        XCTAssertEqual(run.outcome.end, .completed, "\(label): \(run.outcome.detail)")
        let original = shape.original(in: run.root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path), "\(label): the original is removed")

        let records = Self.newRecords(under: run.root, before: before)
        XCTAssertGreaterThanOrEqual(records.count, 2, "\(label) wrote the folder's record and the output's: \(records.map(\.lastPathComponent))")
        for record in records {
            guard let envelope = try? ProvenanceEnvelopeReader.load(fromSidecar: record) else {
                XCTFail("\(label): \(record.lastPathComponent) does not read")
                continue
            }
            // Each output a record names exists with the digest it states.
            let outputs = [envelope.output].compactMap { $0 } + envelope.outputs
            XCTAssertFalse(outputs.isEmpty, "\(label): \(record.lastPathComponent) names no output")
            for output in outputs {
                let url = URL(fileURLWithPath: output.path)
                XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "\(label): \(record.lastPathComponent) names \(output.path), which is gone")
                XCTAssertNotNil(output.checksumSHA256, "\(label): \(output.path) has no digest")
                XCTAssertEqual(ProvenanceRecorder.sha256(of: url), output.checksumSHA256, "\(label): \(output.path)")
            }
            let signature = ProvenanceSigningConfiguration.signatureURL(for: record)
            if shape.runSigns {
                XCTAssertTrue(FileManager.default.fileExists(atPath: signature.path), "\(label): \(record.lastPathComponent) is unsigned, though a key is set")
                let verify = await RouteParityHarness.runCLI(
                    cliBinary, arguments: ["provenance", "verify", record.path], timeout: .seconds(60)
                )
                XCTAssertEqual(verify.status, 0, "\(label): \(record.lastPathComponent): \(verify.detail)")
                XCTAssertTrue(verify.stdout.contains("Signature valid"), "\(label): \(record.lastPathComponent): \(verify.stdout)")
            } else {
                XCTAssertFalse(
                    FileManager.default.fileExists(atPath: signature.path),
                    "\(label): \(record.lastPathComponent) keeps a signature file the run did not write"
                )
            }
        }

        // The folder's record: the removed original is an input with its digest and no output.
        let rootRecord = original.deletingLastPathComponent().appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        guard let root = try? ProvenanceEnvelopeReader.load(fromSidecar: rootRecord) else {
            return XCTFail("\(label): the folder's record does not read")
        }
        XCTAssertEqual(
            root.files.first { $0.role == .input && $0.path == original.path }?.checksumSHA256, originalDigest,
            "\(label): the original is an input with its digest"
        )
        let everyOutput = [root.output].compactMap { $0 } + root.outputs
            + root.files.filter { $0.role == .output } + root.steps.flatMap(\.outputs)
        XCTAssertFalse(everyOutput.contains { $0.path == original.path }, "\(label): the removed original is named as an output")
        XCTAssertTrue(root.outputs.contains { $0.path.hasSuffix("/SRR9.fastq.gz") }, "\(label): \(root.outputs.map(\.path))")
    }

    /// The SHA-256 of every file under `root` by its relative name.
    private static func digests(under root: URL) -> [String: String] {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return [:]
        }
        var result: [String: String] = [:]
        while let url = walker.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let relative = String(url.resolvingSymlinksInPath().standardizedFileURL.path.dropFirst(base.count + 1))
            result[relative] = ProvenanceRecorder.sha256(of: url)
        }
        return result
    }

    /// Every record under `root` that the run wrote or rewrote. A fixture record left as it was is not one.
    private static func newRecords(under root: URL, before: [String: String]) -> [URL] {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        return digests(under: root).compactMap { relative, digest -> URL? in
            guard relative.hasSuffix(".lungfish-provenance.json"), before[relative] != digest else { return nil }
            return URL(fileURLWithPath: base).appendingPathComponent(relative)
        }
        .sorted { $0.path < $1.path }
    }
}

// MARK: - The fixture, the sides and the stand-ins

extension FastqIngestRouteParityReplayTests {
    nonisolated static let title = "FASTQ Ingestion: SRR9"

    /// The heap every side is pinned to. The live policy never gives an ingest this value, since its floor is 4 GB,
    /// so a side that ignored the pin shows in its record.
    nonisolated static let pinnedHeapGB = 3

    /// The hidden variable `ManagedJavaHeapPolicy` reads in a debug build. The name is written out here so that a
    /// rename of the seam shows in this class (review A47 landing 22 item 5, FX47 (i)).
    nonisolated static let pinnedHeapVariable = "LUNGFISH_MANAGED_JAVA_HEAP_PIN_GB"

    /// What every side gets: the stand-in conda root, no shared package cache, and the pinned heap. Without the pin
    /// each side sizes its heap from the host's live free memory, and two runs seconds apart can differ by a whole
    /// gigabyte in the `-Xmx` their records name.
    nonisolated static func standInEnvironment(condaRoot: String) -> [String: String] {
        [
            "LUNGFISH_CONDA_ROOT": condaRoot,
            "LUNGFISH_CONDA_SHARED_PKGS": "0",
            pinnedHeapVariable: String(pinnedHeapGB),
        ]
    }

    /// Four single-end reads, none a duplicate.
    nonisolated static let reads = [
        "@SRR9.1 a/1\nACGTACGTACGTAAAC\n+\nIIIIIIIIIIIIIIII\n",
        "@SRR9.2 b/1\nTTGGCCAATTGGCCAA\n+\nIIIIIIIIIIIIIIII\n",
        "@SRR9.3 c/1\nGGGGCCCCAAAATTTT\n+\nIIIIIIIIIIIIIIII\n",
        "@SRR9.4 d/1\nCATGCATGCATGCATG\n+\nIIIIIIIIIIIIIIII\n",
    ]

    /// A project folder holding the file that was copied in.
    nonisolated static func writeFixture(_ root: URL) throws {
        let folder = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try reads.joined().write(to: folder.appendingPathComponent("SRR9_1.fastq"), atomically: true, encoding: .utf8)
    }

    /// A bundle that holds the file and no record.
    nonisolated static func writeBundleFixture(_ root: URL) throws {
        let folder = root.appendingPathComponent("Sample.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try reads.joined().write(to: folder.appendingPathComponent("SRR9_1.fastq"), atomically: true, encoding: .utf8)
    }

    /// A bundle that holds the file and the signed import record it came with, built as the app's copy
    /// into a project builds one (`FASTQIngestionProvenanceTests`). A key must be set to sign the record.
    nonisolated static func writeBundleWithSignedImportRecord(_ root: URL) throws {
        let folder = root.appendingPathComponent("Sample.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let imported = folder.appendingPathComponent("SRR9_1.fastq")
        try reads.joined().write(to: imported, atomically: true, encoding: .utf8)
        let download = root.appendingPathComponent("cli-download.fastq")
        try reads.joined().write(to: download, atomically: true, encoding: .utf8)
        let argv = ["lungfish-cli", "fetch", "ncbi", "SRR9", "--output", download.path]
        let envelope = try ProvenanceRunBuilder(
            workflowName: "CLI FASTQ Download", workflowVersion: "2026.05", toolName: "lungfish-cli", toolVersion: "2026.05"
        )
        .argv(argv)
        .output(download, format: .fastq, role: .output)
        .step(
            ProvenanceStep(
                toolName: "lungfish-cli", toolVersion: "2026.05", argv: argv,
                outputs: [try ProvenanceFileDescriptor.file(url: download, format: .fastq, role: .output)],
                exitStatus: 0, wallTimeSeconds: 1
            )
        )
        .runtime(ProvenanceRuntimeIdentity.fixture())
        .complete(exitStatus: 0, startedAt: Date(timeIntervalSince1970: 10), endedAt: Date(timeIntervalSince1970: 11))
        try ProvenanceWriter(signingProvider: nil).write(envelope, toSidecar: ProvenanceRecorder.fileSidecarURL(for: download))
        try GUIImportedProvenanceRehydrator.rehydrateImportedCopy(from: download, to: imported)
        // The copy writes its record unsigned. A command that ran with a key signs the record it writes, so
        // the bundle's record is written again through the default signer.
        let rootRecord = folder.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let written = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: rootRecord))
        try ProvenanceWriter().write(written, toSidecar: rootRecord)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: ProvenanceSigningConfiguration.signatureURL(for: rootRecord).path),
            "the bundle's import record is signed before the ingest runs"
        )
    }

    nonisolated static func input(in root: URL) -> URL {
        root.appendingPathComponent("project/SRR9_1.fastq")
    }

    /// `deriveBaseName` drops the `_1`, so the output carries another name.
    nonisolated static func output(in root: URL) -> URL {
        root.appendingPathComponent("project/SRR9.fastq.gz")
    }

    nonisolated static func record(in root: URL) -> URL {
        root.appendingPathComponent("project/\(ProvenanceRecorder.provenanceFilename)")
    }

    nonisolated static func bundleInput(in root: URL) -> URL {
        root.appendingPathComponent("Sample.lungfishfastq/SRR9_1.fastq")
    }

    nonisolated static func bundleRecord(in root: URL) -> URL {
        root.appendingPathComponent("Sample.lungfishfastq/\(ProvenanceRecorder.provenanceFilename)")
    }

    /// Where the sleeping clumpify of `side` writes its process ID, outside the side roots.
    nonisolated static func pidFile(of side: RouteParitySide, in scratch: URL) -> URL {
        scratch.appendingPathComponent("pids/\(side.folderName).pid")
    }

    /// Sets `environment` for this process until tearDown, for the child of side C, and clears the tool paths the
    /// shared runner remembers.
    private func useEnvironment(_ environment: [String: String]) async {
        for (key, value) in environment {
            if savedEnvironment[key] == nil { savedEnvironment[key] = .some(ProcessInfo.processInfo.environment[key]) }
            setenv(key, value, 1)
        }
        await NativeToolRunner.shared.clearCache()
    }

    /// A conda root of the test's own with `script` as the managed clumpify.
    private func installStandInClumpify(_ script: String, at condaRoot: URL) throws -> URL {
        try ReadsRouteParity.write(script, executableAt: condaRoot.appendingPathComponent("envs/bbtools/bin/clumpify.sh"))
        return condaRoot
    }

    /// Answers a version probe, and otherwise copies the reads of `in=` through gzip to `out=`, without
    /// a name or a time, so the output is the same on every side.
    nonisolated static let copyingClumpify = """
        #!/bin/sh
        in=""
        out=""
        for argument in "$@"; do
          case "$argument" in
            in=*) in="${argument#in=}" ;;
            out=*) out="${argument#out=}" ;;
          esac
        done
        if [ -z "$in" ] || [ -z "$out" ]; then echo "BBMap version 39.00"; exit 0; fi
        gzip -n -c < "$in" > "$out"
        """

    /// Answers a version probe, and otherwise writes one line to standard error and exits 1.
    nonisolated static let failingClumpify = """
        #!/bin/sh
        in=""
        out=""
        for argument in "$@"; do
          case "$argument" in
            in=*) in="${argument#in=}" ;;
            out=*) out="${argument#out=}" ;;
          esac
        done
        if [ -z "$in" ] || [ -z "$out" ]; then echo "BBMap version 39.00"; exit 0; fi
        echo "clumpify: simulated failure" >&2
        exit 1
        """

    /// Records its process ID, writes half an output where `out=` says, and waits.
    nonisolated static func sleepingClumpify(pidFile: URL) -> String {
        """
        #!/bin/sh
        mkdir -p '\(pidFile.deletingLastPathComponent().path)'
        echo $$ > '\(pidFile.path)'
        for argument in "$@"; do
          case "$argument" in
            out=*) printf 'half' > "${argument#out=}" ;;
          esac
        done
        exec /bin/sleep 300
        """
    }
}
