import Foundation
import LungfishIO

/// Publishes the indexed GenBank record metadata used for genotyping into the
/// result bundle so review remains independent of the source reference bundle.
public enum GenotypeReferenceRecordStoreSnapshot {
    public struct PublishedSnapshot: Sendable, Equatable {
        public let info: ONTGenotypeReferenceRecordStoreInfo
        public let sourceReferenceBundleURL: URL
        public let sourceURL: URL
        public let destinationURL: URL
        public let startedAt: Date
        public let completedAt: Date

        public init(
            info: ONTGenotypeReferenceRecordStoreInfo,
            sourceReferenceBundleURL: URL,
            sourceURL: URL,
            destinationURL: URL,
            startedAt: Date,
            completedAt: Date
        ) {
            self.info = info
            self.sourceReferenceBundleURL = sourceReferenceBundleURL.standardizedFileURL
            self.sourceURL = sourceURL.standardizedFileURL
            self.destinationURL = destinationURL.standardizedFileURL
            self.startedAt = startedAt
            self.completedAt = completedAt
        }
    }

    public static let relativeDatabasePath = "metadata/genbank_records.sqlite"

    /// Returns `nil` for FASTA-only references. A declared record store is
    /// validated by `ReferenceBundle` before it is copied.
    public static func publish(
        fromReferenceBundle referenceBundleURL: URL,
        toResultBundle resultBundleURL: URL,
        fileManager: FileManager = .default
    ) async throws -> PublishedSnapshot? {
        let requestedURL = referenceBundleURL.standardizedFileURL
        let nativeReferenceURL: URL
        if requestedURL.pathExtension.lowercased() == "lungfishmhcref" {
            guard let embeddedURL = MHCAmpliconReferenceBundle.referenceBundleURL(in: requestedURL) else {
                return nil
            }
            nativeReferenceURL = embeddedURL
        } else if let enclosingURL = MappingReferenceStager.enclosingReferenceBundleURL(for: requestedURL) {
            nativeReferenceURL = enclosingURL
        } else {
            return nil
        }
        let referenceBundle = try await ReferenceBundle(url: nativeReferenceURL)
        guard let sourceDatabase = try referenceBundle.recordStoreDatabase() else { return nil }

        let startedAt = Date()
        let destinationURL = try publishValidatedDatabase(
            sourceDatabase.databaseURL,
            toResultBundle: resultBundleURL,
            fileManager: fileManager
        )
        let finalDatabase = try GenBankRecordDatabase(url: destinationURL)
        let recordCount = try finalDatabase.recordCount()
        let fieldCount = try finalDatabase.fieldCount()
        let info = ONTGenotypeReferenceRecordStoreInfo(
            databasePath: relativeDatabasePath,
            recordCount: recordCount,
            fieldCount: fieldCount,
            sha256: try ProvenanceFileHasher.sha256(of: destinationURL),
            sizeBytes: Int64(try ProvenanceFileHasher.fileSize(of: destinationURL))
        )
        return PublishedSnapshot(
            info: info,
            sourceReferenceBundleURL: nativeReferenceURL,
            sourceURL: sourceDatabase.databaseURL,
            destinationURL: destinationURL,
            startedAt: startedAt,
            completedAt: Date()
        )
    }

    private static func publishValidatedDatabase(
        _ sourceURL: URL,
        toResultBundle resultBundleURL: URL,
        fileManager: FileManager
    ) throws -> URL {
        let destinationURL = resultBundleURL
            .appendingPathComponent(relativeDatabasePath)
            .standardizedFileURL
        let directoryURL = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let stagingURL = directoryURL.appendingPathComponent(".genbank-records-\(UUID().uuidString).sqlite")
        defer { try? fileManager.removeItem(at: stagingURL) }

        try fileManager.copyItem(at: sourceURL, to: stagingURL)
        let stagedDatabase = try GenBankRecordDatabase(url: stagingURL)
        _ = try stagedDatabase.recordCount()
        _ = try stagedDatabase.fieldCount()

        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: stagingURL)
        } else {
            try fileManager.moveItem(at: stagingURL, to: destinationURL)
        }

        _ = try GenBankRecordDatabase(url: destinationURL)
        return destinationURL
    }
}
