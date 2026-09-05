import XCTest
import SQLite3
import LungfishIO
import LungfishCore
import LungfishWorkflow
@testable import LungfishApp

final class SQLiteImportPublicationTests: XCTestCase {
    func testSnapshotRejectsLeafSymlinkWithoutTouchingItsTarget() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.db")
        let reader = try connection(source)
        defer { sqlite3_close(reader) }
        try execute(reader, "CREATE TABLE state(value TEXT); INSERT INTO state VALUES('retained');")
        let link = root.appendingPathComponent("snapshot-link.db")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        let handle = try SQLitePublicationHandle(url: source)
        XCTAssertThrowsError(try handle.writeSnapshot(to: link))
        XCTAssertEqual(try value(reader), "retained")
        XCTAssertTrue(try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
    }

    func testResumableSnapshotContainsCommittedWALWithoutCopyingJournalFiles() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let final = root.appendingPathComponent("retry.db")
        let source = try connection(final)
        defer { sqlite3_close(source) }
        try execute(source, "CREATE TABLE state(value TEXT); INSERT INTO state VALUES('old'); PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; UPDATE state SET value='committed WAL';")
        let staging = try OperationImportStaging(parentDirectory: root, operationID: UUID())
        let publication = try staging.prepareSQLiteCopy(filename: "retry.db", from: final)
        XCTAssertFalse(FileManager.default.fileExists(atPath: publication.stagedURL.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: publication.stagedURL.path + "-shm"))
        let snapshot = try connection(publication.stagedURL)
        defer { sqlite3_close(snapshot) }
        XCTAssertEqual(try value(snapshot), "committed WAL")
    }

    func testSQLitePublicationUpdatesLiveReaderWithoutReplacingDatabaseInode() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let final = root.appendingPathComponent("retry.db")
        let reader = try connection(final)
        defer { sqlite3_close(reader) }
        try execute(reader, "CREATE TABLE state(value TEXT); INSERT INTO state VALUES('old');")
        let inode = try FileManager.default.attributesOfItem(atPath: final.path)[.systemFileNumber] as? NSNumber
        let staging = try OperationImportStaging(parentDirectory: root, operationID: UUID())
        let publication = try staging.prepareSQLiteCopy(filename: "retry.db", from: final)
        let staged = try connection(publication.stagedURL)
        try execute(staged, "UPDATE state SET value='replacement';")
        sqlite3_close(staged)
        try publication.publish {}
        XCTAssertEqual(try value(reader), "replacement")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: final.path)[.systemFileNumber] as? NSNumber, inode)
    }

    func testSQLiteCommitFailureRestoresExistingReaderAndFinalState() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let final = root.appendingPathComponent("retry.db")
        let reader = try connection(final)
        defer { sqlite3_close(reader) }
        try execute(reader, "CREATE TABLE state(value TEXT); INSERT INTO state VALUES('old');")
        let staging = try OperationImportStaging(parentDirectory: root, operationID: UUID())
        let publication = try staging.prepareSQLiteCopy(filename: "retry.db", from: final)
        let staged = try connection(publication.stagedURL)
        try execute(staged, "UPDATE state SET value='replacement';")
        sqlite3_close(staged)
        XCTAssertThrowsError(try publication.publish {
            XCTAssertEqual(try value(reader), "replacement")
            throw CocoaError(.fileWriteUnknown)
        })
        XCTAssertEqual(try value(reader), "old")
        let fresh = try connection(final)
        defer { sqlite3_close(fresh) }
        XCTAssertEqual(try value(fresh), "old")
    }

    func testVCFPublicationFailureRestoresDatabaseManifestAndAllReceiptArtifacts() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeVCFPublicationFixture(root)
        defer { sqlite3_close(fixture.reader) }
        let originalManifest = try Data(contentsOf: root.appendingPathComponent(BundleManifest.filename))
        let signature = ProvenanceSigningConfiguration.signatureURL(for: fixture.receipt)
        let publicKey = ProvenanceSigningConfiguration.publicKeyURL(for: fixture.receipt)
        try Data("previous signature".utf8).write(to: signature)
        try Data("previous key".utf8).write(to: publicKey)
        XCTAssertThrowsError(try AppDelegate.publishVCFImportArtifacts(
            databasePublication: fixture.publication, bundleURL: root, provenanceURL: fixture.receipt,
            updatedManifest: fixture.updatedManifest
        ) { writer in
            try writer.write(self.fixtureEnvelope("replacement"), toSidecar: fixture.receipt)
            throw CocoaError(.fileWriteUnknown)
        })
        XCTAssertEqual(try value(fixture.reader), "old")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(BundleManifest.filename)), originalManifest)
        XCTAssertEqual(try Data(contentsOf: fixture.receipt), fixture.originalReceipt)
        XCTAssertEqual(try? Data(contentsOf: signature), Data("previous signature".utf8))
        XCTAssertEqual(try? Data(contentsOf: publicKey), Data("previous key".utf8))
    }

    func testVCFLaterReceiptWriterPreservesCurrentDatabaseAndRecoveryArtifacts() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeVCFPublicationFixture(root)
        defer { sqlite3_close(fixture.reader) }
        let laterReceipt = Data("later receipt describing the current replacement database".utf8)
        XCTAssertThrowsError(try AppDelegate.publishVCFImportArtifacts(
            databasePublication: fixture.publication, bundleURL: root, provenanceURL: fixture.receipt,
            updatedManifest: fixture.updatedManifest
        ) { writer in
            try writer.write(self.fixtureEnvelope("replacement"), toSidecar: fixture.receipt)
            try laterReceipt.write(to: fixture.receipt, options: .atomic)
            throw CocoaError(.fileWriteUnknown)
        }) { error in
            let recovery = error as? OperationImportStaging.RecoveryRequired
            XCTAssertNotNil(recovery, "Later receipt ownership must prevent database rollback")
            XCTAssertFalse(recovery?.additionalRecoveryURLs.isEmpty ?? true)
        }
        XCTAssertEqual(try value(fixture.reader), "replacement")
        XCTAssertEqual(try Data(contentsOf: fixture.receipt), laterReceipt)
        let backup = try connection(fixture.publication.staging.directory.appendingPathComponent("previous-retry.db"))
        defer { sqlite3_close(backup) }
        XCTAssertEqual(try value(backup), "old", "Recovery must retain readable previous database content")
    }

    func testVCFDatabaseRestoreFailureRetainsMatchingReceiptAndBothRecoveryLocations() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeVCFPublicationFixture(root)
        defer { sqlite3_close(fixture.reader) }
        XCTAssertThrowsError(try AppDelegate.publishVCFImportArtifacts(
            databasePublication: fixture.publication, bundleURL: root, provenanceURL: fixture.receipt,
            updatedManifest: fixture.updatedManifest
        ) { writer in
            try writer.write(self.fixtureEnvelope("replacement"), toSidecar: fixture.receipt)
            try FileManager.default.removeItem(at: fixture.publication.staging.directory.appendingPathComponent("previous-retry.db"))
            throw NSError(domain: "VCFFixture", code: 71, userInfo: [NSLocalizedDescriptionKey: "original receipt publication failure"])
        }) { error in
            let recovery = error as? OperationImportStaging.RecoveryRequired
            XCTAssertNotNil(recovery)
            XCTAssertTrue(error.localizedDescription.contains("original receipt publication failure"))
            XCTAssertTrue(recovery?.restorationErrorDescription.contains("Cannot open recovery snapshot") == true)
            XCTAssertTrue(error.localizedDescription.contains(fixture.publication.staging.directory.path))
            XCTAssertFalse(recovery?.additionalRecoveryURLs.isEmpty ?? true)
            for location in recovery?.additionalRecoveryURLs ?? [] {
                XCTAssertTrue(error.localizedDescription.contains(location.path))
            }
        }
        XCTAssertEqual(try value(fixture.reader), "replacement")
        XCTAssertEqual(try ProvenanceEnvelopeReader.load(fromSidecar: fixture.receipt)?.workflowName, "replacement")
    }

    func testVCFPublicationMakesManifestVisibleOnlyAfterReceiptAndKeepsLiveReader() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeVCFPublicationFixture(root)
        defer { sqlite3_close(fixture.reader) }
        try AppDelegate.publishVCFImportArtifacts(
            databasePublication: fixture.publication, bundleURL: root, provenanceURL: fixture.receipt,
            updatedManifest: fixture.updatedManifest
        ) { writer in
            XCTAssertEqual(try BundleManifest.load(from: root).name, "original")
            XCTAssertEqual(try value(fixture.reader), "replacement")
            try writer.write(self.fixtureEnvelope("replacement"), toSidecar: fixture.receipt)
        }
        XCTAssertEqual(try BundleManifest.load(from: root).name, "replacement")
        XCTAssertEqual(try ProvenanceEnvelopeReader.load(fromSidecar: fixture.receipt)?.workflowName, "replacement")
        XCTAssertEqual(try value(fixture.reader), "replacement")
    }

    func testNewVCFPublicationCancellationRemovesOwnedDatabaseAndRestoresManifest() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let final = root.appendingPathComponent("new.db")
        let staging = try OperationImportStaging(parentDirectory: root, operationID: UUID())
        let publication = try staging.prepareSQLiteCopy(filename: "new.db", from: final)
        let staged = try connection(publication.stagedURL)
        try execute(staged, "CREATE TABLE state(value TEXT); INSERT INTO state VALUES('new');")
        sqlite3_close(staged)
        let manifest = BundleManifest(name: "original", identifier: "org.lungfish.fixture",
            source: SourceInfo(organism: "Synthetic", assembly: "fixture"))
        try manifest.save(to: root)
        let receipt = root.appendingPathComponent("new.lungfish-provenance.json")
        var cancelled = false
        XCTAssertThrowsError(try AppDelegate.publishVCFImportArtifacts(
            databasePublication: publication, bundleURL: root, provenanceURL: receipt,
            updatedManifest: manifest, shouldCancel: { cancelled }
        ) { writer in
            try writer.write(self.fixtureEnvelope("new"), toSidecar: receipt)
            cancelled = true
        }) { error in
            guard let error = error as? VariantDatabaseError, case .cancelled = error else {
                return XCTFail("Expected ordinary drained cancellation, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: final.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: receipt.path))
        XCTAssertEqual(try BundleManifest.load(from: root).name, "original")
    }

    func testVCFPublicationRejectsManifestChangedAfterCapturedReadBeforeDatabaseMutation() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeVCFPublicationFixture(root)
        defer { sqlite3_close(fixture.reader) }
        let manifestURL = root.appendingPathComponent(BundleManifest.filename)
        let files = try ScientificFilePublicationTransaction(
            protectedURLs: [manifestURL] + ProvenancePublicationArtifacts.sidecarArtifacts(for: fixture.receipt),
            fileDestinations: [manifestURL, fixture.receipt])
        defer { files.commit() }
        let capturedManifest = try BundleManifest.load(from: root)
        let laterManifest = BundleManifest(name: "later external manifest", identifier: "org.lungfish.fixture",
            source: SourceInfo(organism: "Synthetic", assembly: "fixture"))
        try laterManifest.save(to: root)
        let laterBytes = try Data(contentsOf: manifestURL)
        var receiptWriterCalled = false
        XCTAssertThrowsError(try AppDelegate.publishVCFImportArtifacts(
            databasePublication: fixture.publication, bundleURL: root, provenanceURL: fixture.receipt,
            updatedManifest: capturedManifest, filePublication: files
        ) { writer in
            receiptWriterCalled = true
            try writer.write(self.fixtureEnvelope("replacement"), toSidecar: fixture.receipt)
        }) { error in
            XCTAssertTrue(error is OperationImportStaging.RecoveryRequired)
        }
        XCTAssertFalse(receiptWriterCalled, "Reject stale manifest ownership before any publication")
        XCTAssertEqual(try value(fixture.reader), "old")
        XCTAssertEqual(try Data(contentsOf: manifestURL), laterBytes)
        XCTAssertEqual(try Data(contentsOf: fixture.receipt), fixture.originalReceipt)
    }

    func testVCFReimportPreservesUnrelatedManifestFieldsAndTracks() throws {
        func track(_ id: String, count: Int) -> VariantTrackInfo {
            VariantTrackInfo(id: id, name: id, path: "variants/\(id).bcf", indexPath: "variants/\(id).bcf.csi",
                databasePath: "variants/\(id).db", variantType: .mixed, variantCount: count, source: "Synthetic")
        }
        let old = track("replace", count: 1)
        let other = track("retain", count: 2)
        let replacement = track("replace", count: 3)
        let original = BundleManifest(name: "Reference fixture", identifier: "org.lungfish.fixture",
            description: "Retained description", originBundlePath: "/captured/original.lungfishref",
            source: SourceInfo(organism: "Synthetic", assembly: "fixture"), variants: [old, other],
            alignments: [AlignmentTrackInfo(id: "alignment", name: "Retained alignment",
                sourcePath: "alignments/fixture.bam", indexPath: "alignments/fixture.bam.bai")],
            metadata: [MetadataGroup(name: "Retained metadata", items: [MetadataItem(label: "Field", value: "value")])],
            warnings: [BundleWarning(category: "fixture", code: "retained", message: "Retained warning")],
            recordStore: ReferenceRecordStoreInfo(schemaVersion: 1, format: "genbank", databasePath: "records.sqlite", recordCount: 1))
        let updated = AppDelegate.vcfManifestReplacingTrack(replacement, in: original)
        XCTAssertEqual(updated.variants, [other, replacement])
        XCTAssertEqual(updated.alignments, original.alignments)
        XCTAssertEqual(updated.originBundlePath, original.originBundlePath)
        XCTAssertEqual(updated.warnings, original.warnings)
        XCTAssertEqual(updated.recordStore, original.recordStore)
        XCTAssertEqual(updated.metadata, original.metadata)
        XCTAssertEqual(updated.source, original.source)
        XCTAssertEqual(updated.identifier, original.identifier)
        XCTAssertEqual(updated.description, original.description)
        XCTAssertEqual(updated.createdDate, original.createdDate)
    }

    func testVCFCommittedCleanupFailureReturnsWarningAndKeepsPublishedArtifacts() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeVCFPublicationFixture(root)
        defer { sqlite3_close(fixture.reader) }
        try AppDelegate.publishVCFImportArtifacts(
            databasePublication: fixture.publication, bundleURL: root, provenanceURL: fixture.receipt,
            updatedManifest: fixture.updatedManifest
        ) { writer in
            try writer.write(self.fixtureEnvelope("replacement"), toSidecar: fixture.receipt)
        }
        let warning = fixture.publication.staging.finishCommittedImport {
            throw CocoaError(.fileWriteNoPermission)
        }
        XCTAssertTrue(warning?.contains(fixture.publication.staging.directory.path) == true)
        XCTAssertEqual(try value(fixture.reader), "replacement")
        XCTAssertEqual(try BundleManifest.load(from: root).name, "replacement")
        XCTAssertEqual(try ProvenanceEnvelopeReader.load(fromSidecar: fixture.receipt)?.workflowName, "replacement")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.publication.staging.directory.path))
    }

    func testVCFPublicationRejectsSigningArtifactDirectoriesWithoutChangingExistingData() throws {
        for isPublicKey in [false, true] {
            let root = try temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let fixture = try makeVCFPublicationFixture(root)
            defer { sqlite3_close(fixture.reader) }
            let artifact = isPublicKey ? ProvenanceSigningConfiguration.publicKeyURL(for: fixture.receipt)
                : ProvenanceSigningConfiguration.signatureURL(for: fixture.receipt)
            try FileManager.default.createDirectory(at: artifact, withIntermediateDirectories: true)
            let marker = artifact.appendingPathComponent("retained.txt")
            try Data("existing directory content".utf8).write(to: marker)
            XCTAssertThrowsError(try AppDelegate.publishVCFImportArtifacts(
                databasePublication: fixture.publication, bundleURL: root, provenanceURL: fixture.receipt,
                updatedManifest: fixture.updatedManifest
            ) { writer in
                try writer.write(self.fixtureEnvelope("replacement"), toSidecar: fixture.receipt)
            })
            XCTAssertEqual(try value(fixture.reader), "old")
            XCTAssertEqual(try BundleManifest.load(from: root).name, "original")
            XCTAssertEqual(try Data(contentsOf: fixture.receipt), fixture.originalReceipt)
            XCTAssertEqual(try? Data(contentsOf: marker), Data("existing directory content".utf8))
        }
    }

    private func fixtureEnvelope(_ name: String) -> ProvenanceEnvelope {
        ProvenanceEnvelope(workflowName: name, toolName: "fixture", toolVersion: "1", argv: ["/bin/true"], exitStatus: 0)
    }

    private func makeVCFPublicationFixture(_ root: URL) throws -> (
        reader: OpaquePointer, publication: OperationImportStaging.SQLitePublication,
        receipt: URL, originalReceipt: Data, updatedManifest: BundleManifest
    ) {
        let final = root.appendingPathComponent("retry.db")
        let reader = try connection(final)
        try execute(reader, "CREATE TABLE state(value TEXT); INSERT INTO state VALUES('old'); PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;")
        let staging = try OperationImportStaging(parentDirectory: root, operationID: UUID())
        let publication = try staging.prepareSQLiteCopy(filename: "retry.db", from: final)
        let staged = try connection(publication.stagedURL)
        try execute(staged, "UPDATE state SET value='replacement';")
        sqlite3_close(staged)
        let originalManifest = BundleManifest(name: "original", identifier: "org.lungfish.fixture",
            source: SourceInfo(organism: "Synthetic", assembly: "fixture"))
        try originalManifest.save(to: root)
        let updatedManifest = BundleManifest(name: "replacement", identifier: "org.lungfish.fixture",
            source: SourceInfo(organism: "Synthetic", assembly: "fixture"))
        let receipt = root.appendingPathComponent("retry.lungfish-provenance.json")
        try ProvenanceWriter(signingProvider: nil).write(fixtureEnvelope("original"), toSidecar: receipt)
        return (reader, publication, receipt, try Data(contentsOf: receipt), updatedManifest)
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SQLiteImport-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func connection(_ url: URL) throws -> OpaquePointer {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else { throw CocoaError(.fileReadUnknown) }
        return db
    }

    private func execute(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "SQLiteFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
        }
    }

    private func value(_ db: OpaquePointer) throws -> String {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT value FROM state", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else { throw CocoaError(.fileReadCorruptFile) }
        return String(cString: value)
    }
}
