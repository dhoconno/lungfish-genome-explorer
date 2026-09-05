import XCTest
import SQLite3
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
        XCTAssertTrue(envelope.files.contains { $0.originPath == metadataURL.path && $0.role == .input })
        XCTAssertTrue(envelope.files.contains { $0.originPath == fixture.databaseURL.path && $0.role == .input })
        XCTAssertTrue(envelope.outputs.contains {
            $0.path == fixture.databaseURL.path && $0.role == .output && $0.checksumSHA256 != nil
        })
        let inputDB = try XCTUnwrap(envelope.files.first {
            $0.originPath == fixture.databaseURL.path && $0.role == .input
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

    func testProvenanceFailureRestoresLiveReaderAndPreviousProvenance() throws {
        let fixture = try makeVariantBundle()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let metadataURL = fixture.root.appendingPathComponent("metadata.tsv")
        try "sample\tcohort\nSAMPLE_A\tnew\n".write(to: metadataURL, atomically: true, encoding: .utf8)
        let reader = try VariantDatabase(url: fixture.databaseURL)
        let provenanceURL = fixture.bundleURL.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        try ProvenanceWriter(signingProvider: nil).write(ProvenanceEnvelope(workflowName: "Previous fixture",
            toolName: "fixture", toolVersion: "1", argv: ["/bin/true"], exitStatus: 0), to: fixture.bundleURL)
        let original = try Data(contentsOf: provenanceURL)
        let service = VariantSampleMetadataImportService(provenanceWriter: ProvenanceWriter(publicationMutationDidOccur: { mutation in
            if mutation.affectedURLs.contains(provenanceURL) { throw IntentionalProvenanceFailure.write }
        }, signingProvider: nil))
        XCTAssertThrowsError(try service.importMetadata(from: metadataURL, format: .tsv,
            bundleURL: fixture.bundleURL, targets: [VariantSampleMetadataImportTarget(databaseURL: fixture.databaseURL)]))
        XCTAssertNil(reader.sampleMetadata(name: "SAMPLE_A")["cohort"])
        XCTAssertNil(try VariantDatabase(url: fixture.databaseURL).sampleMetadata(name: "SAMPLE_A")["cohort"])
        XCTAssertEqual(try Data(contentsOf: provenanceURL), original)
    }

    func testRollbackPreservesCommittedWALMetadataAndLiveReader() throws {
        let fixture = try makeVariantBundle()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(fixture.databaseURL.path, &connection), SQLITE_OK)
        defer { sqlite3_close(connection) }
        XCTAssertEqual(sqlite3_exec(connection, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; UPDATE samples SET metadata='{\"existing\":\"retained\"}';", nil, nil, nil), SQLITE_OK)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.databaseURL.path + "-wal"))
        let reader = try VariantDatabase(url: fixture.databaseURL)
        let metadata = fixture.root.appendingPathComponent("metadata.tsv")
        try "sample\tcohort\nSAMPLE_A\tnew\n".write(to: metadata, atomically: true, encoding: .utf8)
        let service = VariantSampleMetadataImportService { _, _ in throw IntentionalProvenanceFailure.write }
        XCTAssertThrowsError(try service.importMetadata(from: metadata, format: .tsv,
            bundleURL: fixture.bundleURL, targets: [.init(databaseURL: fixture.databaseURL)])) { error in
            XCTAssertFalse(error is ScientificPublicationRecoveryRequired, "Unexpected restoration failure: \(error)")
        }
        XCTAssertNil(try VariantDatabase(url: fixture.databaseURL).sampleMetadata(name: "SAMPLE_A")["cohort"])
        XCTAssertEqual(reader.sampleMetadata(name: "SAMPLE_A")["existing"], "retained")
        XCTAssertNil(reader.sampleMetadata(name: "SAMPLE_A")["cohort"])
        XCTAssertEqual(try VariantDatabase(url: fixture.databaseURL).sampleMetadata(name: "SAMPLE_A")["existing"], "retained")
    }

    func testFailedProvenanceRestorationRetainsRecoveryAndBothErrors() throws {
        let fixture = try makeVariantBundle()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let provenance = fixture.bundleURL.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        let previous = Data("previous provenance".utf8)
        try previous.write(to: provenance)
        let metadata = fixture.root.appendingPathComponent("metadata.tsv")
        try "sample\tcohort\nSAMPLE_A\tnew\n".write(to: metadata, atomically: true, encoding: .utf8)
        let manager = RestorationFailingFileManager(destination: provenance)
        let writer = ProvenanceWriter(publicationMutationDidOccur: { mutation in
            if mutation.affectedURLs.contains(provenance) {
                manager.failRestoration = true
                throw IntentionalProvenanceFailure.write
            }
        }, signingProvider: nil)
        let service = VariantSampleMetadataImportService(fileManager: manager, provenanceWriter: writer)
        do {
            _ = try service.importMetadata(from: metadata, format: .tsv, bundleURL: fixture.bundleURL,
                targets: [.init(databaseURL: fixture.databaseURL)])
            XCTFail("Expected explicit recovery-required error")
        } catch let error as ScientificPublicationRecoveryRequired {
            defer { for url in error.recoveryURLs { try? FileManager.default.removeItem(at: url) } }
            XCTAssertTrue(error.originalErrorDescription.contains("IntentionalProvenanceFailure"))
            XCTAssertTrue(error.restorationErrorDescription.contains("restoration blocked"))
            let recovery = try XCTUnwrap(error.recoveryURLs.first { $0.lastPathComponent.hasPrefix("variant-provenance-recovery") })
            XCTAssertEqual(try Data(contentsOf: recovery.appendingPathComponent("artifact-0")), previous)
            XCTAssertNil(try VariantDatabase(url: fixture.databaseURL).sampleMetadata(name: "SAMPLE_A")["cohort"])
        }
    }

    func testRollbackPreservesLaterExternalDatabaseAndReceiptWriter() throws {
        let fixture = try makeVariantBundle()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let metadata = fixture.root.appendingPathComponent("metadata.tsv")
        try "sample\tcohort\nSAMPLE_A\towned mutation\n".write(to: metadata, atomically: true, encoding: .utf8)
        let provenance = fixture.bundleURL.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        try Data("original receipt".utf8).write(to: provenance)
        let laterReceipt = Data("later external receipt".utf8)
        let service = VariantSampleMetadataImportService { _, _ in
            var external: OpaquePointer?
            guard sqlite3_open(fixture.databaseURL.path, &external) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
            defer { sqlite3_close(external) }
            XCTAssertEqual(sqlite3_exec(external, "UPDATE samples SET metadata='{\"external\":\"newer writer\"}' WHERE name='SAMPLE_A'", nil, nil, nil), SQLITE_OK)
            try laterReceipt.write(to: provenance, options: .atomic)
            throw IntentionalProvenanceFailure.write
        }
        XCTAssertThrowsError(try service.importMetadata(from: metadata, format: .tsv, bundleURL: fixture.bundleURL,
            targets: [.init(databaseURL: fixture.databaseURL)])) { error in
            XCTAssertTrue(error is ScientificPublicationRecoveryRequired, "Expected fail-closed recovery, got \(error)")
            if let recovery = error as? ScientificPublicationRecoveryRequired {
                defer { for url in recovery.recoveryURLs { try? FileManager.default.removeItem(at: url) } }
                XCTAssertTrue(recovery.recoveryURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
                XCTAssertTrue(recovery.originalErrorDescription.contains("IntentionalProvenanceFailure"))
            }
        }
        XCTAssertEqual(try VariantDatabase(url: fixture.databaseURL).sampleMetadata(name: "SAMPLE_A")["external"], "newer writer")
        XCTAssertEqual(try Data(contentsOf: provenance), laterReceipt)
    }

    func testRollbackPreservesLaterExternalReceiptWithoutDatabaseChange() throws {
        let fixture = try makeVariantBundle()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let metadata = fixture.root.appendingPathComponent("metadata.tsv")
        try "sample\tcohort\nSAMPLE_A\towned mutation\n".write(to: metadata, atomically: true, encoding: .utf8)
        let provenance = fixture.bundleURL.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        try Data("previous receipt".utf8).write(to: provenance)
        let later = Data("external receipt after publication".utf8)
        let writer = ProvenanceWriter(publicationMutationDidOccur: { mutation in
            if mutation.affectedURLs.contains(provenance) {
                try later.write(to: provenance, options: .atomic)
                throw IntentionalProvenanceFailure.write
            }
        }, signingProvider: nil)
        let service = VariantSampleMetadataImportService(provenanceWriter: writer)
        XCTAssertThrowsError(try service.importMetadata(from: metadata, format: .tsv, bundleURL: fixture.bundleURL,
            targets: [.init(databaseURL: fixture.databaseURL)])) { error in
            XCTAssertTrue(error is ScientificPublicationRecoveryRequired, "Expected explicit recovery: \(error)")
            if let recovery = error as? ScientificPublicationRecoveryRequired {
                for url in recovery.recoveryURLs { try? FileManager.default.removeItem(at: url) }
            }
        }
        XCTAssertEqual(try Data(contentsOf: provenance), later)
        XCTAssertEqual(try VariantDatabase(url: fixture.databaseURL).sampleMetadata(name: "SAMPLE_A")["cohort"], "owned mutation",
            "A later receipt may describe the current database; do not restore SQLite before validating receipt ownership.")
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
