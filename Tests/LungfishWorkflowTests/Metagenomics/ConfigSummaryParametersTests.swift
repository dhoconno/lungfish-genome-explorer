// ConfigSummaryParametersTests.swift - Tests for summaryParameters() on config types
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow
@testable import LungfishIO

final class ConfigSummaryParametersTests: XCTestCase {

    // MARK: - EsVirituConfig

    func testEsVirituConfigSummary() {
        let config = EsVirituConfig(
            inputFiles: [URL(fileURLWithPath: "/data/reads.fastq.gz")],
            isPairedEnd: false,
            sampleName: "MySample",
            outputDirectory: URL(fileURLWithPath: "/output"),
            databasePath: URL(fileURLWithPath: "/db/esviritu"),
            qualityFilter: true,
            minReadLength: 75,
            threads: 8
        )

        let params = config.summaryParameters()

        XCTAssertEqual(params["sampleName"], .string("MySample"))
        XCTAssertEqual(params["qualityFilter"], .bool(true))
        XCTAssertEqual(params["minReadLength"], .int(75))
        XCTAssertEqual(params["threads"], .int(8))
        XCTAssertEqual(params["isPairedEnd"], .bool(false))

        // Paths must not appear
        XCTAssertNil(params["inputFiles"])
        XCTAssertNil(params["outputDirectory"])
        XCTAssertNil(params["databasePath"])
    }

    func testEsVirituConfigSummaryPairedEnd() {
        let config = EsVirituConfig(
            inputFiles: [
                URL(fileURLWithPath: "/data/R1.fastq.gz"),
                URL(fileURLWithPath: "/data/R2.fastq.gz"),
            ],
            isPairedEnd: true,
            sampleName: "PairedSample",
            outputDirectory: URL(fileURLWithPath: "/output"),
            databasePath: URL(fileURLWithPath: "/db/esviritu"),
            qualityFilter: false,
            minReadLength: 100
        )

        let params = config.summaryParameters()

        XCTAssertEqual(params["isPairedEnd"], .bool(true))
        XCTAssertEqual(params["qualityFilter"], .bool(false))
        XCTAssertEqual(params["sampleName"], .string("PairedSample"))
    }

    // MARK: - ClassificationConfig

    func testClassificationConfigSummary() {
        let config = ClassificationConfig(
            goal: .profile,
            inputFiles: [URL(fileURLWithPath: "/data/reads.fastq.gz")],
            isPairedEnd: false,
            databaseName: "PlusPF-16",
            databaseVersion: "20240904",
            databasePath: URL(fileURLWithPath: "/db/kraken2"),
            confidence: 0.2,
            minimumHitGroups: 3,
            threads: 4,
            memoryMapping: true,
            quickMode: false,
            outputDirectory: URL(fileURLWithPath: "/output")
        )

        let params = config.summaryParameters()

        XCTAssertEqual(params["goal"], .string("profile"))
        XCTAssertEqual(params["databaseName"], .string("PlusPF-16"))
        XCTAssertEqual(params["confidence"], .double(0.2))
        XCTAssertEqual(params["minimumHitGroups"], .int(3))
        XCTAssertEqual(params["threads"], .int(4))
        XCTAssertEqual(params["memoryMapping"], .bool(true))

        // Paths and version must not appear
        XCTAssertNil(params["inputFiles"])
        XCTAssertNil(params["outputDirectory"])
        XCTAssertNil(params["databasePath"])
        XCTAssertNil(params["databaseVersion"])
    }

    func testClassificationConfigGoalRawValues() {
        let goals: [(ClassificationConfig.Goal, String)] = [
            (.classify, "classify"),
            (.profile, "profile"),
            (.extract, "extract"),
        ]
        for (goal, expectedRaw) in goals {
            let config = ClassificationConfig(
                goal: goal,
                inputFiles: [URL(fileURLWithPath: "/data/reads.fastq.gz")],
                isPairedEnd: false,
                databaseName: "Standard",
                databasePath: URL(fileURLWithPath: "/db"),
                outputDirectory: URL(fileURLWithPath: "/output")
            )
            XCTAssertEqual(config.summaryParameters()["goal"], .string(expectedRaw))
        }
    }

    // MARK: - TaxTriageConfig

    func testTaxTriageConfigSummary() {
        let sample = TaxTriageSample(
            sampleId: "S1",
            fastq1: URL(fileURLWithPath: "/data/R1.fastq.gz"),
            fastq2: URL(fileURLWithPath: "/data/R2.fastq.gz"),
            platform: .illumina
        )
        let config = TaxTriageConfig(
            samples: [sample],
            platform: .illumina,
            outputDirectory: URL(fileURLWithPath: "/output"),
            kraken2DatabasePath: URL(fileURLWithPath: "/db/kraken2"),
            classifiers: ["kraken2"],
            topHitsCount: 20,
            k2Confidence: 0.5,
            rank: "G",
            skipAssembly: false,
            maxCpus: 12
        )

        let params = config.summaryParameters()

        XCTAssertEqual(params["platform"], .string("ILLUMINA"))
        XCTAssertEqual(params["classifiers"], .string("kraken2"))
        XCTAssertEqual(params["topHitsCount"], .int(20))
        XCTAssertEqual(params["k2Confidence"], .double(0.5))
        XCTAssertEqual(params["rank"], .string("G"))
        XCTAssertEqual(params["skipAssembly"], .bool(false))
        XCTAssertEqual(params["maxCpus"], .int(12))

        // Paths must not appear
        XCTAssertNil(params["outputDirectory"])
        XCTAssertNil(params["kraken2DatabasePath"])
        XCTAssertNil(params["sourceBundleURLs"])
        XCTAssertNil(params["samples"])
    }

    func testTaxTriageConfigMultipleClassifiers() {
        let sample = TaxTriageSample(
            sampleId: "S1",
            fastq1: URL(fileURLWithPath: "/data/reads.fastq.gz")
        )
        let config = TaxTriageConfig(
            samples: [sample],
            platform: .oxford,
            outputDirectory: URL(fileURLWithPath: "/output"),
            classifiers: ["kraken2", "metaphlan"]
        )

        let params = config.summaryParameters()

        XCTAssertEqual(params["platform"], .string("OXFORD"))
        XCTAssertEqual(params["classifiers"], .string("kraken2,metaphlan"))
    }

    // MARK: - SPAdesAssemblyConfig

    func testSPAdesConfigSummary() {
        let config = SPAdesAssemblyConfig(
            mode: .meta,
            forwardReads: [URL(fileURLWithPath: "/data/R1.fastq.gz")],
            reverseReads: [URL(fileURLWithPath: "/data/R2.fastq.gz")],
            memoryGB: 32,
            threads: 16,
            minContigLength: 500,
            careful: true,
            outputDirectory: URL(fileURLWithPath: "/output")
        )

        let params = config.summaryParameters()

        XCTAssertEqual(params["mode"], .string("meta"))
        XCTAssertEqual(params["threads"], .int(16))
        XCTAssertEqual(params["memoryGB"], .int(32))
        XCTAssertEqual(params["minContigLength"], .int(500))
        XCTAssertEqual(params["careful"], .bool(true))

        // Paths and custom args must not appear
        XCTAssertNil(params["forwardReads"])
        XCTAssertNil(params["reverseReads"])
        XCTAssertNil(params["unpairedReads"])
        XCTAssertNil(params["outputDirectory"])
        XCTAssertNil(params["customArgs"])
    }

    func testSPAdesModeRawValues() {
        let modes: [(SPAdesMode, String)] = [
            (.isolate, "isolate"),
            (.meta, "meta"),
            (.plasmid, "plasmid"),
            (.rna, "rna"),
            (.biosyntheticSPAdes, "bio"),
        ]
        for (mode, expectedRaw) in modes {
            let config = SPAdesAssemblyConfig(
                mode: mode,
                outputDirectory: URL(fileURLWithPath: "/output")
            )
            XCTAssertEqual(config.summaryParameters()["mode"], .string(expectedRaw))
        }
    }

    // MARK: - Minimap2Config

    func testMinimap2ConfigSummary() {
        let config = Minimap2Config(
            inputFiles: [URL(fileURLWithPath: "/data/reads.fastq.gz")],
            referenceURL: URL(fileURLWithPath: "/ref/genome.fasta"),
            preset: .mapONT,
            threads: 8,
            isPairedEnd: false,
            outputDirectory: URL(fileURLWithPath: "/output"),
            sampleName: "ONT_Run1"
        )

        let params = config.summaryParameters()

        XCTAssertEqual(params["preset"], .string("map-ont"))
        XCTAssertEqual(params["sampleName"], .string("ONT_Run1"))
        XCTAssertEqual(params["threads"], .int(8))
        XCTAssertEqual(params["isPairedEnd"], .bool(false))

        // Paths must not appear
        XCTAssertNil(params["inputFiles"])
        XCTAssertNil(params["referenceURL"])
        XCTAssertNil(params["outputDirectory"])
    }

    func testMinimap2PresetRawValues() {
        let presets: [(Minimap2Preset, String)] = [
            (.shortRead, "sr"),
            (.mapONT, "map-ont"),
            (.mapHiFi, "map-hifi"),
            (.mapPB, "map-pb"),
            (.asm5, "asm5"),
            (.asm20, "asm20"),
            (.splice, "splice"),
            (.spliceSR, "splice:hq"),
        ]
        for (preset, expectedRaw) in presets {
            let config = Minimap2Config(
                inputFiles: [URL(fileURLWithPath: "/data/reads.fastq.gz")],
                referenceURL: URL(fileURLWithPath: "/ref/genome.fasta"),
                preset: preset,
                outputDirectory: URL(fileURLWithPath: "/output"),
                sampleName: "Test"
            )
            XCTAssertEqual(config.summaryParameters()["preset"], .string(expectedRaw))
        }
    }
}
