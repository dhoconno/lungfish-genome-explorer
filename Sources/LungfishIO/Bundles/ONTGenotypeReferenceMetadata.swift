import CryptoKit
import Darwin
import Foundation
import LungfishCore

public struct ONTGenotypeReferenceMetadata: Codable, Equatable, Sendable {
    public let fields: [GenBankRecordDatabase.FieldDefinition]
    public let recordsBySequenceName: [String: [String: String]]
    public let alleleFieldKey: String?

    public init(
        fields: [GenBankRecordDatabase.FieldDefinition],
        recordsBySequenceName: [String: [String: String]],
        alleleFieldKey: String?
    ) {
        self.fields = fields
        self.recordsBySequenceName = recordsBySequenceName
        self.alleleFieldKey = alleleFieldKey
    }
}
