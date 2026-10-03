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
private typealias WorkflowPlatform = LungfishWorkflow.IngestionPlatform

/// Pins how the Import FASTQ sheet's platform, a `LungfishIO.SequencingPlatform`,
/// becomes the `--platform` value of the CLI import the app runs. Written
/// before the R15 reconciliation and expected to pass unchanged after it.
final class FASTQImportPlatformPinTests: XCTestCase {

    // Element, MGI and Unknown used to be passed as illumina. They now keep
    // their own spelling (owner decision 3).
    private let expectedSpellings: [(LungfishIO.SequencingPlatform, String)] = [
        (.illumina, "illumina"),
        (.oxfordNanopore, "ont"),
        (.pacbio, "pacbio"),
        (.element, "element"),
        (.ultima, "ultima"),
        (.mgi, "mgi"),
        (.unknown, "unknown"),
    ]

    func testEverySheetPlatformBecomesAnImportSpellingTheCLIAccepts() {
        XCTAssertEqual(expectedSpellings.map(\.0), LungfishIO.SequencingPlatform.allCases)
        for (platform, spelling) in expectedSpellings {
            let cliValue = FASTQIngestionService.cliPlatformString(for: platform)
            XCTAssertEqual(cliValue, spelling, platform.rawValue)
            XCTAssertEqual(ImportPlatformRequest(cliValue: cliValue), .given(platform), platform.rawValue)
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
                platformIsUserChoice: true,
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

    /// An untouched Platform popup passes --platform auto, so the CLI infers
    /// each sample and records the source as inferred. The sheetless
    /// single-file import does the same. Nothing passes illumina by default.
    func testAnUntouchedPopupAndTheSheetlessPathPassAuto() {
        let r1 = URL(fileURLWithPath: "/data/reads.fastq.gz")
        let project = URL(fileURLWithPath: "/projects/pin.lungfish")
        let untouched = FASTQImportConfiguration(
            inputFiles: [r1], detectedPlatform: .oxfordNanopore, confirmedPlatform: .oxfordNanopore,
            pairingMode: .singleEnd, qualityBinning: .none, skipClumpify: true, deleteOriginals: false,
            postImportRecipe: nil, resolvedPlaceholders: [:], recipeName: nil, compressionLevel: .balanced
        )
        let arguments = FASTQIngestionService.cliImportArguments(
            pair: FASTQFilePair(r1: r1, r2: nil), projectDirectory: project, importConfig: untouched
        )
        XCTAssertEqual(value(after: "--platform", in: arguments), "auto")

        let sheetless = FASTQIngestionService.legacySingleFileImportConfiguration(for: r1)
        XCTAssertEqual(sheetless.cliPlatformValue, "auto")

        // An archive record's platform is recorded as given when kept, an unknown one stays auto.
        XCTAssertEqual(untouched.namingArchivePlatform(.oxfordNanopore).cliPlatformValue, "ont")
        XCTAssertEqual(untouched.namingArchivePlatform(.unknown).cliPlatformValue, "auto")
    }
}
