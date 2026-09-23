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
        // REC-01: inputs now go through `VariantMutationPublication`, which
        // records the database's SQLite *snapshot* path as `.path` and the
        // real database location as `.originPath` (matching the sibling
        // `VariantSampleMetadataImportService`, which already uses this path).
        XCTAssertTrue(envelope.files.contains { $0.originPath == fixture.databaseURL.path && $0.role == .input })
        XCTAssertTrue(envelope.outputs.contains { $0.path == fixture.databaseURL.path && $0.role == .output })
        let inputDB = try XCTUnwrap(envelope.files.first {
            $0.originPath == fixture.databaseURL.path && $0.role == .input
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

    /// REC-01 regression: when both the provenance write AND the SQLite
    /// restoration fail, the service must surface a
    /// `ScientificPublicationRecoveryRequired` carrying both error
    /// descriptions and keep the recovery snapshot on disk, instead of
    /// silently swallowing the restore failure (the old `try?`-based
    /// `restore(_:)`) and deleting its only backup via an unconditional
    /// `defer`.
    func testFailedRestorationAfterProvenanceFailureRetainsRecoveryAndBothErrors() throws {
        let fixture = try makeVariantBundle()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let provenance = fixture.bundleURL.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        let previous = Data("previous provenance".utf8)
        try previous.write(to: provenance)

        let manager = RestorationFailingFileManager(destination: provenance)
        let writer = ProvenanceWriter(publicationMutationDidOccur: { mutation in
            if mutation.affectedURLs.contains(provenance) {
                manager.failRestoration = true
                throw IntentionalMutationProvenanceFailure.write
            }
        }, signingProvider: nil)
        let service = VariantSampleMetadataMutationService(fileManager: manager, provenanceWriter: writer)

        do {
            _ = try service.updateSampleMetadata(
                sampleName: "SAMPLE_A",
                metadata: ["cohort": "treated"],
                bundleURL: fixture.bundleURL,
                targets: [VariantSampleMetadataImportTarget(databaseURL: fixture.databaseURL, trackName: "Variants")]
            )
            XCTFail("Expected explicit recovery-required error")
        } catch let error as ScientificPublicationRecoveryRequired {
            defer { for url in error.recoveryURLs { try? FileManager.default.removeItem(at: url) } }
            XCTAssertTrue(error.originalErrorDescription.contains("IntentionalMutationProvenanceFailure"))
            XCTAssertTrue(error.restorationErrorDescription.contains("restoration blocked"))
            XCTAssertTrue(
                error.recoveryURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) },
                "Recovery artifacts must survive an unrecoverable failure, not be deleted"
            )
            // Only the provenance sidecar restoration was blocked by the
            // fault; the SQLite mutation itself is successfully rolled back
            // via `restorePublicationSnapshot`, so the database is back to
            // its pre-mutation state. The recovery snapshot retained above is
            // what lets a human confirm this and finish the cleanup by hand.
            XCTAssertNil(
                try VariantDatabase(url: fixture.databaseURL).sampleMetadata(name: "SAMPLE_A")["cohort"]
            )
        }
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

private final class RestorationFailingFileManager: FileManager, @unchecked Sendable {
    let destination: URL
    var failRestoration = false
    init(destination: URL) { self.destination = destination; super.init() }
    override func copyItem(at source: URL, to destination: URL) throws {
        if failRestoration && destination.deletingLastPathComponent() == self.destination.deletingLastPathComponent()
            && destination.lastPathComponent.contains(".provenance-restore-") {
            throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "restoration blocked"])
        }
        try super.copyItem(at: source, to: destination)
    }
}
