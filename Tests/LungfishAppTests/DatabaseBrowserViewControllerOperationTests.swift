// DatabaseBrowserViewControllerOperationTests.swift - begin() site in DatabaseBrowserViewModel
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The database browser registers its batch download row through a static begin
// helper (R4). The row is a download row and locks no bundle, so a reporter
// that refuses every begin stands in for a refusal and proves the launch
// closure sits behind the `.started` case. The recorded command is the closest
// `lungfish-cli fetch` command for the source. `fetch sra download` and `fetch
// genome` take one accession, so a single record must parse with the values
// the run uses, and a batch of several records keeps the flat accession list
// that the CLI rejects, which the tests pin as a CLI parity gap. A genome
// assembly names the project's Downloads folder, where the run puts the
// bundle (R3). `fetch ncbi`
// saves one GenBank file where the run builds a bundle for each record, so the
// NCBI nucleotide, NCBI virus and Pathoplexus rows are pinned as parity gaps
// too. A command added later fails a pin and prompts a parse test in its place.

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

    func testSRARunRecordsTheFetchSraDownloadCommandForOneRecord() throws {
        let item = try recordedRow(title: "SRR11140748", accessions: ["SRR11140748"], source: .ena)

        XCTAssertEqual(item.cliCommand, "lungfish-cli fetch sra download SRR11140748 --output-dir .")
        let command = try RecordedCLICommand.parse(item.cliCommand, as: SRADownloadSubcommand.self)
        XCTAssertEqual(command.accession, "SRR11140748")
        XCTAssertEqual(command.outputDir, ".")
        XCTAssertFalse(command.useToolkit)
    }

    func testSRARunBatchRecordsTheFlatAccessionListAsAParityGap() throws {
        let item = try recordedRow(
            title: "European Nucleotide Archive: SRR11140748, SRR11140749 +1 more",
            accessions: ["SRR11140748", "SRR11140749", "SRR11140750"],
            source: .ena
        )

        // CLI parity gap. `fetch sra download` takes one accession, so no single
        // command downloads the batch. The row keeps the flat list it recorded
        // before, which the CLI rejects. Running the command once per accession
        // is the closest reproduction. When a command takes several runs,
        // record it and replace this pin with a parse test.
        XCTAssertEqual(
            item.cliCommand,
            "lungfish-cli fetch sra download SRR11140748 SRR11140749 SRR11140750 --output-dir ."
        )
        XCTAssertThrowsError(try RecordedCLICommand.parse(item.cliCommand))
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

    func testGenomeAssemblyBatchRecordsTheFlatAccessionListAsAParityGap() throws {
        let item = try recordedRow(
            title: "Genome: GCF_003047895.1, GCF_000001405.40",
            accessions: ["GCF_003047895.1", "GCF_000001405.40"],
            source: .ncbi,
            searchType: .genome
        )

        // CLI parity gap. `fetch genome` takes one accession, so no single
        // command builds the batch. The row keeps the flat list, which the CLI
        // rejects. Running the command once per accession is the closest
        // reproduction. When a command takes several assemblies, record it and
        // replace this pin with a parse test.
        XCTAssertEqual(
            item.cliCommand,
            "lungfish-cli fetch genome GCF_003047895.1 GCF_000001405.40"
                + " --output-dir '/tmp/lane 1a2g/Project.lungfish/Downloads'"
        )
        XCTAssertThrowsError(try RecordedCLICommand.parse(item.cliCommand))
    }

    func testGenomeAssemblyWithNoProjectKeepsTheCurrentFolder() throws {
        // With no project in the route context the run picks the Downloads
        // folder of the window the download lands in, which the row cannot
        // know before the run, so the command keeps the current folder.
        let command = DatabaseBrowserViewModel.batchDownloadCLICommand(
            source: .ncbi,
            searchType: .genome,
            accessions: ["GCF_003047895.1"],
            projectURL: nil
        )
        XCTAssertEqual(command, "lungfish-cli fetch genome GCF_003047895.1 --output-dir .")
        XCTAssertEqual(try RecordedCLICommand.parse(command, as: GenomeSubcommand.self).outputDir, ".")
    }

    // MARK: - NCBI nucleotide and virus records, and Pathoplexus

    func testNucleotideAndVirusRowsKeepTheFetchNcbiCommandAsAParityGap() throws {
        for searchType in [NCBISearchType.nucleotide, .virus] {
            let item = try recordedRow(
                title: "GenBank: MN908947.3, NC_045512.2",
                accessions: ["MN908947.3", "NC_045512.2"],
                source: .ncbi,
                searchType: searchType
            )

            // CLI parity gap. The command parses, and it saves one GenBank file
            // where the run builds one `.lungfishref` bundle for each record. It
            // also refuses `--save-to .` at run time, because that path is a
            // directory. `fetch genome <accession>` also builds a bundle from a
            // nucleotide record, with a layout of its own, and is the closest
            // command. When a command reproduces the run, record it and replace
            // this pin.
            XCTAssertEqual(
                item.cliCommand,
                "lungfish-cli fetch ncbi MN908947.3 NC_045512.2 --save-to .",
                "\(searchType)"
            )
            let command = try RecordedCLICommand.parse(item.cliCommand, as: NCBISubcommand.self)
            XCTAssertEqual(command.accessions, ["MN908947.3", "NC_045512.2"])
            XCTAssertEqual(command.saveTo, ".", "a directory, which the command rejects when it writes")
            XCTAssertEqual(command.fetchFormat, "genbank", "the command saves a GenBank file, not a bundle")
        }
    }

    func testPathoplexusRowKeepsTheFetchNcbiCommandAsAParityGap() throws {
        let item = try recordedRow(
            title: "LOC_0001GA1.1",
            accessions: ["LOC_0001GA1.1"],
            source: .pathoplexus
        )

        // CLI parity gap. No fetch command reads Pathoplexus, and its accessions
        // are not NCBI accessions, so this string cannot reproduce the run. The
        // row keeps the value it recorded before until a Pathoplexus command
        // exists.
        XCTAssertEqual(item.cliCommand, "lungfish-cli fetch ncbi LOC_0001GA1.1 --save-to .")
        let command = try RecordedCLICommand.parse(item.cliCommand, as: NCBISubcommand.self)
        XCTAssertEqual(command.accessions, ["LOC_0001GA1.1"])
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
