import Foundation
import XCTest
import LungfishCore
import LungfishIO
@testable import LungfishWorkflow

final class GenotypeReferenceRecordStoreSnapshotTests: XCTestCase {
    func testPublishesValidatedRecordStoreIntoResultBundle() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeReferenceRecordStoreSnapshotTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let referenceURL = root.appendingPathComponent("annotated.lungfishref", isDirectory: true)
        let sourceDatabaseURL = referenceURL.appendingPathComponent("metadata/genbank_records.sqlite")
        let resultURL = root.appendingPathComponent("result.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceDatabaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let record = GenBankRecord(
            sequence: try Sequence(name: "NHP01222", alphabet: .dna, bases: "ACGT"),
            annotations: [
                SequenceAnnotation(
                    type: .gene,
                    name: "Mafa-A1*006:01:02",
                    start: 0,
                    end: 4,
                    qualifiers: ["allele": AnnotationQualifier("Mafa-A1*006:01:02")]
                ),
            ],
            locus: LocusInfo(name: "NHP01222", length: 4, moleculeType: .dna, topology: .linear)
        )
        let created = try GenBankRecordDatabase.create(records: [record], at: sourceDatabaseURL)
        let manifest = BundleManifest(
            name: "Annotated MHC",
            identifier: "test.annotated-mhc",
            source: SourceInfo(organism: "Macaca fascicularis", assembly: "IPD-MHC"),
            recordStore: ReferenceRecordStoreInfo(
                schemaVersion: GenBankRecordDatabase.schemaVersion,
                format: ReferenceRecordStoreInfo.supportedFormat,
                databasePath: "metadata/genbank_records.sqlite",
                recordCount: created.recordCount
            )
        )
        try manifest.save(to: referenceURL)

        let published = try await GenotypeReferenceRecordStoreSnapshot.publish(
            fromReferenceBundle: referenceURL,
            toResultBundle: resultURL
        )
        let snapshot = try XCTUnwrap(published)

        XCTAssertEqual(snapshot.info.databasePath, "metadata/genbank_records.sqlite")
        XCTAssertEqual(snapshot.info.recordCount, 1)
        XCTAssertEqual(snapshot.info.fieldCount, created.fieldCount)
        XCTAssertEqual(snapshot.info.sizeBytes, Int64(try Data(contentsOf: snapshot.destinationURL).count))
        XCTAssertEqual(
            snapshot.info.sha256,
            try ProvenanceFileHasher.sha256(of: snapshot.destinationURL)
        )
        XCTAssertEqual(try Data(contentsOf: snapshot.sourceURL), try Data(contentsOf: snapshot.destinationURL))
        XCTAssertGreaterThanOrEqual(snapshot.completedAt, snapshot.startedAt)
    }

    func testReferenceWithoutRecordStoreReturnsNil() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeReferenceRecordStoreSnapshotTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let referenceURL = root.appendingPathComponent("fasta.lungfishref", isDirectory: true)
        let resultURL = root.appendingPathComponent("result.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: referenceURL, withIntermediateDirectories: true)
        try BundleManifest(
            name: "FASTA Reference",
            identifier: "test.fasta",
            source: SourceInfo(organism: "Macaca fascicularis", assembly: "custom")
        ).save(to: referenceURL)

        let snapshot = try await GenotypeReferenceRecordStoreSnapshot.publish(
            fromReferenceBundle: referenceURL,
            toResultBundle: resultURL
        )

        XCTAssertNil(snapshot)
    }
}
