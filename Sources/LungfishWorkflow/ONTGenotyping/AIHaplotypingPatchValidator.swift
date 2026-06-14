import Foundation
import LungfishIO

public enum AIHaplotypingValidationError: Codable, Error, Equatable, Sendable {
    case registryDigestMismatch
    case inputSnapshotDigestMismatch
    case runMetadataMismatch(String)
    case chunkIDMismatch(expected: String, actual: String?)
    case unknownEvidenceID(String)
    case duplicatePatchOpID(String)
    case duplicateCallTarget(String, String, String)
    case missingCounterevidence(String)
    case missingSupportEvidence(String)
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
        case .unknownEvidenceID: return "unknown_evidence_id"
        case .duplicatePatchOpID: return "duplicate_patch_op_id"
        case .duplicateCallTarget: return "duplicate_call_target"
        case .missingCounterevidence: return "missing_counterevidence"
        case .missingSupportEvidence: return "missing_support_evidence"
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
             .retainCurrentMismatch(let sample, let locus, let slot):
            return ["sample": sample, "locus": locus, "slot": slot]
        case .missingCounterevidence(let patchOpID),
             .missingSupportEvidence(let patchOpID):
            return ["patchOpID": patchOpID]
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

public struct AIHaplotypingPatchValidator: Sendable {
    public static let pendingProvenancePath = "ai-haplotyping/provenance.pending.json"

    private let boundRegistry: AIHaplotypingEvidenceRegistry?
    private let expectedRun: AIHaplotypingRunMetadata?
    private let expectedChunkID: String?
    private let provenancePath: String

    public init(
        expectedRun: AIHaplotypingRunMetadata? = nil,
        expectedChunkID: String? = nil,
        provenancePath: String = AIHaplotypingPatchValidator.pendingProvenancePath
    ) {
        self.boundRegistry = nil
        self.expectedRun = expectedRun
        self.expectedChunkID = expectedChunkID
        self.provenancePath = Self.sanitizedProvenancePath(provenancePath)
    }

    public init(
        registry: AIHaplotypingEvidenceRegistry,
        expectedRun: AIHaplotypingRunMetadata? = nil,
        expectedChunkID: String? = nil,
        provenancePath: String = AIHaplotypingPatchValidator.pendingProvenancePath
    ) {
        self.boundRegistry = registry
        self.expectedRun = expectedRun
        self.expectedChunkID = expectedChunkID
        self.provenancePath = Self.sanitizedProvenancePath(provenancePath)
    }

    public func validate(_ result: AIHaplotypingStructuredResult) -> AIHaplotypingValidationReport {
        guard let boundRegistry else {
            preconditionFailure("Use validate(_:registry:) when AIHaplotypingPatchValidator was created without a bound registry.")
        }
        return validate(result, registry: boundRegistry)
    }

    public func validate(
        _ result: AIHaplotypingStructuredResult,
        registry: AIHaplotypingEvidenceRegistry,
        expectedRun: AIHaplotypingRunMetadata? = nil,
        expectedChunkID: String? = nil
    ) -> AIHaplotypingValidationReport {
        let context = ValidationContext(registry: registry)
        let effectiveExpectedRun = expectedRun ?? self.expectedRun
        let effectiveExpectedChunkID = expectedChunkID ?? self.expectedChunkID

        if result.registryDigest != registry.digest || result.run.registryDigest != registry.digest {
            return rejected(.registryDigestMismatch, result: result)
        }
        if result.inputSnapshotDigest != registry.inputSnapshotDigest
            || result.run.inputSnapshotDigest != registry.inputSnapshotDigest {
            return rejected(.inputSnapshotDigestMismatch, result: result)
        }
        if result.schemaVersion != registry.schemaVersion {
            return rejected(.runMetadataMismatch("schemaVersion"), result: result)
        }
        if result.run.mode != registry.mode {
            return rejected(.runMetadataMismatch("mode"), result: result)
        }
        if result.run.parentRevisionID != registry.parentRevisionID {
            return rejected(.runMetadataMismatch("parentRevisionID"), result: result)
        }
        if let effectiveExpectedRun, let mismatch = firstRunMetadataMismatch(result.run, expected: effectiveExpectedRun) {
            return rejected(.runMetadataMismatch(mismatch), result: result)
        }
        if let effectiveExpectedChunkID, result.chunkID != effectiveExpectedChunkID {
            return rejected(
                .chunkIDMismatch(expected: effectiveExpectedChunkID, actual: result.chunkID),
                result: result
            )
        }
        if let unsupportedClaim = firstUnsupportedClaim(in: result) {
            return rejected(.unsupportedClaim(unsupportedClaim), result: result)
        }
        if let error = firstPatchIdentityError(in: result.calls) {
            return rejected(error, result: result)
        }
        if let error = firstDuplicateProposedLabelError(in: result.calls) {
            return rejected(error, result: result)
        }
        if let error = firstDefinitionIdentityError(in: result.discoveredDefinitions) {
            return rejected(error, result: result)
        }
        if let error = firstDefinitionEvidenceError(in: result.discoveredDefinitions, context: context) {
            return rejected(error, result: result)
        }
        if let error = firstCallValidationError(in: result.calls, context: context) {
            return rejected(error, result: result)
        }

        let normalizedCalls = result.calls.map(normalizedCall(from:))
        let validatedDefinitions = result.discoveredDefinitions.map { definition in
            AIHaplotypingValidatedDefinition(
                definitionID: definition.definitionID,
                locus: definition.locus,
                proposedLabel: definition.proposedLabel,
                normalizedFamily: definition.normalizedFamily,
                supportEvidenceRefs: definition.supportEvidenceRefs,
                counterevidenceRefs: definition.counterevidenceRefs,
                confidenceTier: definition.confidenceTier
            )
        }
        return AIHaplotypingValidationReport(
            accepted: true,
            run: result.run,
            chunkID: result.chunkID,
            registryDigest: result.registryDigest,
            inputSnapshotDigest: result.inputSnapshotDigest,
            normalizedCalls: normalizedCalls,
            validatedDefinitions: validatedDefinitions,
            warnings: result.warnings,
            errors: []
        )
    }

    public static func haplotypeStatus(for callState: GenotypeHaplotypeAICallState) -> GenotypeHaplotypeCallStatus {
        switch callState {
        case .called:
            return .called
        case .novelCandidate, .ambiguousTie:
            return .specialCase
        case .insufficientEvidence,
             .lowSupportOrDropout,
             .conflictsCurrent,
             .conflictsManual,
             .retainCurrent,
             .unresolved:
            return callState == .retainCurrent ? .called : .noHaplotype
        case .notAssayed, .outOfScope:
            return .notAssayed
        }
    }

    private func firstPatchIdentityError(in calls: [AIHaplotypingStructuredCall]) -> AIHaplotypingValidationError? {
        var patchIDs: Set<String> = []
        var targets: Set<CallTarget> = []
        for call in calls {
            guard patchIDs.insert(call.patchOpID).inserted else {
                return .duplicatePatchOpID(call.patchOpID)
            }
            let target = CallTarget(sample: call.sample, locus: call.locus, slot: call.slot)
            guard targets.insert(target).inserted else {
                return .duplicateCallTarget(call.sample, call.locus, call.slot)
            }
        }
        return nil
    }

    private func firstDuplicateProposedLabelError(
        in calls: [AIHaplotypingStructuredCall]
    ) -> AIHaplotypingValidationError? {
        var labelsBySampleLocus: [SampleLocus: [String: Set<String>]] = [:]
        for call in calls {
            let label = call.haplotypeLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, label != "-" else { continue }
            let sampleLocus = SampleLocus(sample: call.sample, locus: call.locus)
            var labels = labelsBySampleLocus[sampleLocus, default: [:]]
            var slots = labels[label, default: []]
            slots.insert(call.slot)
            if slots.count > 1 {
                return .unsupportedDuplicateSlotLabel(call.sample, call.locus, label)
            }
            labels[label] = slots
            labelsBySampleLocus[sampleLocus] = labels
        }
        return nil
    }

    private func firstDefinitionIdentityError(
        in definitions: [AIHaplotypingDiscoveredDefinition]
    ) -> AIHaplotypingValidationError? {
        var definitionIDs: Set<String> = []
        var definitionKeys: Set<String> = []
        for definition in definitions {
            guard definitionIDs.insert(definition.definitionID).inserted else {
                return .duplicateDiscoveredDefinition(definition.definitionID)
            }
            let key = "\(definition.locus):\(definition.proposedLabel)"
            guard definitionKeys.insert(key).inserted else {
                return .provisionalDefinitionCollision(key)
            }
        }
        return nil
    }

    private func firstDefinitionEvidenceError(
        in definitions: [AIHaplotypingDiscoveredDefinition],
        context: ValidationContext
    ) -> AIHaplotypingValidationError? {
        for definition in definitions {
            guard context.loci.contains(definition.locus) else {
                return .unknownDefinitionLocus(definition.locus)
            }
            for evidenceID in definition.supportEvidenceRefs + definition.counterevidenceRefs {
                guard let evidence = context.evidenceByID[evidenceID] else {
                    return .unknownEvidenceID(evidenceID)
                }
                if let evidenceLocus = evidence.locus, evidenceLocus != definition.locus {
                    return .evidenceTargetMismatch(evidenceID, "", definition.locus)
                }
                guard evidence.evidenceClass != .cohortRecurrence else { continue }
            }
            guard hasSubstantiveSupport(definition.supportEvidenceRefs, context: context) else {
                return .missingSupportEvidence(definition.definitionID)
            }
        }
        return nil
    }

    private func firstCallValidationError(
        in calls: [AIHaplotypingStructuredCall],
        context: ValidationContext
    ) -> AIHaplotypingValidationError? {
        for call in calls {
            if !context.samples.contains(call.sample) || !context.loci.contains(call.locus) {
                return .unknownCallTarget(call.sample, call.locus)
            }
            if call.slot != "h1" && call.slot != "h2" {
                return .invalidSource(call.slot)
            }
            guard call.source == .ai else {
                return .invalidSource(call.source.rawValue)
            }
            guard call.reviewState == .needsReview else {
                return .invalidSource(call.reviewState.rawValue)
            }
            guard !call.counterevidenceRefs.isEmpty else {
                return .missingCounterevidence(call.patchOpID)
            }
            for evidenceID in call.supportEvidenceRefs + call.counterevidenceRefs {
                guard let evidence = context.evidenceByID[evidenceID] else {
                    return .unknownEvidenceID(evidenceID)
                }
                if let error = evidenceMismatch(evidence, target: call) {
                    return error
                }
            }
            if requiresSubstantiveSupport(call.callState)
                && !hasSubstantiveSupport(call.supportEvidenceRefs, context: context) {
                return .missingSupportEvidence(call.patchOpID)
            }

            let target = CallTarget(sample: call.sample, locus: call.locus, slot: call.slot)
            if call.callState == .retainCurrent {
                if let error = retainCurrentValidationError(for: call, target: target, context: context) {
                    return error
                }
                continue
            }
            if let manualReview = context.manualReviews[target] {
                let manualConflict = isConflict(
                    existingLabel: manualReview.overrideCall,
                    proposedLabel: call.haplotypeLabel
                )
                if manualConflict && call.callState != .conflictsManual {
                    return .conflictsManualReview(call.sample, call.locus, call.slot)
                }
                if call.callState == .conflictsManual && !manualConflict {
                    return .missingManualConflict(call.sample, call.locus, call.slot)
                }
                if call.callState == .conflictsCurrent {
                    return .missingCurrentConflict(call.sample, call.locus, call.slot)
                }
            } else {
                let currentConflict = context.currentCalls[target].map {
                    isConflict(existingLabel: $0.haplotypeLabel, proposedLabel: call.haplotypeLabel)
                } ?? false
                if currentConflict && call.callState != .conflictsCurrent {
                    return .conflictsCurrentCall(call.sample, call.locus, call.slot)
                }
                if call.callState == .conflictsCurrent && !currentConflict {
                    return .missingCurrentConflict(call.sample, call.locus, call.slot)
                }
                if call.callState == .conflictsManual {
                    return .missingManualConflict(call.sample, call.locus, call.slot)
                }
            }
        }
        return nil
    }

    private func evidenceMismatch(
        _ evidence: EvidenceRecord,
        target call: AIHaplotypingStructuredCall
    ) -> AIHaplotypingValidationError? {
        guard evidence.evidenceClass != .cohortRecurrence else { return nil }
        if let evidenceSample = evidence.sample, evidenceSample != call.sample {
            return .evidenceTargetMismatch(evidence.id, call.sample, call.locus)
        }
        if let evidenceLocus = evidence.locus, evidenceLocus != call.locus {
            return .evidenceTargetMismatch(evidence.id, call.sample, call.locus)
        }
        return nil
    }

    private func normalizedCall(from call: AIHaplotypingStructuredCall) -> AIHaplotypingValidatedCall {
        let status = Self.haplotypeStatus(for: call.callState)
        let primaryLabel = call.callState == .called ? call.haplotypeLabel : nil
        let metadata = GenotypeHaplotypeAICallMetadata(
            patchOpID: call.patchOpID,
            source: call.source,
            sourceState: call.sourceState,
            reviewState: call.reviewState,
            callState: call.callState,
            confidenceTier: call.confidenceTier,
            proposedHaplotypeLabel: call.haplotypeLabel,
            supportEvidenceRefs: call.supportEvidenceRefs,
            counterevidenceRefs: call.counterevidenceRefs,
            alternates: call.alternates,
            rationaleCode: call.rationaleCode,
            rationale: call.rationale,
            provenancePath: provenancePath
        )
        return AIHaplotypingValidatedCall(
            patchOpID: call.patchOpID,
            sample: call.sample,
            locus: call.locus,
            slot: call.slot,
            status: status,
            primaryHaplotypeLabel: primaryLabel,
            proposedHaplotypeLabel: call.haplotypeLabel,
            aiMetadata: metadata,
            supportEvidenceRefs: call.supportEvidenceRefs,
            counterevidenceRefs: call.counterevidenceRefs
        )
    }

    private func hasSubstantiveSupport(
        _ evidenceIDs: [String],
        context: ValidationContext
    ) -> Bool {
        evidenceIDs.contains { evidenceID in
            guard let evidenceClass = context.evidenceByID[evidenceID]?.evidenceClass else {
                return false
            }
            return evidenceClass != .cohortRecurrence
        }
    }

    private func requiresSubstantiveSupport(_ callState: GenotypeHaplotypeAICallState) -> Bool {
        switch callState {
        case .called, .novelCandidate, .ambiguousTie:
            return true
        case .insufficientEvidence,
             .lowSupportOrDropout,
             .conflictsCurrent,
             .conflictsManual,
             .retainCurrent,
             .notAssayed,
             .outOfScope,
             .unresolved:
            return false
        }
    }

    private func retainCurrentValidationError(
        for call: AIHaplotypingStructuredCall,
        target: CallTarget,
        context: ValidationContext
    ) -> AIHaplotypingValidationError? {
        guard context.mode == .aiRefinement else {
            return .invalidSource(call.callState.rawValue)
        }
        let carriedForwardLabel: String
        switch call.sourceState {
        case .current, .deterministic:
            guard let current = context.currentCalls[target] else {
                return .missingCurrentCarryForward(call.sample, call.locus, call.slot)
            }
            carriedForwardLabel = current.haplotypeLabel
        case .manual:
            guard let manual = context.manualReviews[target] else {
                return .missingManualCarryForward(call.sample, call.locus, call.slot)
            }
            carriedForwardLabel = manual.overrideCall
        case .raw:
            return .invalidSource(call.sourceState.rawValue)
        }
        guard normalizedCarryForwardLabel(carriedForwardLabel) == normalizedCarryForwardLabel(call.haplotypeLabel) else {
            return .retainCurrentMismatch(call.sample, call.locus, call.slot)
        }
        return nil
    }

    private func normalizedCarryForwardLabel(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func rejected(
        _ error: AIHaplotypingValidationError,
        result: AIHaplotypingStructuredResult
    ) -> AIHaplotypingValidationReport {
        AIHaplotypingValidationReport(
            accepted: false,
            run: result.run,
            chunkID: result.chunkID,
            registryDigest: result.registryDigest,
            inputSnapshotDigest: result.inputSnapshotDigest,
            normalizedCalls: [],
            validatedDefinitions: [],
            warnings: result.warnings,
            errors: [error]
        )
    }

    private static func sanitizedProvenancePath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? pendingProvenancePath : trimmed
    }

    private func firstRunMetadataMismatch(
        _ actual: AIHaplotypingRunMetadata,
        expected: AIHaplotypingRunMetadata
    ) -> String? {
        if actual.mode != expected.mode { return "mode" }
        if actual.promptTemplateID != expected.promptTemplateID { return "promptTemplateID" }
        if actual.promptTemplateVersion != expected.promptTemplateVersion { return "promptTemplateVersion" }
        if actual.promptHash != expected.promptHash { return "promptHash" }
        if actual.provider != expected.provider { return "provider" }
        if actual.model != expected.model { return "model" }
        if actual.generationParameters != expected.generationParameters { return "generationParameters" }
        if actual.parentRevisionID != expected.parentRevisionID { return "parentRevisionID" }
        if actual.registryDigest != expected.registryDigest { return "registryDigest" }
        if actual.inputSnapshotDigest != expected.inputSnapshotDigest { return "inputSnapshotDigest" }
        return nil
    }

    private func isConflict(existingLabel: String, proposedLabel: String) -> Bool {
        let existing = existingLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !existing.isEmpty, existing != "-" else { return false }
        return existing != proposedLabel.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func firstUnsupportedClaim(in result: AIHaplotypingStructuredResult) -> String? {
        for text in modelTextFields(in: result) {
            if let claim = unsupportedClaim(in: text) {
                return claim
            }
        }
        return nil
    }

    private func modelTextFields(in result: AIHaplotypingStructuredResult) -> [String] {
        var fields: [String] = []
        for call in result.calls {
            fields.append(call.haplotypeLabel)
            if let normalizedFamily = call.normalizedFamily {
                fields.append(normalizedFamily)
            }
            fields.append(contentsOf: call.alternates)
            fields.append(call.rationaleCode)
            fields.append(call.rationale)
        }
        for definition in result.discoveredDefinitions {
            fields.append(definition.proposedLabel)
            if let normalizedFamily = definition.normalizedFamily {
                fields.append(normalizedFamily)
            }
            fields.append(definition.rationaleCode)
            fields.append(definition.rationale)
        }
        fields.append(contentsOf: result.warnings)
        return fields
    }

    private func unsupportedClaim(in text: String) -> String? {
        let normalized = text
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .lowercased()
        let terms = [
            "phase",
            "phasing",
            "homozygous",
            "homozygosity",
            "copy number",
            "inherited",
            "inheritance",
            "absent",
            "absence",
            "clinical",
        ]
        for term in terms {
            if normalized.contains(term) {
                return text
            }
        }
        return nil
    }
}

private struct ValidationContext: Sendable {
    let mode: AIHaplotypingPromptMode
    let samples: Set<String>
    let loci: Set<String>
    let evidenceByID: [String: EvidenceRecord]
    let currentCalls: [CallTarget: CurrentCallEvidence]
    let manualReviews: [CallTarget: ManualReviewEvidence]

    init(registry: AIHaplotypingEvidenceRegistry) {
        mode = registry.mode
        samples = Set(registry.samples.map(\.sample))
        loci = Set(registry.loci.map(\.locus))
        let samplesByID = Dictionary(uniqueKeysWithValues: registry.samples.map { ($0.id, $0.sample) })
        let lociByID = Dictionary(uniqueKeysWithValues: registry.loci.map { ($0.id, $0.locus) })
        var records: [String: EvidenceRecord] = [:]
        for sample in registry.samples {
            records[sample.id] = EvidenceRecord(
                id: sample.id,
                sample: sample.sample,
                locus: nil,
                evidenceClass: nil
            )
        }
        for locus in registry.loci {
            records[locus.id] = EvidenceRecord(
                id: locus.id,
                sample: nil,
                locus: locus.locus,
                evidenceClass: nil
            )
        }
        for observation in registry.observations {
            records[observation.id] = EvidenceRecord(
                id: observation.id,
                sample: samplesByID[observation.sampleID],
                locus: lociByID[observation.locusID],
                evidenceClass: observation.evidenceClass
            )
        }
        for currentCall in registry.currentCalls {
            records[currentCall.id] = EvidenceRecord(
                id: currentCall.id,
                sample: currentCall.sample,
                locus: currentCall.locus,
                evidenceClass: .currentAICall
            )
        }
        for manualReview in registry.manualReviews {
            records[manualReview.id] = EvidenceRecord(
                id: manualReview.id,
                sample: manualReview.sample,
                locus: manualReview.locus,
                evidenceClass: .manualReview
            )
        }
        evidenceByID = records
        currentCalls = Dictionary(uniqueKeysWithValues: registry.currentCalls.map {
            (CallTarget(sample: $0.sample, locus: $0.locus, slot: $0.slot), $0)
        })
        manualReviews = Dictionary(uniqueKeysWithValues: registry.manualReviews.map {
            (CallTarget(sample: $0.sample, locus: $0.locus, slot: $0.slot), $0)
        })
    }
}

private struct EvidenceRecord: Equatable, Sendable {
    let id: String
    let sample: String?
    let locus: String?
    let evidenceClass: AIHaplotypingEvidenceClass?
}

private struct CallTarget: Hashable, Sendable {
    let sample: String
    let locus: String
    let slot: String
}

private struct SampleLocus: Hashable, Sendable {
    let sample: String
    let locus: String
}
