// FASTQConsumerRegistryTests.swift - Every FASTQ-consuming tool declares its handling of every read layout
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class FASTQConsumerRegistryTests: XCTestCase {

    /// Every tool surface that hands FASTQ to an external tool. Adding a
    /// FASTQ consumer means adding its ID here AND a declaration in
    /// FASTQConsumerRegistry (or next to its builder, as the mappers do).
    private static let requiredConsumerIDs: [String] = [
        // Mappers (MappingTool+ReadLayout).
        "map.minimap2", "map.bwa-mem2", "map.bowtie2", "map.bbmap",
        // Classifiers.
        "classify.kraken2", "classify.esviritu", "classify.taxtriage",
        // Assemblers.
        "assemble.spades", "assemble.megahit", "assemble.skesa", "assemble.flye", "assemble.hifiasm",
        // lungfish-cli fastq subcommands.
        "fastq.subsample", "fastq.contaminant-filter", "fastq.entropy-filter", "fastq.deduplicate",
        "fastq.sequence-filter", "fastq.scrub-human", "fastq.deacon-ribo",
        "fastq.search-text", "fastq.search-motif", "fastq.repair",
        "fastq.trim", "fastq.quality-trim", "fastq.adapter-trim", "fastq.fixed-trim",
        "fastq.length-filter", "fastq.primer-remove", "fastq.error-correct", "fastq.ribodetector",
        "fastq.merge", "fastq.deinterleave", "fastq.interleave",
        // GUI in-process derivatives, ingestion, recipes, Workflow Builder.
        "gui.fastq-derivative", "ingest.clumpify",
        "recipe.convert-interleaved-to-paired", "workflow-builder.native-runner",
        // Genotyping, 12S, Viral Recon.
        "genotype.illumina-mhc", "genotype.ont-mhc", "twelve-s.amplicon-matching", "viralrecon.illumina",
    ]

    /// Consumers whose mixed handling pairs records by position. Every
    /// consumer now resolves its layout through FASTQInputLayoutResolver and
    /// either pairs mixed input by name or runs it as single reads, so the
    /// set is empty; adding an ID here is a deliberate act that needs its
    /// own fix scheduled.
    private static let knownUngracefulMixedConsumerIDs: Set<String> = []

    func testEveryRequiredConsumerIsDeclared() {
        let declaredIDs = Set(FASTQConsumerRegistry.declarations.map(\.consumerID))
        let missing = Self.requiredConsumerIDs.filter { !declaredIDs.contains($0) }
        XCTAssertTrue(missing.isEmpty, "FASTQ consumers without a read-layout declaration: \(missing)")
    }

    func testEveryDeclarationIsRequiredAndUnique() {
        let ids = FASTQConsumerRegistry.declarations.map(\.consumerID)
        XCTAssertEqual(ids.count, Set(ids).count, "duplicate consumer IDs: \(ids)")
        let required = Set(Self.requiredConsumerIDs)
        let unlisted = ids.filter { !required.contains($0) }
        XCTAssertTrue(unlisted.isEmpty, "declarations not in the required list: \(unlisted)")
    }

    func testEveryDeclarationCoversEveryLayout() {
        for declaration in FASTQConsumerRegistry.declarations {
            XCTAssertTrue(
                declaration.undeclaredLayouts.isEmpty,
                "\(declaration.consumerID) does not declare \(declaration.undeclaredLayouts)"
            )
            XCTAssertFalse(declaration.mixedRationale.isEmpty, declaration.consumerID)
            XCTAssertFalse(declaration.displayName.isEmpty, declaration.consumerID)
        }
    }

    func testMixedHandlingIsGracefulUnlessDeclaredOtherwise() {
        let ungraceful = Set(FASTQConsumerRegistry.consumersWithUngracefulMixedHandling.map(\.consumerID))
        XCTAssertEqual(ungraceful, Self.knownUngracefulMixedConsumerIDs)
        for declaration in FASTQConsumerRegistry.declarations where !declaration.mixedHandlingIsGraceful {
            XCTAssertNotEqual(
                declaration.handling(for: .mixedMergedAndPairs),
                .asSingle,
                "\(declaration.consumerID) maps mixed input as single reads, which is graceful by definition"
            )
        }
    }

    func testAlreadyFixedPathsDeclareTheContractDefaultForMixedInput() {
        for id in ["classify.kraken2", "classify.esviritu", "map.bowtie2", "map.bbmap"] {
            let declaration = try? XCTUnwrap(FASTQConsumerRegistry.declaration(for: id))
            XCTAssertEqual(declaration?.handling(for: .mixedMergedAndPairs), .asSingle, id)
            XCTAssertEqual(declaration?.handling(for: .pairedFiles), .asPairs, id)
        }
        XCTAssertEqual(FASTQConsumerRegistry.declaration(for: "classify.kraken2")?.handling(for: .strictlyInterleaved), .splitToR1R2)
        XCTAssertEqual(FASTQConsumerRegistry.declaration(for: "classify.esviritu")?.handling(for: .strictlyInterleaved), .asPairs)
    }

    /// The layout every resolver-backed consumer is handed for a bundle whose
    /// records alternate mates, by how its `single_end` was recorded. Only an
    /// explicit choice is final; a defaulted, detected, or pre-2026-09-25
    /// (`nil`) `single_end` is verified against the records. The
    /// SIMULATED-MHC-*-pairs regression: genotyping skipped the bbmerge step
    /// and found zero reads because a defaulted `single_end` was final.
    func testRecordedSingleEndIsFinalForEveryConsumerOnlyWhenExplicit() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("consumer-registry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let cases: [(IngestionMetadata.PairingSource?, FASTQInputLayout)] = [
            (.explicit, .singleEnd),
            (.defaulted, .strictlyInterleaved),
            (.detected, .strictlyInterleaved),
            (nil, .strictlyInterleaved),
        ]
        for (source, expected) in cases {
            let label = source?.rawValue ?? "legacy"
            let bundle = try InterleavedFASTQFixture.writeBundle(
                named: "mhc-pairs-\(label)",
                in: root,
                pairCount: 8,
                naming: .slashSuffix,
                pairingMode: .singleEnd,
                pairingSource: source
            )
            // Every consumer entry point: the bundle, the file inside it, and
            // a metadata-less scratch copy resolved with the bundle as hints.
            let scratch = root.appendingPathComponent("scratch-\(label).fastq")
            try FileManager.default.copyItem(at: bundle.fastqURL, to: scratch)
            let layouts = [
                FASTQInputLayoutResolver.resolve(inputURLs: [bundle.bundleURL]).layout,
                FASTQInputLayoutResolver.resolve(inputURLs: [bundle.fastqURL]).layout,
                FASTQInputLayoutResolver.resolve(fastqURL: scratch, metadataFrom: bundle.bundleURL).layout,
                FASTQPairingModeResolver.resolvePairing(inputURL: scratch, metadataFrom: bundle.bundleURL).layout,
            ]
            XCTAssertEqual(layouts, Array(repeating: expected, count: layouts.count), label)

            for declaration in FASTQConsumerRegistry.declarations {
                XCTAssertEqual(
                    declaration.handling(for: layouts[0]),
                    declaration.handling(for: expected),
                    "\(declaration.consumerID) (\(label))"
                )
            }
            XCTAssertEqual(
                FASTQConsumerRegistry.declaration(for: "genotype.illumina-mhc")?.handling(for: layouts[0]),
                expected == .singleEnd ? .asSingle : .asPairs,
                label
            )
        }
    }

    func testMappersComeFromTheirOwnDeclarations() {
        for tool in MappingTool.allCases {
            XCTAssertEqual(
                FASTQConsumerRegistry.declaration(for: tool.fastqConsumerDeclaration.consumerID),
                tool.fastqConsumerDeclaration
            )
        }
    }
}
