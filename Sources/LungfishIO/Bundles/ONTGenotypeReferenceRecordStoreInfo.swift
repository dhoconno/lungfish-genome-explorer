import CryptoKit
import Darwin
import Foundation
import LungfishCore

public struct ONTGenotypeReferenceRecordStoreInfo: Codable, Equatable, Sendable {
    public static let supportedFormat = "genbank"

    public let databasePath: String
    public let format: String
    public let schemaVersion: Int
    public let recordCount: Int
    public let fieldCount: Int
    public let sha256: String
    public let sizeBytes: Int64

    public init(
        databasePath: String,
        format: String = Self.supportedFormat,
        schemaVersion: Int = GenBankRecordDatabase.schemaVersion,
        recordCount: Int,
        fieldCount: Int,
        sha256: String,
        sizeBytes: Int64
    ) {
        self.databasePath = databasePath
        self.format = format
        self.schemaVersion = schemaVersion
        self.recordCount = recordCount
        self.fieldCount = fieldCount
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
    }

    private enum CodingKeys: String, CodingKey {
        case databasePath = "database_path"
        case format
        case schemaVersion = "schema_version"
        case recordCount = "record_count"
        case fieldCount = "field_count"
        case sha256
        case sizeBytes = "size_bytes"
    }
}
