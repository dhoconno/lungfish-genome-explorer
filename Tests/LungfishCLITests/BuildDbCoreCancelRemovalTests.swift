// BuildDbCoreCancelRemovalTests.swift - A build-db core that stops after it moved or removed files names them
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishWorkflow

/// A cancel inside a `build-db` core after it moved or removed files and before it built the removal step that
/// names them (A18 review section 4 item 3, lane S33 M4). The core builds that step from what it removed so far,
/// from descriptors it already took and with no new hash, and hands it over before it rethrows, so the root
/// record names each file that is gone with the digest a step recorded for it (2.8 P1, BIO 6). Each case runs a
/// real index builder over its core through the executor, as `BuildDbCoreStepHandOverTests` does.
final class BuildDbCoreCancelRemovalTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "build-db-cancel-removal")
    }

    override func tearDown() {
        // A case that failed before it gave `get/` its write permission back leaves it read-only.
        if let scratch, let walker = FileManager.default.enumerator(at: scratch, includingPropertiesForKeys: [.isDirectoryKey]) {
            for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
        }
        TestTempDirectory.cleanup(scratch)
    }

    // MARK: Kraken2

    /// A cancel at the check before the second sample folder, once the first folder's compaction removed its
    /// per-read output and rewrote its result sidecar. The removal step names both as they were.
    func testAKraken2CancelBeforeALaterFolderNamesWhatTheFirstFolderRemoved() async throws {
        let run = try await BuildDbIndexRun.run(
            .kraken2, prepared: try BuildDbIndexFixtures.kraken2(in: scratch), in: scratch, fault: .cancelAfterStep("gzip")
        ) { _ in
            Kraken2ResultIndexer()
        }

        try run.assertCancelledKeepingTheHandedOverSteps()
        XCTAssertEqual(try run.stepNames(), [
            BuildDbIndexRun.launchToolName, "lungfish-kraken2-index", "gzip", ClassificationPipeline.kraken2OutputRemovalToolName,
        ])
        let removed = try XCTUnwrap(try run.record().steps.last?.inputs.map { $0.path.components(separatedBy: "/").suffix(2).joined(separator: "/") })
        XCTAssertEqual(removed, ["SRR35517702/classification.kraken", "SRR35517702/classification-result.json"])
        try run.assertEachBuildOutputIsOnDisk()
        try run.assertEachGoneFileHasARemovalStep()
        try run.assertNoDigestOf("kraken2.sqlite")
    }

    // MARK: EsViritu

    /// A cancel once the BAM move went over, which the read count pass sees at its first BAM. The move left
    /// nothing at the BAMs' old paths, and the removal step names each with the digest the move recorded.
    func testAnEsVirituCancelAfterTheMoveNamesTheMovedBAMsOldPaths() async throws {
        let run = try await esVirituRun(cancellingAfter: "Lungfish EsViritu BAM Relocation")

        try run.assertCancelledKeepingTheHandedOverSteps()
        XCTAssertEqual(try run.stepNames(), [
            BuildDbIndexRun.launchToolName, "Lungfish EsViritu BAM Relocation", "Lungfish EsViritu BAM Relocation Source Removal",
        ])
        try assertTheRemovalNamesTheMovedBAMsOldPaths(run)
    }

    /// A cancel once the last samtools step went over, which the check after the read count pass sees, before the
    /// cleanup. The cleanup's own check shares this catch, and no step or line of the core falls between the two
    /// checks to land a cancel on.
    func testAnEsVirituCancelAfterTheReadCountPassNamesTheMovedBAMsOldPaths() async throws {
        let run = try await esVirituRun(cancellingAfter: "samtools", ordinal: 7)

        try run.assertCancelledKeepingTheHandedOverSteps()
        XCTAssertEqual(
            try run.stepNames(),
            [BuildDbIndexRun.launchToolName, "Lungfish EsViritu BAM Relocation"] + Array(repeating: "samtools", count: 7)
                + ["Lungfish EsViritu BAM Relocation Source Removal"]
        )
        try assertTheRemovalNamesTheMovedBAMsOldPaths(run)
    }

    // MARK: TaxTriage

    /// A cancel inside the executor's cleanup, between the result folder and a serial sample folder. A file the
    /// cleanup cannot remove makes it warn in the result folder, after it removed the fastp and count files there,
    /// and the check before the next folder ends it. The removal step names the two files with the digests the
    /// launch recorded and depends on the build step, which went over before the cleanup started.
    func testATaxTriageCancelInsideTheCleanupNamesTheFilesItRemovedSoFar() async throws {
        let prepared = try BuildDbIndexFixtures.taxTriage(in: scratch, withBAMs: false)
        let serialTop = prepared.appendingPathComponent("S2/top", isDirectory: true)
        try FileManager.default.createDirectory(at: serialTop, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: prepared.appendingPathComponent("top/SRR35517702.top_report.tsv"),
            to: serialTop.appendingPathComponent("S2.top_report.tsv")
        )

        let run = try await BuildDbIndexRun.run(
            .taxtriage, prepared: prepared, in: scratch,
            fault: .cancelAtLine { $0.hasPrefix("Warning: could not remove ") },
            afterCopy: { root in
                try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.appendingPathComponent("get").path)
            }
        ) { _ in
            TaxTriageResultIndexer()
        }
        let folder = try run.folder()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.appendingPathComponent("get").path)

        try run.assertCancelledKeepingTheHandedOverSteps()
        XCTAssertEqual(try run.stepNames(), [
            BuildDbIndexRun.launchToolName, "lungfish build-db taxtriage", BuildDbCommand.TaxTriageSubcommand.cleanupRemovalToolName,
        ])
        let steps = try run.record().steps
        let removal = try XCTUnwrap(steps.last)
        XCTAssertEqual(removal.dependsOn, [steps[1].id], "the removal depends on the build step")
        XCTAssertEqual(
            removal.inputs.map { BuildDbIndexRun.key($0.path) },
            ["fastp/S.fastp.fastq.gz", "count/S.fastq.gz"].map { BuildDbIndexRun.key(folder.appendingPathComponent($0).path) }
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("get/S.get.tsv").path))
        try run.assertEachBuildOutputIsOnDisk()
        try run.assertEachGoneFileHasARemovalStep()
    }

    // MARK: A failure after a hand-over (A18 review ruling 1)

    /// A `--project` EsViritu run whose finalize finds no managed samtools. Its build fails after it moved the BAM,
    /// with no cancel. The core keeps the steps it handed over, the move and the removal of the BAM's old path,
    /// and EsViritu's finalize turns the failure into a warning, so the completed record names a move that
    /// happened before the build failed, and no database. Pins that record.
    func testAnEsVirituBuildThatFailsAfterTheMoveLeavesACompletedRecordThatNamesTheMove() async throws {
        let project = scratch.appendingPathComponent("Project.lungfish", isDirectory: true)
        let shapes = try BundleShapeFixtures(in: project.appendingPathComponent("Imports", isDirectory: true))
        let sample = BuildDbStreamCapture.fixturesFolder.appendingPathComponent("esviritu-mini/SRR35517705", isDirectory: true)
        let esviritu = try StandInEsViritu(root: scratch.appendingPathComponent("tool"), tables: sample.appendingPathComponent("SRR35517705"))
        let home = scratch.appendingPathComponent("HomeWithoutSamtools", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let tool = EsVirituWithItsBAMs(
            base: EsVirituAnalysisRunTool(
                options: EsVirituAnalysisRunOptions(sampleName: "S1", readFormat: .unpaired, databasePath: esviritu.databaseURL, threads: 2),
                groupsSamples: false,
                pipeline: EsVirituPipeline(condaManager: esviritu.condaManager),
                materializer: FASTQCLIMaterializer(runner: .shared),
                installedDatabase: { [databaseURL = esviritu.databaseURL] in databaseURL }
            ),
            bam: sample.appendingPathComponent("SRR35517705_temp/SRR35517705.third.filt.sorted.bam"),
            home: home
        )
        let request = AnalysisRunRequest(
            inputs: [shapes.single], destination: .project(project), commandLine: ["lungfish-cli", "esviritu", "detect"]
        )

        let report = await Task {
            await AnalysisRunExecutor(services: AnalysisRunServices(indexing: EsVirituResultIndexing()))
                .execute(tool, request, events: AnalysisRunEvents { _ in })
        }.value

        XCTAssertEqual(report.status, .completed, report.message)
        XCTAssertTrue(report.warnings.contains { $0.contains("Managed samtools is required") }, "\(report.warnings)")
        let run = BuildDbIndexRun(report: report, handedOver: [], afterTheFault: nil)
        let record = try run.record()
        XCTAssertEqual(record.status, .completed)
        XCTAssertTrue(record.steps.contains { $0.toolName == "EsViritu" }, "\(record.steps.map(\.toolName))")
        XCTAssertEqual(
            Array(record.steps.map(\.toolName).suffix(2)),
            ["Lungfish EsViritu BAM Relocation", "Lungfish EsViritu BAM Relocation Source Removal"]
        )
        XCTAssertFalse(record.steps.contains { $0.toolName.hasPrefix("lungfish build-db") }, "\(record.steps.map(\.toolName))")
        let move = try XCTUnwrap(record.steps.first { $0.toolName == "Lungfish EsViritu BAM Relocation" })
        let removal = try XCTUnwrap(record.steps.last)
        XCTAssertFalse(move.outputs.isEmpty)
        for output in move.outputs {
            XCTAssertTrue(BuildDbIndexRun.isOnDisk(output), "\(output.path) is where the move put it, with its digest")
        }
        XCTAssertEqual(removal.inputs.count, move.inputs.count)
        for (gone, moved) in zip(removal.inputs, move.inputs) {
            XCTAssertTrue(BuildDbIndexRun.same(gone, moved), gone.path)
            XCTAssertFalse(FileManager.default.fileExists(atPath: gone.path), gone.path)
        }
        try run.assertNoDigestOf("esviritu.sqlite")
    }

    // MARK: Runs

    private func esVirituRun(cancellingAfter step: String, ordinal: Int = 1) async throws -> BuildDbIndexRun {
        try await BuildDbIndexRun.run(
            .esviritu, prepared: try BuildDbIndexFixtures.esViritu(in: scratch), in: scratch,
            home: try BuildDbIndexFixtures.samtoolsHome(in: scratch), fault: .cancelAfterStep(step, ordinal: ordinal)
        ) { _ in
            EsVirituResultIndexing()
        }
    }

    /// The removal step names the BAM and its index under their `_temp` paths, both gone, with the digests the
    /// move recorded, and the record names no database.
    private func assertTheRemovalNamesTheMovedBAMsOldPaths(
        _ run: BuildDbIndexRun, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let steps = try run.record().steps
        let move = try XCTUnwrap(steps.first { $0.toolName == "Lungfish EsViritu BAM Relocation" }, file: file, line: line)
        let removal = try XCTUnwrap(steps.last, file: file, line: line)
        XCTAssertEqual(
            try BuildDbIndexRun.encoded([removal]).contains("_temp/SRR35517705.third.filt.sorted.bam.bai"), true,
            "the removal names the index's old path", file: file, line: line
        )
        XCTAssertEqual(removal.inputs.count, move.inputs.count, file: file, line: line)
        for (gone, moved) in zip(removal.inputs, move.inputs) {
            XCTAssertTrue(BuildDbIndexRun.same(gone, moved), "\(gone.path) as the move recorded it", file: file, line: line)
            XCTAssertFalse(FileManager.default.fileExists(atPath: gone.path), file: file, line: line)
        }
        try run.assertEachBuildOutputIsOnDisk(file: file, line: line)
        try run.assertEachGoneFileHasARemovalStep(file: file, line: line)
        try run.assertNoDigestOf("esviritu.sqlite", file: file, line: line)
    }
}

/// The EsViritu tool, with a copy of `bam` put where EsViritu leaves each sample's BAM, in `<sample>_temp` beside
/// the sample's detection table, before its finalize builds the index, as a run that keeps its BAMs leaves them.
/// The finalize runs with `home` as its HOME, where the build looks for its managed samtools.
private struct EsVirituWithItsBAMs: AnalysisRunTool {
    typealias Unit = EsVirituAnalysisRunTool.Unit
    typealias UnitResult = EsVirituAnalysisRunTool.UnitResult

    let base: EsVirituAnalysisRunTool
    let bam: URL
    let home: URL

    var identity: AnalysisRunIdentity { base.identity }
    var terminalPolicy: AnalysisRunTerminalPolicy { base.terminalPolicy }
    var finalizeProgressShare: Double { base.finalizeProgressShare }

    func finalizeProgressShare(for layout: AnalysisRunLayout) -> Double {
        base.finalizeProgressShare(for: layout)
    }

    func plan(_ request: AnalysisRunRequest, context: AnalysisRunPlanningContext) async throws -> AnalysisRunPlan<Unit> {
        try await base.plan(request, context: context)
    }

    func run(_ unit: AnalysisRunUnit<Unit>, context: AnalysisRunUnitContext) async throws -> AnalysisUnitOutcome<UnitResult> {
        try await base.run(unit, context: context)
    }

    func finalize(_ units: [AnalysisUnitReport<UnitResult>], context: AnalysisRunFinalizeContext) async throws -> AnalysisRunFinalization {
        let fileManager = FileManager.default
        let suffix = ".detected_virus.info.tsv"
        let files = fileManager.enumerator(at: context.rootDirectory, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
        for table in files where table.lastPathComponent.hasSuffix(suffix) {
            let sample = String(table.lastPathComponent.dropLast(suffix.count))
            let temp = table.deletingLastPathComponent().appendingPathComponent("\(sample)_temp", isDirectory: true)
            try fileManager.createDirectory(at: temp, withIntermediateDirectories: true)
            try fileManager.copyItem(at: bam, to: temp.appendingPathComponent("\(sample).third.filt.sorted.bam"))
        }
        return try await BuildDbIndexRun.withHome(home) {
            try await base.finalize(units, context: context)
        }
    }
}
