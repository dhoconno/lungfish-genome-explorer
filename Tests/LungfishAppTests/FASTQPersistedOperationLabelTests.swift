// FASTQPersistedOperationLabelTests.swift - The wording that reaches disk never follows a display rename
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishWorkflow

/// Review finding S1. Batch manifest labels and the folders grouped results
/// are written to are on disk, and a recorded command names those folders, so
/// they must not move when a tool or operation is renamed in the menu or the
/// Operations panel. Every label and folder name below is pinned as it is
/// written today.
@MainActor
final class FASTQPersistedOperationLabelTests: XCTestCase {
    private let input = URL(fileURLWithPath: "/tmp/sample.lungfishfastq")

    func testEveryDerivativeKeepsTheLabelAndFolderItWritesToday() throws {
        let primers = FASTQPrimerTrimConfiguration(
            source: .reference, mode: .linked, referenceFasta: "/tmp/primers.fasta",
            errorRate: 0.08, minimumOverlap: 9, tool: .cutadapt
        )
        let cases: [(request: FASTQDerivativeRequest, label: String, folder: String)] = [
            (.subsampleProportion(0.25), "Subsample 25%", "subsample-25"),
            (.subsampleCount(1000), "Subsample 1000 reads", "subsample-1000-reads"),
            (.lengthFilter(min: 50, max: 100), "Length Filter", "length-filter"),
            (.searchText(query: "virus", field: .description, regex: false), "Search", "search"),
            (.searchMotif(pattern: "ACGT", regex: false), "Motif Search", "motif-search"),
            (.deduplicate(preset: .exactPCR, substitutions: 0, optical: false, opticalDistance: 40), "Deduplicate", "deduplicate"),
            (
                .fastpTrim(threshold: 20, windowSize: 4, mode: .cutRight, adapterMode: .autoDetect, adapterSequence: nil),
                "fastp Adapter + Quality Trim", "fastp-adapter-quality-trim"
            ),
            (.qualityTrim(threshold: 20, windowSize: 4, mode: .cutRight), "Quality Trim", "quality-trim"),
            (.adapterTrim(mode: .autoDetect, sequence: nil, sequenceR2: nil, fastaFilename: nil), "Adapter Trim", "adapter-trim"),
            (.fixedTrim(from5Prime: 5, from3Prime: 5), "Fixed Trim", "fixed-trim"),
            (
                .contaminantFilter(mode: .phix, referenceFasta: nil, kmerSize: 31, hammingDistance: 1),
                "Contaminant Filter", "contaminant-filter"
            ),
            (.lowComplexityFilter(entropy: 0.6, window: 50, kmer: 5), "Low-Complexity Filter", "low-complexity-filter"),
            (.pairedEndMerge(strictness: .strict, minOverlap: 15), "Paired-End Merge", "paired-end-merge"),
            (.pairedEndRepair, "Paired-End Repair", "paired-end-repair"),
            (.primerRemoval(configuration: primers), "PCR Primer Trimming", "pcr-primer-trimming"),
            (
                .sequencePresenceFilter(
                    sequence: "ACGT", fastaPath: nil, searchEnd: .fivePrime, minOverlap: 4,
                    errorRate: 0.1, keepMatched: true, searchReverseComplement: false
                ),
                "Sequence Presence Filter", "sequence-presence-filter"
            ),
            (.errorCorrection(kmerSize: 31), "Error Correction", "error-correction"),
            (.reverseComplement, "Reverse Complement", "reverse-complement"),
            (.translate(frameOffset: 0), "Translate", "translate"),
            (
                .demultiplex(
                    kitID: "illumina-nextera", customCSVPath: nil, location: "bothends", symmetryMode: nil,
                    maxDistanceFrom5Prime: 0, maxDistanceFrom3Prime: 0, errorRate: 0.15, engine: .cutadapt,
                    trimBarcodes: true, sampleAssignments: nil, kitOverride: nil
                ),
                "Demultiplex", "demultiplex"
            ),
            (
                .orient(
                    referenceURL: URL(fileURLWithPath: "/tmp/reference.fasta"),
                    wordLength: 12, dbMask: "dust", saveUnoriented: false, extraArguments: []
                ),
                "Orient Sequences", "orient-sequences"
            ),
            (.humanReadScrub(databaseID: "deacon-panhuman", removeReads: true), "Human Read Scrub", "human-read-scrub"),
            (
                .ribosomalRNAFilter(retention: .nonRRNA, ensure: .none),
                "Remove ribosomal RNA sequences", "remove-ribosomal-rna-sequences"
            ),
        ]

        try withOutputParent { controller, parent in
            for (request, label, folder) in cases {
                XCTAssertEqual(request.persistedOperationLabel, label, "the label written to disk for \(request.operationLabel)")
                let launch = FASTQOperationLaunchRequest.derivative(request: request, inputURLs: [input], outputMode: .groupedResult)
                XCTAssertEqual(
                    controller.uniqueFASTQOperationOutputDirectory(in: parent, request: launch).lastPathComponent,
                    folder,
                    "the folder a grouped \(request.operationLabel) result is written to"
                )
            }
        }
    }

    func testOtherLaunchesKeepTheFolderTheyWriteToday() throws {
        let outputDirectory = URL(fileURLWithPath: "/tmp/persisted-label-output", isDirectory: true)
        var launches: [(FASTQOperationLaunchRequest, String)] = [
            (.refreshQCSummary(inputURLs: [input]), "fastq-qc-summary"),
            (
                .ontFluidigmSampleSplit(inputFASTQURL: input, barcodeDefinitionsURL: URL(fileURLWithPath: "/tmp/barcodes.csv"), threads: 1),
                "ont-fluidigm-sample-split"
            ),
            (.map(inputURLs: [input], referenceURL: URL(fileURLWithPath: "/tmp/reference.fasta"), outputMode: .groupedResult), "map-reads"),
            (.classify(tool: .kraken2, inputURLs: [input], databaseName: "standard"), "kraken2"),
            (.classify(tool: .esViritu, inputURLs: [input], databaseName: "standard"), "esviritu"),
            (.classify(tool: .taxTriage, inputURLs: [input], databaseName: "standard"), "taxtriage"),
            (
                .ontGenotyping(request: ONTBarcodeDemuxGenotypingRunRequest(
                    inputFASTQURLs: [input],
                    referenceSourceURL: input,
                    outputDirectory: outputDirectory,
                    outputName: "genotype",
                    analysisName: "genotype",
                    threads: 1,
                    minSupport: 1,
                    mode: .ontSampleBundles,
                    readType: .ont
                )),
                "miseq-amplicon-mhc-genotyping"
            ),
        ]
        let assemblers: [(AssemblyTool, AssemblyReadType, String)] = [
            (.spades, .illuminaShortReads, "spades"),
            (.megahit, .illuminaShortReads, "megahit"),
            (.skesa, .illuminaShortReads, "skesa"),
            (.flye, .ontReads, "flye"),
            (.hifiasm, .pacBioHiFi, "hifiasm"),
        ]
        for (tool, readType, folder) in assemblers {
            let request = AssemblyRunRequest(
                tool: tool,
                readType: readType,
                inputURLs: [input],
                projectName: "demo",
                outputDirectory: outputDirectory,
                pairedEnd: false,
                threads: 1
            )
            launches.append((.assemble(request: request, outputMode: .groupedResult), folder))
        }

        try withOutputParent { controller, parent in
            for (launch, folder) in launches {
                XCTAssertEqual(
                    controller.uniqueFASTQOperationOutputDirectory(in: parent, request: launch).lastPathComponent,
                    folder,
                    "the folder \(launch.operationDisplayTitle) is written to"
                )
            }
        }
    }

    private func withOutputParent(_ body: (MainSplitViewController, URL) throws -> Void) throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("persisted-labels-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try body(MainSplitViewController(), parent)
    }
}
