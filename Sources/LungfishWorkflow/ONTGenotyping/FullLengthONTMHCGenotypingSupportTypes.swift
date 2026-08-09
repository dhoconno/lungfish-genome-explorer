import CryptoKit
import Darwin
import Foundation
import LungfishCore
import LungfishIO

internal struct FullLengthONTMHCReviewCallKey: Hashable {
    let locus: String
    let genotype: String
}

internal final class FullLengthONTMHCProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var latestFraction: Double = 0
    private let handler: (@Sendable (Double, String) -> Void)?

    init(_ handler: (@Sendable (Double, String) -> Void)?) {
        self.handler = handler
    }

    func emit(_ fraction: Double, _ message: String) {
        guard let handler else { return }
        let clampedFraction = min(1, max(0, fraction))
        lock.lock()
        let emittedFraction = max(latestFraction, clampedFraction)
        latestFraction = emittedFraction
        lock.unlock()
        handler(emittedFraction, message)
    }
}

internal struct FullLengthONTMHCSavontPreset: Sendable, Equatable {
    let qualityValueCutoff: Int
    let minimumClusterSize: Int
    let label: String
    let directoryName: String

    static func requested(for request: FullLengthONTMHCGenotypingRunRequest) -> FullLengthONTMHCSavontPreset {
        let prefix = request.savontQualityValueCutoff == FullLengthONTMHCGenotypingRunRequest.defaultSavontQualityValueCutoff
            && request.savontMinimumClusterSize == FullLengthONTMHCGenotypingRunRequest.defaultSavontMinimumClusterSize
            ? "strict"
            : "requested"
        return FullLengthONTMHCSavontPreset(
            qualityValueCutoff: request.savontQualityValueCutoff,
            minimumClusterSize: request.savontMinimumClusterSize,
            label: "\(prefix)-qv\(request.savontQualityValueCutoff)-min\(request.savontMinimumClusterSize)",
            directoryName: "\(prefix)-qv\(request.savontQualityValueCutoff)-min\(request.savontMinimumClusterSize)"
        )
    }

    static let hiddenNoCallFallback = FullLengthONTMHCSavontPreset(
        qualityValueCutoff: FullLengthONTMHCGenotypingRunRequest.defaultSavontQualityValueCutoff,
        minimumClusterSize: 1,
        label: "fallback-qv90-min1",
        directoryName: "fallback-qv90-min1"
    )
}

internal enum FullLengthONTMHCWorkbookTintDefaults {
    static let sharedNovel = "F5D78E"
    static let singletonNovel = "F5B97A"
    static let sharedExtension = "A8D8D0"
    static let singletonExtension = "AFCBF2"
}

struct FullLengthONTMHCWorkbookProjectionInputDocument: Codable, Equatable, Sendable {
    static let schemaVersion = 2

    struct SourceSummary: Codable, Equatable, Sendable {
        let reportRowCount: Int
        let sampleSummaryCount: Int
        let genotypeRowCount: Int
        let unmatchedClusterRowCount: Int
        let orderedAlleleCount: Int
        let includesHaplotypeAnalysis: Bool
        let candidateRecordCount: Int
        let unnameableRecordCount: Int
        let normalizedUnmatchedRowCount: Int
        let referenceRecordCount: Int
    }

    let schemaVersion: Int
    let tintARGB: [String: String]
    let sourceSummary: SourceSummary
    let sheets: [FullLengthONTMHCXLSXPackageWriter.Sheet]

    init(sourceSummary: SourceSummary, sheets: [FullLengthONTMHCXLSXPackageWriter.Sheet]) {
        schemaVersion = Self.schemaVersion
        tintARGB = [
            FullLengthONTMHCWorkbookTintCategory.sharedNovel.rawValue: FullLengthONTMHCWorkbookTintDefaults.sharedNovel,
            FullLengthONTMHCWorkbookTintCategory.singletonNovel.rawValue: FullLengthONTMHCWorkbookTintDefaults.singletonNovel,
            FullLengthONTMHCWorkbookTintCategory.sharedExtension.rawValue: FullLengthONTMHCWorkbookTintDefaults.sharedExtension,
            FullLengthONTMHCWorkbookTintCategory.singletonExtension.rawValue: FullLengthONTMHCWorkbookTintDefaults.singletonExtension,
        ]
        self.sourceSummary = sourceSummary
        self.sheets = sheets
    }
}

internal struct FullLengthONTMHCReferenceInputManifest: Decodable {
    let recordStore: RecordStore?

    enum CodingKeys: String, CodingKey {
        case recordStore = "record_store"
    }

    struct RecordStore: Decodable {
        let databasePath: String

        enum CodingKeys: String, CodingKey {
            case databasePath = "database_path"
        }
    }
}

struct FullLengthONTMHCReferenceCatalogProjection: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let cdnaThreshold: Int
    let records: [MHCReferenceRecord]

    init(cdnaThreshold: Int, records: [MHCReferenceRecord]) {
        schemaVersion = Self.schemaVersion
        self.cdnaThreshold = cdnaThreshold
        self.records = records
    }
}

struct FullLengthONTMHCRawUnmatchedDecisionDocument: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let rows: [FullLengthONTMHCUnmatchedClosestMatchWorkbookRow]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case rows
    }

    init(rows: [FullLengthONTMHCUnmatchedClosestMatchWorkbookRow]) {
        schemaVersion = Self.schemaVersion
        self.rows = rows.sorted {
            if $0.sample != $1.sample {
                return $0.sample < $1.sample
            }
            if $0.cluster != $1.cluster {
                return $0.cluster < $1.cluster
            }
            if $0.candidateSequence != $1.candidateSequence {
                return $0.candidateSequence < $1.candidateSequence
            }
            return $0.clusterReads < $1.clusterReads
        }
    }
}

internal struct FullLengthONTMHCReferenceCatalogInputs: Sendable, Equatable {
    let fastaURL: URL
    let manifestURL: URL?
    let recordStoreURL: URL?

    var allURLs: [URL] {
        [fastaURL, manifestURL, recordStoreURL].compactMap { $0 }
    }
}

internal enum FullLengthONTMHCSavontSampleStatus: String, Sendable, Codable, Equatable {
    case called
    case noCall = "no-call"
    case handledSavontFailure = "handled-savont-failure"
}

struct FullLengthONTMHCReviewCatalogAuthority: Sendable {
    let referenceRecords: [MHCReferenceRecord]
    let candidateDocument: ONTMHCCandidateAllelesDocument
    let unnameableDocument: ONTMHCUnnameableClustersDocument?
    let snapshots: [GenotypeReviewAuthorityFileSnapshot]

    func requireUnchanged() throws {
        for snapshot in snapshots {
            try snapshot.requireUnchanged()
        }
    }
}

internal struct FullLengthONTMHCWorkbookCopyResult: Sendable {
    let revision: ONTGenotypeWorkbookRevision
    let step: FullLengthONTMHCProvenanceStep
}
