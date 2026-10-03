import Foundation
import LungfishIO

public enum AIHaplotypingValidationError: Codable, Error, Equatable, Sendable {
    case registryDigestMismatch
    case inputSnapshotDigestMismatch
    case runMetadataMismatch(String)
    case chunkIDMismatch(expected: String, actual: String?)
    case invalidPatchOpID(String)
    case unknownEvidenceID(String)
    case duplicatePatchOpID(String)
    case duplicateCallTarget(String, String, String)
    case missingCounterevidence(String)
    case missingSupportEvidence(String)
    case invalidHaplotypeLabel(String, String, String)
    case invalidSource(String)
    case unknownCallTarget(String, String)
    case unknownDefinitionLocus(String)
    case evidenceTargetMismatch(String, String, String)
    case conflictsCurrentCall(String, String, String)
    case conflictsManualReview(String, String, String)
    case missingCurrentConflict(String, String, String)
    case missingManualConflict(String, String, String)
    case missingCurrentCarryForward(String, String, String)
    case missingManualCarryForward(String, String, String)
    case invalidCarryForwardLabel(String, String, String)
    case retainCurrentMismatch(String, String, String)
    case unsupportedDuplicateSlotLabel(String, String, String)
    case duplicateDiscoveredDefinition(String)
    case provisionalDefinitionCollision(String)
    case unsupportedClaim(String)

    private enum CodingKeys: String, CodingKey {
        case code, message, fields
    }

    public var code: String {
        switch self {
        case .registryDigestMismatch: return "registry_digest_mismatch"
        case .inputSnapshotDigestMismatch: return "input_snapshot_digest_mismatch"
        case .runMetadataMismatch: return "run_metadata_mismatch"
        case .chunkIDMismatch: return "chunk_id_mismatch"
        case .invalidPatchOpID: return "invalid_patch_op_id"
        case .unknownEvidenceID: return "unknown_evidence_id"
        case .duplicatePatchOpID: return "duplicate_patch_op_id"
        case .duplicateCallTarget: return "duplicate_call_target"
        case .missingCounterevidence: return "missing_counterevidence"
        case .missingSupportEvidence: return "missing_support_evidence"
        case .invalidHaplotypeLabel: return "invalid_haplotype_label"
        case .invalidSource: return "invalid_source"
        case .unknownCallTarget: return "unknown_call_target"
        case .unknownDefinitionLocus: return "unknown_definition_locus"
        case .evidenceTargetMismatch: return "evidence_target_mismatch"
        case .conflictsCurrentCall: return "conflicts_current_call"
        case .conflictsManualReview: return "conflicts_manual_review"
        case .missingCurrentConflict: return "missing_current_conflict"
        case .missingManualConflict: return "missing_manual_conflict"
        case .missingCurrentCarryForward: return "missing_current_carry_forward"
        case .missingManualCarryForward: return "missing_manual_carry_forward"
        case .invalidCarryForwardLabel: return "invalid_carry_forward_label"
        case .retainCurrentMismatch: return "retain_current_mismatch"
        case .unsupportedDuplicateSlotLabel: return "unsupported_duplicate_slot_label"
        case .duplicateDiscoveredDefinition: return "duplicate_discovered_definition"
        case .provisionalDefinitionCollision: return "provisional_definition_collision"
        case .unsupportedClaim: return "unsupported_claim"
        }
    }

    public var fields: [String: String] {
        switch self {
        case .registryDigestMismatch, .inputSnapshotDigestMismatch:
            return [:]
        case .runMetadataMismatch(let field):
            return ["field": field]
        case .chunkIDMismatch(let expected, let actual):
            var fields = ["expected": expected]
            if let actual {
                fields["actual"] = actual
            }
            return fields
        case .invalidPatchOpID(let patchOpID):
            return ["patchOpID": patchOpID]
        case .unknownEvidenceID(let evidenceID):
            return ["evidenceID": evidenceID]
        case .duplicatePatchOpID(let patchOpID):
            return ["patchOpID": patchOpID]
        case .duplicateCallTarget(let sample, let locus, let slot),
             .conflictsCurrentCall(let sample, let locus, let slot),
             .conflictsManualReview(let sample, let locus, let slot),
             .missingCurrentConflict(let sample, let locus, let slot),
             .missingManualConflict(let sample, let locus, let slot),
             .missingCurrentCarryForward(let sample, let locus, let slot),
             .missingManualCarryForward(let sample, let locus, let slot),
             .invalidCarryForwardLabel(let sample, let locus, let slot),
             .retainCurrentMismatch(let sample, let locus, let slot):
            return ["sample": sample, "locus": locus, "slot": slot]
        case .missingCounterevidence(let patchOpID),
             .missingSupportEvidence(let patchOpID):
            return ["patchOpID": patchOpID]
        case .invalidHaplotypeLabel(let sample, let locus, let slot):
            return ["sample": sample, "locus": locus, "slot": slot]
        case .invalidSource(let value):
            return ["value": value]
        case .unknownCallTarget(let sample, let locus):
            return ["sample": sample, "locus": locus]
        case .unknownDefinitionLocus(let locus):
            return ["locus": locus]
        case .evidenceTargetMismatch(let evidenceID, let sample, let locus):
            return ["evidenceID": evidenceID, "sample": sample, "locus": locus]
        case .unsupportedDuplicateSlotLabel(let sample, let locus, let label):
            return ["sample": sample, "locus": locus, "label": label]
        case .duplicateDiscoveredDefinition(let definitionID):
            return ["definitionID": definitionID]
        case .provisionalDefinitionCollision(let key):
            return ["key": key]
        case .unsupportedClaim(let text):
            return ["text": text]
        }
    }

    public var message: String {
        switch self {
        case .registryDigestMismatch:
            return "Structured result registry digest does not match the validated evidence registry."
        case .inputSnapshotDigestMismatch:
            return "Structured result input snapshot digest does not match the validated evidence registry."
        case .runMetadataMismatch(let field):
            return "Structured result run metadata field '\(field)' does not match the expected run metadata."
        case .chunkIDMismatch(let expected, let actual):
            return "Structured result chunkID '\(actual ?? "nil")' does not match expected chunkID '\(expected)'."
        case .invalidPatchOpID:
            return "Structured result contains a blank patch operation ID."
        case .unknownEvidenceID(let evidenceID):
            return "Structured result cites unknown evidence ID '\(evidenceID)'."
        case .duplicatePatchOpID(let patchOpID):
            return "Structured result repeats patch operation ID '\(patchOpID)'."
        case .duplicateCallTarget(let sample, let locus, let slot):
            return "Structured result repeats call target \(sample) \(locus) \(slot)."
        case .missingCounterevidence(let patchOpID):
            return "Structured call '\(patchOpID)' does not cite counterevidence."
        case .missingSupportEvidence(let patchOpID):
            return "Structured call or definition '\(patchOpID)' does not cite substantive support evidence."
        case .invalidHaplotypeLabel(let sample, let locus, let slot):
            return "Structured positive call for \(sample) \(locus) \(slot) uses a blank or placeholder haplotype label."
        case .invalidSource(let value):
            return "Structured result contains invalid source or state value '\(value)'."
        case .unknownCallTarget(let sample, let locus):
            return "Structured result targets unknown sample/locus \(sample) \(locus)."
        case .unknownDefinitionLocus(let locus):
            return "Discovered definition targets unknown locus '\(locus)'."
        case .evidenceTargetMismatch(let evidenceID, let sample, let locus):
            return "Evidence ID '\(evidenceID)' is not valid for target \(sample) \(locus)."
        case .conflictsCurrentCall(let sample, let locus, let slot):
            return "Structured call conflicts with current call \(sample) \(locus) \(slot) without conflict state."
        case .conflictsManualReview(let sample, let locus, let slot):
            return "Structured call conflicts with manual review \(sample) \(locus) \(slot) without conflict state."
        case .missingCurrentConflict(let sample, let locus, let slot):
            return "Structured call marks conflictsCurrent for \(sample) \(locus) \(slot) without an actual current-call conflict."
        case .missingManualConflict(let sample, let locus, let slot):
            return "Structured call marks conflictsManual for \(sample) \(locus) \(slot) without an actual manual-review conflict."
        case .missingCurrentCarryForward(let sample, let locus, let slot):
            return "Structured call marks retainCurrent for \(sample) \(locus) \(slot) without an existing current call to carry forward."
        case .missingManualCarryForward(let sample, let locus, let slot):
            return "Structured call marks retainCurrent for \(sample) \(locus) \(slot) without an existing manual review to carry forward."
        case .invalidCarryForwardLabel(let sample, let locus, let slot):
            return "Structured call marks retainCurrent for \(sample) \(locus) \(slot) with a blank or placeholder carried-forward label."
        case .retainCurrentMismatch(let sample, let locus, let slot):
            return "Structured call marks retainCurrent for \(sample) \(locus) \(slot) but does not match the carried-forward label."
        case .unsupportedDuplicateSlotLabel(let sample, let locus, let label):
            return "Structured result proposes duplicate label '\(label)' across slots for \(sample) \(locus)."
        case .duplicateDiscoveredDefinition(let definitionID):
            return "Structured result repeats discovered definition ID '\(definitionID)'."
        case .provisionalDefinitionCollision(let key):
            return "Structured result has conflicting provisional definition evidence for '\(key)'."
        case .unsupportedClaim(let text):
            return "Structured result contains unsupported claim text '\(text)'."
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(code, forKey: .code)
        try container.encode(message, forKey: .message)
        try container.encode(fields, forKey: .fields)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let code = try container.decode(String.self, forKey: .code)
        let fields = try container.decodeIfPresent([String: String].self, forKey: .fields) ?? [:]

        func field(_ key: String) throws -> String {
            guard let value = fields[key] else {
                throw DecodingError.dataCorruptedError(
                    forKey: .fields,
                    in: container,
                    debugDescription: "Missing AI haplotyping validation error field '\(key)' for code '\(code)'."
                )
            }
            return value
        }

        switch code {
        case "registry_digest_mismatch":
            self = .registryDigestMismatch
        case "input_snapshot_digest_mismatch":
            self = .inputSnapshotDigestMismatch
        case "run_metadata_mismatch":
            self = .runMetadataMismatch(try field("field"))
        case "chunk_id_mismatch":
            self = .chunkIDMismatch(expected: try field("expected"), actual: fields["actual"])
        case "invalid_patch_op_id":
            self = .invalidPatchOpID(try field("patchOpID"))
        case "unknown_evidence_id":
            self = .unknownEvidenceID(try field("evidenceID"))
        case "duplicate_patch_op_id":
            self = .duplicatePatchOpID(try field("patchOpID"))
        case "duplicate_call_target":
            self = .duplicateCallTarget(try field("sample"), try field("locus"), try field("slot"))
        case "missing_counterevidence":
            self = .missingCounterevidence(try field("patchOpID"))
        case "missing_support_evidence":
            self = .missingSupportEvidence(try field("patchOpID"))
        case "invalid_haplotype_label":
            self = .invalidHaplotypeLabel(try field("sample"), try field("locus"), try field("slot"))
        case "invalid_source":
            self = .invalidSource(try field("value"))
        case "unknown_call_target":
            self = .unknownCallTarget(try field("sample"), try field("locus"))
        case "unknown_definition_locus":
            self = .unknownDefinitionLocus(try field("locus"))
        case "evidence_target_mismatch":
            self = .evidenceTargetMismatch(try field("evidenceID"), try field("sample"), try field("locus"))
        case "conflicts_current_call":
            self = .conflictsCurrentCall(try field("sample"), try field("locus"), try field("slot"))
        case "conflicts_manual_review":
            self = .conflictsManualReview(try field("sample"), try field("locus"), try field("slot"))
        case "missing_current_conflict":
            self = .missingCurrentConflict(try field("sample"), try field("locus"), try field("slot"))
        case "missing_manual_conflict":
            self = .missingManualConflict(try field("sample"), try field("locus"), try field("slot"))
        case "missing_current_carry_forward":
            self = .missingCurrentCarryForward(try field("sample"), try field("locus"), try field("slot"))
        case "missing_manual_carry_forward":
            self = .missingManualCarryForward(try field("sample"), try field("locus"), try field("slot"))
        case "invalid_carry_forward_label":
            self = .invalidCarryForwardLabel(try field("sample"), try field("locus"), try field("slot"))
        case "retain_current_mismatch":
            self = .retainCurrentMismatch(try field("sample"), try field("locus"), try field("slot"))
        case "unsupported_duplicate_slot_label":
            self = .unsupportedDuplicateSlotLabel(try field("sample"), try field("locus"), try field("label"))
        case "duplicate_discovered_definition":
            self = .duplicateDiscoveredDefinition(try field("definitionID"))
        case "provisional_definition_collision":
            self = .provisionalDefinitionCollision(try field("key"))
        case "unsupported_claim":
            self = .unsupportedClaim(try field("text"))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .code,
                in: container,
                debugDescription: "Unknown AI haplotyping validation error code '\(code)'."
            )
        }
    }
}
