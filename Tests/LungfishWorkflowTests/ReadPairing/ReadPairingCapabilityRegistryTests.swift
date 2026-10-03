// ReadPairingCapabilityRegistryTests.swift - Every read consumer declares a pairing capability
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class ReadPairingCapabilityRegistryTests: XCTestCase {

    func testEveryFASTQConsumerDeclaresACapability() {
        let declared = Set(ReadPairingCapabilityRegistry.declarations.map(\.consumerID))
        let consumers = FASTQConsumerRegistry.declarations.map(\.consumerID)
        let missing = consumers.filter { !declared.contains($0) }
        XCTAssertTrue(missing.isEmpty, "FASTQ consumers without a read-pairing capability: \(missing)")
    }

    func testEveryCapabilityNamesAFASTQConsumerOnce() {
        let ids = ReadPairingCapabilityRegistry.declarations.map(\.consumerID)
        XCTAssertEqual(ids.count, Set(ids).count, "duplicate consumer IDs: \(ids)")
        let consumers = Set(FASTQConsumerRegistry.declarations.map(\.consumerID))
        let unknown = ids.filter { !consumers.contains($0) }
        XCTAssertTrue(unknown.isEmpty, "capabilities for consumers FASTQConsumerRegistry does not know: \(unknown)")
        for declaration in ReadPairingCapabilityRegistry.declarations {
            XCTAssertFalse(declaration.rationale.isEmpty, declaration.consumerID)
        }
    }

    /// The contract's capability table, tool by tool.
    func testCapabilitiesMatchTheContractTable() {
        let expected: [String: ReadPairingCapability] = [
            "map.minimap2": .bothInOneRunAsNameInterleavedStream,
            "map.bwa-mem2": .bothInOneRunAsNameInterleavedStream,
            "map.bowtie2": .bothInOneRunAsSeparateFiles,
            "map.bbmap": .pairsOrSinglesPerRun,
            "classify.kraken2": .bothInOneRunAsSeparateFiles,
            "classify.esviritu": .pairsOnlyWhenAllPaired,
            "classify.taxtriage": .pairsOnlyWhenAllPaired,
            "viralrecon.illumina": .pairsOnlyWhenAllPaired,
            "assemble.spades": .bothInOneRunAsSeparateFiles,
            "assemble.megahit": .bothInOneRunAsSeparateFiles,
            "assemble.skesa": .bothInOneRunAsSeparateFiles,
            "assemble.flye": .singleReadsOnly,
            "assemble.hifiasm": .singleReadsOnly,
            "genotype.ont-mhc": .singleReadsOnly,
            "twelve-s.amplicon-matching": .singleReadsOnly,
            "fastq.merge": .bothInOneRunAsNameInterleavedStream,
            "fastq.length-filter": .singleReadsOnly,
        ]
        for (id, capability) in expected {
            XCTAssertEqual(ReadPairingCapabilityRegistry.capability(for: id), capability, id)
        }
    }

    /// Lane A1 adds the resolver and no consumer runs on it yet. A lane that
    /// moves a tool onto the resolver flips `adopted` for it and adds its ID here.
    func testAdoptedConsumersAreTheOnesMovedOntoTheResolver() {
        let adopted = Set(ReadPairingCapabilityRegistry.declarations.filter(\.adopted).map(\.consumerID))
        XCTAssertEqual(adopted, [])
    }

    func testCapabilityKeepsSeparateFilesForKindsThatTakeOneForm() {
        XCTAssertEqual(ReadPairingCapability(kind: .singleReadsOnly, mixedInput: .nameInterleavedStream).mixedInput, .separateFiles)
        XCTAssertEqual(ReadPairingCapability.bothInOneRunAsNameInterleavedStream.provenanceName, "both_in_one_run/name_interleaved_stream")
        XCTAssertEqual(ReadPairingCapability.pairsOrSinglesPerRun.provenanceName, "pairs_or_singles_per_run")
    }
}
