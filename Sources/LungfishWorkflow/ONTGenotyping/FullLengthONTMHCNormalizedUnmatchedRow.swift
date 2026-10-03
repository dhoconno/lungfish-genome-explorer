import CryptoKit
import Foundation
import LungfishCore
import LungfishIO

struct FullLengthONTMHCNormalizedUnmatchedRow: Codable, Equatable, Sendable {
    let recordCategory: FullLengthONTMHCUnmatchedRecordCategory
    let stableClusterID: String
    let provisionalAlleleName: String?
    let locus: String?
    let classificationOrReason: String
    let closestReferenceAllele: String?
    let closestReferenceRawID: String?
    let extensionOf: [String]
    let snpCount: Int?
    let insertedBases: Int?
    let deletedBases: Int?
    let longGapBases: Int?
    let comparableBases: Int?
    let failedMetrics: [String: Double]
    let supportClass: String
    let independentSampleCount: Int
    let occurrenceCount: Int
    let totalClusterReads: Int
    let supportingSampleIDs: [String]
    let readsBySample: [String: Int]
    let fastaRecordID: String
    let sequenceSHA256: String
    let nucleotideSequence: String?
    let putativeAminoAcidTranslation: String?
    let translationStatus: FullLengthONTMHCTranslationStatus
    let internalEvidenceReference: String?

    enum CodingKeys: String, CodingKey {
        case recordCategory = "record_category"
        case stableClusterID = "stable_cluster_id"
        case provisionalAlleleName = "provisional_allele_name"
        case locus
        case classificationOrReason = "classification_or_reason"
        case closestReferenceAllele = "closest_reference_allele"
        case closestReferenceRawID = "closest_reference_raw_id"
        case extensionOf = "extension_of"
        case snpCount = "snp_count"
        case insertedBases = "inserted_bases"
        case deletedBases = "deleted_bases"
        case longGapBases = "long_gap_bases"
        case comparableBases = "comparable_bases"
        case failedMetrics = "failed_metrics"
        case supportClass = "support_class"
        case independentSampleCount = "independent_sample_count"
        case occurrenceCount = "occurrence_count"
        case totalClusterReads = "total_cluster_reads"
        case supportingSampleIDs = "supporting_sample_ids"
        case readsBySample = "reads_by_sample"
        case fastaRecordID = "fasta_record_id"
        case sequenceSHA256 = "sequence_sha256"
        case nucleotideSequence = "nucleotide_sequence"
        case putativeAminoAcidTranslation = "putative_amino_acid_translation"
        case translationStatus = "translation_status"
        case internalEvidenceReference = "internal_evidence_reference"
    }
}
