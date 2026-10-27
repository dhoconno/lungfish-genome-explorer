// EsVirituDetectionExportLoaderTests.swift - The batch database reading the EsViritu viewer and its export leaf share
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.31 M3, ARCH ruling 1.1 row A1 and BIO ruling on 12.31 G1 (G1-2). The viewer and
// `esviritu export detections` build the exported result from the same rows with these functions.

import LungfishCore
import LungfishIO
import XCTest
@testable import LungfishWorkflow

final class EsVirituDetectionExportLoaderTests: XCTestCase {
    private static func row(
        sample: String,
        accession: String,
        assembly: String,
        readCount: Int,
        meanCoverage: Double? = 2,
        avgReadIdentity: Double? = 0.9,
        family: String? = "Picornaviridae",
        segment: String? = nil,
        contigLength: Int = 1_000,
        assemblyLength: Int = 2_000,
        rpkmf: Double = 1.5,
        filteredReads: Int = 10_000
    ) -> EsVirituDetectionRow {
        EsVirituDetectionRow(
            sample: sample,
            virusName: "virus \(assembly)",
            description: nil,
            contigLength: contigLength,
            segment: segment,
            accession: accession,
            assembly: assembly,
            assemblyLength: assemblyLength,
            kingdom: "Viruses",
            phylum: nil,
            tclass: nil,
            torder: "Picornavirales",
            family: family,
            genus: nil,
            species: "species \(assembly)",
            subspecies: nil,
            rpkmf: rpkmf,
            readCount: readCount,
            uniqueReads: nil,
            coveredBases: 500,
            meanCoverage: meanCoverage,
            avgReadIdentity: avgReadIdentity,
            pi: nil,
            filteredReadsInSample: filteredReads,
            bamPath: nil,
            bamIndexPath: nil
        )
    }

    func testDetectionReadsMissingValuesAsZeroOrEmpty() {
        let detection = EsVirituDetectionExport.detection(
            from: Self.row(sample: "sample-A", accession: "acc-1", assembly: "asm-1", readCount: 7, meanCoverage: nil)
        )
        XCTAssertEqual(detection.sampleId, "sample-A")
        XCTAssertEqual(detection.accession, "acc-1")
        XCTAssertEqual(detection.assembly, "asm-1")
        XCTAssertEqual(detection.description, "")
        XCTAssertEqual(detection.order, "Picornavirales")
        XCTAssertEqual(detection.readCount, 7)
        XCTAssertEqual(detection.meanCoverage, 0)
        XCTAssertEqual(detection.pi, 0)
        XCTAssertEqual(detection.length, 1_000)
    }

    func testAssemblyWeightsCoverageAndIdentityByReadCountAndKeepsRowOrder() throws {
        let group = [
            Self.row(sample: "sample-A", accession: "acc-2", assembly: "asm-1", readCount: 30, meanCoverage: 4, avgReadIdentity: 1),
            Self.row(sample: "sample-A", accession: "acc-1", assembly: "asm-1", readCount: 10, meanCoverage: 0, avgReadIdentity: 0.5),
        ]
        let assembly = try XCTUnwrap(EsVirituDetectionExport.assembly(from: group))
        XCTAssertEqual(assembly.totalReads, 40)
        XCTAssertEqual(assembly.meanCoverage, 3, accuracy: 1e-12)
        XCTAssertEqual(assembly.avgReadIdentity, 0.875, accuracy: 1e-12)
        XCTAssertEqual(assembly.contigs.map(\.accession), ["acc-2", "acc-1"])
        XCTAssertNil(EsVirituDetectionExport.assembly(from: []))
    }

    /// Walk row 18 (WO-2). An assembly of one contig reports that contig's identity to the last digit. Summing identity
    /// times reads and dividing by the reads gave 0.9969929135297526 for a contig at 0.9969929135297527 with 5 reads, so
    /// an assembly row copied one digit away from the export of its contig.
    func testAnAssemblyOfOneContigKeepsThatContigsIdentityToTheLastDigit() throws {
        let identity = 0.9969929135297527
        for reads in [5, 10, 20, 41, 79] {
            let row = Self.row(
                sample: "sample-A", accession: "acc-1", assembly: "asm-1", readCount: reads, avgReadIdentity: identity
            )
            let assembly = try XCTUnwrap(EsVirituDetectionExport.assembly(from: [row]))
            XCTAssertEqual(assembly.avgReadIdentity, identity, "one contig with \(reads) reads")
        }
        // Contigs of one identity weigh to that identity, whatever their reads.
        let group = [10, 3, 7].enumerated().map { index, reads in
            Self.row(
                sample: "sample-A", accession: "acc-\(index)", assembly: "asm-1", readCount: reads, avgReadIdentity: identity
            )
        }
        XCTAssertEqual(try XCTUnwrap(EsVirituDetectionExport.assembly(from: group)).avgReadIdentity, identity, "three contigs")
    }

    /// Contigs of different identities keep the read-weighted sum and divide, bit for bit (walk WO-2 changed only
    /// contigs of one identity).
    func testAnAssemblyOfContigsWithDifferentIdentitiesKeepsTheReadWeightedSumToTheLastDigit() throws {
        let parts: [(identity: Double, reads: Int)] = [(0.9969929135297527, 5), (0.98, 7), (0.9954517210367101, 41)]
        let rows = parts.enumerated().map { index, part in
            Self.row(
                sample: "sample-A", accession: "acc-\(index)", assembly: "asm-1",
                readCount: part.reads, avgReadIdentity: part.identity
            )
        }
        let total = parts.reduce(0) { $0 + $1.reads }
        let expected = parts.reduce(0.0) { $0 + $1.identity * Double($1.reads) } / Double(total)
        let assembly = try XCTUnwrap(EsVirituDetectionExport.assembly(from: rows))
        XCTAssertEqual(assembly.avgReadIdentity, expected, "different identities keep the old arithmetic exactly")
    }

    /// BIO-ASSEMBLY-RPKMF and -DEPTH. The viewer's builder measures a segmented virus over its whole genome, as the
    /// parser's builder does and as EsViritu's own assembly summary does. The assembly is 4000 bp. Its third segment of
    /// 1000 bp has no reads and so no row. The first row is segment 2, since EsViritu sorts segments as text.
    func testAssemblyFromRowsIsMeasuredOverTheWholeAssembly() throws {
        let rows = [
            Self.row(
                sample: "sample-A", accession: "seg-2", assembly: "asm-1", readCount: 5, meanCoverage: 0.75,
                segment: "2", contigLength: 1_000, assemblyLength: 4_000, rpkmf: 5.0, filteredReads: 1_000_000
            ),
            Self.row(
                sample: "sample-A", accession: "seg-1", assembly: "asm-1", readCount: 30, meanCoverage: 2.25,
                segment: "1", contigLength: 2_000, assemblyLength: 4_000, rpkmf: 15.0, filteredReads: 1_000_000
            ),
        ]
        let workflow = try XCTUnwrap(EsVirituDetectionExport.assembly(from: rows))
        XCTAssertEqual(workflow.rpkmf, 8.75, accuracy: 1e-9) // 35 / 4.0 / 1.0; sum 20, first row 5, detected length 11.67
        XCTAssertEqual(workflow.meanCoverage, 1.3125, accuracy: 1e-9) // (0.75 * 1000 + 2.25 * 2000) / 4000; read-weighted 2.0357

        // The parser's builder gives the same two numbers, so the two builders cannot part again.
        let parsed = try XCTUnwrap(EsVirituDetectionParser.groupByAssembly(workflow.contigs).first)
        XCTAssertEqual(workflow.rpkmf, parsed.rpkmf)
        XCTAssertEqual(workflow.meanCoverage, parsed.meanCoverage)
    }

    func testBatchResultKeepsTheSelectedSamplesInTheViewersOrder() {
        let rows = [
            Self.row(sample: "sample-B", accession: "b-1", assembly: "asm-9", readCount: 20),
            Self.row(sample: "sample-A", accession: "a-1", assembly: "asm-1", readCount: 5),
            Self.row(sample: "sample-A", accession: "a-2", assembly: "asm-2", readCount: 20),
            Self.row(sample: "sample-A", accession: "a-3", assembly: "asm-1", readCount: 5),
            Self.row(sample: "sample-C", accession: "c-1", assembly: "asm-1", readCount: 99),
        ]
        let result = EsVirituDetectionExport.batchResult(rows: rows, selectedSamples: ["sample-A", "sample-B"])
        XCTAssertEqual(result.sampleId, "batch")
        XCTAssertEqual(result.assemblies.map(\.assembly), ["asm-2", "asm-9", "asm-1"])
        XCTAssertEqual(result.detections.map(\.accession), ["a-2", "b-1", "a-1", "a-3"])
        XCTAssertEqual(result.detectedFamilyCount, 1)
        XCTAssertEqual(result.detectedSpeciesCount, 3)
    }

    func testBatchResultNamesItsOneSampleAndHoldsNothingWithNoSample() {
        let rows = [
            Self.row(sample: "sample-A", accession: "a-1", assembly: "asm-1", readCount: 5),
            Self.row(sample: "sample-B", accession: "b-1", assembly: "asm-1", readCount: 5),
        ]
        let one = EsVirituDetectionExport.batchResult(rows: rows, selectedSamples: ["sample-B"])
        XCTAssertEqual(one.sampleId, "sample-B")
        XCTAssertEqual(one.detections.map(\.accession), ["b-1"])

        let none = EsVirituDetectionExport.batchResult(rows: rows, selectedSamples: [])
        XCTAssertEqual(none.sampleId, "batch")
        XCTAssertTrue(none.detections.isEmpty)
    }

    func testAssembliesFollowTheViewersLookupKeys() {
        let lookup = EsVirituDetectionExport.assemblyLookup(rows: [
            Self.row(sample: "sample-A", accession: "a-1", assembly: "asm-1", readCount: 5),
            Self.row(sample: "sample-B", accession: "b-1", assembly: "asm-1", readCount: 5),
        ])
        XCTAssertEqual(
            Set(lookup.keys),
            [
                EsVirituDetectionExport.groupKey(sample: "sample-A", assembly: "asm-1"),
                EsVirituDetectionExport.groupKey(sample: "sample-B", assembly: "asm-1"),
            ]
        )
        XCTAssertEqual(EsVirituDetectionExport.groupKey(sample: "s", assembly: "a"), "s\ta")
        let picked = EsVirituDetectionExport.assemblies(in: lookup, selectedSamples: ["sample-B"])
        XCTAssertEqual(picked.flatMap(\.contigs).map(\.accession), ["b-1"])
    }

    func testMetadataTableMirrorsTheColumnController() throws {
        let store = try SampleMetadataStore(
            csvData: Data("Sample\tGroup\tSite\nsample-A\tcase\tnorth\nsample-B\tcontrol\t\n".utf8),
            knownSampleIds: ["sample-A", "sample-B", "sample-C"]
        )
        let table = EsVirituDetectionExport.metadataTable(
            store: store,
            visibleColumns: ["Site", "Group", "Missing"],
            sampleIds: ["sample-A", "sample-B", "sample-C"]
        )
        XCTAssertEqual(table.headers, ["Group", "Site"])
        XCTAssertEqual(table.valuesBySample["sample-A"], ["case", "north"])
        XCTAssertEqual(table.valuesBySample["sample-B"], ["control", ""])
        XCTAssertEqual(table.valuesBySample["sample-C"], ["", ""])

        let hidden = EsVirituDetectionExport.metadataTable(store: store, visibleColumns: [], sampleIds: ["sample-A"])
        XCTAssertEqual(hidden.headers, [])
        XCTAssertEqual(hidden.valuesBySample["sample-A"], [])

        let noStore = EsVirituDetectionExport.metadataTable(store: nil, visibleColumns: ["Group"], sampleIds: ["sample-A"])
        XCTAssertEqual(noStore.headers, [])
        XCTAssertTrue(noStore.valuesBySample.isEmpty)
    }
}
