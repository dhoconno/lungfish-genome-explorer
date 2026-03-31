// ClassificationConfigMutabilityTests.swift - Tests for classification config mutability
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

/// Tests verifying that classification config types have mutable fields.
///
/// These configs were changed from `let` to `var` to support runtime path
/// rewriting (e.g., resolving virtual FASTQ pointers to materialized files).
/// These tests ensure the fields remain mutable and prevent accidental
/// regression to immutable declarations.
final class ClassificationConfigMutabilityTests: XCTestCase {

    // MARK: - ClassificationConfig.inputFiles Mutability

    func testClassificationConfigInputFilesCanBeMutated() {
        var config = ClassificationConfig(
            goal: .classify,
            inputFiles: [URL(fileURLWithPath: "/data/R1.fastq.gz")],
            isPairedEnd: false,
            databaseName: "standard",
            databasePath: URL(fileURLWithPath: "/db/kraken2"),
            confidence: 0.2,
            minimumHitGroups: 2,
            outputDirectory: URL(fileURLWithPath: "/output")
        )

        let newFile = URL(fileURLWithPath: "/data/materialized_R1.fastq.gz")
        config.inputFiles = [newFile]

        XCTAssertEqual(config.inputFiles.count, 1)
        XCTAssertEqual(config.inputFiles[0].lastPathComponent, "materialized_R1.fastq.gz")
    }

    func testClassificationConfigInputFilesCanAppend() {
        var config = ClassificationConfig(
            goal: .classify,
            inputFiles: [URL(fileURLWithPath: "/data/R1.fastq.gz")],
            isPairedEnd: true,
            databaseName: "standard",
            databasePath: URL(fileURLWithPath: "/db/kraken2"),
            confidence: 0.2,
            minimumHitGroups: 2,
            outputDirectory: URL(fileURLWithPath: "/output")
        )

        config.inputFiles.append(URL(fileURLWithPath: "/data/R2.fastq.gz"))

        XCTAssertEqual(config.inputFiles.count, 2)
    }

    // MARK: - EsVirituConfig.inputFiles Mutability

    func testEsVirituConfigInputFilesCanBeMutated() {
        var config = EsVirituConfig(
            inputFiles: [URL(fileURLWithPath: "/data/R1.fastq.gz")],
            isPairedEnd: false,
            sampleName: "test",
            outputDirectory: URL(fileURLWithPath: "/output"),
            databasePath: URL(fileURLWithPath: "/db/esviritu")
        )

        config.inputFiles = [
            URL(fileURLWithPath: "/data/materialized_R1.fastq.gz"),
            URL(fileURLWithPath: "/data/materialized_R2.fastq.gz"),
        ]

        XCTAssertEqual(config.inputFiles.count, 2)
        XCTAssertEqual(config.inputFiles[0].lastPathComponent, "materialized_R1.fastq.gz")
    }

    // MARK: - TaxTriageSample.fastq1 and fastq2 Mutability

    func testTaxTriageSampleFastq1CanBeMutated() {
        var sample = TaxTriageSample(
            sampleId: "S1",
            fastq1: URL(fileURLWithPath: "/data/R1.fastq.gz"),
            fastq2: nil,
            platform: .illumina
        )

        sample.fastq1 = URL(fileURLWithPath: "/data/materialized_R1.fastq.gz")

        XCTAssertEqual(sample.fastq1.lastPathComponent, "materialized_R1.fastq.gz")
    }

    func testTaxTriageSampleFastq2CanBeMutated() {
        var sample = TaxTriageSample(
            sampleId: "S1",
            fastq1: URL(fileURLWithPath: "/data/R1.fastq.gz"),
            fastq2: nil,
            platform: .illumina
        )

        // Mutate from nil to a value
        sample.fastq2 = URL(fileURLWithPath: "/data/materialized_R2.fastq.gz")
        XCTAssertEqual(sample.fastq2?.lastPathComponent, "materialized_R2.fastq.gz")

        // Mutate back to nil
        sample.fastq2 = nil
        XCTAssertNil(sample.fastq2)
    }

    // MARK: - TaxTriageConfig.samples Mutability

    func testTaxTriageConfigSamplesCanBeMutated() {
        let sample1 = TaxTriageSample(
            sampleId: "S1",
            fastq1: URL(fileURLWithPath: "/data/S1_R1.fastq.gz"),
            platform: .illumina
        )

        var config = TaxTriageConfig(
            samples: [sample1],
            platform: .illumina,
            outputDirectory: URL(fileURLWithPath: "/output")
        )

        let sample2 = TaxTriageSample(
            sampleId: "S2",
            fastq1: URL(fileURLWithPath: "/data/S2_R1.fastq.gz"),
            platform: .illumina
        )
        config.samples.append(sample2)

        XCTAssertEqual(config.samples.count, 2)
        XCTAssertEqual(config.samples[1].sampleId, "S2")
    }

    func testTaxTriageConfigSamplesCanBeReplaced() {
        let sample1 = TaxTriageSample(
            sampleId: "S1",
            fastq1: URL(fileURLWithPath: "/data/S1_R1.fastq.gz"),
            platform: .illumina
        )

        var config = TaxTriageConfig(
            samples: [sample1],
            platform: .illumina,
            outputDirectory: URL(fileURLWithPath: "/output")
        )

        // Replace the entire samples array (simulates path rewriting)
        config.samples = config.samples.map { original in
            var mutated = original
            mutated.fastq1 = URL(fileURLWithPath: "/materialized/\(original.sampleId)_R1.fastq.gz")
            return mutated
        }

        XCTAssertEqual(config.samples[0].fastq1.lastPathComponent, "S1_R1.fastq.gz")
    }
}
