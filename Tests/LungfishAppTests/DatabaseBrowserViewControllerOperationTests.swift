// DatabaseBrowserViewControllerOperationTests.swift - begin() site in DatabaseBrowserViewModel
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The database browser registers its batch download row through a static begin
// helper (R4). The row is a download row and locks no bundle, so a reporter
// that refuses every begin stands in for a refusal and proves the launch
// closure sits behind the `.started` case. Only one NCBI genome assembly
// records a command, `fetch genome`, which must parse with the values the run
// uses and names the project's Downloads folder, where the run puts the
// bundle (R3). SRA runs, genome batches, NCBI nucleotide and virus records and
// Pathoplexus records record no command, and the tests pin each as a CLI
// parity gap. A command added later fails a pin and prompts a parse test in
// its place.

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishCore
import LungfishKit
import LungfishKitTestSupport

@MainActor
final class DatabaseBrowserViewControllerOperationTests: XCTestCase {
    private let routeContext = OperationRouteContext(
        projectURL: URL(fileURLWithPath: "/tmp/lane 1a2g/Project.lungfish"),
        windowStateScopeID: UUID()
    )

    /// Registers the batch download row on a recording reporter and checks what
    /// every row shares.
    private func recordedRow(
        title: String,
        accessions: [String],
        source: DatabaseSource,
        searchType: NCBISearchType = .nucleotide
    ) throws -> RecordingOperationReporter.Item {
        let reporter = RecordingOperationReporter()
        var launchedID: UUID?

        let result = DatabaseBrowserViewModel.beginBatchDownloadOperation(
            title: title,
            accessions: accessions,
            source: source,
            searchType: searchType,
            routeContext: routeContext,
            reporter: reporter
        ) { launchedID = $0 }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(reporter.items.count, 1)
        XCTAssertEqual(result.startedID, item.id)
        XCTAssertEqual(launchedID, item.id)
        XCTAssertEqual(item.title, title)
        XCTAssertEqual(item.initialDetail, "Preparing \(accessions.count) record(s)...")
        XCTAssertEqual(item.operationType, .download)
        XCTAssertNil(item.targetBundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertEqual(item.routeContext, routeContext)
        return item
    }

    // MARK: - SRA runs

    func testSRARunsRecordNoCommandAsAParityGap() throws {
        // `fetch sra download` downloads one run and stops. The run then
        // imports the FASTQ files into the project with the settings the user
        // confirmed in the import sheet, which no command does, so no SRA row
        // records a command, for one run or several.
        for accessions in [["SRR11140748"], ["SRR11140748", "SRR11140749", "SRR11140750"]] {
            let item = try recordedRow(title: accessions.joined(separator: ", "), accessions: accessions, source: .ena)
            XCTAssertNil(item.cliCommand, "\(accessions)")
            assertCLIParityGap(item.cliCommand, id: "download-sra")
        }
    }

    // MARK: - NCBI genome assemblies

    func testGenomeAssemblyRecordsTheFetchGenomeCommandForOneRecord() throws {
        let item = try recordedRow(
            title: "GCF_003047895.1",
            accessions: ["GCF_003047895.1"],
            source: .ncbi,
            searchType: .genome
        )

        // The row used to record `fetch genome --accession <accessions> -o .`,
        // which the CLI never parsed, and then `--output-dir .`, the shell's
        // current folder. The run copies the bundle it builds into the
        // project's Downloads folder, which the command now names.
        XCTAssertEqual(
            item.cliCommand,
            "lungfish-cli fetch genome GCF_003047895.1 --output-dir '/tmp/lane 1a2g/Project.lungfish/Downloads'"
        )
        XCTAssertFalse(item.cliCommand?.contains("--accession") ?? true)
        let command = try RecordedCLICommand.parse(item.cliCommand, as: GenomeSubcommand.self)
        XCTAssertEqual(command.accession, "GCF_003047895.1")
        XCTAssertEqual(command.outputDir, "/tmp/lane 1a2g/Project.lungfish/Downloads")
        XCTAssertNil(command.name)
        XCTAssertFalse(command.fastaOnly)
        XCTAssertFalse(command.noBundle)
    }

    func testGenomeAssemblyBatchRecordsNoCommandAsAParityGap() throws {
        let item = try recordedRow(
            title: "Genome: GCF_003047895.1, GCF_000001405.40",
            accessions: ["GCF_003047895.1", "GCF_000001405.40"],
            source: .ncbi,
            searchType: .genome
        )

        // `fetch genome` takes one accession, so no single command builds the
        // batch, and the row records no command.
        XCTAssertNil(item.cliCommand)
        assertCLIParityGap(item.cliCommand, id: "download-genome-batch")
    }

    func testGenomeAssemblyWithNoProjectRecordsNoCommandAsAParityGap() throws {
        // With no project in the route context the run picks the Downloads
        // folder of the window the download lands in, which the row cannot
        // know before the run. A relative `--output-dir .` would break the
        // absolute-path rule, so the row records no command.
        let reporter = RecordingOperationReporter()
        DatabaseBrowserViewModel.beginBatchDownloadOperation(
            title: "GCF_003047895.1",
            accessions: ["GCF_003047895.1"],
            source: .ncbi,
            searchType: .genome,
            routeContext: nil,
            reporter: reporter
        ) { _ in }
        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertNil(item.cliCommand)
        assertCLIParityGap(item.cliCommand, id: "download-genome-no-project")
    }

    // MARK: - NCBI nucleotide and virus records, and Pathoplexus

    func testNucleotideAndVirusRowsRecordNoCommandAsAParityGap() throws {
        for searchType in [NCBISearchType.nucleotide, .virus] {
            let item = try recordedRow(
                title: "GenBank: MN908947.3, NC_045512.2",
                accessions: ["MN908947.3", "NC_045512.2"],
                source: .ncbi,
                searchType: searchType
            )

            // `fetch ncbi` saves one GenBank file where the run builds one
            // `.lungfishref` bundle for each record. `fetch genome
            // <accession>` also builds a bundle from a nucleotide record, with
            // a layout of its own, and is the closest command.
            XCTAssertNil(item.cliCommand, "\(searchType)")
            assertCLIParityGap(item.cliCommand, id: "download-ncbi-bundle")
        }
    }

    func testPathoplexusRowRecordsNoCommandAsAParityGap() throws {
        let item = try recordedRow(
            title: "LOC_0001GA1.1",
            accessions: ["LOC_0001GA1.1"],
            source: .pathoplexus
        )

        // No fetch command reads Pathoplexus, and its accessions are not NCBI
        // accessions.
        XCTAssertNil(item.cliCommand)
        assertCLIParityGap(item.cliCommand, id: "download-pathoplexus")
    }

    // MARK: - Refusal

    func testRefusedBatchDownloadLaunchesNothing() {
        // No real center refuses this row, because it requests no lock. A
        // reporter that refuses every begin proves the launch closure sits
        // behind the `.started` case, for every source.
        let reporter = RecordingOperationReporter(lockHeldBy: "Importing BAM")
        var launched = 0

        for (source, searchType) in [
            (DatabaseSource.ena, NCBISearchType.nucleotide),
            (.ncbi, .genome),
            (.ncbi, .nucleotide),
            (.pathoplexus, .nucleotide),
        ] {
            let result = DatabaseBrowserViewModel.beginBatchDownloadOperation(
                title: "Download",
                accessions: ["ACC1"],
                source: source,
                searchType: searchType,
                routeContext: routeContext,
                reporter: reporter
            ) { _ in launched += 1 }
            XCTAssertNil(result.startedID, "\(source) \(searchType)")
        }

        XCTAssertEqual(launched, 0, "a refused row must launch nothing")
        XCTAssertEqual(reporter.items.count, 4)
        XCTAssertTrue(reporter.items.allSatisfy { $0.state == .refused })
    }
}
