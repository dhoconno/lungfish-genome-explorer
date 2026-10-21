// DatabaseBrowserViewControllerOperationTests.swift - begin() site in DatabaseBrowserViewModel
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The database browser registers its batch download row through a static begin
// helper (R4). The row is a download row and locks no bundle, so a reporter
// that refuses every begin stands in for a refusal and proves the launch
// closure sits behind the `.started` case. NCBI genome assemblies with a
// project, one or a batch, record `fetch genome`, which must parse with the
// values the run uses and names the folder the run writes the bundles into
// (R3, lane A44). NCBI nucleotide and virus records with a project record
// `fetch ncbi --bundle`, which must parse the same way (lane A45), and
// Pathoplexus records with a project record `fetch pathoplexus` (lane A45).
// SRA runs begin with no command, which their route sets for each run when the
// import sheet is confirmed. A download with no project registers no row and
// says No Project Open (DatabaseBrowserNoProjectDownloadRefusalTests, lane A60).

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
        searchType: NCBISearchType = .nucleotide,
        pathoplexusOrganism: String? = nil
    ) throws -> RecordingOperationReporter.Item {
        let reporter = RecordingOperationReporter()
        var launchedID: UUID?

        let result = DatabaseBrowserViewModel.beginBatchDownloadOperation(
            title: title,
            accessions: accessions,
            source: source,
            searchType: searchType,
            routeContext: routeContext,
            pathoplexusOrganism: pathoplexusOrganism,
            reporter: reporter
        ) { launchedID = $0 }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(reporter.items.count, 1)
        XCTAssertEqual(result?.startedID, item.id)
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

    func testSRARunsBeginWithNoCommandBecauseTheRouteSetsOneForEachRun() throws {
        // The import sheet comes after the row, and its settings are flags of
        // `fetch sra download`, so the row begins with no command, for one run
        // or several. That is no longer a parity gap (the ratchet carries no
        // `download-sra` id and no test pins one). `startSRADownloadTask` sets
        // one line for each run when the sheet is confirmed, which
        // DatabaseBrowserSRARowLaunchTests and DatabaseBrowserSRARowLaunchReplayTests
        // parse and replay.
        for accessions in [["SRR11140748"], ["SRR11140748", "SRR11140749", "SRR11140750"]] {
            let item = try recordedRow(title: accessions.joined(separator: ", "), accessions: accessions, source: .ena)
            XCTAssertNil(item.cliCommand, "\(accessions)")
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
        // current folder. The run writes the bundle into the project's
        // Downloads folder, which the command names, and reads its events.
        XCTAssertEqual(
            item.cliCommand,
            "lungfish-cli fetch genome GCF_003047895.1 --output-dir '/tmp/lane 1a2g/Project.lungfish/Downloads' --format json"
        )
        XCTAssertFalse(item.cliCommand?.contains("--accession") ?? true)
        let command = try RecordedCLICommand.parse(item.cliCommand, as: GenomeSubcommand.self)
        XCTAssertEqual(command.accessions, ["GCF_003047895.1"])
        XCTAssertEqual(command.outputDir, "/tmp/lane 1a2g/Project.lungfish/Downloads")
        XCTAssertEqual(command.globalOptions.outputFormat, .json)
        XCTAssertNil(command.name)
        XCTAssertNil(command.intoBundle)
        XCTAssertNil(command.apiKey)
        XCTAssertFalse(command.fastaOnly)
        XCTAssertFalse(command.noBundle)
    }

    func testGenomeAssemblyBatchRecordsOneFetchGenomeCommandForEveryAccession() throws {
        let item = try recordedRow(
            title: "Genome: GCF_003047895.1, GCF_000001405.40",
            accessions: ["GCF_003047895.1", "GCF_000001405.40"],
            source: .ncbi,
            searchType: .genome
        )

        // `fetch genome` takes several accessions since lane A44. The run
        // launches it for each row, and each bundle's record names its own
        // accession, so one command with every accession builds the batch.
        let command = try RecordedCLICommand.parse(item.cliCommand, as: GenomeSubcommand.self)
        XCTAssertEqual(command.accessions, ["GCF_003047895.1", "GCF_000001405.40"])
        XCTAssertEqual(command.outputDir, "/tmp/lane 1a2g/Project.lungfish/Downloads")
        XCTAssertEqual(command.globalOptions.outputFormat, .json)
        XCTAssertNil(command.name)
    }

    // MARK: - NCBI nucleotide and virus records (lane A45), and Pathoplexus

    func testNucleotideAndVirusRowsRecordTheFetchNCBIBundleCommand() throws {
        for searchType in [NCBISearchType.nucleotide, .virus] {
            let item = try recordedRow(
                title: "GenBank: MN908947.3, NC_045512.2",
                accessions: ["MN908947.3", "NC_045512.2"],
                source: .ncbi,
                searchType: searchType
            )

            // The row built a `.lungfishref` bundle for each record while `fetch ncbi`
            // saved one GenBank file. `--bundle` builds the browser's bundles, and the run
            // writes them into the project's Downloads folder, which the command names.
            XCTAssertEqual(
                item.cliCommand,
                "lungfish-cli fetch ncbi MN908947.3 NC_045512.2 --bundle "
                    + "--output-dir '/tmp/lane 1a2g/Project.lungfish/Downloads' --format json",
                "\(searchType)")
            let command = try RecordedCLICommand.parse(item.cliCommand, as: NCBISubcommand.self)
            XCTAssertTrue(command.bundle)
            XCTAssertEqual(command.accessions, ["MN908947.3", "NC_045512.2"])
            XCTAssertEqual(command.outputDir, "/tmp/lane 1a2g/Project.lungfish/Downloads")
            XCTAssertEqual(command.globalOptions.outputFormat, .json)
            XCTAssertFalse(command.noGFF3)
            XCTAssertNil(command.apiKey, "the key reaches the child through its environment")
            XCTAssertNil(command.saveTo)
        }
    }

    func testTheGFF3SettingTurnedOffRecordsNoGFF3() throws {
        let reporter = RecordingOperationReporter()
        DatabaseBrowserViewModel.beginBatchDownloadOperation(
            title: "MN908947.3",
            accessions: ["MN908947.3"],
            source: .ncbi,
            searchType: .nucleotide,
            routeContext: routeContext,
            includeGFF3Annotations: false,
            reporter: reporter
        ) { _ in }
        let item = try XCTUnwrap(reporter.items.first)
        let command = try RecordedCLICommand.parse(item.cliCommand, as: NCBISubcommand.self)
        XCTAssertTrue(command.noGFF3)
        XCTAssertTrue(command.bundle)
    }

    func testPathoplexusRowsRecordTheFetchPathoplexusCommand() throws {
        let item = try recordedRow(
            title: "PP_0012345, PP_0012346",
            accessions: ["PP_0012345", "PP_0012346"],
            source: .pathoplexus,
            pathoplexusOrganism: "mpox"
        )

        // Its accessions are not NCBI accessions, so the organism names the Pathoplexus the records
        // are read from, and the run writes the bundles into the project's Downloads folder.
        XCTAssertEqual(
            item.cliCommand,
            "lungfish-cli fetch pathoplexus PP_0012345 PP_0012346 --organism mpox "
                + "--output-dir '/tmp/lane 1a2g/Project.lungfish/Downloads' --format json")
        let command = try RecordedCLICommand.parse(item.cliCommand, as: PathoplexusSubcommand.self)
        XCTAssertEqual(command.accessions, ["PP_0012345", "PP_0012346"])
        XCTAssertEqual(command.organism, "mpox")
        XCTAssertEqual(command.outputDir, "/tmp/lane 1a2g/Project.lungfish/Downloads")
        XCTAssertEqual(command.globalOptions.outputFormat, .json)
        XCTAssertFalse(command.noGFF3)
        XCTAssertNil(command.apiKey, "the key reaches the child through its environment")
    }

    func testThePathoplexusGFF3SettingTurnedOffRecordsNoGFF3() throws {
        let reporter = RecordingOperationReporter()
        DatabaseBrowserViewModel.beginBatchDownloadOperation(
            title: "PP_0012345",
            accessions: ["PP_0012345"],
            source: .pathoplexus,
            searchType: .nucleotide,
            routeContext: routeContext,
            includeGFF3Annotations: false,
            pathoplexusOrganism: "mpox",
            reporter: reporter
        ) { _ in }
        let command = try RecordedCLICommand.parse(
            try XCTUnwrap(reporter.items.first).cliCommand, as: PathoplexusSubcommand.self)
        XCTAssertTrue(command.noGFF3)
    }

    func testPathoplexusRowWithNoOrganismRecordsNoCommand() throws {
        // The browser refuses a Pathoplexus download with no organism selected, so a row never gets
        // here without one. The command would not parse without it, so it records nil.
        let item = try recordedRow(title: "PP_0012345", accessions: ["PP_0012345"], source: .pathoplexus)
        XCTAssertNil(item.cliCommand)
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
            XCTAssertNotNil(result, "\(source) \(searchType): a row with a project reaches the reporter")
            XCTAssertNil(result?.startedID, "\(source) \(searchType)")
        }

        XCTAssertEqual(launched, 0, "a refused row must launch nothing")
        XCTAssertEqual(reporter.items.count, 4)
        XCTAssertTrue(reporter.items.allSatisfy { $0.state == .refused })
    }
}
