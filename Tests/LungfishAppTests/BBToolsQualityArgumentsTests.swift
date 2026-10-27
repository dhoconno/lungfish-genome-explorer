// BBToolsQualityArgumentsTests.swift - Every BBTools site states Phred+33 through the one constant set
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCLI
@testable import LungfishOperations
@testable import LungfishWorkflow
import LungfishIO
import LungfishPortable

/// BIO-BIN-QIN, row BBTOOLS-QIN. No tool runs here. Each site builds its argv through its own builder, and the argv holds
/// the flags of its constant once each. The real-tool twin is BBToolsQualityEncodingConformanceTests.
final class BBToolsQualityArgumentsTests: XCTestCase {

    private let file = URL(fileURLWithPath: "/tmp/qin/in.fastq")
    private let other = URL(fileURLWithPath: "/tmp/qin/other.fastq")
    private let out = URL(fileURLWithPath: "/tmp/qin/out.fastq")
    private let out2 = URL(fileURLWithPath: "/tmp/qin/out2.fastq")

    func testTheConstantsHoldTheRuledFlags() {
        XCTAssertEqual(BBToolsQualityArguments.input, ["qin=33"])
        XCTAssertEqual(BBToolsQualityArguments.readAndWrite, ["qin=33", "qout=33"])
        XCTAssertEqual(BBToolsQualityArguments.keepEveryScore, ["qin=33", "qout=33", "maxcalledquality=93"])
    }

    func testEverySiteStatesItsQualityFlagsOnce() throws {
        let keep = BBToolsQualityArguments.keepEveryScore
        let both = BBToolsQualityArguments.readAndWrite
        let primers = FastqPrimerRemovalSubcommand.ToolArguments(engine: .bbduk(
            primers: "literal=ACGTACGTACGTACGT", kmerSize: 15, minKmer: 11, hammingDistance: 1, searchWindow: 60,
            readThrough: FastqPrimerRemovalSubcommand.ReadThroughPass(
                primers: "literal=ACGTACGTACGTACGT", kmerSize: 15, window: 24)))
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("bbtools-qin-unit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let reference = folder.appendingPathComponent("reference.fa")
        try Data(">c\nACGT\n".utf8).write(to: reference)

        let sites: [(String, [String], [String])] = [
            // clumpify, steps that pass reads through
            ("FastqDeduplicateSubcommand", FastqDeduplicateSubcommand.clumpifyArguments(
                input: file.path, output: out.path, heapGB: 1, substitutions: 0, interleaved: false, optical: false,
                opticalDistance: 40), keep),
            ("FASTQBatchImporter.pairedDedupeArguments", FASTQBatchImporter.pairedDedupeArguments(
                r1: file, r2: other, outR1: out, outR2: out2, heapGB: 1, substitutions: 0, optical: false,
                opticalDistance: 2500, threads: 2), keep),
            ("FASTQBatchImporter.interleavedDedupeArguments", FASTQBatchImporter.interleavedDedupeArguments(
                input: file, output: out, optical: false, threads: 2, interleaved: true), keep),
            ("FASTQDerivativeService.dedupeArguments", FASTQDerivativeService.dedupeArguments(
                input: file, output: out, heapGB: 1, substitutions: 0, interleaved: true, optical: true,
                opticalDistance: 2500), keep),
            // bbduk
            ("FastqContaminantFilterSubcommand", try FastqContaminantFilterSubcommand.bbdukArguments(
                inputURL: file, outputPath: out.path, mode: "custom", reference: reference.path, kmerSize: 31,
                hammingDistance: 1, interleaved: true), keep),
            ("FastqEntropyFilterSubcommand", FastqEntropyFilterSubcommand.bbdukArguments(
                inputURL: file, outputPath: out.path, entropy: 0.5, window: 50, kmer: 5, threads: 2, heapGB: 1,
                interleaved: false), keep),
            ("FastqSequenceFilterSubcommand", FastqSequenceFilterSubcommand.bbdukArguments(
                inputURL: file, outputPath: out.path, keepMatched: true, interleaved: true, literal: "ACGTACGTACGTACG",
                referenceURL: nil, minOverlap: 15, errorRate: 0.1, searchReverseComplement: true, searchEnd: "left"), keep),
            ("FastqPrimerRemovalSubcommand single", primers.arguments(input: file.path, output: out.path, paired: false), keep),
            ("FastqPrimerRemovalSubcommand paired", primers.arguments(input: file.path, output: out.path, paired: true), keep),
            ("FastqPrimerRemovalSubcommand read-through single",
             primers.readThroughArguments(input: file.path, output: out.path, paired: false) ?? [], keep),
            ("FastqPrimerRemovalSubcommand read-through paired",
             primers.readThroughArguments(input: file.path, output: out.path, paired: true) ?? [], keep),
            ("FASTQLengthFilterPlan", FASTQLengthFilterPlan.make(
                inputPath: file.path, outputPath: out.path, minLength: 100, maxLength: 200, pairAware: true).arguments, keep),
            ("FASTQBatchImporter.interleavedLengthFilterArguments", FASTQBatchImporter.interleavedLengthFilterArguments(
                input: file, output: out, minLength: 100, maxLength: nil, threads: 2), keep),
            ("FullLengthONTMHCGenotypingPipeline forward primer", FullLengthONTMHCGenotypingPipeline.primerTrimArguments(
                input: file, output: out, primers: other, ktrim: "l"), keep),
            ("FullLengthONTMHCGenotypingPipeline reverse primer", FullLengthONTMHCGenotypingPipeline.primerTrimArguments(
                input: file, output: out, primers: other, ktrim: "r"), keep),
            // reformat
            ("BBToolsPairArguments.interleave", BBToolsPairArguments.interleave(r1: file.path, r2: other.path, output: out.path), keep),
            ("BBToolsPairArguments.deinterleave", BBToolsPairArguments.deinterleave(input: file.path, out1: out.path, out2: out2.path), keep),
            ("RecipeEngine.pairedToInterleavedArguments", RecipeEngine.pairedToInterleavedArguments(
                r1: file, r2: other, output: out, threads: 2), keep),
            ("RecipeEngine.interleavedToPairedArguments", RecipeEngine.interleavedToPairedArguments(
                input: file, out1: out, out2: out2, threads: 2), keep),
            ("FastqSubsampleSubcommand", FastqSubsampleSubcommand.reformatSampleArguments(
                input: file.path, output: out.path, proportion: 0.5, count: 10, seed: 7), keep),
            ("FullLengthONTMHCGenotypingPipeline length filter", FullLengthONTMHCGenotypingPipeline.lengthFilterArguments(
                input: file, output: out, minimumLength: 100, maximumLength: 200), keep),
            ("PortableStoragePlan.trimGaloreInterleaveArguments", PortableStoragePlan.trimGaloreInterleaveArguments(
                r1: file, r2: other, output: out, compressionLevel: 4, threads: 2), keep),
            // repair and tadpole
            ("FastqRepairSubcommand", FastqRepairSubcommand.repairArguments(input: file, repaired: out, singletons: out2), keep),
            ("FastqErrorCorrectSubcommand", FastqErrorCorrectSubcommand.tadpoleArguments(input: file, output: out.path, kmerSize: 31), keep),
            // bbmerge computes new scores, so it takes qin and qout and no cap
            ("FASTQBatchImporter.mergeArguments", FASTQBatchImporter.mergeArguments(
                input: file, merged: out, unmerged: out2, minOverlap: 12, threads: 2, interleaved: true, strict: true), both),
            ("FASTQDerivativeService.mergeArguments", FASTQDerivativeService.mergeArguments(
                source: file, merged: out, unmerged: out2, minOverlap: 12, interleaved: false, strict: false), both),
            ("FastqMergeSubcommand", FastqMergeSubcommand.bbmergeArguments(
                input: file, merged: out, unmerged: out2, minOverlap: 12, strict: true), both),
            ("IlluminaAmpliconPairMerger", IlluminaAmpliconPairMerger.bbmergeArguments(
                input: file, merged: out, unmerged: out2, threads: 2), both),
        ]
        for (site, argv, flags) in sites {
            assertStates(argv, flags, site)
        }
        for flag in ["maxcalledquality=93"] {
            for (site, argv, flags) in sites where flags == both {
                XCTAssertFalse(argv.contains(flag), "\(site) must not carry \(flag), which stops bbmerge")
            }
        }
    }

    func testTheMapperStatesTheInputEncoding() throws {
        let reference = URL(fileURLWithPath: "/tmp/qin/reference.fa")
        let output = URL(fileURLWithPath: "/tmp/qin/mapping")
        for modeID in [MappingMode.bbmapStandard.id, MappingMode.bbmapPacBio.id] {
            let request = MappingRunRequest(
                tool: .bbmap, modeID: modeID, inputFASTQURLs: [file], referenceFASTAURL: reference,
                outputDirectory: output, sampleName: "sample", pairedEnd: false, threads: 4, inputLayout: .singleEnd)
            let argv = try MappingCommandBuilder.buildCommand(
                for: request,
                referenceLocator: ReferenceLocator(
                    referenceURL: reference, indexPrefixURL: output.appendingPathComponent("reference-index"))
            ).arguments
            assertStates(argv, BBToolsQualityArguments.input, "MappingCommandBuilder \(modeID)")
        }
    }

    private func assertStates(
        _ argv: [String], _ flags: [String], _ site: String, line: UInt = #line
    ) {
        XCTAssertFalse(argv.isEmpty, "\(site) built no argv", line: line)
        for flag in flags {
            XCTAssertEqual(argv.filter { $0 == flag }.count, 1, "\(site) states \(flag) once, argv \(argv)", line: line)
        }
    }
}
