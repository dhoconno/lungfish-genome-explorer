// ViewerEsVirituOperationTests.swift - begin() site in ViewerViewController+EsViritu
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The EsViritu viewer registers one row, the BLAST verification of a
// detection (R4). It locks no bundle. Since Phase 2.12 (lane 12.08) the row
// records the `lungfish-cli blast submit` command its search runs, and a test
// parses it. The row begins before the reads are extracted from the BAM, with
// no command, and takes its command once the reads have made the plan (review
// 12.08 fix 4), so Cancel and the stage word reach the row during the
// extraction. Three tests hold that order.

import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
@testable import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport

@MainActor
final class ViewerEsVirituOperationTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        try await super.setUp()
        folder = try TestTempDirectory.make(prefix: "esviritu-blast-row")
        OperationCenter.useTemporaryFailureReportsForTesting()
    }

    override func tearDown() async throws {
        TestTempDirectory.cleanup(folder)
        try await super.tearDown()
    }

    func testDetectionBlastRowRecordsItsTitleTypeAndNoLock() throws {
        let reporter = RecordingOperationReporter()
        var launchedID: UUID?

        ViewerViewController.beginEsVirituBlastVerificationOperation(
            taxonName: "Hepatitis B virus",
            reporter: reporter
        ) { launchedID = $0 }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(reporter.items.count, 1)
        XCTAssertEqual(launchedID, item.id)
        XCTAssertEqual(item.title, "BLAST Hepatitis B virus")
        XCTAssertEqual(item.initialDetail, "Preparing BLAST verification\u{2026}")
        XCTAssertEqual(item.operationType, .blastVerification)
        XCTAssertNil(item.targetBundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertNil(item.routeContext)
    }

    func testDetectionBlastRowRecordsTheBlastSubmitCommandItRuns() throws {
        let scratch = try TestTempDirectory.make(prefix: "esviritu-blast-begin")
        defer { TestTempDirectory.cleanup(scratch) }
        let project = scratch.appendingPathComponent("Project.lungfish", isDirectory: true)
        let result = project.appendingPathComponent("Analyses/esviritu-run", isDirectory: true)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        let detection = BlastSubmitParity.esVirituDetection(
            name: "Influenza A virus", species: "Alphainfluenzavirus influenzae", genus: "Alphainfluenzavirus"
        )
        // Six reads and a count of 4, so the subsample draws four.
        let reads = (1...6).map { (id: "read_\($0)", sequence: String(repeating: "ACGT", count: $0 + 2)) }
        let plan = try ViewerViewController.esVirituBlastSubmitPlan(
            detection: detection, reads: reads, readCount: 4, accessions: ["NC_026433.1"], projectURL: project,
            sourceResultURL: result
        )
        let reporter = RecordingOperationReporter()

        ViewerViewController.beginEsVirituBlastVerificationOperation(
            taxonName: detection.name,
            cliCommand: plan.cliCommand,
            reporter: reporter
        ) { _ in }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(item.cliCommand, plan.cliCommand)
        let command = try RecordedCLICommand.parse(item.cliCommand, as: BlastCommand.SubmitSubcommand.self)
        let stage = URL(fileURLWithPath: command.queryPath).deletingLastPathComponent()
        XCTAssertTrue(stage.lastPathComponent.hasPrefix("blast-submit-"), command.queryPath)
        XCTAssertEqual(stage.deletingLastPathComponent().lastPathComponent, ".tmp", "the query file sits in the project's .tmp")
        let output = URL(fileURLWithPath: command.outputPath).deletingLastPathComponent()
        XCTAssertEqual(output.lastPathComponent, "blast-verifications")
        XCTAssertEqual(output.deletingLastPathComponent().path, project.path, "the search sits under the project")
        XCTAssertEqual(command.label, "Influenza A virus")
        XCTAssertNil(command.taxId, "EsViritu names no tax ID")
        XCTAssertEqual(command.contig, "NC_026433.1", "the accession the reads came from")
        XCTAssertEqual(command.sample, "S1")
        XCTAssertEqual(command.sourceResult, result.path)
        XCTAssertEqual(command.subsampleCount, 4)
        XCTAssertEqual(command.subsampleSeed, 0)
        XCTAssertEqual(command.acceptedTaxIds, [])
        XCTAssertEqual(command.acceptedNames, ["Influenza A virus", "Alphainfluenzavirus influenzae"])
        XCTAssertEqual(command.relatedNames, ["Alphainfluenzavirus"], "the genus counts as a relative")
        XCTAssertEqual(command.globalOptions.outputFormat, .json)
        XCTAssertEqual(String(decoding: plan.queryData, as: UTF8.self).components(separatedBy: ">").count - 1, 4)
    }

    func testDetectionBlastLaunchesNothingWhenTheBeginIsRefused() {
        // No real center refuses this row, because it requests no lock. A
        // reporter that refuses every begin proves the launch closure sits
        // behind the `.started` case.
        let reporter = RecordingOperationReporter(lockHeldBy: "Importing BAM")
        var launched = false

        let result = ViewerViewController.beginEsVirituBlastVerificationOperation(
            taxonName: "Hepatitis B virus",
            reporter: reporter
        ) { _ in launched = true }

        guard case .refused = result else { return XCTFail("the helper must report the refusal") }
        XCTAssertFalse(launched, "a refused row must launch nothing")
        XCTAssertEqual(reporter.items.count, 1)
        XCTAssertEqual(reporter.items.first?.state, .refused)
    }

    // MARK: - The row begins before the extraction (review 12.08 fix 4, UX 3 and 4)

    /// While the reads are extracted the Operations panel shows one running BLAST row with the stage word and
    /// no command. Once the reads are in, the row takes the command of the plan they make before the leaf
    /// starts, so the command names the count the draw took.
    func testTheBlastRowBeginsBeforeTheExtractionAndTakesItsCommandAfterIt() async throws {
        let fixture = try makeFixture()
        let detection = Self.detection(named: "Influenza A virus (row order)")
        let gate = ExtractionGate()
        addTeardownBlock { await gate.open(with: []) }
        let spy = BlastDrawerSpy()
        let viewer = ViewerViewController()

        let task = viewer.launchEsVirituBlastSubmit(
            detection: detection, readCount: 2, accessions: ["NC_026433.1"], bamURL: fixture.bam, bamIndexURL: nil,
            resultURL: fixture.result, controller: nil, drawer: spy.drawer,
            runner: CLIBlastSubmitRunner(cliURLOverride: fixture.leaf), extractReads: { _, _, _, _ in try await gate.extract() },
            taxonomyContext: { _ in BlastTaxonomyContext(cladeTaxIds: [2955291], cladeNames: ["Influenza A virus"]) }
        )

        XCTAssertNotNil(task, "a project is open, so the search starts")
        let armed = await waitUntil(timeout: .seconds(10)) { await gate.started }
        XCTAssertTrue(armed, "the extraction never started")
        let row = try XCTUnwrap(self.row(titled: "BLAST \(detection.name)"), "no row while the reads are extracted")
        let id = row.id
        defer { OperationCenter.shared.clearItem(id: id) }
        XCTAssertEqual(row.state, .running)
        XCTAssertEqual(row.operationType, .blastVerification)
        XCTAssertEqual(row.detail, "Extracting reads for selected accessions\u{2026}")
        XCTAssertNil(row.cliCommand, "the command waits for the plan the reads make")
        XCTAssertEqual(spy.failures, [])

        await gate.open(with: Self.reads)
        let leafStarted = await waitUntil(timeout: .seconds(30)) { FileManager.default.fileExists(atPath: fixture.leafStarted.path) }
        XCTAssertTrue(leafStarted, "the leaf never started")
        let running = try XCTUnwrap(self.row(id))
        XCTAssertEqual(running.state, .running)
        let command = try RecordedCLICommand.parse(running.cliCommand, as: BlastCommand.SubmitSubcommand.self)
        XCTAssertEqual(command.contig, "NC_026433.1")
        XCTAssertEqual(command.subsampleCount, 2, "the count the draw took, which only the reads fix")
        XCTAssertEqual(command.sourceResult, fixture.result.path)
        XCTAssertEqual(command.label, detection.name)
        XCTAssertEqual(command.acceptedTaxIds, [2955291], "the search is judged by the taxonomy the launch read")

        OperationCenter.shared.cancel(id: id)
        let ended = await waitUntil(timeout: .seconds(15)) { self.row(id)?.state == .cancelled }
        XCTAssertTrue(ended, "the cancelled row never reached Cancelled")
    }

    /// A Cancel on the row while the reads are extracted ends the row cancelled and starts no search. The
    /// extraction is then let go, as a tool that ignores the signal would, and its reads reach nothing: no
    /// stage under the project's `.tmp`, no leaf, no alert and no failure in the drawer.
    func testCancellingTheRowDuringTheExtractionStartsNoSearch() async throws {
        let fixture = try makeFixture()
        let detection = Self.detection(named: "Influenza A virus (cancel in extraction)")
        let gate = ExtractionGate()
        addTeardownBlock { await gate.open(with: []) }
        let spy = BlastDrawerSpy()
        let presenter = RecordingNoProjectPresenter()
        let viewer = ViewerViewController()

        let launched = AppDelegate.NoProjectPresenterSeam.$presenter.withValue(presenter) {
            viewer.launchEsVirituBlastSubmit(
                detection: detection, readCount: 2, accessions: ["NC_026433.1"], bamURL: fixture.bam, bamIndexURL: nil,
                resultURL: fixture.result, controller: nil, drawer: spy.drawer,
                runner: CLIBlastSubmitRunner(cliURLOverride: fixture.leaf), extractReads: { _, _, _, _ in try await gate.extract() },
                taxonomyContext: { _ in
                    XCTFail("a row cancelled during the extraction reads no taxonomy")
                    return BlastTaxonomyContext()
                }
            )
        }
        let task = try XCTUnwrap(launched)
        let armed = await waitUntil(timeout: .seconds(10)) { await gate.started }
        XCTAssertTrue(armed, "the extraction never started")
        let row = try XCTUnwrap(self.row(titled: "BLAST \(detection.name)"), "no row to cancel while the reads are extracted")
        let id = row.id
        defer { OperationCenter.shared.clearItem(id: id) }

        OperationCenter.shared.cancel(id: id)
        XCTAssertEqual(self.row(id)?.state, .cancelling)
        await gate.open(with: Self.reads)
        await task.value

        let ended = try XCTUnwrap(self.row(id))
        XCTAssertEqual(ended.state, .cancelled)
        XCTAssertEqual(ended.detail, "Cancelled by user")
        XCTAssertNil(ended.errorMessage, "a cancel carries no failure text")
        XCTAssertNil(ended.cliCommand, "no plan was made, so the row never took a command")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.leafStarted.path), "no leaf, so no search")
        let stages = (try? FileManager.default.contentsOfDirectory(atPath: fixture.project.appendingPathComponent(".tmp").path)) ?? []
        XCTAssertEqual(stages.filter { $0.hasPrefix("blast-submit-") }, [], "no query was staged")
        XCTAssertEqual(spy.failures, [], "the drawer is told of no failure")
        XCTAssertEqual(spy.results.count, 0)
        XCTAssertEqual(presenter.presentations.count, 0, "a cancel shows no alert")
    }

    /// The taxonomy is read after the extraction and before the checks that guard the launch, so a Cancel while it is read
    /// ends the row cancelled, with no plan, no stage and no search.
    func testCancellingTheRowWhileTheTaxonomyIsReadStartsNoSearch() async throws {
        let fixture = try makeFixture()
        let detection = Self.detection(named: "Influenza A virus (cancel in taxonomy)")
        let gate = TaxonomyGate()
        addTeardownBlock { await gate.open() }
        let spy = BlastDrawerSpy()
        let reads = Self.reads
        let viewer = ViewerViewController()

        let launched = viewer.launchEsVirituBlastSubmit(
            detection: detection, readCount: 2, accessions: ["NC_026433.1"], bamURL: fixture.bam, bamIndexURL: nil,
            resultURL: fixture.result, controller: nil, drawer: spy.drawer,
            runner: CLIBlastSubmitRunner(cliURLOverride: fixture.leaf), extractReads: { _, _, _, _ in reads },
            taxonomyContext: { _ in await gate.read() }
        )
        let task = try XCTUnwrap(launched)
        let armed = await waitUntil(timeout: .seconds(10)) { await gate.started }
        XCTAssertTrue(armed, "the taxonomy was never read")
        let row = try XCTUnwrap(self.row(titled: "BLAST \(detection.name)"), "no row to cancel while the taxonomy is read")
        let id = row.id
        defer { OperationCenter.shared.clearItem(id: id) }

        OperationCenter.shared.cancel(id: id)
        await gate.open()
        await task.value

        let ended = try XCTUnwrap(self.row(id))
        XCTAssertEqual(ended.state, .cancelled)
        XCTAssertNil(ended.cliCommand, "no plan was made, so the row never took a command")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.leafStarted.path), "no leaf, so no search")
        XCTAssertEqual(spy.failures, [], "the drawer is told of no failure")
    }

    /// A failed extraction fails the row with the error's words and shows the same words once in the drawer.
    func testAnExtractionFailureFailsTheRowAndTheDrawer() async throws {
        let fixture = try makeFixture()
        let detection = Self.detection(named: "Influenza A virus (extraction failure)")
        let spy = BlastDrawerSpy()
        let viewer = ViewerViewController()

        let launched = viewer.launchEsVirituBlastSubmit(
            detection: detection, readCount: 2, accessions: ["NC_026433.1"], bamURL: fixture.bam, bamIndexURL: nil,
            resultURL: fixture.result, controller: nil, drawer: spy.drawer,
            runner: CLIBlastSubmitRunner(cliURLOverride: fixture.leaf), extractReads: { _, _, _, _ in throw BlastServiceError.noSequences }
        )
        let task = try XCTUnwrap(launched)
        await task.value

        let words = BlastServiceError.noSequences.localizedDescription
        let row = try XCTUnwrap(self.row(titled: "BLAST \(detection.name)"), "the failure reaches the Operations panel")
        defer { OperationCenter.shared.clearItem(id: row.id) }
        XCTAssertEqual(row.state, .failed)
        XCTAssertEqual(row.errorMessage, words)
        XCTAssertEqual(row.detail, words)
        XCTAssertNil(row.cliCommand, "no plan was made, so the row never took a command")
        XCTAssertEqual(spy.failures, [words], "the drawer shows the failure once")
        XCTAssertEqual(spy.results.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.leafStarted.path), "no leaf, so no search")
    }

    // MARK: - Judged at species level (lane BLAST-ESVIRITU-SPECIES, BIO-BLAST-WALK Q2)

    /// The walk's own read: its five hits in NCBI's order, the record's numbers, and the tax IDs NCBI gave. All five sit in
    /// one species, 3433757, and the first is a sibling of the claim. With the database's tax ID the read supports the row,
    /// and no order of the five changes that.
    func testEsVirituOC43WalkRunReadsSupportedAtSpeciesLevel() throws {
        let plan = try oc43Plan(taxonomyContext: oc43SpeciesContext())

        for order in [Self.oc43Hits, Self.oc43Hits.moving("PZ054573"), Self.oc43Hits.moving("OZ540695")] {
            let result = Self.judge(plan, hits: order)
            XCTAssertEqual(result.supportingCount, 1, order[0].accession)
            XCTAssertEqual(result.contradictingCount, 0, order[0].accession)
            XCTAssertEqual(result.confidence, .supported, order[0].accession)
            XCTAssertEqual(result.readResults[0].hasLCADisagreement, false, order[0].accession)
        }
    }

    /// Another species that shares the row's first word stays outside, and so does the genus above the species, so the
    /// first-word rule no longer judges a row with a lineage.
    func testEsVirituSpeciesCladeLeavesOtherHumanCoronavirusesOutside() throws {
        let plan = try oc43Plan(taxonomyContext: oc43SpeciesContext())

        let hku1 = Self.judge(plan, hits: [Self.oc43Hit("NC_006577.2", "Human coronavirus HKU1", 290028)])
        XCTAssertEqual(hku1.readResults[0].matchesQueriedTaxon, false, "HKU1 is another species of the subgenus")
        XCTAssertEqual(hku1.contradictingCount, 1)

        let genus = Self.judge(plan, hits: [Self.oc43Hit("MN996532.2", "Betacoronavirus", 694002)])
        XCTAssertEqual(genus.readResults[0].matchesQueriedTaxon, false, "a record filed at the genus sits above the species")
    }

    /// Without the database or the NCBI Taxonomy the row keeps its names, so the walk's read still reads as the walk read it.
    /// This pins the Known limit of the ruling, not a wanted result.
    func testEsVirituOC43WalkReadWithoutLineageStaysUnsupported() throws {
        let names = Self.oc43Detection.blastTaxonomyContext(databaseDirectory: nil, taxonomyDirectory: nil)
        let result = Self.judge(try oc43Plan(taxonomyContext: names), hits: Self.oc43Hits)

        XCTAssertEqual(result.supportingCount, 0)
        XCTAssertEqual(result.contradictingCount, 1)
        XCTAssertEqual(result.confidence, .unsupported)
    }

    // MARK: - Fixtures

    /// The walk's OC43 row, as EsViritu's result table writes it, with its rank prefixes.
    private static let oc43Detection = ViralDetection(
        sampleId: "SRR35517703", name: "Human coronavirus OC43", description: "Human coronavirus OC43 strain ATCC VR-759",
        length: 30_741, segment: nil, accession: "NC_006213.1", assembly: "GCF_003972325.1", assemblyLength: 30_741,
        kingdom: "k__Viruses", phylum: "p__Pisuviricota", tclass: "c__Pisoniviricetes", order: "o__Nidovirales",
        family: "f__Coronaviridae", genus: "g__Betacoronavirus", species: "s__Betacoronavirus 1",
        subspecies: "t__Human coronavirus OC43", rpkmf: 10, readCount: 2, coveredBases: 100, meanCoverage: 1,
        avgReadIdentity: 99, pi: 0, filteredReadsInSample: 1_000_000
    )

    /// One hit of the walk's read SRR35517703.5327004 (query length 100). Each saved hit aligned 98 of 98 at E 1.09818e-41.
    private static func oc43Hit(_ accession: String, _ organism: String, _ taxId: Int) -> BlastHit {
        BlastHit(
            accession: accession, title: organism, organism: organism, taxId: taxId,
            hsps: [BlastHSP(bitScore: 182.092, evalue: 1.09818e-41, identity: 98, alignLength: 98, queryFrom: 1, queryTo: 98)]
        )
    }

    private static let oc43Hits = [
        oc43Hit("PZ529564", "Canine respiratory coronavirus", 215681),
        oc43Hit("PZ054573", "Human coronavirus OC43", 31631), oc43Hit("PZ892151", "Human coronavirus OC43", 31631),
        oc43Hit("OZ540695", "Bovine coronavirus", 11128), oc43Hit("OZ540701", "Bovine coronavirus", 11128),
    ]

    /// The context the row takes from a temporary EsViritu table and NCBI dump that hold the real rows, cut to these IDs.
    private func oc43SpeciesContext() throws -> BlastTaxonomyContext {
        let database = folder.appendingPathComponent("v3.2.4", isDirectory: true)
        let taxonomy = folder.appendingPathComponent("ncbi-taxonomy", isDirectory: true)
        for directory in [database, taxonomy] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        try (
            "Accession\tName\tgenus\tspecies\tsubspecies\tTaxID\n"
                + "NC_006213.1\tHuman coronavirus OC43\tg__Betacoronavirus\ts__Betacoronavirus 1\tt__Human coronavirus OC43\t31631\n"
        ).write(to: database.appendingPathComponent("virus_pathogen_database.all_metadata.tsv"), atomically: true, encoding: .utf8)
        let nodes = [
            (694002, 2501931, "genus"), (2509481, 694002, "subgenus"), (3433757, 2509481, "species"),
            (694003, 3433757, "no rank"), (31631, 694003, "no rank"), (11128, 694003, "no rank"), (215681, 694003, "no rank"),
            (3433758, 2509481, "species"), (290028, 3433758, "no rank"),
        ]
        try nodes.map { "\($0.0)\t|\t\($0.1)\t|\t\($0.2)\t|\t\t|\t9\t|\n" }.joined()
            .write(to: taxonomy.appendingPathComponent("nodes.dmp"), atomically: true, encoding: .utf8)
        let names = [(31631, "Human coronavirus OC43"), (694003, "Betacoronavirus 1"), (3433757, "Betacoronavirus gravedinis")]
        try names.map { "\($0.0)\t|\t\($0.1)\t|\t\t|\tscientific name\t|\n" }.joined()
            .write(to: taxonomy.appendingPathComponent("names.dmp"), atomically: true, encoding: .utf8)
        return Self.oc43Detection.blastTaxonomyContext(databaseDirectory: database, taxonomyDirectory: taxonomy)
    }

    /// The plan of the walk's search, under `taxonomyContext`.
    private func oc43Plan(taxonomyContext: BlastTaxonomyContext) throws -> BlastSubmitPlan {
        let project = folder.appendingPathComponent("OC43.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        return try ViewerViewController.esVirituBlastSubmitPlan(
            detection: Self.oc43Detection, reads: [(id: "SRR35517703.5327004", sequence: "ACGT")], readCount: 1,
            accessions: ["NC_006213.1"], projectURL: project, taxonomyContext: taxonomyContext
        )
    }

    /// What `blast submit` reads from `plan` for one read with these hits, judged as the leaf judges them.
    private static func judge(_ plan: BlastSubmitPlan, hits: [BlastHit]) -> BlastVerificationResult {
        let readResults = BlastService(environment: [:]).assignVerdicts(
            searchResults: [BlastSearchResult(queryId: "SRR35517703.5327004", queryLength: 100, hits: hits)],
            eValueThreshold: 1e-10, queriedTaxonName: plan.request.label,
            acceptedTaxIds: Set(plan.request.acceptedTaxIds), acceptedTaxonNames: plan.request.acceptedNames,
            relatedTaxIds: Set(plan.request.relatedTaxIds), relatedTaxonNames: plan.request.relatedNames
        )
        return BlastVerificationResult(
            taxonName: plan.request.label, taxId: 0, readResults: readResults, submittedAt: Date(timeIntervalSince1970: 0),
            completedAt: nil, rid: "EFDUA8BD014", blastProgram: "blastn", database: "core_nt"
        )
    }

    /// Three reads of the selected accession, as the BAM extraction gives them.
    private static let reads: [(id: String, sequence: String)] = [
        (id: "read_1", sequence: "ACGTACGTACGTACGTACGT"), (id: "read_2", sequence: "GGCCTTAAGGCCTTAAGGCC"),
        (id: "read_3", sequence: "TTTTGGGGCCCCAAAATTTT"),
    ]

    private static func detection(named name: String) -> ViralDetection {
        BlastSubmitParity.esVirituDetection(name: name, species: "Alphainfluenzavirus influenzae", genus: "Alphainfluenzavirus")
    }

    /// A project with an EsViritu result and a stand-in `lungfish-cli` that records its process ID in
    /// `leafStarted` when it starts and then waits. The file's absence says no leaf ran.
    private struct Fixture {
        let project: URL
        let result: URL
        let bam: URL
        let leaf: URL
        let leafStarted: URL
    }

    private func makeFixture() throws -> Fixture {
        let project = folder.appendingPathComponent("Project.lungfish", isDirectory: true)
        let result = project.appendingPathComponent("Analyses/esviritu-run", isDirectory: true)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        let started = folder.appendingPathComponent("leaf.started")
        let partial = folder.appendingPathComponent("leaf.started.partial")
        let leaf = folder.appendingPathComponent("lungfish-cli-\(UUID().uuidString)")
        let script = "#!/bin/sh\n/bin/echo $$ > '\(partial.path)'\n/bin/mv '\(partial.path)' '\(started.path)'\nexec /bin/sleep 30\n"
        try script.write(to: leaf, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: leaf.path)
        return Fixture(
            project: project, result: result, bam: result.appendingPathComponent("sample.bam"), leaf: leaf, leafStarted: started
        )
    }

    private func row(titled title: String) -> OperationCenter.Item? {
        OperationCenter.shared.items.first { $0.title == title }
    }

    private func row(_ id: UUID) -> OperationCenter.Item? {
        OperationCenter.shared.items.first { $0.id == id }
    }
}

private extension Array where Element == BlastHit {
    /// The same hits with the first of `accession` listed first, as NCBI may list hits tied at one score.
    func moving(_ accession: String) -> [BlastHit] {
        filter { $0.accession == accession } + filter { $0.accession != accession }
    }
}

/// What the drawer of a BLAST action was told, in order.
@MainActor
private final class BlastDrawerSpy {
    private(set) var phases: [BlastJobPhase] = []
    private(set) var results: [BlastVerificationResult] = []
    private(set) var failures: [String] = []

    var drawer: BlastSubmitDrawer {
        BlastSubmitDrawer(
            loading: { [self] phase in phases.append(phase) },
            results: { [self] result, _ in results.append(result) },
            failure: { [self] text in failures.append(text) }
        )
    }
}

/// A stand-in for the taxonomy read that waits for the test, so a Cancel can land while it runs.
private actor TaxonomyGate {
    private var continuation: CheckedContinuation<BlastTaxonomyContext, Never>?
    private(set) var started = false

    func read() async -> BlastTaxonomyContext {
        started = true
        return await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        continuation?.resume(returning: BlastTaxonomyContext())
        continuation = nil
    }
}

/// A stand-in for the BAM extraction that waits for the test, so the row can be read while the extraction
/// runs. `open` lets it return the reads it is handed.
private actor ExtractionGate {
    private var continuation: CheckedContinuation<[(id: String, sequence: String)], any Error>?
    private(set) var started = false

    func extract() async throws -> [(id: String, sequence: String)] {
        started = true
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func open(with reads: [(id: String, sequence: String)]) {
        continuation?.resume(returning: reads)
        continuation = nil
    }
}
