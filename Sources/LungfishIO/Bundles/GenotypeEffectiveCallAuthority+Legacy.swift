import Foundation

extension GenotypeEffectiveCallAuthority {
    /// The existing native typed/legacy MiSeq selection gate, shared with capture.
    public static func isIdentityBoundMiSeqShape(
        legacyBundleKind: String?, legacyWorkflowDeclarationsAbsent: Bool,
        workflowKind: GenotypeResultWorkflowKind?, workflowMode: GenotypeResultWorkflowMode?,
        analysis: GenotypeHaplotypeAnalysis?
    ) -> Bool {
        let typed = workflowKind == .miSeqAmpliconMHCGenotype && workflowMode == .haplotyped
        let legacy = legacyWorkflowDeclarationsAbsent && workflowKind == nil && workflowMode == nil
            && legacyBundleKind == "ont-barcode-genotype"
            && normalizedCallIdentifier(analysis?.assayID ?? "") == "MHC-exon2-miSeq"
        return typed || legacy
    }

    public static func workflowDeclarationsAreAbsent(in manifest: ONTGenotypeResultBundleManifest) -> Bool {
        let kind = manifest.workflowKindDeclaration
        let mode = manifest.workflowModeDeclaration
        return kind.originalValue == nil && kind.issue == nil && mode.originalValue == nil && mode.issue == nil
    }

    public static func hasUsableAnalysis(_ analysis: GenotypeHaplotypeAnalysis?) -> Bool {
        guard let analysis else { return false }
        var samples = Set<String>(), keys = Set<[String]>()
        var count = 0
        for sample in analysis.samples {
            let name = normalizedCallIdentifier(sample.sample)
            guard !name.isEmpty, samples.insert(name).inserted else { return false }
            for call in sample.calls {
                let locus = normalizedCallIdentifier(call.locus)
                guard !locus.isEmpty, !normalizedCallIdentifier(call.haplotype1).isEmpty,
                      !normalizedCallIdentifier(call.haplotype2).isEmpty,
                      keys.insert([name, locus]).inserted else { return false }
                count += 1
            }
        }
        return count > 0
    }

    public static func usesIdentityBoundOverrides(in manifest: ONTGenotypeResultBundleManifest,
                                                  analysis: GenotypeHaplotypeAnalysis) -> Bool {
        isIdentityBoundMiSeqShape(legacyBundleKind: manifest.kind,
            legacyWorkflowDeclarationsAbsent: workflowDeclarationsAreAbsent(in: manifest),
            workflowKind: manifest.workflowKind, workflowMode: manifest.workflowMode, analysis: analysis)
            && hasUsableAnalysis(analysis)
    }

    /// Existing non-MiSeq native presentation precedence. Do not substitute the
    /// revision-aware MiSeq override index or the manual-only assignment index.
    public static func resolveLegacy(sample: String, call: GenotypeHaplotypeLocusCall,
                                     sidecar: GenotypeAnnotationSidecar) -> LocusValue {
        func slot(_ slot: HaplotypeSlot, baseline: String) -> SlotValue {
            let override = sidecar.callOverrides.first {
                $0.sample == sample && $0.locus == call.locus && $0.slot == slot
            }
            let manual = sidecar.manualHaplotypeAssignments.reversed().first {
                $0.sample == sample && $0.locus == call.locus && $0.slot == slot
            }
            let changed = override != nil || manual != nil
            let effective = override?.overrideCall ?? manual?.label ?? baseline
            return .init(baseline: baseline, effective: effective,
                status: changed ? overrideStatus(effective: effective, baseline: call.status) : call.status,
                source: changed ? .analystOverride : .pipeline, authoritativeOverride: override)
        }
        let h1 = slot(.h1, baseline: call.haplotype1), rawH2 = slot(.h2, baseline: call.haplotype2)
        let changed = h1.source == .analystOverride || rawH2.source == .analystOverride
        let unresolved = h1.effective == "?" || rawH2.effective == "?"
        let status: GenotypeHaplotypeCallStatus = changed && !unresolved
            && !h1.effective.hasPrefix("ERR") && !rawH2.effective.hasPrefix("ERR") ? .called : call.status
        let h2 = SlotValue(baseline: rawH2.baseline,
            effective: normalizedSecondHaplotype(first: h1.effective, second: rawH2.effective, status: rawH2.status),
            status: rawH2.status, source: rawH2.source, authoritativeOverride: rawH2.authoritativeOverride)
        return .init(sample: sample, locus: call.locus, h1: h1, h2: h2, status: status)
    }

    private static func normalizedCallIdentifier(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
