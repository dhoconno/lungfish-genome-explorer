// SystemTempScratchPinTests.swift - Where workflow scratch lands outside a project, and what removes it
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane S32 M1 (2.10 P1 and P3, 2.11 S3). Each pin points the system temp folder at a
// folder under a TestTempDirectory root through `TMPDIR`, which
// `ProjectTempDirectory.systemTemporaryDirectory()` honours, so no pin touches the real system temp
// folder. The project sweep (`AnalysisRunScratch`) lists only `<project>/.tmp`, so at the base a folder
// in the system temp folder was one that nothing removed. Since S32 M2 it carries a marker and the
// launch sweep (`SystemTempScratchSweep`) claims it once its creator is gone.

import Darwin
import Foundation
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow
import XCTest

final class SystemTempScratchPinTests: XCTestCase {
    private var root: URL!
    /// Stands in for the system temp folder.
    private var systemTemp: URL!
    private var previousTMPDIR: String?

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "system-temp-scratch-pin").resolvingSymlinksInPath()
        systemTemp = root.appendingPathComponent("T", isDirectory: true)
        try FileManager.default.createDirectory(at: systemTemp, withIntermediateDirectories: true)
        previousTMPDIR = ProcessInfo.processInfo.environment["TMPDIR"]
        setenv("TMPDIR", systemTemp.path, 1)
    }

    override func tearDownWithError() throws {
        if let previousTMPDIR { setenv("TMPDIR", previousTMPDIR, 1) } else { unsetenv("TMPDIR") }
        TestTempDirectory.cleanup(root)
    }

    /// W5. A volume the scratch probe rejects (ExFAT) puts the engine's scratch in the system temp
    /// folder, and a cancelled run leaves it there for a sweep (P3).
    func testACancelledEngineRunOnARejectedVolumeLeavesItsScratchInTheSystemTempFolder() throws {
        let project = try makeProject("Engine.lungfish")
        let analysis = project.appendingPathComponent("Analyses/taxtriage-1", isDirectory: true)
        try FileManager.default.createDirectory(at: analysis, withIntermediateDirectories: true)
        let engine = NextflowEngineProcess(configuration: .forTests())

        let scratch = try engine.makeScratch(contextURL: analysis, volumeQualifiesForScratch: false, environment: [:])
        engine.finish(scratch, .leaveForSweep)

        XCTAssertTrue(Self.isDirectory(scratch.workDirectory), "a cancelled run keeps its work folder for the sweep")
        try assertLeftInTheSystemTempFolder(scratch.launchDirectory, prefix: "nextflow-engine-test-", project: project)
    }

    /// W7. TaxTriage stages a run whose paths hold a space in a space-free `taxtriage-` folder in the
    /// system temp folder, inside a project too.
    func testATaxTriageStagingOfAPathWithASpaceLeavesItsFolderInTheSystemTempFolder() throws {
        let project = try makeProject("Lungfish Docs.lungfish")
        let imports = project.appendingPathComponent("Imports", isDirectory: true)
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
        let reads = imports.appendingPathComponent("sample reads.fastq.gz")
        try Data("ACGT".utf8).write(to: reads)
        let output = project.appendingPathComponent("Analyses/taxtriage-batch-1", isDirectory: true)
        let config = TaxTriageConfig(
            samples: [TaxTriageSample(sampleId: "S1", fastq1: reads, platform: .illumina)],
            outputDirectory: output
        )

        let execution = try TaxTriagePipeline().prepareExecutionConfig(for: config)

        let redirect = try XCTUnwrap(execution.redirectDirectory, "a path with a space is staged")
        try assertLeftInTheSystemTempFolder(redirect, prefix: "taxtriage-", project: project)
    }

    /// SW7 (c). An ONT import stages its chunks in a hidden folder beside its output, inside the
    /// project but not under the project's `.tmp`, so the project sweep does not cover a killed import's
    /// staging folder (2.12).
    func testAnONTImportStagesBesideItsOutputAndNotUnderTheProjectTmp() async throws {
        let project = try makeProject("ONT.lungfish")
        let source = root.appendingPathComponent("fastq_pass", isDirectory: true)
        let barcode = source.appendingPathComponent("barcode01", isDirectory: true)
        try FileManager.default.createDirectory(at: barcode, withIntermediateDirectories: true)
        try "@r1 runid=test flow_cell_id=FLO-MIN sample_id=S1 barcode=barcode01\nACGT\n+\n!!!!\n"
            .write(to: barcode.appendingPathComponent("chunk_0.fastq"), atomically: true, encoding: .utf8)
        let imports = project.appendingPathComponent("Imports", isDirectory: true)
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
        let output = imports.appendingPathComponent("run", isDirectory: true)
        let tmp = ProjectTempDirectory.tempRoot(for: project)
        let seen = SeenNames()

        _ = try await ONTImportWorkflow().importDirectory(
            config: ONTImportConfig(sourceDirectory: source, outputDirectory: output, maxConcurrentBarcodes: 1),
            context: Self.ontContext(source: source, output: output)
        ) { _, _ in
            seen.add(beside: Self.names(in: imports), underTmp: Self.names(in: tmp))
        }

        let staging = seen.beside.filter { $0.hasPrefix(".run.ont-import-staging-") }
        XCTAssertFalse(staging.isEmpty, "the import stages beside its output, saw \(seen.beside.sorted())")
        XCTAssertTrue(seen.underTmp.isEmpty, "nothing stages under the project .tmp, saw \(seen.underTmp.sorted())")
    }

    /// S32 review fix 1. `LUNGFISH_TAXTRIAGE_KEEP_WORK=1` keeps a run's scratch for debugging, and the
    /// engine promises that a kept scratch is never removed. In the system temp folder the marker must
    /// say so, since the launch sweep reads it there. The pin uses TaxTriage's own engine settings,
    /// because the sweep claims only LGE prefixes (`taxtriage-run-`) and `.forTests()` has none.
    func testAKeepWorkScratchInTheSystemTempFolderSurvivesTheSweep() throws {
        let project = try makeProject("Keep.lungfish")
        let analysis = project.appendingPathComponent("Analyses/taxtriage-1", isDirectory: true)
        try FileManager.default.createDirectory(at: analysis, withIntermediateDirectories: true)
        let engine = NextflowEngineProcess(
            configuration: NextflowWorkflowDescriptor.taxTriage.engineConfiguration(profile: "local")
        )

        let scratch = try engine.makeScratch(
            contextURL: analysis,
            volumeQualifiesForScratch: false,
            environment: [TaxTriagePipeline.keepWorkEnvironmentKey: "1"]
        )
        engine.finish(scratch, .remove)

        let name = scratch.launchDirectory.lastPathComponent
        let marker = try OwnedWorkDirectoryMarkerStore.load(
            from: scratch.launchDirectory.resolvingSymlinksInPath(),
            expectedProjectURL: systemTemp
        )
        XCTAssertTrue(marker.keepIntermediates, "the marker of a scratch kept for debugging says so")
        let outcome = SystemTempScratchSweep.sweep(root: systemTemp, processInspector: { _ in nil })
        XCTAssertEqual(outcome.refused[name], .keptForDebugging)
        XCTAssertTrue(Self.isDirectory(scratch.launchDirectory), "the sweep leaves a scratch kept for debugging")
    }

    // MARK: - Helpers

    private func makeProject(_ name: String) throws -> URL {
        let project = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        return project
    }

    /// The folder sits in the system temp folder, outside the project `.tmp` the project sweep lists,
    /// and carries the `OwnedWorkDirectoryMarker` that names its creator (none at the base, W1).
    private func assertLeftInTheSystemTempFolder(
        _ folder: URL,
        prefix: String,
        project: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let resolved = folder.resolvingSymlinksInPath()
        XCTAssertTrue(Self.isDirectory(resolved), "\(folder.path) is left", file: file, line: line)
        XCTAssertEqual(resolved.deletingLastPathComponent().path, systemTemp.path, file: file, line: line)
        XCTAssertTrue(resolved.lastPathComponent.hasPrefix(prefix), resolved.lastPathComponent, file: file, line: line)
        XCTAssertFalse(
            Self.names(in: ProjectTempDirectory.tempRoot(for: project)).contains(resolved.lastPathComponent),
            "the project sweep lists only the project .tmp",
            file: file,
            line: line
        )
        XCTAssertNoThrow(
            try OwnedWorkDirectoryMarkerStore.load(from: resolved, expectedProjectURL: systemTemp),
            "S32 M2, scratch with no project carries a marker naming its creator, bound to the system temp folder",
            file: file,
            line: line
        )
    }

    private static func names(in folder: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// The names the progress callback saw, which runs off the test's task.
    private final class SeenNames: @unchecked Sendable {
        private let lock = NSLock()
        private var besideNames: Set<String> = []
        private var tmpNames: Set<String> = []

        func add(beside: [String], underTmp: [String]) {
            lock.withLock {
                besideNames.formUnion(beside)
                tmpNames.formUnion(underTmp)
            }
        }

        var beside: Set<String> { lock.withLock { besideNames } }
        var underTmp: Set<String> { lock.withLock { tmpNames } }
    }

    private static func ontContext(source: URL, output: URL) -> ONTImportWorkflow.CommandContext {
        let argv = ["lungfish", "fastq", "import-ont", source.path, "--output", output.path, "--concurrency", "1"]
        return ONTImportWorkflow.CommandContext(
            caller: .cli,
            workflowName: "lungfish fastq import-ont",
            workflowVersion: "test-version",
            toolName: "lungfish fastq import-ont",
            toolVersion: "test-version",
            argv: argv,
            durableReplayArgv: argv,
            reproducibleCommand: argv.joined(separator: " "),
            explicitOptions: ["input": .file(source), "output": .file(output), "concurrency": .integer(1)],
            defaultOptions: [
                "includeUnclassified": .boolean(false),
                "concurrency": .integer(4),
                "useVirtualConcatenation": .boolean(true),
            ],
            resolvedOptions: [
                "input": .file(source),
                "output": .file(output),
                "includeUnclassified": .boolean(false),
                "concurrency": .integer(1),
                "useVirtualConcatenation": .boolean(true),
                "caller": .string("cli"),
            ],
            runtimeIdentity: ProvenanceRuntimeIdentity(
                appVersion: "test-version",
                executablePath: "/tmp/lungfish-test",
                operatingSystemVersion: "test-os",
                architecture: "test-arch"
            )
        )
    }
}
