// DatabaseBrowserSRARowLaunchTests.swift - The route of the SRA browser's rows
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A45 M3, panel decision C4. An SRA run of the browser's batch download runs
// `lungfish-cli fetch sra download <run> --bundle`, its only route since Phase 2.11 deleted the in-process
// route with its hidden key (K3). The row begins before the import sheet, so
// the command it records holds the sheet's flags and is set once the sheet is confirmed.

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow

final class DatabaseBrowserSRARowLaunchTests: XCTestCase {
    private let project = URL(fileURLWithPath: "/tmp/lane a45/Project.lungfish")

    /// Every spelling the sheet can produce reaches the leaf as the window passes it to `import fastq`,
    /// in the same order, and the key never travels in the arguments.
    func testTheFlagsAreTheWindowsImportFlagsForEverySheetValue() {
        let sheets: [(String, FASTQImportConfiguration)] = [
            ("untouched", sheet()),
            ("ont and single", sheet(platform: .oxfordNanopore, pairing: .singleEnd)),
            ("interleaved", sheet(pairing: .interleaved)),
            ("binned", sheet(binning: .illumina4)),
            ("maximum compression", sheet(compression: .maximum)),
            ("a recipe", sheet(recipe: "illumina-pe-clean")),
            ("no optimize", sheet(skipClumpify: true)),
            ("a tool", sheet(tool: .bbtools)),
        ]
        for (label, config) in sheets {
            let window = DatabaseBrowserViewModel.sraImportCLIArguments(
                importConfig: config, r1: URL(fileURLWithPath: "/stage/SRR1.fastq.gz"), r2: nil, projectDirectory: project)
            // `import fastq <file> --project <folder>` then the flags, with `--format json` among them.
            var flags = Array(window.dropFirst(5))
            let format = flags.firstIndex(of: "--format")
            if let format { flags.removeSubrange(format...(format + 1)) }
            XCTAssertNotNil(format, label)
            for preferNCBI in [false, true] {
                let args = DatabaseBrowserViewModel.sraFetchArguments(
                    accession: "SRR1", importConfig: config, project: project, preferNCBI: preferNCBI)
                XCTAssertEqual(
                    args,
                    ["fetch", "sra", "download", "SRR1", "--bundle", "--project", project.path] + flags
                        + (preferNCBI ? ["--prefer-source", "ncbi"] : []) + ["--format", "json"],
                    "\(label) \(preferNCBI)")
                XCTAssertFalse(args.contains("--api-key"), label)
            }
        }
    }

    /// One line for each run in run order, and each line parses with the values the run uses.
    func testTheCommandIsOneParsedLinePerRunInRunOrder() throws {
        let config = sheet(platform: .illumina, pairing: .pairedEnd, binning: .illumina4, recipe: "illumina-pe-clean")
        let lists = ["SRR1", "SRR2"].map {
            DatabaseBrowserViewModel.sraFetchArguments(accession: $0, importConfig: config, project: project, preferNCBI: true)
        }
        let command = DatabaseBrowserViewModel.sraRowCLICommand(arguments: lists)
        let lines = command.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasPrefix("lungfish-cli fetch sra download SRR1 --bundle --project "), lines[0])
        XCTAssertTrue(lines[1].hasPrefix("lungfish-cli fetch sra download SRR2 --bundle --project "), lines[1])
        for (line, run) in zip(lines, ["SRR1", "SRR2"]) {
            let parsed = try RecordedCLICommand.parse(line, as: SRADownloadSubcommand.self)
            XCTAssertEqual(parsed.accession, run)
            XCTAssertTrue(parsed.bundle)
            XCTAssertEqual(parsed.project, project.path)
            XCTAssertEqual(parsed.preferSource, .ncbi)
            XCTAssertEqual(parsed.importOptions.platform, "illumina")
            XCTAssertEqual(parsed.importOptions.pairing, "paired")
            XCTAssertEqual(parsed.importOptions.qualityBinning, "illumina4")
            XCTAssertEqual(parsed.importOptions.recipe, "illumina-pe-clean")
            XCTAssertEqual(parsed.globalOptions.outputFormat, .json)
        }
    }

    // MARK: - Sheets

    private func sheet(
        platform: LungfishIO.SequencingPlatform? = nil,
        pairing: FASTQIngestionConfig.PairingMode? = nil,
        binning: QualityBinningScheme = .none,
        skipClumpify: Bool = false,
        tool: ClumpingTool = .auto,
        recipe: String? = nil,
        compression: CompressionLevel? = .balanced
    ) -> FASTQImportConfiguration {
        FASTQImportConfiguration(
            inputFiles: [],
            detectedPlatform: .illumina,
            confirmedPlatform: platform ?? .illumina,
            platformIsUserChoice: platform != nil,
            pairingMode: pairing ?? .singleEnd,
            pairingModeIsUserChoice: pairing != nil,
            qualityBinning: binning,
            skipClumpify: skipClumpify,
            clumpingTool: tool,
            deleteOriginals: false,
            postImportRecipe: nil,
            resolvedPlaceholders: [:],
            recipeName: recipe,
            compressionLevel: compression)
    }
}
