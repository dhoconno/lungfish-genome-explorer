import Foundation
import LungfishIO

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
        let normalizedResult = normalizedTargetReferences(in: result, context: context)
        if let unsupportedClaim = firstUnsupportedClaim(in: normalizedResult) {
            return rejected(.unsupportedClaim(unsupportedClaim), result: normalizedResult)
        }
        let coalescedResult: AIHaplotypingStructuredResult
        switch coalescedDuplicateTargetCalls(in: normalizedResult) {
        case .success(let result):
            coalescedResult = result
        case .failure(let error):
            return rejected(error, result: normalizedResult)
        }
        if let error = firstPatchIdentityError(in: coalescedResult.calls) {
            return rejected(error, result: coalescedResult)
        }
        if let error = firstDuplicateProposedLabelError(in: coalescedResult.calls) {
            return rejected(error, result: coalescedResult)
        }
        if let error = firstDefinitionIdentityError(in: coalescedResult.discoveredDefinitions) {
            return rejected(error, result: coalescedResult)
        }
        if let error = firstDefinitionEvidenceError(in: coalescedResult.discoveredDefinitions, context: context) {
            return rejected(error, result: coalescedResult)
        }
        if let error = firstCallValidationError(in: coalescedResult.calls, context: context) {
            return rejected(error, result: coalescedResult)
        }

        let normalizedCalls = coalescedResult.calls.map(normalizedCall(from:))
        let validatedDefinitions = coalescedResult.discoveredDefinitions.map { definition in
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
            run: coalescedResult.run,
            chunkID: coalescedResult.chunkID,
            registryDigest: coalescedResult.registryDigest,
            inputSnapshotDigest: coalescedResult.inputSnapshotDigest,
            normalizedCalls: normalizedCalls,
            validatedDefinitions: validatedDefinitions,
            warnings: coalescedResult.warnings,
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
            let patchOpID = call.patchOpID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !patchOpID.isEmpty else {
                return .invalidPatchOpID(call.patchOpID)
            }
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

    private func coalescedDuplicateTargetCalls(
        in result: AIHaplotypingStructuredResult
    ) -> Result<AIHaplotypingStructuredResult, AIHaplotypingValidationError> {
        var callsByTarget: [CallTarget: AIHaplotypingStructuredCall] = [:]
        var calls: [AIHaplotypingStructuredCall] = []
        for call in result.calls {
            let target = CallTarget(sample: call.sample, locus: call.locus, slot: call.slot)
            guard let existing = callsByTarget[target] else {
                callsByTarget[target] = call
                calls.append(call)
                continue
            }
            guard substantivelySameCall(existing, call) else {
                return .failure(.duplicateCallTarget(call.sample, call.locus, call.slot))
            }
        }
        guard calls.count != result.calls.count else {
            return .success(result)
        }
        return .success(AIHaplotypingStructuredResult(
            schemaVersion: result.schemaVersion,
            run: result.run,
            registryDigest: result.registryDigest,
            inputSnapshotDigest: result.inputSnapshotDigest,
            chunkID: result.chunkID,
            discoveredDefinitions: result.discoveredDefinitions,
            calls: calls,
            warnings: result.warnings
        ))
    }

    private func substantivelySameCall(
        _ lhs: AIHaplotypingStructuredCall,
        _ rhs: AIHaplotypingStructuredCall
    ) -> Bool {
        lhs.sample == rhs.sample
            && lhs.locus == rhs.locus
            && lhs.slot == rhs.slot
            && lhs.haplotypeLabel == rhs.haplotypeLabel
            && lhs.normalizedFamily == rhs.normalizedFamily
            && lhs.source == rhs.source
            && lhs.sourceState == rhs.sourceState
            && lhs.reviewState == rhs.reviewState
            && lhs.callState == rhs.callState
            && lhs.confidenceTier == rhs.confidenceTier
            && lhs.supportEvidenceRefs == rhs.supportEvidenceRefs
            && lhs.counterevidenceRefs == rhs.counterevidenceRefs
            && lhs.alternates == rhs.alternates
    }

    private func normalizedTargetReferences(
        in result: AIHaplotypingStructuredResult,
        context: ValidationContext
    ) -> AIHaplotypingStructuredResult {
        let calls = result.calls.map { call in
            let sample = context.normalizedSampleReference(call.sample)
            let locus = context.normalizedLocusReference(call.locus)
            let supportEvidenceRefs = call.supportEvidenceRefs.map(context.normalizedEvidenceReference)
            let counterevidenceRefs = call.counterevidenceRefs.map(context.normalizedEvidenceReference)
            return AIHaplotypingStructuredCall(
                patchOpID: call.patchOpID,
                sample: sample,
                locus: locus,
                slot: call.slot,
                haplotypeLabel: call.haplotypeLabel,
                normalizedFamily: call.normalizedFamily,
                source: call.source,
                sourceState: call.sourceState,
                reviewState: call.reviewState,
                callState: normalizedCallState(
                    call.callState,
                    sample: sample,
                    locus: locus,
                    slot: call.slot,
                    haplotypeLabel: call.haplotypeLabel,
                    supportEvidenceRefs: supportEvidenceRefs,
                    counterevidenceRefs: counterevidenceRefs,
                    rationaleCode: call.rationaleCode,
                    rationale: call.rationale,
                    context: context
                ),
                confidenceTier: call.confidenceTier,
                supportEvidenceRefs: supportEvidenceRefs,
                counterevidenceRefs: counterevidenceRefs,
                alternates: call.alternates,
                rationaleCode: call.rationaleCode,
                rationale: call.rationale
            )
        }
        let discoveredDefinitions = result.discoveredDefinitions.map { definition in
            AIHaplotypingDiscoveredDefinition(
                definitionID: definition.definitionID,
                locus: context.normalizedLocusReference(definition.locus),
                proposedLabel: definition.proposedLabel,
                normalizedFamily: definition.normalizedFamily,
                supportEvidenceRefs: definition.supportEvidenceRefs.map(context.normalizedEvidenceReference),
                counterevidenceRefs: definition.counterevidenceRefs.map(context.normalizedEvidenceReference),
                confidenceTier: definition.confidenceTier,
                rationaleCode: definition.rationaleCode,
                rationale: definition.rationale
            )
        }
        return AIHaplotypingStructuredResult(
            schemaVersion: result.schemaVersion,
            run: result.run,
            registryDigest: result.registryDigest,
            inputSnapshotDigest: result.inputSnapshotDigest,
            chunkID: result.chunkID,
            discoveredDefinitions: discoveredDefinitions,
            calls: calls,
            warnings: result.warnings
        )
    }

    private func normalizedCallState(
        _ callState: GenotypeHaplotypeAICallState,
        sample: String,
        locus: String,
        slot: String,
        haplotypeLabel: String,
        supportEvidenceRefs: [String],
        counterevidenceRefs: [String],
        rationaleCode: String,
        rationale: String,
        context: ValidationContext
    ) -> GenotypeHaplotypeAICallState {
        if requiresPositiveHaplotypeLabel(callState)
            && !isCallableCarryForwardLabel(haplotypeLabel) {
            return .unresolved
        }
        let target = CallTarget(sample: sample, locus: locus, slot: slot)
        if callState == .called,
           let currentCall = context.currentCalls[target],
           isConflict(existingLabel: currentCall.haplotypeLabel, proposedLabel: haplotypeLabel),
           counterevidenceRefs.contains(currentCall.id),
           explicitlyAcknowledgesCurrentConflict(
               rationaleCode: rationaleCode,
               rationale: rationale,
               supportEvidenceRefs: supportEvidenceRefs,
               currentEvidenceID: currentCall.id
           ) {
            return .conflictsCurrent
        }
        guard callState == .conflictsCurrent else {
            return callState
        }
        guard let currentCall = context.currentCalls[target],
              !isConflict(existingLabel: currentCall.haplotypeLabel, proposedLabel: haplotypeLabel) else {
            return callState
        }
        return isCallableCarryForwardLabel(haplotypeLabel) ? .called : .unresolved
    }

    private func explicitlyAcknowledgesCurrentConflict(
        rationaleCode: String,
        rationale: String,
        supportEvidenceRefs: [String],
        currentEvidenceID: String
    ) -> Bool {
        guard !supportEvidenceRefs.isEmpty else { return false }
        let text = "\(rationaleCode) \(rationale)".lowercased()
        let mentionsCurrent = text.contains("current")
        let mentionsConflict = text.contains("conflict")
            || text.contains("contradict")
            || text.contains("supersed")
            || text.contains("override")
            || text.contains("replace")
            || text.contains("disagree")
        return mentionsCurrent && mentionsConflict && !currentEvidenceID.isEmpty
    }

    private func firstDuplicateProposedLabelError(
        in calls: [AIHaplotypingStructuredCall]
    ) -> AIHaplotypingValidationError? {
        var callsByTargetLabel: [SampleLocusLabel: [AIHaplotypingStructuredCall]] = [:]
        var orderedKeys: [SampleLocusLabel] = []
        for call in calls {
            let label = call.haplotypeLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, label != "-" else { continue }
            let key = SampleLocusLabel(sample: call.sample, locus: call.locus, label: label)
            if callsByTargetLabel[key] == nil {
                orderedKeys.append(key)
            }
            callsByTargetLabel[key, default: []].append(call)
        }

        for key in orderedKeys {
            guard let groupedCalls = callsByTargetLabel[key] else { continue }
            let slots = Set(groupedCalls.map(\.slot))
            guard slots.count > 1 else { continue }
            guard allowsDuplicateSlotLabel(groupedCalls) else {
                return .unsupportedDuplicateSlotLabel(key.sample, key.locus, key.label)
            }
        }
        return nil
    }

    private func allowsDuplicateSlotLabel(_ calls: [AIHaplotypingStructuredCall]) -> Bool {
        return Set(calls.map(\.slot)) == ["h1", "h2"]
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
                if let evidenceLocus = evidence.locus,
                   evidenceLocus != definition.locus {
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
            if requiresPositiveHaplotypeLabel(call.callState)
                && !isCallableCarryForwardLabel(call.haplotypeLabel) {
                return .invalidHaplotypeLabel(call.sample, call.locus, call.slot)
            }
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
        if let evidenceLocus = evidence.locus,
           !isCompatibleEvidenceLocus(evidenceLocus, targetLocus: call.locus) {
            return .evidenceTargetMismatch(evidence.id, call.sample, call.locus)
        }
        return nil
    }

    private func isCompatibleEvidenceLocus(_ evidenceLocus: String, targetLocus: String) -> Bool {
        if evidenceLocus == targetLocus { return true }
        if isAdjacentHaplotypeContext(evidenceLocus, targetLocus) { return true }
        if evidenceLocus == "MHC-L" {
            return targetLocus == "MHC-A" || targetLocus == "MHC-E"
        }
        return false
    }

    private func isAdjacentHaplotypeContext(_ evidenceLocus: String, _ targetLocus: String) -> Bool {
        GenotypeHaplotypeLocusResolver.isReportableHaplotypeLocus(evidenceLocus)
            && GenotypeHaplotypeLocusResolver.isReportableHaplotypeLocus(targetLocus)
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

    private func requiresPositiveHaplotypeLabel(_ callState: GenotypeHaplotypeAICallState) -> Bool {
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
        guard isCallableCarryForwardLabel(carriedForwardLabel) else {
            return .invalidCarryForwardLabel(call.sample, call.locus, call.slot)
        }
        guard normalizedCarryForwardLabel(carriedForwardLabel) == normalizedCarryForwardLabel(call.haplotypeLabel) else {
            return .retainCurrentMismatch(call.sample, call.locus, call.slot)
        }
        return nil
    }

    private func normalizedCarryForwardLabel(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isCallableCarryForwardLabel(_ value: String) -> Bool {
        let normalized = normalizedCarryForwardLabel(value)
        guard !normalized.isEmpty, normalized != "-" else { return false }
        let uppercased = normalized.uppercased()
        guard !uppercased.hasPrefix("ERR:") else { return false }
        guard uppercased != "NOT ASSAYED" else { return false }
        return true
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
        guard isCallableCarryForwardLabel(existing) else { return false }
        let proposed = proposedLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isCallableCarryForwardLabel(proposed) else { return false }
        return existing != proposed
    }

    private func firstUnsupportedClaim(in result: AIHaplotypingStructuredResult) -> String? {
        for field in modelTextFields(in: result) {
            if let claim = unsupportedClaim(
                in: field.text,
                allowsHomozygosity: field.allowsHomozygosity,
                allowsAbsence: field.allowsAbsence
            ) {
                return claim
            }
        }
        return nil
    }

    private func modelTextFields(in result: AIHaplotypingStructuredResult) -> [ModelTextField] {
        var fields: [ModelTextField] = []
        for call in result.calls {
            fields.append(ModelTextField(text: call.haplotypeLabel))
            if let normalizedFamily = call.normalizedFamily {
                fields.append(ModelTextField(text: normalizedFamily))
            }
            fields.append(contentsOf: call.alternates.map { ModelTextField(text: $0) })
            fields.append(ModelTextField(
                text: call.rationaleCode,
                allowsHomozygosity: true,
                allowsAbsence: true
            ))
            fields.append(ModelTextField(
                text: call.rationale,
                allowsHomozygosity: true,
                allowsAbsence: true
            ))
        }
        for definition in result.discoveredDefinitions {
            fields.append(ModelTextField(text: definition.proposedLabel))
            if let normalizedFamily = definition.normalizedFamily {
                fields.append(ModelTextField(text: normalizedFamily))
            }
            fields.append(ModelTextField(text: definition.rationaleCode))
            fields.append(ModelTextField(text: definition.rationale))
        }
        fields.append(contentsOf: result.warnings.map {
            ModelTextField(text: $0, allowsHomozygosity: true, allowsAbsence: true)
        })
        return fields
    }

    private func unsupportedClaim(in text: String, allowsHomozygosity: Bool, allowsAbsence: Bool) -> String? {
        let normalized = text
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .lowercased()
        var terms = [
            "phase",
            "phasing",
            "copy number",
            "inherited",
            "inheritance",
            "clinical",
        ]
        if !allowsHomozygosity {
            terms.append(contentsOf: ["homozygous", "homozygosity"])
        }
        if !allowsAbsence {
            terms.append(contentsOf: ["absent", "absence"])
        }
        for term in terms {
            if term == "clinical" {
                guard containsUnsupportedClinicalClaim(in: normalized) else {
                    continue
                }
                return text
            }
            if normalized.contains(term) {
                return text
            }
        }
        return nil
    }

    private func containsUnsupportedClinicalClaim(in normalizedText: String) -> Bool {
        var text = normalizedText
        for allowedPhrase in ["not clinical", "non clinical", "nonclinical"] {
            text = text.replacingOccurrences(of: allowedPhrase, with: "")
        }
        return text.contains("clinical")
    }
}

private struct ModelTextField {
    let text: String
    let allowsHomozygosity: Bool
    let allowsAbsence: Bool

    init(text: String, allowsHomozygosity: Bool = false, allowsAbsence: Bool = false) {
        self.text = text
        self.allowsHomozygosity = allowsHomozygosity
        self.allowsAbsence = allowsAbsence
    }
}

private struct ValidationContext: Sendable {
    let mode: AIHaplotypingPromptMode
    let samples: Set<String>
    let loci: Set<String>
    let sampleReferences: [String: String]
    let locusReferences: [String: String]
    let evidenceByID: [String: EvidenceRecord]
    let currentCalls: [CallTarget: CurrentCallEvidence]
    let manualReviews: [CallTarget: ManualReviewEvidence]

    init(registry: AIHaplotypingEvidenceRegistry) {
        mode = registry.mode
        samples = Set(registry.samples.map(\.sample))
        loci = Set(registry.loci.map(\.locus).filter {
            GenotypeHaplotypeLocusResolver.isReportableHaplotypeLocus($0)
        })
        let samplesByID = Dictionary(uniqueKeysWithValues: registry.samples.map { ($0.id, $0.sample) })
        let lociByID = Dictionary(uniqueKeysWithValues: registry.loci.map { ($0.id, $0.locus) })
        var sampleReferences: [String: String] = [:]
        for sample in registry.samples {
            sampleReferences[sample.sample] = sample.sample
            sampleReferences[sample.id] = sample.sample
        }
        self.sampleReferences = sampleReferences
        var locusReferences: [String: String] = [:]
        for locus in registry.loci {
            locusReferences[locus.locus] = locus.locus
            locusReferences[locus.id] = locus.locus
        }
        self.locusReferences = locusReferences
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

    func normalizedSampleReference(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return sampleReferences[trimmed] ?? trimmed
    }

    func normalizedLocusReference(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let locus = locusReferences[trimmed] {
            return locus
        }
        let canonical = GenotypeHaplotypeLocusResolver.canonicalLocusName(trimmed)
        return loci.contains(canonical) ? canonical : trimmed
    }

    func normalizedEvidenceReference(_ rawValue: String) -> String {
        if evidenceByID[rawValue] != nil {
            return rawValue
        }

        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if evidenceByID[trimmed] != nil {
            return trimmed
        }
        if trimmed.hasSuffix("|") {
            let pipeStripped = String(trimmed.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            if evidenceByID[pipeStripped] != nil {
                return pipeStripped
            }
        }
        let pipeComponents = trimmed
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        if pipeComponents.count == 2,
           pipeComponents[0] == pipeComponents[1],
           evidenceByID[pipeComponents[0]] != nil {
            return pipeComponents[0]
        }

        for prefix in ["sample:", "locus:"] {
            let duplicatedPrefix = "\(prefix)\(prefix)"
            if trimmed.hasPrefix(duplicatedPrefix) {
                let candidate = prefix + trimmed.dropFirst(duplicatedPrefix.count)
                if evidenceByID[String(candidate)] != nil {
                    return String(candidate)
                }
            }
        }

        guard trimmed.hasPrefix("obs:") else {
            return rawValue
        }

        if let pipeIndex = trimmed.firstIndex(of: "|") {
            let baseID = String(trimmed[..<pipeIndex])
            if let uniqueBaseObservationID = uniqueEvidenceID(matchingPrefix: "\(baseID)|") {
                return uniqueBaseObservationID
            }
        }

        for suffix in ["g", "N"] {
            let trailingVariant = "\(trimmed)\(suffix)"
            if evidenceByID[trailingVariant] != nil {
                return trailingVariant
            }
        }

        if let pipedObservationID = uniqueEvidenceID(matchingPrefix: "\(trimmed)|") {
            return pipedObservationID
        }

        if let pipedAliasObservationID = uniquePipedAliasObservationID(matching: trimmed) {
            return pipedAliasObservationID
        }

        if let terminalSuffixObservationID = uniqueTerminalSuffixObservationID(matching: trimmed) {
            return terminalSuffixObservationID
        }

        if let alleleFamilySuffixObservationID = uniqueAlleleFamilySuffixObservationID(matching: trimmed) {
            return alleleFamilySuffixObservationID
        }

        if let collapsedMarkerObservationID = uniqueCollapsedMarkerObservationID(matching: trimmed) {
            return collapsedMarkerObservationID
        }

        if let leadingRegionTokenObservationID = uniqueLeadingRegionTokenObservationID(matching: trimmed) {
            return leadingRegionTokenObservationID
        }

        return rawValue
    }

    private func uniqueEvidenceID(matchingPrefix prefix: String) -> String? {
        var match: String?
        for evidenceID in evidenceByID.keys where evidenceID.hasPrefix(prefix) {
            guard match == nil else {
                return nil
            }
            match = evidenceID
        }
        return match
    }

    private func uniquePipedAliasObservationID(matching rawObservationID: String) -> String? {
        guard let raw = observationIDParts(rawObservationID),
              let rawMarker = markerPrefixAndTail(raw.genotype) else {
            return nil
        }

        var match: String?
        for evidenceID in evidenceByID.keys {
            guard let candidate = observationIDParts(evidenceID),
                  candidate.sample == raw.sample,
                  candidate.locus == raw.locus,
                  let pipeIndex = candidate.genotype.firstIndex(of: "|") else {
                continue
            }

            let candidateBase = String(candidate.genotype[..<pipeIndex])
            guard let candidateMarker = markerPrefixAndTail(candidateBase),
                  candidateMarker.leadingToken == rawMarker.leadingToken,
                  areCompatibleCollapsedMarkerGroups(
                      candidateMarker.haplotypeGroups,
                      rawMarker.haplotypeGroups
                  ) else {
                continue
            }

            let aliasStart = candidate.genotype.index(after: pipeIndex)
            let aliases = candidate.genotype[aliasStart...]
                .split(separator: ",", omittingEmptySubsequences: true)
                .map { normalizedPipedAliasToken(String($0)) }
            guard aliases.contains(rawMarker.tail) else {
                continue
            }
            guard match == nil else {
                return nil
            }
            match = evidenceID
        }
        return match
    }

    private func normalizedPipedAliasToken(_ rawAlias: String) -> String {
        var alias = rawAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        while alias.hasPrefix("_") {
            alias.removeFirst()
        }
        return alias
    }

    private func uniqueTerminalSuffixObservationID(matching rawObservationID: String) -> String? {
        guard let raw = observationIDParts(rawObservationID) else {
            return nil
        }

        let genotypePrefix = "\(raw.genotype)_"
        var match: String?
        for evidenceID in evidenceByID.keys {
            guard let candidate = observationIDParts(evidenceID),
                  candidate.sample == raw.sample,
                  candidate.locus == raw.locus,
                  candidate.genotype.hasPrefix(genotypePrefix) else {
                continue
            }
            let suffix = String(candidate.genotype.dropFirst(genotypePrefix.count))
            guard isTerminalObservationSuffix(suffix) else {
                continue
            }
            guard match == nil else {
                return nil
            }
            match = evidenceID
        }
        return match
    }

    private func isTerminalObservationSuffix(_ suffix: String) -> Bool {
        if suffix.hasSuffix("bp") {
            let lengthToken = suffix.dropLast(2)
            return !lengthToken.isEmpty && lengthToken.allSatisfy { $0.isNumber }
        }
        return !suffix.isEmpty && suffix.allSatisfy { $0.isNumber }
    }

    private func uniqueAlleleFamilySuffixObservationID(matching rawObservationID: String) -> String? {
        guard let raw = observationIDParts(rawObservationID),
              let rawMarker = markerPrefixAndTail(raw.genotype),
              let rawStem = alleleFamilyStem(rawMarker.tail) else {
            return nil
        }

        var match: String?
        for evidenceID in evidenceByID.keys {
            guard let candidate = observationIDParts(evidenceID),
                  candidate.sample == raw.sample,
                  candidate.locus == raw.locus,
                  candidate.genotype != raw.genotype,
                  let candidateMarker = markerPrefixAndTail(candidate.genotype),
                  candidateMarker.leadingToken == rawMarker.leadingToken,
                  areCompatibleCollapsedMarkerGroups(
                      candidateMarker.haplotypeGroups,
                      rawMarker.haplotypeGroups
                  ),
                  alleleFamilyStem(candidateMarker.tail) == rawStem else {
                continue
            }
            guard match == nil else {
                return nil
            }
            match = evidenceID
        }
        return match
    }

    private func alleleFamilyStem(_ tail: String) -> String? {
        if let groupSuffix = tail.range(of: #"g\d+ex$"#, options: .regularExpression) {
            let stem = String(tail[..<groupSuffix.lowerBound])
            return stem.isEmpty ? nil : stem
        }
        if let numericSuffix = tail.range(of: #"_\d+$"#, options: .regularExpression) {
            let stem = String(tail[..<numericSuffix.lowerBound])
            return stem.isEmpty ? nil : stem
        }
        return nil
    }

    private func uniqueCollapsedMarkerObservationID(matching rawObservationID: String) -> String? {
        guard let raw = observationIDParts(rawObservationID),
              let rawSignature = markerSignature(for: raw.genotype) else {
            return nil
        }

        var match: String?
        for evidenceID in evidenceByID.keys {
            guard let candidate = observationIDParts(evidenceID),
                  candidate.sample == raw.sample,
                  candidate.locus == raw.locus,
                  let candidateSignature = markerSignature(for: candidate.genotype),
                  candidateSignature.skeleton == rawSignature.skeleton,
                  areCompatibleCollapsedMarkerGroups(
                      candidateSignature.haplotypeGroups,
                      rawSignature.haplotypeGroups
                  ) else {
                continue
            }
            guard match == nil else {
                return nil
            }
            match = evidenceID
        }
        return match
    }

    private func uniqueLeadingRegionTokenObservationID(matching rawObservationID: String) -> String? {
        guard let raw = observationIDParts(rawObservationID),
              let rawTail = markerTailAfterLeadingToken(raw.genotype) else {
            return nil
        }

        var match: String?
        for evidenceID in evidenceByID.keys {
            guard let candidate = observationIDParts(evidenceID),
                  candidate.sample == raw.sample,
                  candidate.locus == raw.locus,
                  candidate.genotype != raw.genotype,
                  markerTailAfterLeadingToken(candidate.genotype) == rawTail else {
                continue
            }
            guard match == nil else {
                return nil
            }
            match = evidenceID
        }
        return match
    }

    private func markerTailAfterLeadingToken(_ genotype: String) -> String? {
        guard let firstUnderscore = genotype.firstIndex(of: "_"),
              firstUnderscore < genotype.index(before: genotype.endIndex) else {
            return nil
        }
        let leadingToken = genotype[..<firstUnderscore]
        guard leadingToken.allSatisfy({ $0.isNumber }) else {
            return nil
        }
        return String(genotype[genotype.index(after: firstUnderscore)...])
    }

    private func markerPrefixAndTail(
        _ genotype: String
    ) -> (leadingToken: String, haplotypeGroups: Set<String>, tail: String)? {
        let parts = genotype.split(separator: "_", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else {
            return nil
        }
        let groups = haplotypeGroups(in: String(parts[1]))
        guard !groups.isEmpty else {
            return nil
        }
        return (String(parts[0]), groups, String(parts[2]))
    }

    private func areCompatibleCollapsedMarkerGroups(_ lhs: Set<String>, _ rhs: Set<String>) -> Bool {
        !lhs.intersection(rhs).isEmpty
    }

    private func observationIDParts(_ rawValue: String) -> ObservationIDParts? {
        let parts = rawValue.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "obs" else {
            return nil
        }
        return ObservationIDParts(
            sample: String(parts[1]),
            locus: String(parts[2]),
            genotype: String(parts[3])
        )
    }

    private func markerSignature(for genotype: String) -> MarkerSignature? {
        let parts = genotype.split(separator: "_", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else {
            return nil
        }
        let haplotypeGroups = haplotypeGroups(in: String(parts[1]))
        guard !haplotypeGroups.isEmpty else {
            return nil
        }
        return MarkerSignature(
            skeleton: "\(parts[0])_\(parts[2])",
            haplotypeGroups: haplotypeGroups
        )
    }

    private func haplotypeGroups(in rawToken: String) -> Set<String> {
        var groups: Set<String> = []
        var index = rawToken.startIndex
        while index < rawToken.endIndex {
            guard rawToken[index] == "M" else {
                return []
            }
            var next = rawToken.index(after: index)
            let digitsStart = next
            while next < rawToken.endIndex, rawToken[next].isNumber {
                next = rawToken.index(after: next)
            }
            guard digitsStart != next else {
                return []
            }
            groups.insert(String(rawToken[index..<next]))
            index = next
        }
        return groups
    }
}

private struct ObservationIDParts: Equatable, Sendable {
    let sample: String
    let locus: String
    let genotype: String
}

private struct MarkerSignature: Equatable, Sendable {
    let skeleton: String
    let haplotypeGroups: Set<String>
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

private struct SampleLocusLabel: Hashable, Sendable {
    let sample: String
    let locus: String
    let label: String
}
