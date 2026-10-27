// SRAImportCLIArgumentsSheetPinTests.swift - Every Import sheet value, as the SRA row hands it to lungfish-cli import fastq
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A45 M3, ruling A45-M3 section 1. The SRA row imports each run it downloads with the
// settings of the Import FASTQ sheet, as the argument vector `sraImportCLIArguments` builds. M3 moves
// the row onto `fetch sra download --bundle`, whose flags are those of `CLIImportRunner.buildCLIArguments`
// with the same names and values. This pin passes at the base and fixes every spelling the sheet can
// produce, one setting at a time from an untouched sheet, so the leaf's flags are parsed from the same
// table (`tail` below is the part after `--project <folder>`). A value that reads differently on either
// side fails here first.

import XCTest
import LungfishIO
import LungfishWorkflow
@testable import LungfishApp

final class SRAImportCLIArgumentsSheetPinTests: XCTestCase {
    private let r1 = URL(fileURLWithPath: "/stage/SRR1_1.fastq.gz")
    private let r2 = URL(fileURLWithPath: "/stage/SRR1_2.fastq.gz")
    private let unpaired = URL(fileURLWithPath: "/stage/SRR1.fastq.gz")
    private let single = URL(fileURLWithPath: "/stage/SRR1.fastq.gz")
    private let project = URL(fileURLWithPath: "/projects/demo.lungfish")

    /// A sheet with the settings given. A nil platform or pairing is the popup left as the sheet proposed it.
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

    private func arguments(_ config: FASTQImportConfiguration, files: Files = .pair) -> [String] {
        DatabaseBrowserViewModel.sraImportCLIArguments(
            importConfig: config,
            r1: files == .single ? single : r1,
            r2: files == .single ? nil : r2,
            unpaired: files == .triple ? unpaired : nil,
            projectDirectory: project)
    }

    private enum Files { case single, pair, triple }

    private func head(_ files: Files) -> [String] {
        switch files {
        case .single: ["import", "fastq", single.path, "--project", project.path]
        case .pair: ["import", "fastq", r1.path, r2.path, "--project", project.path]
        case .triple: ["import", "fastq", r1.path, r2.path, unpaired.path, "--project", project.path]
        }
    }

    private func assertArguments(
        _ config: FASTQImportConfiguration, files: Files = .pair, tail: [String], _ label: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(arguments(config, files: files), head(files) + tail, label, file: file, line: line)
    }

    func testAnUntouchedSheetNamesAutoPlatformAndPairsAPairedRun() {
        assertArguments(
            sheet(),
            tail: ["--platform", "auto", "--pairing", "paired", "--format", "json", "--quality-binning", "none", "--compression", "balanced"],
            "an untouched sheet")
    }

    func testEachPlatformKeepsItsImportSpelling() {
        let spellings: [(LungfishIO.SequencingPlatform, String)] = [
            (.illumina, "illumina"), (.oxfordNanopore, "ont"), (.pacbio, "pacbio"), (.element, "element"),
            (.ultima, "ultima"), (.mgi, "mgi"), (.unknown, "unknown"),
        ]
        XCTAssertEqual(spellings.map(\.0), LungfishIO.SequencingPlatform.allCases)
        for (platform, spelling) in spellings {
            assertArguments(
                sheet(platform: platform),
                tail: ["--platform", spelling, "--pairing", "paired", "--format", "json", "--quality-binning", "none", "--compression", "balanced"],
                "platform \(platform.rawValue)")
        }
    }

    func testEachQualityBinningAndCompressionKeepsItsSpelling() {
        for (binning, spelling) in [(QualityBinningScheme.none, "none"), (.fiveStep, "fiveStep"), (.illumina4, "illumina4"), (.eightLevel, "eightLevel")] {
            assertArguments(
                sheet(binning: binning),
                tail: ["--platform", "auto", "--pairing", "paired", "--format", "json", "--quality-binning", spelling, "--compression", "balanced"],
                "quality binning \(spelling)")
        }
        XCTAssertEqual(QualityBinningScheme.allCases.count, 4)
        for (level, spelling) in [(CompressionLevel.fast, "fast"), (.balanced, "balanced"), (.maximum, "maximum"), (nil, "balanced")] {
            assertArguments(
                sheet(compression: level),
                tail: ["--platform", "auto", "--pairing", "paired", "--format", "json", "--quality-binning", "none", "--compression", spelling],
                "compression \(spelling)")
        }
        XCTAssertEqual(CompressionLevel.allCases.count, 3)
    }

    func testTheRecipeAndTheStorageToolComeAfterTheCompression() {
        let base = ["--platform", "auto", "--pairing", "paired", "--format", "json", "--quality-binning", "none", "--compression", "balanced"]
        assertArguments(sheet(recipe: "vsp2"), tail: base + ["--recipe", "vsp2"], "a recipe")
        assertArguments(sheet(tool: .auto), tail: base, "the automatic storage tool is the CLI's default")
        assertArguments(sheet(tool: .bbtools), tail: base + ["--clumping-tool", "bbtools"], "bbtools")
        assertArguments(sheet(tool: .trimGalore), tail: base + ["--clumping-tool", "trim-galore"], "trim galore")
        assertArguments(sheet(tool: .none), tail: base + ["--no-optimize-storage"], "no storage tool")
        assertArguments(sheet(skipClumpify: true), tail: base + ["--no-optimize-storage"], "storage optimization skipped")
        assertArguments(
            sheet(tool: .trimGalore, recipe: "vsp2"), tail: base + ["--recipe", "vsp2", "--clumping-tool", "trim-galore"],
            "a recipe sits before the storage tool")
        XCTAssertEqual(ClumpingTool.allCases.count, 4)
    }

    func testAChosenPairingReachesASingleFileRunAndAPairedRunIgnoresIt() {
        let rest = ["--format", "json", "--quality-binning", "none", "--compression", "balanced"]
        assertArguments(sheet(), files: .single, tail: ["--platform", "auto"] + rest, "a single file, pairing left to the CLI")
        for (mode, spelling) in [
            (FASTQIngestionConfig.PairingMode.singleEnd, "single"), (.pairedEnd, "paired"), (.interleaved, "interleaved"),
        ] {
            assertArguments(
                sheet(pairing: mode), files: .single, tail: ["--platform", "auto", "--pairing", spelling] + rest,
                "a single file with pairing \(spelling)")
            assertArguments(
                sheet(pairing: mode), files: .pair, tail: ["--platform", "auto", "--pairing", "paired"] + rest,
                "a run that arrived as two files is one paired sample whatever the sheet chose (\(spelling))")
        }
    }

    func testARunWithUnpairedReadsHandsAllThreeFilesInOrder() {
        assertArguments(
            sheet(),
            files: .triple,
            tail: ["--platform", "auto", "--pairing", "paired", "--format", "json", "--quality-binning", "none", "--compression", "balanced"],
            "a pair with its unpaired file")
    }
}
