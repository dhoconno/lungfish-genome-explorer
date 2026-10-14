// FastqIngestRouteParityReplayTests.swift - The in-place FASTQ ingestion routes, on a stand-in clumpify
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A47 M3 (panel G1, C4 and C13, ARCH 2 and 3, BIO 1 and 4, UX 1 and 3, QA 1, 4 and
// 5, and the ruling on M3 section 3). Copying a FASTQ file into a project ingests it in place. The
// parity case runs one ingestion on the three sides of RouteParityHarness.
//
// - Side A, the in-process route the app ran until this lane (`startInPlaceIngestionInProcess`).
// - Side C, the CLI route, `startInPlaceIngestionThroughCLI` on the built `lungfish-cli`.
// - Side C', the command side C's row recorded, rebased and run by the built CLI.
//
// A against C declares the record (item d, `<ANY>`, closed by the 2.11 E14 deletion) and nothing
// else, and C against C' declares nothing. The class also holds C's record to every fact A's record
// names, each side's row to side A's words (C's words less the five steps the leaf adds equal A's,
// and A's come in order within C's), and the cancel on every side. The differences that need no
// declaration are the ruling's items (a) to (c): the order of the record and the removal, a clumping
// that resolves to none, and a sidecar that fails to write. They are fixed on the leaf and shown
// there (`FastqIngestLeafDurabilityTests`), and the final trees do not differ.
//
// Declared in words, not in the tree. C's bar is the pipeline's fraction times 0.9, with the digest,
// sidecar, record and removal steps filling the rest, so it only rises and A's bar is not compared.
// C's row shows five words A's does not: "Recording the digest of the original file...", "Moving the
// output into place...", "Writing the metadata sidecar...", "Writing the record..." and "Removing
// the original file...".
//
// A stand-in clumpify answers every side (G2). It copies the reads through gzip. Side A reads its
// conda root from LUNGFISH_CONDA_ROOT, which the test sets for its run, and sides C and C' get it
// through the app's subprocess environment and the harness. The real clumpify stays in
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

    enum Case: String, Sendable {
        case copiedIn
        case cancel
    }

    override func setUp() async throws {
        try await super.setUp()
        scratch = try TestTempDirectory.make(prefix: "fastq-ingest-parity")
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        cliBinary = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH, so sides C and C' cannot run"
        )
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
        TestTempDirectory.cleanup(scratch)
        try await super.tearDown()
    }

    // MARK: - A against C, C against C'

    func testTheIngestionRoutesAgreeAndTheRecordedCommandReproducesTheCLIRoute() async throws {
        let condaRoot = try installStandInClumpify(Self.copyingClumpify, at: scratch.appendingPathComponent("tools/conda"))
        let environment = ["LUNGFISH_CONDA_ROOT": condaRoot.path, "LUNGFISH_CONDA_SHARED_PKGS": "0"]
        await useEnvironment(environment)
        let harness = RouteParityHarness(
            cliBinary: cliBinary, kind: .bundle, replayTimeout: .seconds(120), environment: { _ in environment }
        )
        var rows: [RouteParitySide: MappingRouteRow] = [:]
        let runs = try await harness.run(
            in: scratch.appendingPathComponent("parity", isDirectory: true),
            fixture: Self.writeFixture,
            sideA: { root in
                let input = Self.input(in: root)
                let (row, item) = try await ReadsRouteParity.record(title: Self.title) {
                    FASTQIngestionService.startInPlaceIngestionInProcess(url: input, routeContext: nil)
                }
                rows[.a] = ReadsRouteParity.rooted(row, root)
                return ReadsRouteParity.outcome(of: item)
            },
            sideC: { root in
                let input = Self.input(in: root)
                let runner = CLIReadsRunner(cliURLOverride: self.cliBinary)
                let (row, item) = try await ReadsRouteParity.record(title: Self.title) {
                    FASTQIngestionService.startInPlaceIngestionThroughCLI(url: input, routeContext: nil, runner: runner)
                }
                rows[.c] = ReadsRouteParity.rooted(row, root)
                return ReadsRouteParity.outcome(of: item, recordsCommand: true)
            }
        )

        XCTAssertEqual(runs.all.map(\.outcome.end), [.completed, .completed, .completed], runs.all.map(\.outcome.detail).joined(separator: "\n"))

        // BIO's item (d). A's record is the app's own and shares no structure with the leaf's, so
        // the tree comparison reports the whole file, which no entry may declare. The facts A's
        // record names are held to C's record first, then A's record files leave A's tree, and the
        // difference is declared in BIO's D1 form, as "only in C".
        try assertCKeepsEveryFactAKeeps(runs)
        try removeProvenanceFiles(in: runs.a.root)
        for run in runs.all { try maskIngestionDate(in: run.root) }
        let result = try harness.evaluate(Case.copiedIn, declared: Self.declared, runs: runs)
        RouteParityHarness.assertNoFailures(result.failures, in: "\(Case.copiedIn)")

        // The final trees hold the same reads: the original is gone, and the gzip file and its sidecar stand.
        for side in [runs.a, runs.c, runs.cPrime] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: Self.input(in: side.root).path), "side \(side.side) removed the original")
            XCTAssertTrue(FileManager.default.fileExists(atPath: Self.output(in: side.root).path), "side \(side.side) published the output")
            XCTAssertNotNil(FASTQMetadataStore.load(for: Self.output(in: side.root))?.ingestion, "side \(side.side) wrote the sidecar")
        }

        // UX 1 and 3. C's words, less the five steps the leaf adds, are A's, and A's come in order
        // within C's. Both rows end the same way, and C's bar only rises.
        let rowA = try XCTUnwrap(rows[.a])
        let rowC = try XCTUnwrap(rows[.c])
        XCTAssertEqual(rowC.shown.filter { !Self.newStepWords.contains($0) }, rowA.shown, "C's words less the five new steps are A's")
        XCTAssertEqual(rowC.end, rowA.end, "both rows end with the same words")
        XCTAssertEqual(rowC.bar, rowC.bar.sorted(), "the CLI route's bar only rises")
        XCTAssertTrue(rowC.shown.contains("Waiting for available import slot\u{2026}"), "the slot wait is shown as before")

        // The row records the command the leaf ran (CLI-EQUIVALENCE, provenance names the command).
        let command = try XCTUnwrap(runs.c.outcome.recordedCommand)
        let argv = try RecordedCLICommand.arguments(of: command)
        XCTAssertTrue(argv.starts(with: ["fastq", "ingest", Self.input(in: runs.c.root).path]), "\(argv)")
        XCTAssertEqual(runs.cPrime.replayedArguments.count, 1, "C' replays the one command")
    }

    // MARK: - The facts of A's record (ruling section 3, item d)

    /// The sidecar names the second each run finished (`ingestion.ingestionDate`), a wall-clock value
    /// that the contract's masks leave as written, so two runs a second apart would differ. The test
    /// sets it to one value on every side and compares the rest of the sidecar as it is.
    private func maskIngestionDate(in root: URL) throws {
        let sidecar = FASTQMetadataStore.metadataURL(for: Self.output(in: root))
        let text = try String(contentsOf: sidecar, encoding: .utf8)
        let masked = text.replacingOccurrences(
            of: #""ingestionDate"\s*:\s*"[^"]*""#, with: #""ingestionDate" : "1970-01-01T00:00:00Z""#, options: .regularExpression
        )
        XCTAssertNotEqual(masked, text, "the sidecar of \(root.lastPathComponent) holds an ingestion date")
        try masked.write(to: sidecar, atomically: true, encoding: .utf8)
    }

    /// Removes every record file under `root`: the root record and the sidecar of each output.
    private func removeProvenanceFiles(in root: URL) throws {
        for name in try FileManager.default.subpathsOfDirectory(atPath: root.path)
        where name.hasSuffix(ProvenanceRecorder.provenanceFilename) {
            try FileManager.default.removeItem(atPath: root.appendingPathComponent(name).path)
        }
    }

    /// Every fact A's record keeps is in C's, though C's record has other steps and names. Both live
    /// in the folder's root record, where the sidecar and the output are named, the clumpify step
    /// stands, the original is an input, and the options the run chose are the same.
    private func assertCKeepsEveryFactAKeeps(_ runs: RouteParityRuns) throws {
        let a = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: Self.record(in: runs.a.root)), "side A's record")
        let c = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: Self.record(in: runs.c.root)), "side C's record")
        let toolsC = Set(c.steps.map(\.toolName))
        for tool in a.steps.map(\.toolName) where tool != "lungfish-app" {
            XCTAssertTrue(toolsC.contains(tool), "C's record keeps the \(tool) step, it holds \(toolsC)")
        }
        let output = Self.output(in: runs.c.root)
        let sidecar = FASTQMetadataStore.metadataURL(for: output)
        XCTAssertTrue(c.outputs.contains { $0.path == output.path }, "the output is named")
        XCTAssertTrue(c.steps.flatMap(\.outputs).contains { $0.path == sidecar.path }, "the sidecar is named, where A's write-metadata step named it")
        let original = Self.input(in: runs.c.root)
        let digest = c.files.first { $0.role == .input && $0.path == original.path }?.checksumSHA256
        XCTAssertNotNil(digest, "the original is an input with its digest")
        let explicitA = a.options.explicit
        let explicitC = c.options.explicit
        XCTAssertEqual(explicitC["deleteOriginals"], explicitA["deleteOriginals"])
        XCTAssertEqual(explicitC["threads"], explicitA["threads"])
        XCTAssertEqual(explicitC["skipClumpify"], explicitA["skipClumpify"])
        XCTAssertEqual(explicitC["binning"], explicitA["qualityBinning"])
        XCTAssertEqual(explicitC["outputPairingMode"], explicitA["outputPairingMode"])
        XCTAssertEqual(explicitC["wasClumpified"], explicitA["wasClumpified"])
    }

    // MARK: - Cancel

    /// The window's Cancel on every side while the clumpify runs (QA 4, SWIFT 3). The leaf exits
    /// 125 inside the grace, its record reads cancelled and no process is left. The folder is a
    /// bundle that held no record, so the leaf writes its own `cancelled` one there, and the
    /// in-process route wrote nothing and left the original, which is the difference declared.
    func testACancelEndsCancelledOnEverySideAndOnlyCWritesARecord() async throws {
        let toolRoots = try Dictionary(uniqueKeysWithValues: RouteParitySide.allCases.map { side -> (RouteParitySide, URL) in
            let root = scratch.appendingPathComponent("cancel-tools/\(side.folderName)/conda", isDirectory: true)
            return (side, try installStandInClumpify(Self.sleepingClumpify(pidFile: Self.pidFile(of: side, in: scratch)), at: root))
        })
        let harness = RouteParityHarness(
            cliBinary: cliBinary, kind: .bundle, replayTimeout: .seconds(60),
            environment: { root in
                let side = RouteParitySide.allCases.first { $0.folderName == root.lastPathComponent } ?? .c
                return ["LUNGFISH_CONDA_ROOT": toolRoots[side]?.path ?? "", "LUNGFISH_CONDA_SHARED_PKGS": "0"]
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
        let cli = cliBinary!
        let result = try await harness.assertParity(
            Case.cancel, declared: Self.declaredCancel, in: scratch.appendingPathComponent("cancel", isDirectory: true),
            cancel: cancel,
            fixture: Self.writeBundleFixture,
            sideA: { root in
                await self.useEnvironment(["LUNGFISH_CONDA_ROOT": toolRoots[.a]?.path ?? "", "LUNGFISH_CONDA_SHARED_PKGS": "0"])
                let input = Self.bundleInput(in: root)
                let pid = Self.pidFile(of: .a, in: scratch)
                let (_, item) = try await ReadsRouteParity.record(title: Self.title) {
                    FASTQIngestionService.startInPlaceIngestionInProcess(url: input, routeContext: nil)
                    Task { @MainActor in
                        _ = await waitUntil(timeout: .seconds(30)) { FileManager.default.fileExists(atPath: pid.path) }
                        if let id = OperationCenter.shared.items.first(where: { $0.title == Self.title && $0.state.isActive })?.id {
                            OperationCenter.shared.cancel(id: id)
                        }
                    }
                }
                return ReadsRouteParity.outcome(of: item)
            },
            sideC: { root in
                let arguments = try FASTQIngestionService.inPlaceIngestionCLIArguments(url: Self.bundleInput(in: root))
                let run = await RouteParityHarness.runCLI(
                    cli, arguments: arguments, timeout: .seconds(60),
                    environment: harness.environment(root), cancelWhen: { cancel.isReached(root) }
                )
                return RouteParitySideOutcome(
                    end: run.end, detail: run.detail,
                    recordedCommand: OperationCenter.buildCLICommand(subcommand: "", args: arguments), cancel: run.cancel
                )
            }
        )
        for run in result.runs.all {
            XCTAssertEqual(run.outcome.end, .cancelled, "side \(run.side): \(run.outcome.detail)")
            XCTAssertEqual(
                try String(contentsOf: Self.bundleInput(in: run.root), encoding: .utf8), Self.reads.joined(),
                "side \(run.side) leaves the original as it was"
            )
        }
    }
}

// MARK: - Declared differences

extension FastqIngestRouteParityReplayTests {
    /// The five steps the leaf adds to the row (ruling section 3, item e).
    static let newStepWords: Set<String> = [
        "Recording the digest of the original file...",
        "Moving the output into place...",
        "Writing the metadata sidecar...",
        "Writing the record...",
        "Removing the original file...",
    ]

    /// BIO's item (d). Side C writes the record the leaf writes, in the form of every `fastq` leaf
    /// (`lungfish fastq ingest`, the original with its digest, the sidecar as an output, and a
    /// sidecar record beside the output). Side A wrote the record of the app ("FASTQ Ingestion" and a
    /// `lungfish-app` step). The 2.11 E14 deletion retires the in-process route.
    static let declared: [RouteParityDeclaredDifference<Case>] = [
        RouteParityDeclaredDifference(
            [.copiedIn: 2], "only in C: <ANY>lungfish-provenance.json",
            reason: "C writes the leaf's record, which names the original with its digest, and A wrote the app's record, "
                + "held to C's facts in the test",
            closedBy: "2.11, E14 deletion"
        ),
    ]

    /// BIO's D1 form. The in-process route writes nothing when it is cancelled.
    static let declaredCancel: [RouteParityDeclaredDifference<Case>] = [
        RouteParityDeclaredDifference(
            [.cancel: 1], "only in A: Sample.lungfishfastq/SRR9.fastq.gz",
            reason: "A leaves the half-written output of the cancelled tool in the folder, C builds in a hidden folder and removes it",
            closedBy: "2.11, E14 deletion"
        ),
        RouteParityDeclaredDifference(
            [.cancel: 2], "only in C: <ANY>lungfish-provenance.json",
            reason: "C writes the cancelled record, A never wrote one",
            closedBy: "2.11, E14 deletion"
        ),
    ]
}

// MARK: - The fixture, the sides and the stand-ins

extension FastqIngestRouteParityReplayTests {
    nonisolated static let title = "FASTQ Ingestion: SRR9"

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

    /// Sets `environment` for this process until tearDown, for side A, and clears the tool paths the
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
