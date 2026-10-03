// MainSplitGenomicsDisplayDerivativeCases.swift - Derivative requests and the commands they must record
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The FASTQ derivative row (site 42) and the FASTQ operations dialog row
// (site 43) in MainSplitViewController+GenomicsDisplay.swift record the
// `lungfish-cli fastq` command FASTQOperationCLIInvocationBuilder builds, and
// FASTQOperationOutputImporter records the same invocation as derivative
// provenance (R3, R8). MainSplitGenomicsDisplayOperationTests parses each
// recorded command with the real CLI parser and calls the case's `verify`
// closure to compare the parsed values with the request.

import ArgumentParser
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishIO
import LungfishWorkflow

/// One derivative request and what its recorded command must parse to.
struct GenomicsDisplayDerivativeCase {
    let name: String
    let request: FASTQDerivativeRequest
    let verify: (any ParsableCommand, String) throws -> Void

    init(
        _ name: String,
        _ request: FASTQDerivativeRequest,
        verify: @escaping (any ParsableCommand, String) throws -> Void
    ) {
        self.name = name
        self.request = request
        self.verify = verify
    }
}

enum GenomicsDisplayDerivativeCases {
    /// The derivative kinds whose recorded command is a lungfish-cli command
    /// at both FASTQ launch sites. The dataset viewport row used to record the
    /// last seven wrongly. Five were native tool commands, and two left out a
    /// value the run uses (the cutadapt-linked engine and the distances from
    /// the read ends). The length filter's pairing has a test of its own.
    static func bothSitesRecord() -> [GenomicsDisplayDerivativeCase] {
        let primerLiteral = FASTQPrimerTrimConfiguration(
            source: .literal, forwardSequence: "ACGTACGTAC", tool: .bbduk,
            kmerSize: 23, minKmer: 11, hammingDistance: 1
        )
        let primerLinked = FASTQPrimerTrimConfiguration(
            source: .reference, mode: .linked, referenceFasta: "/tmp/lane 1a2h/primers.fasta",
            errorRate: 0.08, minimumOverlap: 9, tool: .cutadapt
        )
        return [
            GenomicsDisplayDerivativeCase("subsample by proportion", .subsampleProportion(0.1)) { parsed, input in
                let command = try XCTUnwrap(parsed as? FastqSubsampleSubcommand)
                XCTAssertEqual(command.input, input)
                XCTAssertEqual(command.proportion, 0.1)
                XCTAssertNil(command.count)
                XCTAssertEqual(command.output.output, "<derived>")
            },
            GenomicsDisplayDerivativeCase("subsample by count", .subsampleCount(1000)) { parsed, input in
                let command = try XCTUnwrap(parsed as? FastqSubsampleSubcommand)
                XCTAssertEqual(command.input, input)
                XCTAssertEqual(command.count, 1000)
                XCTAssertNil(command.proportion)
                XCTAssertEqual(command.output.output, "<derived>")
            },
            GenomicsDisplayDerivativeCase("length filter minimum only", .lengthFilter(min: 100, max: nil)) { parsed, input in
                let command = try XCTUnwrap(parsed as? FastqLengthFilterSubcommand)
                XCTAssertEqual(command.input, input)
                XCTAssertEqual(command.minLength, 100)
                XCTAssertNil(command.maxLength)
                XCTAssertEqual(command.output.output, "<derived>")
            },
            GenomicsDisplayDerivativeCase("search text", .searchText(query: "virus", field: .description, regex: true)) { parsed, input in
                let command = try XCTUnwrap(parsed as? FastqSearchTextSubcommand)
                XCTAssertEqual(command.input, input)
                XCTAssertEqual(command.query, "virus")
                XCTAssertEqual(command.field, "description")
                XCTAssertTrue(command.regex)
                XCTAssertEqual(command.output.output, "<derived>")
            },
            GenomicsDisplayDerivativeCase("search motif", .searchMotif(pattern: "GATTACA", regex: false)) { parsed, input in
                let command = try XCTUnwrap(parsed as? FastqSearchMotifSubcommand)
                XCTAssertEqual(command.input, input)
                XCTAssertEqual(command.pattern, "GATTACA")
                XCTAssertFalse(command.regex)
                XCTAssertEqual(command.output.output, "<derived>")
            },
            GenomicsDisplayDerivativeCase(
                "deduplicate",
                .deduplicate(preset: .exactPCR, substitutions: 2, optical: true, opticalDistance: 12000)
            ) { parsed, input in
                let command = try XCTUnwrap(parsed as? FastqDeduplicateSubcommand)
                XCTAssertEqual(command.input, input)
                XCTAssertEqual(command.substitutions, 2)
                XCTAssertTrue(command.optical)
                XCTAssertEqual(command.opticalDistance, 12000)
                XCTAssertEqual(command.output.output, "<derived>")
            },
            GenomicsDisplayDerivativeCase(
                "fastp trim with automatic adapters",
                .fastpTrim(threshold: 20, windowSize: 4, mode: .cutRight, adapterMode: .autoDetect, adapterSequence: nil)
            ) { parsed, input in
                let command = try XCTUnwrap(parsed as? FastqTrimSubcommand)
                XCTAssertEqual(command.input, input)
                XCTAssertEqual(command.threshold, 20)
                XCTAssertEqual(command.windowSize, 4)
                XCTAssertEqual(command.mode, "cut-right")
                XCTAssertTrue(command.adapterTrimming)
                XCTAssertNil(command.adapterSequence)
                XCTAssertEqual(command.output.output, "<derived>")
            },
            GenomicsDisplayDerivativeCase(
                "fastp trim with a specified adapter",
                .fastpTrim(threshold: 30, windowSize: 5, mode: .cutBoth, adapterMode: .specified, adapterSequence: "AGATCGGAAGAG")
            ) { parsed, input in
                let command = try XCTUnwrap(parsed as? FastqTrimSubcommand)
                XCTAssertEqual(command.input, input)
                XCTAssertEqual(command.threshold, 30)
                XCTAssertEqual(command.windowSize, 5)
                XCTAssertEqual(command.mode, "cut-both")
                XCTAssertTrue(command.adapterTrimming)
                XCTAssertEqual(command.adapterSequence, "AGATCGGAAGAG")
            },
            GenomicsDisplayDerivativeCase(
                "quality trim with extra arguments",
                .qualityTrim(threshold: 25, windowSize: 6, mode: .cutFront, extraArguments: ["--cut_mean_quality", "25"])
            ) { parsed, input in
                let command = try XCTUnwrap(parsed as? FastqQualityTrimSubcommand)
                XCTAssertEqual(command.input, input)
                XCTAssertEqual(command.threshold, 25)
                XCTAssertEqual(command.windowSize, 6)
                XCTAssertEqual(command.mode, "cut-front")
                XCTAssertEqual(command.extraArgs, AdvancedCommandLineOptions.join(["--cut_mean_quality", "25"]))
                XCTAssertEqual(command.output.output, "<derived>")
            },
            GenomicsDisplayDerivativeCase(
                "adapter trim with a specified adapter",
                .adapterTrim(mode: .specified, sequence: "ACGTACGT", sequenceR2: nil, fastaFilename: nil)
            ) { parsed, input in
                let command = try XCTUnwrap(parsed as? FastqAdapterTrimSubcommand)
                XCTAssertEqual(command.input, input)
                XCTAssertEqual(command.adapterSequence, "ACGTACGT")
                XCTAssertEqual(command.output.output, "<derived>")
            },
            GenomicsDisplayDerivativeCase("fixed trim", .fixedTrim(from5Prime: 5, from3Prime: 7)) { parsed, input in
                let command = try XCTUnwrap(parsed as? FastqFixedTrimSubcommand)
                XCTAssertEqual(command.input, input)
                XCTAssertEqual(command.front, 5)
                XCTAssertEqual(command.tail, 7)
                XCTAssertEqual(command.output.output, "<derived>")
            },
            GenomicsDisplayDerivativeCase(
                "contaminant filter with a custom reference",
                .contaminantFilter(mode: .custom, referenceFasta: "/tmp/lane 1a2h/contaminants.fasta", kmerSize: 27, hammingDistance: 2)
            ) { parsed, input in
                let command = try XCTUnwrap(parsed as? FastqContaminantFilterSubcommand)
                XCTAssertEqual(command.input, input)
                XCTAssertEqual(command.mode, "custom")
                XCTAssertEqual(command.reference, "/tmp/lane 1a2h/contaminants.fasta")
                XCTAssertEqual(command.kmerSize, 27)
                XCTAssertEqual(command.hammingDistance, 2)
                XCTAssertEqual(command.output.output, "<derived>")
            },
            GenomicsDisplayDerivativeCase("low-complexity filter", .lowComplexityFilter(entropy: 0.6, window: 50, kmer: 5)) { parsed, input in
                let command = try XCTUnwrap(parsed as? FastqEntropyFilterSubcommand)
                XCTAssertEqual(command.input, input)
                XCTAssertEqual(command.entropy, 0.6)
                XCTAssertEqual(command.window, 50)
                XCTAssertEqual(command.kmer, 5)
                XCTAssertEqual(command.output.output, "<derived>")
            },
            GenomicsDisplayDerivativeCase("paired-end merge", .pairedEndMerge(strictness: .strict, minOverlap: 15)) { parsed, input in
                let command = try XCTUnwrap(parsed as? FastqMergeSubcommand)
                XCTAssertEqual(command.input, input)
                XCTAssertEqual(command.minOverlap, 15)
                XCTAssertTrue(command.strict)
                XCTAssertTrue(command.countDuplicates)
                XCTAssertEqual(command.output.output, "<derived>")
            },
            GenomicsDisplayDerivativeCase("paired-end repair", .pairedEndRepair) { parsed, input in
                let command = try XCTUnwrap(parsed as? FastqRepairSubcommand)
                XCTAssertEqual(command.input, input)
                XCTAssertEqual(command.output.output, "<derived>")
            },
            GenomicsDisplayDerivativeCase("primer removal with literal primers", .primerRemoval(configuration: primerLiteral)) { parsed, input in
                let command = try XCTUnwrap(parsed as? FastqPrimerRemovalSubcommand)
                XCTAssertEqual(command.input, input)
                XCTAssertEqual(command.literalSequence, "ACGTACGTAC")
                XCTAssertNil(command.reference)
                XCTAssertEqual(command.kmerSize, 23)
                XCTAssertEqual(command.minKmer, 11)
                XCTAssertEqual(command.hammingDistance, 1)
                XCTAssertEqual(command.engine, .bbduk)
                XCTAssertEqual(command.output.output, "<derived>")
            },
            GenomicsDisplayDerivativeCase("error correction", .errorCorrection(kmerSize: 40)) { parsed, input in
                let command = try XCTUnwrap(parsed as? FastqErrorCorrectSubcommand)
                XCTAssertEqual(command.input, input)
                XCTAssertEqual(command.kmerSize, 40)
                XCTAssertEqual(command.output.output, "<derived>")
            },
            // Interleave names the R1 and R2 files of a paired bundle, which
            // the input here is not. FASTQInterleaveCommandTests covers it.
            GenomicsDisplayDerivativeCase("deinterleave", .interleaveReformat(direction: .deinterleave)) { parsed, input in
                let command = try XCTUnwrap(parsed as? FastqDeinterleaveSubcommand)
                XCTAssertEqual(command.input, input)
                XCTAssertEqual(command.out1, "<derived>.R1.fastq")
                XCTAssertEqual(command.out2, "<derived>.R2.fastq")
            },
            GenomicsDisplayDerivativeCase(
                "demultiplex with a kit",
                .demultiplex(
                    kitID: "illumina-nextera", customCSVPath: nil, location: "bothends", symmetryMode: nil,
                    maxDistanceFrom5Prime: 0, maxDistanceFrom3Prime: 0, errorRate: 0.15, engine: .cutadapt,
                    trimBarcodes: true, sampleAssignments: nil, kitOverride: nil
                )
            ) { parsed, input in
                let command = try XCTUnwrap(parsed as? FastqDemultiplexSubcommand)
                XCTAssertEqual(command.input, input)
                XCTAssertEqual(command.kit, "illumina-nextera")
                XCTAssertEqual(command.output, "<derived>")
                XCTAssertEqual(command.location, "bothends")
                XCTAssertEqual(command.errorRate, 0.15)
                XCTAssertEqual(command.engine, DemultiplexEngine.cutadapt.rawValue)
                XCTAssertFalse(command.noTrim)
            },
            GenomicsDisplayDerivativeCase(
                "demultiplex with exact bare barcodes",
                .demultiplex(
                    kitID: "illumina-nextera", customCSVPath: nil, location: "bothends", symmetryMode: nil,
                    maxDistanceFrom5Prime: 0, maxDistanceFrom3Prime: 0, errorRate: 0.15, engine: .exactBareBarcode,
                    trimBarcodes: false, sampleAssignments: nil, kitOverride: nil
                )
            ) { parsed, input in
                let command = try XCTUnwrap(parsed as? FastqDemultiplexSubcommand)
                XCTAssertEqual(command.input, input)
                XCTAssertEqual(command.kit, "illumina-nextera")
                XCTAssertEqual(command.engine, DemultiplexEngine.exactBareBarcode.rawValue)
                XCTAssertEqual(command.output, "<derived>")
            },
            GenomicsDisplayDerivativeCase(
                "ribosomal RNA filter",
                .ribosomalRNAFilter(retention: .nonRRNA, ensure: .none)
            ) { parsed, input in
                let command = try XCTUnwrap(parsed as? FastqDeaconRiboSubcommand)
                XCTAssertEqual(command.inputs, [input])
                XCTAssertEqual(command.retain, FASTQRiboDetectorRetention.nonRRNA.rawValue)
                XCTAssertEqual(command.databaseID, DeaconRibokmersDatabaseInstaller.databaseID)
                XCTAssertEqual(command.outputDirectory, "<derived>")
            },
            GenomicsDisplayDerivativeCase("reverse complement", .reverseComplement) { parsed, input in
                let command = try XCTUnwrap(parsed as? FastqReverseComplementSubcommand)
                XCTAssertEqual(command.input, input)
                XCTAssertEqual(command.output.output, "<derived>")
            },
            GenomicsDisplayDerivativeCase("translate", .translate(frameOffset: 1)) { parsed, input in
                let command = try XCTUnwrap(parsed as? FastqTranslateSubcommand)
                XCTAssertEqual(command.input, input)
                XCTAssertEqual(command.frame, 2)
                XCTAssertEqual(command.output.output, "<derived>")
            },
            GenomicsDisplayDerivativeCase(
                "sequence presence filter",
                .sequencePresenceFilter(
                    sequence: "ACGT", fastaPath: nil, searchEnd: .fivePrime, minOverlap: 16,
                    errorRate: 0.15, keepMatched: true, searchReverseComplement: false
                )
            ) { parsed, input in
                let command = try XCTUnwrap(parsed as? FastqSequenceFilterSubcommand)
                XCTAssertEqual(command.input, input)
                XCTAssertEqual(command.sequence, "ACGT")
                XCTAssertEqual(command.searchEnd, "left")
                XCTAssertEqual(command.minOverlap, 16)
                XCTAssertEqual(command.errorRate, 0.15)
                XCTAssertTrue(command.keepMatched)
                XCTAssertFalse(command.searchReverseComplement)
                XCTAssertEqual(command.output.output, "<derived>")
            },
            GenomicsDisplayDerivativeCase(
                "orient",
                .orient(
                    referenceURL: URL(fileURLWithPath: "/tmp/lane 1a2h/ref.fasta"),
                    wordLength: 12, dbMask: "dust", saveUnoriented: false, extraArguments: []
                )
            ) { parsed, input in
                let command = try XCTUnwrap(parsed as? FastqOrientSubcommand)
                XCTAssertEqual(command.input, input)
                XCTAssertEqual(command.reference, "/tmp/lane 1a2h/ref.fasta")
                XCTAssertEqual(command.wordLength, 12)
                XCTAssertEqual(command.dbMask, "dust")
                XCTAssertEqual(command.output.output, "<derived>")
            },
            GenomicsDisplayDerivativeCase("human read scrub", .humanReadScrub(databaseID: "deacon-panhuman", removeReads: true)) { parsed, input in
                let command = try XCTUnwrap(parsed as? FastqScrubHumanSubcommand)
                XCTAssertEqual(command.input, input)
                XCTAssertEqual(command.databaseID, "deacon-panhuman")
                XCTAssertEqual(command.output.output, "<derived>")
            },
            GenomicsDisplayDerivativeCase(
                "primer removal with cutadapt linked primers from a reference",
                .primerRemoval(configuration: primerLinked)
            ) { parsed, input in
                let command = try XCTUnwrap(parsed as? FastqPrimerRemovalSubcommand)
                XCTAssertEqual(command.input, input)
                XCTAssertEqual(command.reference, "/tmp/lane 1a2h/primers.fasta")
                XCTAssertNil(command.literalSequence)
                XCTAssertEqual(command.engine, .cutadaptLinked)
                XCTAssertEqual(command.minimumOverlap, 9)
                XCTAssertEqual(command.errorRate, 0.08)
                XCTAssertEqual(command.output.output, "<derived>")
            },
            GenomicsDisplayDerivativeCase(
                "demultiplex with distances from the read ends",
                .demultiplex(
                    kitID: "custom-kit", customCSVPath: "/tmp/lane 1a2h/kit.csv", location: "fiveprime",
                    symmetryMode: nil, maxDistanceFrom5Prime: 3, maxDistanceFrom3Prime: 4, errorRate: 0.1,
                    engine: .cutadapt, trimBarcodes: false, sampleAssignments: nil, kitOverride: nil
                )
            ) { parsed, input in
                let command = try XCTUnwrap(parsed as? FastqDemultiplexSubcommand)
                XCTAssertEqual(command.input, input)
                XCTAssertEqual(command.kit, "/tmp/lane 1a2h/kit.csv")
                XCTAssertEqual(command.location, "fiveprime")
                XCTAssertEqual(command.maxDistanceFrom5Prime, 3)
                XCTAssertEqual(command.maxDistanceFrom3Prime, 4)
                XCTAssertEqual(command.errorRate, 0.1)
                XCTAssertTrue(command.noTrim)
                XCTAssertEqual(command.output, "<derived>")
            },
        ]
    }
}
