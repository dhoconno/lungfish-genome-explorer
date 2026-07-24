import Foundation
import LungfishIO
import XCTest
@testable import LungfishWorkflow

final class FullLengthONTMHCFinalBAMParserTests: XCTestCase {
    func testRoutesCompleteCDNAEmbeddedInLongerClusterToCandidates() throws {
        let fixture = try Fixture.singleReference(
            referenceLength: 1_000,
            clusterLength: 3_000,
            moleculeClass: .cDNA
        )
        defer { fixture.remove() }
        try fixture.writeSAM(records: [
            fixture.record(
                qname: "allele-A",
                rname: "S1|cluster_ReadCount-8",
                position: 1_001,
                cigar: "1000="
            ),
        ])

        let summary = try XCTUnwrap(try fixture.parse(referenceRecords: fixture.annotatedReferences)["S1"])

        XCTAssertTrue(summary.rows.isEmpty)
        XCTAssertEqual(summary.unmatchedClusters.map(\.name), ["cluster_ReadCount-8"])
        XCTAssertTrue(summary.cdnaMatchedClusters.isEmpty)
        XCTAssertEqual(summary.cdnaStructuralInterpretations.map(\.relationship), [.extension])
        XCTAssertEqual(summary.cdnaStructuralInterpretations.map(\.referenceSequenceID), ["allele-A"])
    }

    func testRoutesSpliceGapCDNAAlignmentToCandidates() throws {
        let fixture = try Fixture.singleReference(
            referenceLength: 1_000,
            clusterLength: 2_000,
            moleculeClass: .cDNA
        )
        defer { fixture.remove() }
        try fixture.writeSAM(records: [
            fixture.record(
                qname: "allele-A",
                rname: "S1|cluster_ReadCount-8",
                cigar: "500=1000N500="
            ),
        ])

        let summary = try XCTUnwrap(try fixture.parse(referenceRecords: fixture.annotatedReferences)["S1"])

        XCTAssertTrue(summary.rows.isEmpty)
        XCTAssertEqual(summary.unmatchedClusters.map(\.name), ["cluster_ReadCount-8"])
        XCTAssertTrue(summary.cdnaMatchedClusters.isEmpty)
        XCTAssertEqual(summary.cdnaStructuralInterpretations.map(\.relationship), [.extension])
    }

    func testKeepsEndToEndCDNAMatchKnown() throws {
        let fixture = try Fixture.singleReference(
            referenceLength: 1_000,
            clusterLength: 1_000,
            moleculeClass: .cDNA
        )
        defer { fixture.remove() }
        try fixture.writeSAM(records: [
            fixture.record(qname: "allele-A", rname: "S1|cluster_ReadCount-8", cigar: "1000="),
        ])

        let summary = try XCTUnwrap(try fixture.parse(referenceRecords: fixture.annotatedReferences)["S1"])

        XCTAssertEqual(summary.rows.map(\.allele), ["allele-A"])
        XCTAssertTrue(summary.unmatchedClusters.isEmpty)
        XCTAssertEqual(summary.cdnaMatchedClusters.map(\.name), ["cluster_ReadCount-8"])
        XCTAssertEqual(summary.cdnaStructuralInterpretations.map(\.relationship), [.known])
    }

    func testRejectsCDNAAlignmentMissingTenPercentOfReference() throws {
        let fixture = try Fixture.singleReference(
            referenceLength: 1_000,
            clusterLength: 900,
            moleculeClass: .cDNA
        )
        defer { fixture.remove() }
        try fixture.writeSAM(records: [
            fixture.record(qname: "allele-A", rname: "S1|cluster_ReadCount-8", cigar: "100H900="),
        ])

        let summary = try XCTUnwrap(try fixture.parse(referenceRecords: fixture.annotatedReferences)["S1"])

        XCTAssertTrue(summary.rows.isEmpty)
        XCTAssertEqual(summary.unmatchedClusters.map(\.name), ["cluster_ReadCount-8"])
        XCTAssertTrue(summary.cdnaMatchedClusters.isEmpty)
        XCTAssertTrue(summary.cdnaStructuralInterpretations.isEmpty)
    }

    func testAnnotatedGenomicReferenceRemainsKnownBelowLengthFallbackThreshold() throws {
        let fixture = try Fixture.singleReference(
            referenceLength: 1_000,
            clusterLength: 1_000,
            moleculeClass: .genomicDNA
        )
        defer { fixture.remove() }
        try fixture.writeSAM(records: [
            fixture.record(qname: "allele-A", rname: "S1|cluster_ReadCount-8", cigar: "1000="),
        ])

        let summary = try XCTUnwrap(try fixture.parse(referenceRecords: fixture.annotatedReferences)["S1"])

        XCTAssertEqual(summary.rows.map(\.allele), ["allele-A"])
        XCTAssertTrue(summary.cdnaMatchedClusters.isEmpty)
    }

    func testAllowsOneBaseCDNAIndelInEndToEndKnownMatch() throws {
        let fixture = try Fixture.singleReference(
            referenceLength: 1_000,
            clusterLength: 999,
            moleculeClass: .cDNA
        )
        defer { fixture.remove() }
        try fixture.writeSAM(records: [
            fixture.record(
                qname: "allele-A",
                rname: "S1|cluster_ReadCount-8",
                cigar: "499=1I500=",
                nm: 1
            ),
        ])

        let summary = try XCTUnwrap(try fixture.parse(referenceRecords: fixture.annotatedReferences)["S1"])

        XCTAssertEqual(summary.rows.map(\.allele), ["allele-A"])
        XCTAssertEqual(summary.cdnaMatchedClusters.map(\.name), ["cluster_ReadCount-8"])
    }

    func testStreamsValidatedRecordsAndPreservesKnownTieUnmatchedClosestAndCDNAOutcomes() throws {
        let fixture = try Fixture(
            references: [
                ("allele-A", String(repeating: "A", count: 12)),
                ("allele-B", String(repeating: "C", count: 12)),
                ("allele-cDNA", String(repeating: "G", count: 4)),
            ],
            samples: [
                .init(
                    sampleID: "S1",
                    readGroupID: "rg-S1",
                    clusterRecords: [
                        .init(name: "known_ReadCount-8", sequence: String(repeating: "A", count: 12), readCount: 8),
                        .init(name: "cdna_ReadCount-7", sequence: String(repeating: "C", count: 12), readCount: 7),
                        .init(name: "unmatched_ReadCount-6", sequence: String(repeating: "G", count: 12), readCount: 6),
                    ]
                ),
            ]
        )
        defer { fixture.remove() }
        try fixture.writeSAM(
            headers: ["@RG\tID:rg-S1\tSM:S1"],
            records: [
                fixture.record(qname: "allele-A", rname: "S1|known_ReadCount-8", cigar: "12="),
                fixture.record(qname: "allele-B", rname: "S1|known_ReadCount-8", cigar: "12="),
                fixture.record(qname: "allele-cDNA", rname: "S1|cdna_ReadCount-7", cigar: "4=8I", nm: 8),
                fixture.record(qname: "allele-A", rname: "S1|unmatched_ReadCount-6", cigar: "11=1X", nm: 1),
            ]
        )

        let summaries = try fixture.parse(cdnaThreshold: 10, minUnmatchedReads: 5)
        let summary = try XCTUnwrap(summaries["S1"])

        XCTAssertEqual(summary.rows.map(\.allele), ["allele-A", "allele-B"])
        XCTAssertEqual(summary.rows.map(\.cluster), ["known_ReadCount-8", "known_ReadCount-8"])
        XCTAssertEqual(summary.unmatchedClusters.map(\.name), ["cdna_ReadCount-7", "unmatched_ReadCount-6"])
        XCTAssertEqual(summary.cdnaMatchedClusters.map(\.name), [])
        XCTAssertEqual(summary.closestMatches.map(\.closestReference), ["allele-A", "allele-cDNA"])
        XCTAssertEqual(summary.closestMatches.map(\.cluster), ["unmatched_ReadCount-6", "cdna_ReadCount-7"])
    }

    func testAcceptsTerminalHardClipsFromFinalBAMValidation() throws {
        let fixture = try Fixture(
            references: [("allele-A", String(repeating: "A", count: 453))],
            samples: [
                .init(
                    sampleID: "S1",
                    readGroupID: "rg-S1",
                    clusterRecords: [
                        .init(
                            name: "cluster_ReadCount-8",
                            sequence: String(repeating: "A", count: 12),
                            readCount: 8
                        ),
                    ]
                ),
            ],
            moleculeClasses: ["allele-A": .genomicDNA]
        )
        defer { fixture.remove() }
        try fixture.writeSAM(records: [
            fixture.record(
                qname: "allele-A",
                rname: "S1|cluster_ReadCount-8",
                cigar: "426H12=15H"
            ),
        ])

        let summary = try XCTUnwrap(
            try fixture.parse(referenceRecords: fixture.annotatedReferences)["S1"]
        )

        XCTAssertEqual(summary.rows.map(\.allele), ["allele-A"])
        XCTAssertEqual(summary.rows.map(\.cluster), ["cluster_ReadCount-8"])
        XCTAssertTrue(summary.unmatchedClusters.isEmpty)
    }

    func testRejectsUnknownTargetWithLineAndContext() throws {
        let fixture = try Fixture.standard()
        defer { fixture.remove() }
        try fixture.writeSAM(
            records: [fixture.record(qname: "allele-A", rname: "S1|unknown", cigar: "12=")]
        )

        XCTAssertThrowsError(try fixture.parse()) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("line 4"), message)
            XCTAssertTrue(message.contains("unknown target 'S1|unknown'"), message)
            XCTAssertTrue(message.contains("allele-A"), message)
        }
    }

    func testRejectsUnknownAlleleWithLineAndContext() throws {
        let fixture = try Fixture.standard()
        defer { fixture.remove() }
        try fixture.writeSAM(
            records: [fixture.record(qname: "unknown-allele", rname: "S1|cluster_ReadCount-8", cigar: "12=")]
        )

        XCTAssertThrowsError(try fixture.parse()) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("line 4"), message)
            XCTAssertTrue(message.contains("unknown allele QNAME 'unknown-allele'"), message)
        }
    }

    func testRejectsMalformedMandatoryFieldsAndFlag() throws {
        let fixture = try Fixture.standard()
        defer { fixture.remove() }

        try fixture.writeSAM(records: ["allele-A\tnot-a-flag\tS1|cluster_ReadCount-8\t1\t60\t12=\t*\t0\t0\t*\t*\tRG:Z:rg-S1\tNM:i:0"])
        XCTAssertThrowsError(try fixture.parse()) { error in
            XCTAssertTrue(error.localizedDescription.contains("invalid FLAG 'not-a-flag'"), error.localizedDescription)
        }

        try fixture.writeSAM(records: ["allele-A\t0\tS1|cluster_ReadCount-8\t1\t60"])
        XCTAssertThrowsError(try fixture.parse()) { error in
            XCTAssertTrue(error.localizedDescription.contains("11 mandatory fields"), error.localizedDescription)
        }
    }

    func testRejectsDuplicateAndContradictoryReadGroupDeclarations() throws {
        let fixture = try Fixture.standard()
        defer { fixture.remove() }

        try fixture.writeSAM(
            headers: ["@RG\tID:rg-S1\tSM:S1", "@RG\tID:rg-S1\tSM:S1"],
            records: []
        )
        XCTAssertThrowsError(try fixture.parse()) { error in
            XCTAssertTrue(error.localizedDescription.contains("duplicate @RG ID 'rg-S1'"), error.localizedDescription)
        }

        try fixture.writeSAM(
            headers: ["@RG\tID:rg-S1\tSM:S1", "@RG\tID:rg-S1\tSM:S2"],
            records: []
        )
        XCTAssertThrowsError(try fixture.parse()) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("conflicting @RG ID 'rg-S1'"), message)
            XCTAssertTrue(message.contains("line 4"), message)
        }
    }

    func testRequiresEveryDeclaredTargetAndReadGroupHeaderExactlyOnce() throws {
        let fixture = try Fixture.standard()
        defer { fixture.remove() }

        try fixture.writeSAM(headers: [], records: [])
        XCTAssertThrowsError(try fixture.parse()) { error in
            XCTAssertTrue(error.localizedDescription.contains("missing expected @RG ID 'rg-S1'"), error.localizedDescription)
        }

        try fixture.writeSAM(includeSequenceHeaders: false, records: [])
        XCTAssertThrowsError(try fixture.parse()) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("missing expected @SQ SN 'S1|cluster_ReadCount-8'"),
                error.localizedDescription
            )
        }
    }

    func testRejectsCrossSampleTargetAndReadGroupEvidence() throws {
        let fixture = try Fixture(
            references: [("allele-A", String(repeating: "A", count: 12))],
            samples: [
                .init(
                    sampleID: "S1",
                    readGroupID: "rg-S1",
                    clusterRecords: [.init(name: "c1", sequence: String(repeating: "A", count: 12), readCount: 8)]
                ),
                .init(
                    sampleID: "S2",
                    readGroupID: "rg-S2",
                    clusterRecords: [.init(name: "c2", sequence: String(repeating: "C", count: 12), readCount: 8)]
                ),
            ]
        )
        defer { fixture.remove() }
        try fixture.writeSAM(
            headers: ["@RG\tID:rg-S1\tSM:S1", "@RG\tID:rg-S2\tSM:S2"],
            records: [fixture.record(qname: "allele-A", rname: "S1|c1", cigar: "12=", readGroupID: "rg-S2")]
        )

        XCTAssertThrowsError(try fixture.parse()) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("read group sample 'S2' does not match target sample 'S1'"), message)
            XCTAssertTrue(message.contains("S1|c1"), message)
        }
    }

    func testRejectsDuplicateOrMalformedAlignmentReadGroupTags() throws {
        let fixture = try Fixture.standard()
        defer { fixture.remove() }
        let prefix = "allele-A\t0\tS1|cluster_ReadCount-8\t1\t60\t12=\t*\t0\t0\t*\t*"

        try fixture.writeSAM(records: [prefix + "\tRG:Z:rg-S1\tRG:Z:rg-S1\tNM:i:0"])
        XCTAssertThrowsError(try fixture.parse()) { error in
            XCTAssertTrue(error.localizedDescription.contains("exactly one RG tag"), error.localizedDescription)
        }

        try fixture.writeSAM(records: [prefix + "\tRG:i:1\tNM:i:0"])
        XCTAssertThrowsError(try fixture.parse()) { error in
            XCTAssertTrue(error.localizedDescription.contains("valid RG:Z tag"), error.localizedDescription)
        }
    }

    func testRejectsOutOfBoundsCoordinateAndTask2CIGARFailure() throws {
        let fixture = try Fixture.standard()
        defer { fixture.remove() }

        try fixture.writeSAM(records: [fixture.record(qname: "allele-A", rname: "S1|cluster_ReadCount-8", position: 2, cigar: "12=")])
        XCTAssertThrowsError(try fixture.parse()) { error in
            XCTAssertTrue(error.localizedDescription.contains("extends beyond target length 12"), error.localizedDescription)
        }

        try fixture.writeSAM(records: [fixture.record(qname: "allele-A", rname: "S1|cluster_ReadCount-8", cigar: "0M")])
        XCTAssertThrowsError(try fixture.parse()) { error in
            XCTAssertTrue(error.localizedDescription.contains("invalid CIGAR"), error.localizedDescription)
        }
    }

    func testExplicitlySkipsStructurallyValidUnmappedRecords() throws {
        let fixture = try Fixture.standard()
        defer { fixture.remove() }
        try fixture.writeSAM(records: [
            "allele-A\t4\t*\t0\t0\t*\t*\t0\t0\t*\t*",
        ])

        let summary = try XCTUnwrap(try fixture.parse()["S1"])

        XCTAssertTrue(summary.rows.isEmpty)
        XCTAssertEqual(summary.unmatchedClusters.map(\.name), ["cluster_ReadCount-8"])
        XCTAssertTrue(summary.closestMatches.isEmpty)
    }

    func testLargeInputIsConsumedOneRecordAtATime() throws {
        let fixture = try Fixture.standard()
        defer { fixture.remove() }
        let recordCount = 25_000
        try fixture.writeSAM(records: (0..<recordCount).map { _ in
            fixture.record(qname: "allele-A", rname: "S1|cluster_ReadCount-8", cigar: "12=")
        })
        let observation = RecordLifecycleObservation()
        let parser = FullLengthONTMHCFinalBAMParser(recordLifecycleObserver: observation.observe)

        let summaries = try fixture.parse(using: parser)

        XCTAssertEqual(observation.recordCount, recordCount)
        XCTAssertEqual(observation.maximumRecordsInFlight, 1)
        XCTAssertEqual(summaries["S1"]?.rows.map(\.allele), ["allele-A"])
    }

    func testCancelledParseStopsWithoutProducingSummaries() async throws {
        let fixture = try Fixture.standard()
        defer { fixture.remove() }
        try fixture.writeSAM(records: (0..<25_000).map { _ in
            fixture.record(qname: "allele-A", rname: "S1|cluster_ReadCount-8", cigar: "12=")
        })
        let task = Task {
            try fixture.parse()
        }

        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected final BAM parsing cancellation")
        } catch is CancellationError {
            // Expected.
        }
    }
}

private extension FullLengthONTMHCFinalBAMParserTests {
    final class RecordLifecycleObservation: @unchecked Sendable {
        private let lock = NSLock()
        private var recordsInFlight = 0
        private(set) var maximumRecordsInFlight = 0
        private(set) var recordCount = 0

        func observe(_ event: FullLengthONTMHCFinalBAMRecordLifecycleEvent) {
            lock.withLock {
                switch event {
                case .willProcess:
                    recordsInFlight += 1
                    maximumRecordsInFlight = max(maximumRecordsInFlight, recordsInFlight)
                case .didProcess:
                    recordsInFlight -= 1
                    recordCount += 1
                }
            }
        }
    }

    struct Fixture {
        let root: URL
        let referenceURL: URL
        let samURL: URL
        let references: [(String, String)]
        let samples: [FullLengthONTMHCFinalBAMSampleContext]
        let annotatedReferences: [MHCReferenceRecord]

        init(
            references: [(String, String)],
            samples: [FullLengthONTMHCFinalBAMSampleContext],
            moleculeClasses: [String: MHCReferenceMoleculeClass] = [:]
        ) throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "full-length-ont-mhc-final-bam-parser-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            self.root = root
            self.referenceURL = root.appendingPathComponent("reference.fasta")
            self.samURL = root.appendingPathComponent("view.sam")
            self.references = references
            self.samples = samples
            self.annotatedReferences = references.map { reference in
                let moleculeClass = moleculeClasses[reference.0]
                    ?? (reference.1.count < 2_000 ? .cDNA : .genomicDNA)
                return MHCReferenceRecord(
                    sequenceID: reference.0,
                    alleleName: reference.0,
                    locus: "A",
                    moleculeClass: moleculeClass,
                    classEvidence: moleculeClasses[reference.0] == nil
                        ? .lengthThresholdFallback
                        : .annotatedMetadata,
                    sequenceLength: reference.1.count
                )
            }
            try references.map { ">\($0.0)\n\($0.1)\n" }
                .joined()
                .write(to: referenceURL, atomically: true, encoding: .utf8)
        }

        static func singleReference(
            referenceLength: Int,
            clusterLength: Int,
            moleculeClass: MHCReferenceMoleculeClass
        ) throws -> Fixture {
            try Fixture(
                references: [("allele-A", String(repeating: "A", count: referenceLength))],
                samples: [
                    .init(
                        sampleID: "S1",
                        readGroupID: "rg-S1",
                        clusterRecords: [
                            .init(
                                name: "cluster_ReadCount-8",
                                sequence: String(repeating: "A", count: clusterLength),
                                readCount: 8
                            ),
                        ]
                    ),
                ],
                moleculeClasses: ["allele-A": moleculeClass]
            )
        }

        static func standard() throws -> Fixture {
            try Fixture(
                references: [("allele-A", String(repeating: "A", count: 12))],
                samples: [
                    .init(
                        sampleID: "S1",
                        readGroupID: "rg-S1",
                        clusterRecords: [
                            .init(
                                name: "cluster_ReadCount-8",
                                sequence: String(repeating: "A", count: 12),
                                readCount: 8
                            ),
                        ]
                    ),
                ]
            )
        }

        func writeSAM(
            headers: [String]? = nil,
            includeSequenceHeaders: Bool = true,
            records: [String]
        ) throws {
            let readGroups = headers ?? samples.compactMap { sample in
                sample.readGroupID.map { "@RG\tID:\($0)\tSM:\(sample.sampleID)" }
            }
            let sequenceHeaders = includeSequenceHeaders ? samples.flatMap { sample in
                sample.clusterRecords.map { "@SQ\tSN:\(sample.sampleID)|\($0.name)\tLN:\($0.sequence.count)" }
            } : []
            let lines = ["@HD\tVN:1.6\tSO:coordinate"] + sequenceHeaders + readGroups + records
            try (lines.joined(separator: "\n") + "\n").write(
                to: samURL,
                atomically: true,
                encoding: .utf8
            )
        }

        func record(
            qname: String,
            rname: String,
            position: Int = 1,
            cigar: String,
            readGroupID: String = "rg-S1",
            nm: Int = 0
        ) -> String {
            "\(qname)\t0\t\(rname)\t\(position)\t60\t\(cigar)\t*\t0\t0\t*\t*\tRG:Z:\(readGroupID)\tNM:i:\(nm)"
        }

        func parse(
            using parser: FullLengthONTMHCFinalBAMParser = .init(),
            referenceRecords: [MHCReferenceRecord]? = nil,
            cdnaThreshold: Int = 2_000,
            minUnmatchedReads: Int = 5
        ) throws -> [String: FullLengthONTMHCClusterGenotypingSummary] {
            try parser.genotypeSummaries(
                samURL: samURL,
                referenceFASTAURL: referenceURL,
                referenceRecords: referenceRecords,
                samples: samples,
                cdnaThreshold: cdnaThreshold,
                minUnmatchedReads: minUnmatchedReads
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
