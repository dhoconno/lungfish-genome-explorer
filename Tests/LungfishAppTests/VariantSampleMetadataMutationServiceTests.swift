import XCTest
import LungfishCore
import LungfishIO
import LungfishWorkflow
@testable import LungfishApp

final class VariantSampleMetadataMutationServiceTests: XCTestCase {
    func testSampleMetadataEditWritesProvenanceForMutatedDatabase() throws {
        let fixture = try makeVariantBundle()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = try VariantSampleMetadataMutationService().updateSampleMetadata(
            sampleName: "SAMPLE_A",
            metadata: ["cohort": "treated"],
            bundleURL: fixture.bundleURL,
            targets: [VariantSampleMetadataImportTarget(databaseURL: fixture.databaseURL, trackName: "Variants")]
        )

        XCTAssertEqual(result.totalUpdated, 1)
        let db = try VariantDatabase(url: fixture.databaseURL)
        XCTAssertEqual(db.sampleMetadata(name: "SAMPLE_A")["cohort"], "treated")

        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: fixture.bundleURL))
        XCTAssertEqual(envelope.workflowName, "Variant sample metadata edit")
        XCTAssertEqual(envelope.options.explicit["sampleName"]?.stringValue, "SAMPLE_A")
        XCTAssertTrue(envelope.files.contains { $0.path == fixture.databaseURL.path && $0.role == .input })
        XCTAssertTrue(envelope.outputs.contains { $0.path == fixture.databaseURL.path && $0.role == .output })
        let inputDB = try XCTUnwrap(envelope.files.first {
            $0.path == fixture.databaseURL.path && $0.role == .input
        })
        let outputDB = try XCTUnwrap(envelope.outputs.first {
            $0.path == fixture.databaseURL.path && $0.role == .output
        })
        XCTAssertNotEqual(inputDB.checksumSHA256, outputDB.checksumSHA256)
    }

    func testDeleteMetadataFieldWritesProvenance() throws {
        let fixture = try makeVariantBundle()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        _ = try VariantSampleMetadataMutationService().updateSampleMetadata(
            sampleName: "SAMPLE_A",
            metadata: ["cohort": "treated", "site": "A"],
            bundleURL: fixture.bundleURL,
            targets: [VariantSampleMetadataImportTarget(databaseURL: fixture.databaseURL, trackName: "Variants")]
        )

        let result = try VariantSampleMetadataMutationService().deleteMetadataField(
            fieldName: "site",
            sampleRows: [
                VariantSampleMetadataMutationRow(
                    name: "SAMPLE_A",
                    sourceFile: "variants.vcf",
                    metadata: ["cohort": "treated", "site": "A"]
                )
            ],
            bundleURL: fixture.bundleURL,
            targets: [VariantSampleMetadataImportTarget(databaseURL: fixture.databaseURL, trackName: "Variants")]
        )

        XCTAssertEqual(result.totalUpdated, 1)
        let db = try VariantDatabase(url: fixture.databaseURL)
        XCTAssertEqual(db.sampleMetadata(name: "SAMPLE_A")["cohort"], "treated")
        XCTAssertNil(db.sampleMetadata(name: "SAMPLE_A")["site"])

        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: fixture.bundleURL))
        XCTAssertEqual(envelope.workflowName, "Variant sample metadata column deletion")
        XCTAssertEqual(envelope.options.explicit["fieldName"]?.stringValue, "site")
    }

    func testEditRestoresDatabaseWhenProvenanceWriteFails() throws {
        let fixture = try makeVariantBundle()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let service = VariantSampleMetadataMutationService { _, _ in
            throw IntentionalMutationProvenanceFailure.write
        }

        XCTAssertThrowsError(
            try service.updateSampleMetadata(
                sampleName: "SAMPLE_A",
                metadata: ["cohort": "treated"],
                bundleURL: fixture.bundleURL,
                targets: [VariantSampleMetadataImportTarget(databaseURL: fixture.databaseURL, trackName: "Variants")]
            )
        )

        let db = try VariantDatabase(url: fixture.databaseURL)
        XCTAssertNil(db.sampleMetadata(name: "SAMPLE_A")["cohort"])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.bundleURL.appendingPathComponent(ProvenanceWriter.provenanceFilename).path
        ))
    }

    private func makeVariantBundle() throws -> (root: URL, bundleURL: URL, databaseURL: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VariantSampleMetadataMutation-\(UUID().uuidString)", isDirectory: true)
        let bundleURL = root.appendingPathComponent("reference.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try "{}".write(
            to: bundleURL.appendingPathComponent(BundleManifest.filename),
            atomically: true,
            encoding: .utf8
        )
        let vcfURL = root.appendingPathComponent("variants.vcf")
        try """
        ##fileformat=VCFv4.2
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\tSAMPLE_A
        chr1\t100\t.\tA\tG\t50\tPASS\t.\tGT\t0/1
        """.write(to: vcfURL, atomically: true, encoding: .utf8)
        let databaseURL = bundleURL.appendingPathComponent("variants.db")
        try VariantDatabase.createFromVCF(
            vcfURL: vcfURL,
            outputURL: databaseURL,
            parseGenotypes: true,
            sourceFile: "variants.vcf",
            progressHandler: nil
        )
        return (root, bundleURL, databaseURL)
    }
}

private enum IntentionalMutationProvenanceFailure: Error {
    case write
}
