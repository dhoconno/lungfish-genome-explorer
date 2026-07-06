import XCTest
import LungfishCore
import LungfishIO
import LungfishWorkflow
@testable import LungfishApp

final class VariantSampleMetadataImportServiceTests: XCTestCase {
    func testImportWritesProvenanceForMutatedVariantDatabase() throws {
        let fixture = try makeVariantBundle()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let metadataURL = fixture.root.appendingPathComponent("metadata.tsv")
        try """
        sample_name\tcohort\tanimal
        SAMPLE_A\ttreated\tmacaque
        SAMPLE_B\tcontrol\tmacaque
        """.write(to: metadataURL, atomically: true, encoding: .utf8)

        let result = try VariantSampleMetadataImportService().importMetadata(
            from: metadataURL,
            format: .tsv,
            bundleURL: fixture.bundleURL,
            targets: [VariantSampleMetadataImportTarget(databaseURL: fixture.databaseURL, trackName: "Variants")]
        )

        XCTAssertEqual(result.totalUpdated, 2)
        let db = try VariantDatabase(url: fixture.databaseURL)
        XCTAssertEqual(db.sampleMetadata(name: "SAMPLE_A")["cohort"], "treated")
        XCTAssertEqual(db.sampleMetadata(name: "SAMPLE_B")["cohort"], "control")

        let provenanceURL = fixture.bundleURL.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        XCTAssertEqual(result.provenanceURL, provenanceURL)
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: fixture.bundleURL))
        XCTAssertEqual(envelope.workflowName, "Variant sample metadata import")
        XCTAssertEqual(envelope.options.resolvedDefaults["totalUpdated"]?.integerValue, 2)
        XCTAssertTrue(envelope.files.contains { $0.path == metadataURL.path && $0.role == .input })
        XCTAssertTrue(envelope.files.contains { $0.path == fixture.databaseURL.path && $0.role == .input })
        XCTAssertTrue(envelope.outputs.contains {
            $0.path == fixture.databaseURL.path && $0.role == .output && $0.checksumSHA256 != nil
        })
        let inputDB = try XCTUnwrap(envelope.files.first {
            $0.path == fixture.databaseURL.path && $0.role == .input
        })
        let outputDB = try XCTUnwrap(envelope.outputs.first {
            $0.path == fixture.databaseURL.path && $0.role == .output
        })
        XCTAssertNotEqual(inputDB.checksumSHA256, outputDB.checksumSHA256)

        let rollupURL = fixture.bundleURL
            .appendingPathComponent(ProvenanceWriter.bundleProvenanceDirectoryName, isDirectory: true)
            .appendingPathComponent(ProvenanceWriter.bundleRollupFilename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rollupURL.path))
        let databaseSidecarURL = try XCTUnwrap(
            ProvenanceWriter.bundleOutputSidecarURL(for: fixture.databaseURL, inBundle: fixture.bundleURL)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: databaseSidecarURL.path))
    }

    func testImportRestoresDatabaseWhenProvenanceWriteFails() throws {
        let fixture = try makeVariantBundle()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let metadataURL = fixture.root.appendingPathComponent("metadata.tsv")
        try """
        sample_name\tcohort
        SAMPLE_A\ttreated
        """.write(to: metadataURL, atomically: true, encoding: .utf8)

        let service = VariantSampleMetadataImportService { _, _ in
            throw IntentionalProvenanceFailure.write
        }

        XCTAssertThrowsError(
            try service.importMetadata(
                from: metadataURL,
                format: .tsv,
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
            .appendingPathComponent("VariantSampleMetadataImport-\(UUID().uuidString)", isDirectory: true)
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
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\tSAMPLE_A\tSAMPLE_B
        chr1\t100\t.\tA\tG\t50\tPASS\t.\tGT\t0/1\t0/0
        """.write(to: vcfURL, atomically: true, encoding: .utf8)
        let databaseURL = bundleURL.appendingPathComponent("variants.db")
        try VariantDatabase.createFromVCF(vcfURL: vcfURL, outputURL: databaseURL)
        return (root, bundleURL, databaseURL)
    }
}

private enum IntentionalProvenanceFailure: Error {
    case write
}
