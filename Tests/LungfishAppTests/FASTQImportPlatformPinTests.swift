// FASTQImportPlatformPinTests.swift - Pins the platform the app passes to `import fastq` (R15)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishIO
import LungfishWorkflow
@testable import LungfishApp

/// The four-case platform `lungfish-cli import fastq --platform` accepts.
/// Before the R15 reconciliation it was a second public enum named
/// `SequencingPlatform`.
private typealias WorkflowPlatform = LungfishWorkflow.SequencingPlatform

/// Pins how the Import FASTQ sheet's platform, a `LungfishIO.SequencingPlatform`,
/// becomes the `--platform` value of the CLI import the app runs. Written
/// before the R15 reconciliation and expected to pass unchanged after it.
final class FASTQImportPlatformPinTests: XCTestCase {

    private let expectedSpellings: [(LungfishIO.SequencingPlatform, String)] = [
        (.illumina, "illumina"),
        (.oxfordNanopore, "ont"),
        (.pacbio, "pacbio"),
        (.element, "illumina"),
        (.ultima, "ultima"),
        (.mgi, "illumina"),
        (.unknown, "illumina"),
    ]

    func testEverySheetPlatformBecomesAnImportSpellingTheCLIAccepts() {
        XCTAssertEqual(expectedSpellings.map(\.0), LungfishIO.SequencingPlatform.allCases)
        for (platform, spelling) in expectedSpellings {
            let cliValue = FASTQIngestionService.cliPlatformString(for: platform)
            XCTAssertEqual(cliValue, spelling, platform.rawValue)
            XCTAssertNotNil(WorkflowPlatform(rawValue: cliValue), platform.rawValue)
        }
    }

    func testImportAndSRAArgumentsCarryTheImportSpelling() {
        let r1 = URL(fileURLWithPath: "/data/reads.fastq.gz")
        let project = URL(fileURLWithPath: "/projects/pin.lungfish")
        let pair = FASTQFilePair(r1: r1, r2: nil)
        for (platform, spelling) in expectedSpellings {
            let config = FASTQImportConfiguration(
                inputFiles: [r1],
                detectedPlatform: platform,
                confirmedPlatform: platform,
                pairingMode: .singleEnd,
                qualityBinning: .none,
                skipClumpify: true,
                deleteOriginals: false,
                postImportRecipe: nil,
                resolvedPlaceholders: [:],
                recipeName: nil,
                compressionLevel: .balanced
            )
            let importArguments = FASTQIngestionService.cliImportArguments(
                pair: pair, projectDirectory: project, importConfig: config
            )
            XCTAssertEqual(value(after: "--platform", in: importArguments), spelling, platform.rawValue)

            let sraArguments = DatabaseBrowserViewModel.sraImportCLIArguments(
                importConfig: config, r1: r1, r2: nil, projectDirectory: project
            )
            XCTAssertEqual(value(after: "--platform", in: sraArguments), spelling, platform.rawValue)
        }
    }

    private func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}
