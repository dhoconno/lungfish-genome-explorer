import CryptoKit
import Foundation
import XCTest
@testable import LungfishIO
@testable import LungfishWorkflow

final class AmpliconGenotypeScientificArtifactPublisherTests: XCTestCase {
    func testPublishesObservedNovelRecordsWithExactSequenceAndSortedSupport() throws {
        let fixture = try Fixture(
            csv: """
            sample,genotype,passed_alignments,passed_unique_reads
            SampleB,E_02_nov_17,4,3
            SampleA,Mafa-E*02:01,8,7
            SampleA,E_02_nov_17,9,8
            """,
            fasta: """
            >E_02_nov_17 exact run identity
            ACGTACGT
            >Mafa-E*02:01
            TTTT
            """
        )
        defer { fixture.remove() }

        let publication = try AmpliconGenotypeScientificArtifactPublisher().publish(
            reportCSVURL: fixture.csvURL,
            referenceFASTAURL: fixture.fastaURL,
            retainedBAMURL: fixture.bamURL,
            retainedBAIURL: fixture.baiURL,
            outputDirectoryURL: fixture.outputDirectory
        )

        let document = try XCTUnwrap(publication.provisionalExon2Document)
        XCTAssertEqual(document.records.map(\.genotype), ["E_02_nov_17"])
        XCTAssertEqual(document.records[0].fastaRecordID, "E_02_nov_17")
        XCTAssertEqual(document.records[0].sequenceLength, 8)
        XCTAssertEqual(document.records[0].sampleSupport.map(\.sample), ["SampleA", "SampleB"])
        XCTAssertEqual(document.records[0].sampleSupport.map(\.passedAlignments), [9, 4])
        XCTAssertEqual(document.records[0].sampleSupport.map(\.passedUniqueReads), [8, 3])
        XCTAssertEqual(
            try String(contentsOf: try XCTUnwrap(publication.sequencesFASTAURL), encoding: .utf8),
            ">E_02_nov_17 provisional_exon_2\nACGTACGT\n"
        )
        XCTAssertNotNil(publication.alignmentArtifacts.genotypingEvidence)
        XCTAssertNil(publication.alignmentArtifacts.reciprocalEvidence)
        XCTAssertEqual(publication.provisionalExon2Artifacts?.schemaVersion, 1)
    }

    func testNovelDetectionIsCaseInsensitiveAndSupportRowsAggregatePerSample() throws {
        let fixture = try Fixture(
            csv: """
            sample,genotype,passed_alignments,passed_unique_reads
            SampleA,E_02_NOV_17,3,2
            SampleA,E_02_NOV_17,4,3
            """,
            fasta: """
            >E_02_NOV_17
            ACGT
            """
        )
        defer { fixture.remove() }

        let publication = try AmpliconGenotypeScientificArtifactPublisher().publish(
            reportCSVURL: fixture.csvURL,
            referenceFASTAURL: fixture.fastaURL,
            retainedBAMURL: fixture.bamURL,
            retainedBAIURL: fixture.baiURL,
            outputDirectoryURL: fixture.outputDirectory
        )

        XCTAssertEqual(
            publication.provisionalExon2Document?.records.first?.sampleSupport,
            [
                ONTGenotypeProvisionalExon2SampleSupport(
                    sample: "SampleA",
                    passedAlignments: 7,
                    passedUniqueReads: 5
                ),
            ]
        )
    }

    func testPublishesOnlyEvidencePairWhenNoProvisionalCallsExist() throws {
        let fixture = try Fixture(
            csv: """
            sample,genotype,passed_alignments,passed_unique_reads
            SampleA,Mafa-E*02:01,8,7
            """,
            fasta: """
            >Mafa-E*02:01
            TTTT
            """
        )
        defer { fixture.remove() }

        let publication = try AmpliconGenotypeScientificArtifactPublisher().publish(
            reportCSVURL: fixture.csvURL,
            referenceFASTAURL: fixture.fastaURL,
            retainedBAMURL: fixture.bamURL,
            retainedBAIURL: fixture.baiURL,
            outputDirectoryURL: fixture.outputDirectory
        )

        XCTAssertNil(publication.provisionalExon2Document)
        XCTAssertNil(publication.provisionalExon2Artifacts)
        XCTAssertNil(publication.catalogJSONURL)
        XCTAssertNil(publication.sequencesFASTAURL)
        XCTAssertNotNil(publication.alignmentArtifacts.genotypingEvidence)
    }

    func testPublishesRepresentativeProvisionalCatalogWithinLinearBudget() throws {
        let genotypes = (0..<100).map {
            String(format: "Mafa-E_02_nov_%03d", $0)
        }
        let samples = (0..<52).map {
            String(format: "Sample%02d", $0)
        }
        var csvLines = [
            "sample,genotype,passed_alignments,passed_unique_reads",
        ]
        for genotype in genotypes {
            for sample in samples {
                csvLines.append("\(sample),\(genotype),9,8")
            }
        }
        let fasta = genotypes.map {
            ">\($0)\nACGTACGT"
        }.joined(separator: "\n")
        let fixture = try Fixture(
            csv: csvLines.joined(separator: "\n"),
            fasta: fasta
        )
        defer { fixture.remove() }

        let startedAt = Date()
        let publication = try AmpliconGenotypeScientificArtifactPublisher()
            .publish(
                reportCSVURL: fixture.csvURL,
                referenceFASTAURL: fixture.fastaURL,
                retainedBAMURL: fixture.bamURL,
                retainedBAIURL: fixture.baiURL,
                outputDirectoryURL: fixture.outputDirectory
            )
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertEqual(publication.provisionalExon2Document?.records.count, 100)
        XCTAssertTrue(
            publication.provisionalExon2Document?.records.allSatisfy {
                $0.sampleSupport.count == 52
            } == true
        )
        XCTAssertLessThan(
            elapsed,
            2.0,
            "Publishing should group support once instead of rescanning all support for every genotype"
        )
    }

    func testRejectsObservedNovelIdentifierMissingFromExactRunReference() throws {
        let fixture = try Fixture(
            csv: """
            sample,genotype,passed_alignments,passed_unique_reads
            SampleA,E_02_nov_17,8,7
            """,
            fasta: """
            >Mafa-E*02:01
            TTTT
            """
        )
        defer { fixture.remove() }

        XCTAssertThrowsError(
            try AmpliconGenotypeScientificArtifactPublisher().publish(
                reportCSVURL: fixture.csvURL,
                referenceFASTAURL: fixture.fastaURL,
                retainedBAMURL: fixture.bamURL,
                retainedBAIURL: fixture.baiURL,
                outputDirectoryURL: fixture.outputDirectory
            )
        ) { error in
            XCTAssertEqual(
                error as? AmpliconGenotypeScientificArtifactPublisherError,
                .missingReferenceRecord("E_02_nov_17")
            )
        }
    }

    private struct Fixture {
        let root: URL
        let outputDirectory: URL
        let csvURL: URL
        let fastaURL: URL
        let bamURL: URL
        let baiURL: URL

        init(csv: String, fasta: String) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("amplicon-science-\(UUID().uuidString)", isDirectory: true)
            outputDirectory = root.appendingPathComponent("result.lungfishgenotype", isDirectory: true)
            try FileManager.default.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: true
            )
            csvURL = outputDirectory.appendingPathComponent("result-genotypes.csv")
            fastaURL = root.appendingPathComponent("reference.fasta")
            bamURL = outputDirectory.appendingPathComponent("result.retained.demuxed.bam")
            baiURL = outputDirectory.appendingPathComponent("result.retained.demuxed.bam.bai")
            try Data((csv + "\n").utf8).write(to: csvURL)
            try Data((fasta + "\n").utf8).write(to: fastaURL)
            try Data("bam".utf8).write(to: bamURL)
            try Data("bai".utf8).write(to: baiURL)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
