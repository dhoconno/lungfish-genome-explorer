// FASTQDialogDemultiplexStagedInputTests.swift - Demultiplex Barcodes of a derived bundle keeps the picked bundle as its source
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// DEMUX-STAGED-INPUT (Phase 4 close, S2 by BIO). The dialog used to stage a derived bundle (a subsample, a trim, any
// virtual derivative) as `materialized-inputs-<UUID>/materialized-<UUID>.fastq.gz` for `lungfish-cli fastq
// demultiplex`, so the run's record named a copy the run deleted, no barcode bundle linked back to the bundle the
// person picked, and the Operations row kept `-o '<derived>'`. The dialog now hands the CLI the picked bundle.
//
// The input is DEMUX-PROBE's smallest failing input (`Tests/Fixtures/demux-staged-input`), 322 interleaved pairs of
// 100 bp reads with an Illumina index in the read names, in a "Subsample by Count" derived bundle. The counts are
// the ones BIO counted from the truth table with the packaged build: D701 240, D702 204, D703 120, D704 60 and
// unassigned 20, every pair whole (SCR/rulings/DEMUX-PROBE.md, Part 2).
//
// DEMUX-FIX (SF-3) runs the same dialog on the raw one-file import the subsample is made from. A raw import is not a
// derived root (`FastqCommand.swift` sets `rootBundleURL` only from a derived source, backlog row B1), so its barcode
// bundles are physical and carry no `derived.manifest.json`. That run asserts no manifest, so row B1 can change it.

import ArgumentParser
import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
@testable import LungfishOperations
import LungfishTestSupport
import LungfishWorkflow

@MainActor
final class FASTQDialogDemultiplexStagedInputTests: XCTestCase {
    private static let expectedReads: [String: Int] = ["D701": 240, "D702": 204, "D703": 120, "D704": 60]
    private static let expectedUnassigned = 20
    private static let totalReads = 644
    private static let derivedName = "P4PE_S1_L001-subsampleCount"

    private struct Project {
        let scratch: URL
        let project: URL
        /// The raw import, one interleaved file, which a person can also pick.
        let raw: URL
        /// The bundle the person picks, a Subsample by Count of the imported interleaved pairs.
        let picked: URL
    }

    private static var fixtureReads: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/demux-staged-input/P4PE_S1_L001.fastq.gz")
    }

    /// A project with the import (one interleaved file) and its Subsample by Count at 1,000 reads, more than the
    /// 644 reads present, so no read drops. The app stores that result as a derived bundle that holds its reads as a file.
    private func makeProject() throws -> Project {
        // The physical path (/private/var, not /var), which the resolvers and the CLI use.
        let made = try TestTempDirectory.make(prefix: "fastq-demux-staged-input")
        let physical = try XCTUnwrap(realpath(made.path, nil))
        defer { free(physical) }
        let scratch = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
        addTeardownBlock { TestTempDirectory.cleanup(scratch) }
        let project = scratch.appendingPathComponent("Project.lungfish", isDirectory: true)
        let fileManager = FileManager.default

        let source = project.appendingPathComponent("Imports/P4PE_S1_L001.lungfishfastq", isDirectory: true)
        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
        let sourceFASTQ = source.appendingPathComponent("P4PE_S1_L001.fastq.gz")
        try fileManager.copyItem(at: Self.fixtureReads, to: sourceFASTQ)
        FASTQMetadataStore.save(
            PersistedFASTQMetadata(ingestion: IngestionMetadata(
                pairingMode: .interleaved,
                originalFilenames: ["P4PE_S1_L001_R1_001.fastq.gz", "P4PE_S1_L001_R2_001.fastq.gz"]
            )),
            for: sourceFASTQ
        )

        let picked = project.appendingPathComponent("Analyses/\(Self.derivedName).lungfishfastq", isDirectory: true)
        try fileManager.createDirectory(at: picked, withIntermediateDirectories: true)
        let payload = picked.appendingPathComponent("subsampleCount.fastq.gz")
        try fileManager.copyItem(at: Self.fixtureReads, to: payload)
        FASTQMetadataStore.save(
            PersistedFASTQMetadata(ingestion: IngestionMetadata(pairingMode: .interleaved)),
            for: payload
        )
        let operation = FASTQDerivativeOperation(kind: .subsampleCount, count: 1000)
        try FASTQBundle.saveDerivedManifest(
            FASTQDerivedBundleManifest(
                name: Self.derivedName,
                parentBundleRelativePath: "@/Imports/P4PE_S1_L001.lungfishfastq",
                rootBundleRelativePath: "@/Imports/P4PE_S1_L001.lungfishfastq",
                rootFASTQFilename: "P4PE_S1_L001.fastq.gz",
                payload: .full(fastqFilename: "subsampleCount.fastq.gz"),
                lineage: [operation],
                operation: operation,
                cachedStatistics: .countsOnlyFixture(readCount: Self.totalReads, baseCount: Int64(Self.totalReads * 100)),
                pairingMode: .interleaved,
                sequenceFormat: .fastq
            ),
            in: picked
        )
        XCTAssertTrue(FASTQBundle.isDerivedBundle(picked))
        return Project(scratch: scratch, project: project, raw: source, picked: picked)
    }

    private func requireSeqkit() async throws {
        if !(await NativeToolRunner.shared.isToolAvailable(.seqkit)) {
            try ToolAvailability.skipOrFail("managed seqkit is not installed (a virtual barcode bundle is read with it)")
        }
    }

    /// A word of a record or a command, with a leading `@/` spelled as a path under the project.
    private func expanded(_ word: String, in project: Project) -> String {
        word.hasPrefix(PortablePath.projectPrefix)
            ? project.project.appendingPathComponent(String(word.dropFirst(PortablePath.projectPrefix.count))).path
            : word
    }

    /// The reads of a barcode bundle, physical or virtual, in file order.
    private func records(
        ofBarcodeBundle bundle: URL,
        in project: Project,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> [FASTQRecord] {
        let payload: URL
        if FASTQBundle.isDerivedBundle(bundle) {
            payload = project.scratch.appendingPathComponent("barcode-\(UUID().uuidString).fastq")
            try await FASTQDerivativeService.shared.exportMaterializedFASTQ(fromDerivedBundle: bundle, to: payload)
        } else {
            payload = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: bundle), bundle.lastPathComponent, file: file, line: line)
        }
        return try await FASTQOperationTestHelper.loadFASTQRecords(from: payload)
    }

    /// Checks the run folder `output`: the counts, every pair whole, and, when `linksBack`, the lineage of every
    /// barcode bundle. A derived source gives each barcode bundle a manifest that names the picked bundle. A raw
    /// import gives none (backlog row B1), so a run on it passes `linksBack: false`.
    private func assertTheBarcodeBundles(
        in output: URL,
        project: Project,
        linksBack: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let manifest = try XCTUnwrap(DemultiplexManifest.load(from: output), "a demux manifest in \(output.path)", file: file, line: line)
        XCTAssertEqual(manifest.inputReadCount, Self.totalReads, file: file, line: line)
        XCTAssertEqual(manifest.unassigned.readCount, Self.expectedUnassigned, "unassigned", file: file, line: line)
        for (barcodeID, reads) in Self.expectedReads {
            let barcode = try XCTUnwrap(manifest.barcodes.first { $0.barcodeID == barcodeID }, barcodeID, file: file, line: line)
            XCTAssertEqual(barcode.readCount, reads, barcodeID, file: file, line: line)
        }

        // Every barcode bundle, the unassigned one too, holds whole pairs and (for a derived source) links back to the picked bundle.
        let bundles = try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == FASTQBundle.directoryExtension }
        XCTAssertEqual(bundles.count, Self.expectedReads.count + 1, "four barcode bundles and the unassigned one", file: file, line: line)
        var pairsSeen = 0
        for bundle in bundles {
            let name = bundle.deletingPathExtension().lastPathComponent
            if linksBack {
                let derived = try XCTUnwrap(
                    FASTQBundle.loadDerivedManifest(in: bundle),
                    "a derived.manifest.json in \(bundle.lastPathComponent)",
                    file: file, line: line
                )
                XCTAssertEqual(derived.pairingMode, .interleaved, "pairing of \(name)", file: file, line: line)
                XCTAssertEqual(
                    expanded(derived.parentBundleRelativePath, in: project), project.picked.path,
                    "the parent of \(name) is the picked bundle", file: file, line: line
                )
            }
            let held = try await records(ofBarcodeBundle: bundle, in: project, file: file, line: line)
            XCTAssertEqual(held.count % 2, 0, "\(name) holds whole pairs", file: file, line: line)
            for index in stride(from: 0, to: held.count - 1, by: 2) {
                let (first, second) = (held[index], held[index + 1])
                XCTAssertEqual(first.identifier, second.identifier, "mates adjacent in \(name)", file: file, line: line)
                XCTAssertTrue(first.description?.hasPrefix("1:") == true, "mate 1 first in \(name)", file: file, line: line)
                XCTAssertTrue(second.description?.hasPrefix("2:") == true, "mate 2 second in \(name)", file: file, line: line)
            }
            pairsSeen += held.count / 2
            let expected = Self.expectedReads[name] ?? Self.expectedUnassigned
            XCTAssertEqual(held.count, expected, "reads of \(name)", file: file, line: line)
        }
        XCTAssertEqual(pairsSeen * 2, Self.totalReads, "every pair is in exactly one bundle", file: file, line: line)
    }

    /// The route the fix hands the run to. The CLI, given the derived bundle itself, keeps every pair whole, gives
    /// BIO's counts and writes the lineage. It passes before the fix and after it.
    func testTheCLIGivenTheDerivedBundleKeepsEveryPairAndLinksBack() async throws {
        try await requireSeqkit()
        let project = try makeProject()
        let output = project.project.appendingPathComponent("Analyses/demultiplex-cli", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = try await DialogRowInProcessCLIRunner().run(
            invocation: FASTQCLIInvocation(
                subcommand: "fastq",
                arguments: [
                    "demultiplex", project.picked.path,
                    "--kit", "truseq-single-a",
                    "-o", output.path,
                    "--engine", "header-index",
                ]
            ),
            outputDirectory: output,
            progress: { _, _ in }
        )
        try await assertTheBarcodeBundles(in: output, project: project)
    }

    /// The dialog's run on the derived bundle: the CLI gets the bundle, the record names it, every barcode bundle
    /// links back to it and the row's command can be run again.
    func testDemultiplexingADerivedBundleFromTheDialogHandsTheCLITheBundle() async throws {
        let project = try makeProject()
        try await assertTheDialogHandsTheCLI(project.picked, in: project, linksBack: true)
    }

    /// The dialog's run on the raw one-file import (DEMUX-FIX, SF-3). The CLI gets the import bundle and not the file
    /// inside it, the counts and the pairs are BIO's, and the record and the row name the import. Its barcode bundles
    /// are physical and carry no `derived.manifest.json` (backlog row B1), so no manifest is asserted.
    func testDemultiplexingARawPairedBundleFromTheDialogHandsTheCLITheBundle() async throws {
        let project = try makeProject()
        try await assertTheDialogHandsTheCLI(project.raw, in: project, linksBack: false)
    }

    /// Runs Demultiplex Barcodes on `picked` as the dialog does and checks what the person is left with.
    private func assertTheDialogHandsTheCLI(_ picked: URL, in project: Project, linksBack: Bool) async throws {
        try await requireSeqkit()
        let state = FASTQOperationDialogState(
            initialCategory: .demultiplexing,
            selectedInputURLs: [picked],
            projectURL: project.project
        )
        state.selectTool(.demultiplexBarcodes)
        state.demultiplexBarcodeSource = .builtinKit
        state.demultiplexKitID = "truseq-single-a"
        state.demultiplexEngine = .headerIndex
        state.prepareForRun()
        XCTAssertTrue(state.isRunEnabled)
        let launch = try XCTUnwrap(state.pendingLaunchRequest)
        guard case .derivative(.demultiplex(_, _, _, _, _, _, _, let engine, _, _, _), let inputs, _) = launch else {
            return XCTFail("the dialog builds a demultiplex request, got \(launch)")
        }
        XCTAssertEqual(engine, .headerIndex)
        XCTAssertEqual(inputs, [picked])

        let destinationRoot = try XCTUnwrap(state.outputDirectoryURL).standardizedFileURL
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        let workingDirectory = MainSplitViewController().uniqueFASTQOperationOutputDirectory(in: destinationRoot, request: launch)
        let service = FASTQOperationExecutionService(
            commandRunner: DialogRowInProcessCLIRunner(),
            directImporter: BundleFASTQOperationImporter(destinationDirectory: destinationRoot)
        )
        let reporter = RecordingOperationReporter()
        let id = try MainSplitViewController.beginFASTQLaunchRequestOperation(
            title: "FASTQ: \(launch.operationDisplayTitle)",
            request: launch,
            executionService: service,
            routeContext: nil,
            outputTargetPath: workingDirectory.path,
            reporter: reporter
        ) { _ in }.requireStarted()
        // At begin the row already spells the run folder, as the launch site gives it, so a run that fails keeps a
        // command that runs again.
        let begun = try XCTUnwrap(reporter.items.first?.cliCommand)
        XCTAssertFalse(begun.contains("<derived>"), begun)
        let begunShown = try XCTUnwrap(RecordedCLICommand.parseScript(begun).first as? FastqDemultiplexSubcommand)
        XCTAssertEqual(begunShown.output, workingDirectory.path)
        let result = try await service.execute(request: launch, workingDirectory: workingDirectory)
        FASTQOperationRowCommand.apply(FASTQOperationRowCommand.refinement(for: result), to: id, reporter: reporter)

        // The argv input is the picked bundle, never a staged copy.
        let invocation = try XCTUnwrap(result.executedInvocations.first)
        XCTAssertEqual(invocation.arguments.prefix(2).map { $0 }, ["demultiplex", picked.path])
        XCTAssertFalse(invocation.argv.contains { $0.contains("materialized-inputs-") }, "\(invocation.argv)")
        XCTAssertEqual(result.importedURLs, [workingDirectory])

        // The counts, the pairs and, for a derived source, the lineage of every barcode bundle.
        try await assertTheBarcodeBundles(in: workingDirectory, project: project, linksBack: linksBack)

        // The run's record names the bundle as its input, and no staged copy.
        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: workingDirectory), "the run's record")
        // The record spells a temporary folder as /var and this test as /private/var, so paths are compared resolved.
        let pickedPath = picked.resolvingSymlinksInPath().path
        XCTAssertTrue(
            envelope.argv.contains { URL(fileURLWithPath: expanded($0, in: project)).resolvingSymlinksInPath().path == pickedPath },
            "the record's argv names the picked bundle: \(envelope.argv)"
        )
        let recordedInputs = (envelope.files + envelope.steps.flatMap(\.inputs)).filter { $0.role == .input }.map(\.path)
        XCTAssertFalse(recordedInputs.isEmpty)
        XCTAssertFalse(recordedInputs.contains { $0.contains("materialized-inputs-") }, "\(recordedInputs)")
        XCTAssertTrue(
            recordedInputs.contains { URL(fileURLWithPath: expanded($0, in: project)).resolvingSymlinksInPath().path.hasPrefix(pickedPath) },
            "an input of the record is the picked bundle: \(recordedInputs)"
        )

        // The row's command names the bundle and the run folder, so Copy CLI Command runs the run again.
        let row = try XCTUnwrap(reporter.items.first?.cliCommand)
        XCTAssertTrue(row.hasPrefix("lungfish-cli fastq demultiplex "), row)
        XCTAssertFalse(row.contains("<derived>"), row)
        XCTAssertFalse(row.contains("materialized-inputs-"), row)
        let shown = try XCTUnwrap(RecordedCLICommand.parseScript(row).first as? FastqDemultiplexSubcommand)
        XCTAssertEqual(URL(fileURLWithPath: shown.input).resolvingSymlinksInPath().path, pickedPath)
        XCTAssertEqual(
            URL(fileURLWithPath: shown.output).resolvingSymlinksInPath().path,
            workingDirectory.resolvingSymlinksInPath().path
        )
        XCTAssertEqual(shown.engine, "header-index")
        XCTAssertTrue(
            (reporter.items.first?.logs.map(\.message) ?? []).allSatisfy { !$0.contains("keeps the command recorded at launch") },
            "the row takes the record's command and logs no reason to keep the launch command"
        )

        // The staging is gone and nothing was staged beside the run.
        let leftovers = (FileManager.default.subpaths(atPath: project.project.path) ?? [])
            .filter { $0.split(separator: "/").contains { $0.hasPrefix("materialized-inputs-") } }
        XCTAssertEqual(leftovers, [], "staging left in the project")
    }
}
