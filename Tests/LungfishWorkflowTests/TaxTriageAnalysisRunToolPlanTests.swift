// TaxTriageAnalysisRunToolPlanTests.swift - The plan of TaxTriage on the analysis run executor, its refusals and layouts
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

/// Lane A2 of Phase 2.9, milestone 1. `TaxTriageAnalysisRunTool` plans a `taxtriage run` request and
/// runs nothing yet, so each test checks the plan, a refusal before any folder exists, or the folder
/// names the executor's own functions give the plan's units. No test launches Nextflow.
final class TaxTriageAnalysisRunToolPlanTests: XCTestCase {

    var root: URL!
    var database: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "taxtriage-tool-plan").resolvingSymlinksInPath()
        database = root.appendingPathComponent("kraken2-db", isDirectory: true)
        try FileManager.default.createDirectory(at: database, withIntermediateDirectories: true)
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - Identity

    func testTheToolIsTaxTriageUnderItsOwnWorkflowNameAndWarnsOnAFailedSampleOfABatch() {
        let tool = makeTool(makeRequest(input: "/unused"))

        XCTAssertEqual(tool.identity.toolID, .taxtriage)
        XCTAssertEqual(tool.identity.workflowName, "lungfish.taxtriage.run")
        XCTAssertEqual(tool.identity.displayName, "TaxTriage")
        XCTAssertEqual(tool.terminalPolicy, .warnOnFailedUnits)
        XCTAssertEqual(
            AnalysisToolRegistry.descriptor(for: .taxtriage)?.provisioning,
            .lockedPipeline(NextflowWorkflowDescriptor.taxTriage.lockPipelineID),
            "the plan reads the lock entry the registry names, through the descriptor"
        )
    }

    // MARK: - The pin (N4)

    func testThePlanTakesTheCommitAndTagFromTheLockItsServicesHold() async throws {
        let reads = try writeReads("S1.fastq")
        let output = root.appendingPathComponent("out", isDirectory: true)

        let custom = try await plan(makeTool(makeRequest(input: reads.path, sample: "S1"), lock: Self.lock(Self.customPin)), .directory(output))
        let unit = try XCTUnwrap(custom.units.first?.value)
        XCTAssertEqual(unit.revision, Self.customPin.revision)
        XCTAssertEqual(unit.githubReleaseVersion, Self.customPin.releaseVersion)
        XCTAssertEqual(unit.config.revision, Self.customPin.revision, "without --revision the launch runs the pinned commit")

        let bundledPin = try XCTUnwrap(ManagedToolLock.bundled.pipeline(id: "taxtriage"))
        let bundled = try await plan(makeTool(makeRequest(input: reads.path, sample: "S1")), .directory(output))
        let bundledUnit = try XCTUnwrap(bundled.units.first?.value)
        XCTAssertEqual(bundledUnit.revision, bundledPin.revision)
        XCTAssertEqual(bundledUnit.githubReleaseVersion, bundledPin.releaseVersion)
        XCTAssertEqual(bundledUnit.config.revision, bundledPin.revision)

        // The tag rule of the record, with the pin the plan resolved.
        let cases: [(revision: String, tag: String?)] = [
            (bundledPin.revision, bundledPin.releaseVersion),
            (bundledPin.releaseVersion, bundledPin.releaseVersion),
            ("v3.3.9", "v3.3.9"),
            ("main", nil),
        ]
        for (revision, tag) in cases {
            XCTAssertEqual(TaxTriageConfig.githubReleaseVersion(for: revision, pin: NextflowPipelinePin(bundledPin)), tag, revision)
        }
    }

    func testAGivenRevisionIsWhatTheLaunchRunsAndWhatTheStepRecords() async throws {
        let reads = try writeReads("S1.fastq")
        let tool = makeTool(makeRequest(input: reads.path, sample: "S1", revision: "v3.3.9"), lock: Self.lock(Self.customPin))

        let planned = try await plan(tool, .directory(root.appendingPathComponent("out", isDirectory: true)))
        let unit = try XCTUnwrap(planned.units.first?.value)

        XCTAssertEqual(unit.config.revision, "v3.3.9")
        XCTAssertEqual(unit.revision, "v3.3.9", "the step names the revision that ran, never the pin's commit")
        XCTAssertEqual(unit.githubReleaseVersion, "v3.3.9")

        let cases: [(given: String, tag: String?)] = [
            ("main", nil),
            (Self.customPin.revision, "v9.9.9"),
            ("v9.9.9", "v9.9.9"),
        ]
        for (given, tag) in cases {
            let tool = makeTool(makeRequest(input: reads.path, sample: "S1", revision: given), lock: Self.lock(Self.customPin))
            let planned = try await plan(tool, .directory(root.appendingPathComponent("out", isDirectory: true)))
            let unit = try XCTUnwrap(planned.units.first?.value)
            XCTAssertEqual(unit.config.revision, given, given)
            XCTAssertEqual(unit.revision, given, given)
            XCTAssertEqual(unit.githubReleaseVersion, tag, given)
        }
    }

    func testALockWithNoUsableTaxTriagePinRefusesWithN4sWordsAndLeavesNoFolder() async throws {
        let reads = try writeReads("S1.fastq")
        let words = "LGE's tool lock has no pinned version of TaxTriage, so LGE will not run it."
        let viralRecon = PipelineSpec(id: "nf-core-viralrecon", repository: "nf-core/viralrecon", revision: "3.0.0", releaseVersion: "3.0.0")
        let locks: [(name: String, lock: ManagedToolLock)] = [
            ("no-entry", Self.lock()),
            ("another-pipeline-only", Self.lock(viralRecon)),
            ("blank-revision", Self.lock(PipelineSpec(id: "taxtriage", repository: "jhuapl-bio/taxtriage", revision: " ", releaseVersion: "v3.3.8"))),
            ("blank-repository", Self.lock(PipelineSpec(id: "taxtriage", repository: "", revision: Self.customPin.revision, releaseVersion: "v3.3.8"))),
        ]
        for (name, lock) in locks {
            let output = root.appendingPathComponent("out-\(name)", isDirectory: true)
            let tool = makeTool(makeRequest(input: reads.path, sample: "S1"), lock: lock)

            let error = await planError(tool, .directory(output))
            XCTAssertEqual(error?.localizedDescription, words, name)
            XCTAssertEqual((error as? any AnalysisRunExitCoding)?.analysisRunExitCode, 126, name)

            let report = await execute(tool, .directory(output))
            XCTAssertEqual(report.status, .failed, name)
            XCTAssertEqual(report.exitCode, 126, name)
            XCTAssertEqual(report.message, words, name)
            XCTAssertNil(report.analysisDirectory, name)
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "\(name): a refused plan makes no folder")
        }
    }

    /// N4 amended (5 to 0). The executor route refuses at plan, so no unit asks the pipeline for the
    /// Docker wait and no folder exists. The pipeline route's case is in TaxTriagePipelinePinRefusalTests.
    func testAnUnpinnedTaxTriageRefusesBeforeTheDockerWaitAndLeavesNoFolder() async throws {
        let reads = try writeReads("S1.fastq")
        let output = root.appendingPathComponent("out", isDirectory: true)
        let probe = ScriptedDockerProbe(answers: [true])
        let tool = TaxTriageAnalysisRunTool(
            request: makeRequest(input: reads.path, sample: "S1"),
            services: TaxTriageRunServices(
                makePipeline: { TaxTriagePipeline(containerRuntimeProbe: probe) },
                expandInputs: Self.expandFolder,
                materializer: ReadSetFixtures.StubMaterializer(readsByBundlePath: [:]),
                lock: Self.lock()
            )
        )

        let report = await execute(tool, .directory(output))

        XCTAssertEqual(report.status, .failed)
        XCTAssertEqual(report.exitCode, 126)
        XCTAssertEqual(report.message, "LGE's tool lock has no pinned version of TaxTriage, so LGE will not run it.")
        XCTAssertNil(report.analysisDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "a refused plan makes no folder")
        XCTAssertEqual(probe.daemonQueries, 0, "the refusal comes before the Docker wait")
    }

    // MARK: - A folder of mates (T8)

    func testAFolderThatHoldsMatesIsRefusedWithT8sWordsWithOrWithoutBatch() async throws {
        let folder = root.appendingPathComponent("reads", isDirectory: true)
        try writeReads("S1_R1.fastq", in: folder)
        try writeReads("S1_R2.fastq", in: folder)
        try writeReads("S2.fastq", in: folder)
        let words = "The folder \(folder.path) holds paired reads, such as S1_R1.fastq and S1_R2.fastq. Use --samplesheet to pair them."
        let output = root.appendingPathComponent("out", isDirectory: true)
        let tool = makeTool(makeRequest(input: folder.path))

        for batch in [false, true] {
            let error = await planError(tool, .directory(output), batch: batch)
            XCTAssertEqual(error?.localizedDescription, words, "batch \(batch)")
            XCTAssertEqual((error as? any AnalysisRunExitCoding)?.analysisRunExitCode, 3, "batch \(batch)")
        }
        let report = await execute(tool, .directory(output))
        XCTAssertEqual(report.exitCode, 3)
        XCTAssertEqual(report.message, words)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "a refused plan makes no folder")
    }

    func testAFolderOfBundlesAndOfSingleReadsRunsOneSamplePerInput() async throws {
        let folder = root.appendingPathComponent("inputs", isDirectory: true)
        try makeBundle("A.lungfishfastq", in: folder)
        try makeBundle("B_R1.lungfishfastq", in: folder)
        try makeBundle("B_R2.lungfishfastq", in: folder)
        try writeReads("C.fastq", in: folder)

        let planned = try await plan(makeTool(makeRequest(input: folder.path)), .directory(root.appendingPathComponent("out", isDirectory: true)))

        XCTAssertEqual(planned.layout, .singleFolder)
        XCTAssertEqual(planned.units.count, 1)
        let unit = try XCTUnwrap(planned.units.first)
        XCTAssertEqual(unit.label, "4 samples")
        XCTAssertEqual(unit.value.config.samples.map(\.sampleId), ["A", "B_R1", "B_R2", "C"])
        XCTAssertEqual(
            unit.value.config.samples.map(\.fastq1.lastPathComponent),
            ["A.lungfishfastq", "B_R1.lungfishfastq", "B_R2.lungfishfastq", "C.fastq"],
            "a bundle is one sample whatever its name, so a folder of bundles keeps working (T8)"
        )
        XCTAssertTrue(unit.value.config.samples.allSatisfy { $0.fastq2 == nil })
    }

    func testAMateNameOutsideAFolderOfMatesIsNotRefused() async throws {
        let output = root.appendingPathComponent("out", isDirectory: true)
        let lone = try writeReads("S1_R1.fastq")
        let filePlan = try await plan(makeTool(makeRequest(input: lone.path, sample: "S1")), .directory(output))
        let fileUnit = try XCTUnwrap(filePlan.units.first?.value)
        XCTAssertEqual(fileUnit.config.samples.map(\.sampleId), ["S1"], "a file named as a mate is one sample")
        XCTAssertNil(fileUnit.config.samples.first?.fastq2)

        let folder = root.appendingPathComponent("one-mate", isDirectory: true)
        try writeReads("S1_R1.fastq", in: folder)
        try writeReads("S2.fastq", in: folder)
        let folderPlan = try await plan(makeTool(makeRequest(input: folder.path)), .directory(output))
        XCTAssertEqual(
            folderPlan.units.first?.value.config.samples.map(\.sampleId),
            ["S1_R1", "S2"],
            "a folder with an R1 and no R2 holds no pair, so T8 does not refuse it"
        )
    }

    // MARK: - Sample folders (T9)

    func testTheOneSanitizerNamesEachSampleFolderOfABatchAndTheSampleKeepsItsName() async throws {
        let sheet = try writeSamplesheet([("S.1", "a.fastq"), ("S 1", "b.fastq"), ("S__1", "c.fastq")])

        let planned = try await plan(makeTool(makeRequest(samplesheet: sheet.path)), .directory(root.appendingPathComponent("out", isDirectory: true)), batch: true)

        XCTAssertEqual(planned.layout, .batchRoot)
        XCTAssertEqual(planned.units.map(\.label), ["S.1", "S 1", "S__1"])
        for unit in planned.units {
            XCTAssertEqual(unit.value.config.samples.map(\.sampleId), [unit.label], "the samplesheet keeps the user's name (T9)")
            XCTAssertFalse(unit.value.handsFactsToRoot)
        }

        // The executor names each unit's folder through the one sanitizer, in plan order
        // (`AnalysisRunExecutor+Units.swift`), so the three samples run in these folders.
        let batchRoot = root.appendingPathComponent("batch-root", isDirectory: true)
        try FileManager.default.createDirectory(at: batchRoot, withIntermediateDirectories: true)
        let folders = try planned.units.map { try AnalysesFolder.batchSampleDirectory(named: $0.label, in: batchRoot).lastPathComponent }
        XCTAssertEqual(folders, ["S_1", "S_1-2", "S_1-3"])

        // The legacy route kept its own names (T9). Its serial runner went in 2.13 K1b, so the names its namer gave these
        // three samples at the base stand here as a literal list (QA 2), which the one sanitizer's never equal.
        let legacy = ["S.1", "S_1", "S__1"]
        XCTAssertNotEqual(folders, legacy, "the executor's folders are not the legacy route's")
    }

    // MARK: - Layouts (T5)

    func testAPlainOutputPoolsEverySampleIntoOneLaunchInTheFolderItNames() async throws {
        let sheet = try writeSamplesheet([("S1", "a.fastq"), ("S2", "b.fastq"), ("S3", "c.fastq")])
        let output = root.appendingPathComponent("out", isDirectory: true)

        let planned = try await plan(makeTool(makeRequest(samplesheet: sheet.path)), .directory(output))

        XCTAssertEqual(planned.layout, .singleFolder)
        XCTAssertEqual(planned.units.count, 1)
        let unit = try XCTUnwrap(planned.units.first)
        XCTAssertEqual(unit.label, "3 samples")
        XCTAssertEqual(unit.value.config.samples.map(\.sampleId), ["S1", "S2", "S3"])
        XCTAssertEqual(unit.value.config.outputDirectory, output.standardizedFileURL)
        XCTAssertTrue(unit.value.handsFactsToRoot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "the plan writes nothing")
    }

    func testAOneSampleProjectRunWritesIntoOneSharedBatchRootWithOrWithoutBatch() async throws {
        let project = try makeProject()
        let reads = try writeReads("S1.fastq")

        var layouts: [AnalysisRunLayout] = []
        for batch in [false, true] {
            let planned = try await plan(makeTool(makeRequest(input: reads.path, sample: "S1")), .project(project), batch: batch)
            layouts.append(planned.layout)
            XCTAssertEqual(planned.units.map(\.label), ["S1"], "batch \(batch)")
            XCTAssertEqual(planned.units.map(\.value.handsFactsToRoot), [true], "batch \(batch)")
        }
        XCTAssertEqual(layouts, [.sharedBatchRoot, .sharedBatchRoot])
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: project.appendingPathComponent(AnalysesFolder.directoryName).path),
            "the plan writes nothing"
        )

        // The executor's folder step names the shared root as the app names its one-sample run (2.8 T4).
        let folder = try AnalysisRunFolder.prepare(
            destination: .project(project),
            toolID: .taxtriage,
            layout: layouts[0],
            command: "lungfish-cli taxtriage run",
            startedAt: Date()
        )
        XCTAssertTrue(folder.root.lastPathComponent.hasPrefix("taxtriage-batch-"), folder.root.lastPathComponent)
        XCTAssertEqual(AnalysesFolder.readAnalysisMetadata(from: folder.root)?.isBatch, true)
    }

    func testSeveralSamplesOfAProjectRunAndEverySampleOfABatchLaunchAlone() async throws {
        let sheet = try writeSamplesheet([("S1", "a.fastq"), ("S2", "b.fastq")])
        let project = try makeProject()

        let projectPlan = try await plan(makeTool(makeRequest(samplesheet: sheet.path)), .project(project))
        XCTAssertEqual(projectPlan.layout, .batchRoot)
        XCTAssertEqual(projectPlan.units.map(\.label), ["S1", "S2"])
        XCTAssertEqual(projectPlan.units.map { $0.value.config.samples.map(\.sampleId) }, [["S1"], ["S2"]])
        XCTAssertEqual(projectPlan.units.map(\.value.handsFactsToRoot), [false, false])

        let reads = try writeReads("S3.fastq")
        let batchPlan = try await plan(
            makeTool(makeRequest(input: reads.path, sample: "S3")),
            .directory(root.appendingPathComponent("out", isDirectory: true)),
            batch: true
        )
        XCTAssertEqual(batchPlan.layout, .batchRoot)
        XCTAssertEqual(batchPlan.units.map(\.label), ["S3"])
        XCTAssertEqual(batchPlan.units.map(\.value.handsFactsToRoot), [false])
    }

    // MARK: - Refusals

    func testEveryRefusalOfTheRequestExitsWithThreeBeforeAnyFolder() async throws {
        let reads = try writeReads("S1.fastq")
        let twoReads = root.appendingPathComponent("two", isDirectory: true)
        try writeReads("A.fastq", in: twoReads)
        try writeReads("B.fastq", in: twoReads)
        let empty = root.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let missing = root.appendingPathComponent("missing").path
        let duplicates = try writeSamplesheet([("S1", "a.fastq"), ("S1", "b.fastq")], named: "duplicates.csv")
        let missingFile = try writeSamplesheet([("S1", "a.fastq")], named: "missing-file.csv", writesFiles: false)

        let cases: [(name: String, request: TaxTriageRunRequest, words: String)] = [
            ("no input", makeRequest(), "Provide either --input (with --sample) or --samplesheet"),
            ("both inputs", makeRequest(input: reads.path, samplesheet: duplicates.path), "Cannot use both --input and --samplesheet"),
            ("a missing samplesheet", makeRequest(samplesheet: missing), "Samplesheet not found: \(missing)"),
            ("an empty folder", makeRequest(input: empty.path), "No eligible FASTQ inputs found in \(empty.path)"),
            ("--input2 beside a folder", makeRequest(input: twoReads.path, input2: reads.path, sample: "S1"), "--input2 cannot be combined with a directory containing multiple inputs"),
            ("a missing R2", makeRequest(input: reads.path, input2: missing, sample: "S1"), "Input R2 file not found: \(missing)"),
            ("no database", makeRequest(input: reads.path, sample: "S1", database: .none), "A Kraken2 database is required: pass --db <path>"),
            ("a missing database", makeRequest(input: reads.path, sample: "S1", database: .at(URL(fileURLWithPath: missing))), "Database not found: \(missing)"),
            ("unparsable extra arguments", makeRequest(input: reads.path, sample: "S1", extraArguments: "--foo 'bar"), "Advanced options contain an unterminated ' quote."),
            ("a blank revision", makeRequest(input: reads.path, sample: "S1", revision: " "), "--revision is blank. Name a TaxTriage commit or tag, or leave out --revision to run the pinned version."),
            ("a confidence above 1", makeRequest(input: reads.path, sample: "S1", confidence: 1.5), "k2_confidence must be between 0.0 and 1.0, got 1.5"),
            ("no top hits", makeRequest(input: reads.path, sample: "S1", topHits: 0), "top_hits_count must be positive, got 0"),
            ("a duplicate in one launch", makeRequest(samplesheet: duplicates.path), "Duplicate sample IDs: S1"),
            ("a missing samplesheet file", makeRequest(samplesheet: missingFile.path), "Input file not found for sample 'S1': a.fastq"),
        ]
        let output = root.appendingPathComponent("out", isDirectory: true)
        for (name, request, words) in cases {
            let tool = makeTool(request)
            let error = await planError(tool, .directory(output))
            XCTAssertEqual(error?.localizedDescription, words, name)
            XCTAssertEqual((error as? any AnalysisRunExitCoding)?.analysisRunExitCode, 3, name)

            let report = await execute(tool, .directory(output))
            XCTAssertEqual(report.exitCode, 3, name)
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "\(name): a refused plan makes no folder")
        }

        // Each sample of a batch launches alone, so two samples of one name are two launches, as the
        // app's serial batch runs them.
        let batch = try await plan(makeTool(makeRequest(samplesheet: duplicates.path)), .directory(output), batch: true)
        XCTAssertEqual(batch.units.map(\.label), ["S1", "S1"])
    }

    // MARK: - Helpers

    static let customPin = PipelineSpec(
        id: "taxtriage",
        repository: "jhuapl-bio/taxtriage",
        revision: "0123456789abcdef0123456789abcdef01234567",
        releaseVersion: "v9.9.9"
    )

    static func lock(_ pipelines: PipelineSpec...) -> ManagedToolLock {
        ManagedToolLock(packID: "lungfish-tools", displayName: "Test lock", version: "test", tools: [], managedData: [], pipelines: pipelines)
    }

    /// Lists a folder's reads and bundles in path order, as `CLIClassificationFolderResolver` does for
    /// the command, and passes a file or a bundle through.
    static let expandFolder: @Sendable ([String], Bool) throws -> [URL] = { arguments, _ in
        try arguments.flatMap { argument -> [URL] in
            let url = URL(fileURLWithPath: argument).standardizedFileURL
            guard TaxTriageAnalysisRunTool.isFolder(url) else { return [url] }
            return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                .filter { FASTQBundle.isBundleURL($0) || ["fastq", "fq"].contains($0.pathExtension.lowercased()) }
                .map(\.standardizedFileURL)
                .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        }
    }

    enum DatabaseChoice {
        case installed
        case none
        case at(URL)
    }

    func makeRequest(
        input: String? = nil,
        input2: String? = nil,
        sample: String? = nil,
        samplesheet: String? = nil,
        revision: String? = nil,
        extraArguments: String = "",
        database: DatabaseChoice = .installed,
        confidence: Double = 0.2,
        topHits: Int = 10
    ) -> TaxTriageRunRequest {
        let databasePath: URL?
        switch database {
        case .installed: databasePath = self.database
        case .none: databasePath = nil
        case .at(let url): databasePath = url
        }
        return TaxTriageRunRequest(
            input: input,
            input2: input2,
            sampleID: sample,
            samplesheet: samplesheet,
            revision: revision,
            extraArguments: extraArguments,
            settings: TaxTriageConfig(
                samples: [],
                outputDirectory: root,
                kraken2DatabasePath: databasePath,
                topHitsCount: topHits,
                k2Confidence: confidence,
                maxCpus: 2
            )
        )
    }

    func makeTool(_ request: TaxTriageRunRequest, lock: ManagedToolLock = .bundled) -> TaxTriageAnalysisRunTool {
        TaxTriageAnalysisRunTool(
            request: request,
            services: TaxTriageRunServices(
                expandInputs: Self.expandFolder,
                materializer: ReadSetFixtures.StubMaterializer(readsByBundlePath: [:]),
                lock: lock
            )
        )
    }

    func runRequest(_ destination: AnalysisRunDestination, batch: Bool) -> AnalysisRunRequest {
        AnalysisRunRequest(inputs: [], destination: destination, groupsSamples: batch, commandLine: ["lungfish-cli", "taxtriage", "run"])
    }

    func plan(
        _ tool: TaxTriageAnalysisRunTool,
        _ destination: AnalysisRunDestination,
        batch: Bool = false
    ) async throws -> AnalysisRunPlan<TaxTriageRunUnit> {
        try await tool.plan(runRequest(destination, batch: batch), context: AnalysisRunPlanningContext(projectURL: destination.projectURL))
    }

    func planError(_ tool: TaxTriageAnalysisRunTool, _ destination: AnalysisRunDestination, batch: Bool = false) async -> Error? {
        do {
            _ = try await plan(tool, destination, batch: batch)
            return nil
        } catch {
            return error
        }
    }

    func execute(_ tool: TaxTriageAnalysisRunTool, _ destination: AnalysisRunDestination, batch: Bool = false) async -> AnalysisRunReport {
        await AnalysisRunExecutor.unsigned.execute(tool, runRequest(destination, batch: batch), events: .discarding)
    }

    @discardableResult
    func writeReads(_ name: String, in folder: URL? = nil) throws -> URL {
        let directory = folder ?? root.appendingPathComponent("loose", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try ReadSetFixtures.fastq(["\(name)-read"]).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @discardableResult
    func makeBundle(_ name: String, in folder: URL) throws -> URL {
        let bundle = folder.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try ReadSetFixtures.fastq(["\(name)-read"]).write(to: bundle.appendingPathComponent("reads.fastq"), atomically: true, encoding: .utf8)
        return bundle
    }

    /// A samplesheet of one single-end file per row, written beside its reads unless `writesFiles` is false.
    func writeSamplesheet(
        _ rows: [(sample: String, file: String)],
        named name: String = "samplesheet.csv",
        writesFiles: Bool = true
    ) throws -> URL {
        let folder = root.appendingPathComponent("reads-of-\(name.replacingOccurrences(of: ".csv", with: ""))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var lines = ["sample,fastq_1,fastq_2,platform"]
        for row in rows {
            let file = folder.appendingPathComponent(row.file)
            if writesFiles {
                try ReadSetFixtures.fastq(["\(row.sample)-read"]).write(to: file, atomically: true, encoding: .utf8)
            }
            lines.append("\(row.sample),\(file.path),,ILLUMINA")
        }
        let sheet = root.appendingPathComponent(name)
        try lines.joined(separator: "\n").write(to: sheet, atomically: true, encoding: .utf8)
        return sheet
    }

    func makeProject() throws -> URL {
        let project = root.appendingPathComponent("Fixture.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        return project
    }
}
