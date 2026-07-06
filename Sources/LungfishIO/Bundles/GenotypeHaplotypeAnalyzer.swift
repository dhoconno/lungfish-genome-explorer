import Foundation
import LungfishCore

public enum GenotypeHaplotypeAnalyzer {
    public static func analyze(
        calls: [ONTGenotypeCall],
        definitionSet: GenotypeHaplotypeDefinitionSet,
        generatedAt: String? = nil
    ) -> GenotypeHaplotypeAnalysis {
        analyze(
            calls: calls,
            definitionSet: definitionSet,
            generatedAt: generatedAt,
            dropoutFilter: nil
        )
    }

    /// Re-analyze with an optional dropout filter applied to the raw calls
    /// before matching. Genotypes that fall below the per-locus threshold
    /// are dropped from each sample's observed set, then the standard
    /// subset-match algorithm runs. Use this from the inspector to support
    /// "live" threshold changes without touching the persisted pipeline
    /// output: the bundle's `haplotypeAnalysis` stays authoritative, while
    /// this re-analysis drives what the viewport renders.
    public static func analyze(
        calls: [ONTGenotypeCall],
        definitionSet: GenotypeHaplotypeDefinitionSet,
        generatedAt: String? = nil,
        dropoutFilter: GenotypeDropoutEvaluator?
    ) -> GenotypeHaplotypeAnalysis {
        let filteredCalls = applyDropout(calls, evaluator: dropoutFilter, definitionSet: definitionSet)
        let callsBySample = Dictionary(grouping: filteredCalls, by: { normalizedSampleName($0.sample) })
        let observedLoci = observedDefinitionLoci(calls: calls, definitionSet: definitionSet)
        let rawSampleNames = Set(calls.map { normalizedSampleName($0.sample) })
        let samples = rawSampleNames.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }.map { sample in
            let sampleCalls = callsBySample[sample] ?? []
            return GenotypeHaplotypeSampleAnalysis(
                sample: sample,
                calls: deterministicHaplotypingLocusDefinitions(in: definitionSet).map { definition in
                    callHaplotype(
                        locusDefinition: definition,
                        calls: sampleCalls,
                        locusObservedInRun: observedLoci.contains(definition.locus)
                    )
                }
            )
        }
        let classIIResolvedSamples = resolveLinkedMCMClassIIAmbiguousDP(in: samples, definitionSet: definitionSet)
        let eResolvedSamples = resolveLinkedMCMMHCEAmbiguousSupport(in: classIIResolvedSamples, definitionSet: definitionSet)
        let resolvedSamples = enforceMCMHaplotypeSlotContiguity(in: eResolvedSamples, definitionSet: definitionSet)
        return GenotypeHaplotypeAnalysis(
            assayID: definitionSet.assayID,
            definitionSetID: definitionSet.id,
            definitionSetName: definitionSet.displayName,
            speciesName: definitionSet.speciesName,
            generatedAt: generatedAt,
            samples: resolvedSamples
        )
    }

    private static func deterministicHaplotypingLocusDefinitions(
        in definitionSet: GenotypeHaplotypeDefinitionSet
    ) -> [GenotypeHaplotypeLocusDefinition] {
        guard definitionSet.speciesCode.caseInsensitiveCompare("MCM") == .orderedSame else {
            return definitionSet.locusDefinitions
        }
        return definitionSet.locusDefinitions.filter {
            GenotypeHaplotypeLocusResolver.canonicalLocusName($0.locus) != "MHC-E"
        }
    }

    private struct OrderedMCMFamilyPair: Hashable {
        let first: String
        let second: String

        var families: [String] { [first, second] }
        var familySet: Set<String> { Set(families) }
    }

    private static func enforceMCMHaplotypeSlotContiguity(
        in samples: [GenotypeHaplotypeSampleAnalysis],
        definitionSet: GenotypeHaplotypeDefinitionSet
    ) -> [GenotypeHaplotypeSampleAnalysis] {
        guard definitionSet.speciesCode.caseInsensitiveCompare("MCM") == .orderedSame else {
            return samples
        }
        return samples.map { sample in
            var changed = false
            let calls = sample.calls.map { call -> GenotypeHaplotypeLocusCall in
                let reordered = reorderMCMHaplotypeSlotsByFamilyNumber(in: call)
                if reordered != call { changed = true }
                return reordered
            }
            return changed ? GenotypeHaplotypeSampleAnalysis(sample: sample.sample, calls: calls) : sample
        }
    }

    private static func reorderMCMHaplotypeSlotsByFamilyNumber(
        in call: GenotypeHaplotypeLocusCall
    ) -> GenotypeHaplotypeLocusCall {
        guard let callPair = orderedMCMFamilyPair(from: call),
              let firstKey = mcmFamilySortKey(callPair.first),
              let secondKey = mcmFamilySortKey(callPair.second),
              firstKey > secondKey else {
            return call
        }
        let orderedPair = OrderedMCMFamilyPair(first: callPair.second, second: callPair.first)

        let haplotypeByFamily = [
            callPair.first: call.haplotype1,
            callPair.second: call.haplotype2,
        ]
        guard let haplotype1 = haplotypeByFamily[orderedPair.first],
              let haplotype2 = haplotypeByFamily[orderedPair.second] else {
            return call
        }
        let matchedHaplotypes = reorderMatchedMCMHaplotypes(
            call.matchedHaplotypes,
            using: orderedPair
        )
        let note = "MCM haplotype-slot contiguity: reordered \(call.locus) to \(orderedPair.first)/\(orderedPair.second) by ascending haplotype family number."
        let notes = ([call.notes].filter { !$0.isEmpty } + [note]).joined(separator: " ")
        return GenotypeHaplotypeLocusCall(
            locus: call.locus,
            sourceLocus: call.sourceLocus,
            haplotype1: haplotype1,
            haplotype2: haplotype2,
            status: call.status,
            matchedHaplotypes: matchedHaplotypes,
            observedGenotypeCount: call.observedGenotypeCount,
            observedGenotypes: call.observedGenotypes,
            notes: notes
        )
    }

    private static func reorderMatchedMCMHaplotypes(
        _ matchedHaplotypes: [GenotypeHaplotypeMatchedDefinition],
        using pair: OrderedMCMFamilyPair
    ) -> [GenotypeHaplotypeMatchedDefinition] {
        guard matchedHaplotypes.count == 2 else { return matchedHaplotypes }
        var matchByFamily: [String: GenotypeHaplotypeMatchedDefinition] = [:]
        for match in matchedHaplotypes {
            guard let family = singletonMCMFamily(in: match.name),
                  matchByFamily[family] == nil else {
                return matchedHaplotypes
            }
            matchByFamily[family] = match
        }
        guard Set(matchByFamily.keys) == pair.familySet else { return matchedHaplotypes }
        return pair.families.compactMap { matchByFamily[$0] }
    }

    private static func orderedMCMFamilyPair(
        from call: GenotypeHaplotypeLocusCall
    ) -> OrderedMCMFamilyPair? {
        guard call.status == .called || call.status == .specialCase,
              let first = singletonMCMFamily(in: call.haplotype1),
              let second = singletonMCMFamily(in: call.haplotype2),
              first != second else {
            return nil
        }
        return OrderedMCMFamilyPair(first: first, second: second)
    }

    private static func mcmFamilySortKey(_ family: String) -> Int? {
        guard family.first == "M",
              let value = Int(family.dropFirst()) else {
            return nil
        }
        return value
    }

    private static func singletonMCMFamily(in value: String) -> String? {
        guard !value.isEmpty,
              value != "-",
              value != "Not assayed",
              !value.hasPrefix("ERR:") else {
            return nil
        }
        let families = mcmFamilies(inAlleleName: value)
        guard families.count == 1 else { return nil }
        return families.first
    }

    private static func resolveLinkedMCMMHCEAmbiguousSupport(
        in samples: [GenotypeHaplotypeSampleAnalysis],
        definitionSet: GenotypeHaplotypeDefinitionSet
    ) -> [GenotypeHaplotypeSampleAnalysis] {
        guard definitionSet.speciesCode.caseInsensitiveCompare("MCM") == .orderedSame,
              let eDefinition = definitionSet.locusDefinitions.first(where: {
                  GenotypeHaplotypeLocusResolver.canonicalLocusName($0.locus) == "MHC-E"
              }) else {
            return samples
        }
        return samples.map { sample in
            guard let aIndex = sample.calls.firstIndex(where: {
                GenotypeHaplotypeLocusResolver.canonicalLocusName($0.locus) == "MHC-A"
            }),
            let eIndex = sample.calls.firstIndex(where: {
                GenotypeHaplotypeLocusResolver.canonicalLocusName($0.locus) == "MHC-E"
            }) else {
                return sample
            }
            let aCall = sample.calls[aIndex]
            let eCall = sample.calls[eIndex]
            let resolved = resolveMCMMHCECall(eCall, usingLinkedA: aCall, locusDefinition: eDefinition)
            guard resolved != eCall else { return sample }
            var calls = sample.calls
            calls[eIndex] = resolved
            return GenotypeHaplotypeSampleAnalysis(sample: sample.sample, calls: calls)
        }
    }

    private static func resolveMCMMHCECall(
        _ eCall: GenotypeHaplotypeLocusCall,
        usingLinkedA aCall: GenotypeHaplotypeLocusCall,
        locusDefinition: GenotypeHaplotypeLocusDefinition
    ) -> GenotypeHaplotypeLocusCall {
        guard eCall.status == .noHaplotype || eCall.status == .called else { return eCall }
        let aFamilies = Set(linkedMCMFamilies(from: aCall))
        guard !aFamilies.isEmpty else { return eCall }

        let existingNames = Set(eCall.matchedHaplotypes.map(\.name))
        let candidateMatches = supportOnlyMHCECandidateMatches(
            locusDefinition: locusDefinition,
            observedGenotypes: eCall.observedGenotypes,
            linkedFamilies: aFamilies,
            excludingNames: existingNames
        )
        guard candidateMatches.count == 1, let candidate = candidateMatches.first else { return eCall }

        var matched = eCall.status == .called ? eCall.matchedHaplotypes : []
        guard matched.count < 2 else { return eCall }
        matched.append(candidate)
        let haplotype1 = matched[0].name
        let haplotype2 = matched.count > 1 ? matched[1].name : "-"
        let note = "MHC-E support-only evidence resolved to \(candidate.name) from linked MHC-A call."
        let notes = ([eCall.notes].filter { !$0.isEmpty } + [note]).joined(separator: " ")
        return GenotypeHaplotypeLocusCall(
            locus: eCall.locus,
            sourceLocus: eCall.sourceLocus,
            haplotype1: haplotype1,
            haplotype2: haplotype2,
            status: .called,
            matchedHaplotypes: matched,
            observedGenotypeCount: eCall.observedGenotypeCount,
            observedGenotypes: eCall.observedGenotypes,
            notes: notes
        )
    }

    private static func supportOnlyMHCECandidateMatches(
        locusDefinition: GenotypeHaplotypeLocusDefinition,
        observedGenotypes: [String],
        linkedFamilies: Set<String>,
        excludingNames: Set<String>
    ) -> [GenotypeHaplotypeMatchedDefinition] {
        locusDefinition.haplotypes.compactMap { haplotype -> GenotypeHaplotypeMatchedDefinition? in
            guard !excludingNames.contains(haplotype.name),
                  let family = mcmFamily(haplotype.name),
                  linkedFamilies.contains(family) else {
                return nil
            }
            let supportOnlyObserved = haplotype.diagnosticAlleles.filter { allele in
                isSupportOnlyAllele(allele, in: haplotype)
                    && observedGenotypes.contains { genotype in
                        isSupportOnlyGenotype(genotype)
                            && GenotypeHaplotypeDiagnosticMatcher.matches(
                                genotype: genotype,
                                diagnosticAllele: allele
                            )
                    }
            }
            guard !supportOnlyObserved.isEmpty else { return nil }
            return GenotypeHaplotypeMatchedDefinition(
                name: haplotype.name,
                diagnosticAlleles: haplotype.diagnosticAlleles,
                observedDiagnosticAlleles: supportOnlyObserved
            )
        }
    }

    private static func isSupportOnlyAllele(_ allele: String, in haplotype: GenotypeHaplotypeDefinition) -> Bool {
        guard let evidenceWeights = haplotype.evidenceWeights else { return false }
        return (evidenceWeights[allele] ?? 1.0) < 1.0
    }

    private static func isSupportOnlyGenotype(_ genotype: String) -> Bool {
        genotype.localizedCaseInsensitiveContains("evidence_classes=support_only")
    }

    private static func resolveLinkedMCMClassIIAmbiguousDP(
        in samples: [GenotypeHaplotypeSampleAnalysis],
        definitionSet: GenotypeHaplotypeDefinitionSet
    ) -> [GenotypeHaplotypeSampleAnalysis] {
        guard definitionSet.speciesCode.caseInsensitiveCompare("MCM") == .orderedSame else {
            return samples
        }
        return samples.map { sample in
            guard let dqIndex = sample.calls.firstIndex(where: {
                GenotypeHaplotypeLocusResolver.canonicalLocusName($0.locus) == "MHC-DQ"
            }),
            let dpIndex = sample.calls.firstIndex(where: {
                GenotypeHaplotypeLocusResolver.canonicalLocusName($0.locus) == "MHC-DP"
            }) else {
                return sample
            }
            let dqCall = sample.calls[dqIndex]
            let dpCall = sample.calls[dpIndex]
            let resolved = resolveMCMClassIIDPCall(dpCall, usingLinkedDQ: dqCall)
            guard resolved != dpCall else { return sample }
            var calls = sample.calls
            calls[dpIndex] = resolved
            return GenotypeHaplotypeSampleAnalysis(sample: sample.sample, calls: calls)
        }
    }

    private static func resolveMCMClassIIDPCall(
        _ dpCall: GenotypeHaplotypeLocusCall,
        usingLinkedDQ dqCall: GenotypeHaplotypeLocusCall
    ) -> GenotypeHaplotypeLocusCall {
        let dqFamilies = linkedDQFamilies(from: dqCall)
        guard !dqFamilies.isEmpty else { return dpCall }

        if let resolved = resolveConcreteMCMClassIIDPOvercall(dpCall, dqFamilies: dqFamilies) {
            return resolved
        }

        let originalValues = [dpCall.haplotype1, dpCall.haplotype2]
        var usedResolvedFamilies = Set<String>()
        var resolvedValues: [String] = []
        for (index, value) in originalValues.enumerated() {
            let ambiguousFamilies = mcmFamilies(inAlleleName: value)
            guard ambiguousFamilies.count > 1 else {
                resolvedValues.append(value)
                if let family = mcmFamily(value) {
                    usedResolvedFamilies.insert(family)
                }
                continue
            }
            if let family = linkedMCMFamily(
                at: index,
                candidates: ambiguousFamilies,
                dqFamilies: dqFamilies,
                usedFamilies: usedResolvedFamilies
            ) {
                usedResolvedFamilies.insert(family)
                resolvedValues.append("\(family)DP")
            } else {
                resolvedValues.append(value)
            }
        }

        guard resolvedValues != originalValues else { return dpCall }
        let resolutionNotes = zip(originalValues, resolvedValues).compactMap { original, resolved -> String? in
            guard mcmFamilies(inAlleleName: original).count > 1, resolved != original else { return nil }
            return "MHC-DP \(original) ambiguity resolved to \(resolved) from linked MHC-DQ call."
        }
        let notes = ([dpCall.notes].filter { !$0.isEmpty } + resolutionNotes).joined(separator: " ")
        return GenotypeHaplotypeLocusCall(
            locus: dpCall.locus,
            sourceLocus: dpCall.sourceLocus,
            haplotype1: resolvedValues[0],
            haplotype2: resolvedValues[1],
            status: dpCall.status,
            matchedHaplotypes: dpCall.matchedHaplotypes,
            observedGenotypeCount: dpCall.observedGenotypeCount,
            observedGenotypes: dpCall.observedGenotypes,
            notes: notes
        )
    }

    private static func resolveConcreteMCMClassIIDPOvercall(
        _ dpCall: GenotypeHaplotypeLocusCall,
        dqFamilies: [String?]
    ) -> GenotypeHaplotypeLocusCall? {
        guard dpCall.matchedHaplotypes.count > 1 else { return nil }
        var matchByFamily: [String: GenotypeHaplotypeMatchedDefinition] = [:]
        for matched in dpCall.matchedHaplotypes {
            let families = mcmFamilies(inAlleleName: matched.name)
            guard families.count == 1, let family = families.first else { continue }
            matchByFamily[family] = matchByFamily[family] ?? matched
        }
        let matchedFamilies = Set(matchByFamily.keys)
        guard matchedFamilies.count > 1 else { return nil }

        var selectedFamilies: [String] = []
        for family in dqFamilies.compactMap({ $0 }) where matchByFamily[family] != nil {
            if !selectedFamilies.contains(family) {
                selectedFamilies.append(family)
            }
        }
        let selectedFamilySet = Set(selectedFamilies)
        guard !selectedFamilies.isEmpty,
              selectedFamilySet.count < matchedFamilies.count,
              selectedFamilies.count <= 2 else {
            return nil
        }

        let selectedMatches = selectedFamilies.compactMap { matchByFamily[$0] }
        let haplotype1 = selectedMatches[0].name
        let haplotype2 = selectedMatches.count > 1 ? selectedMatches[1].name : "-"
        let original = dpCall.matchedHaplotypes.map(\.name).joined(separator: ", ")
        let resolved = selectedMatches.map(\.name).joined(separator: ", ")
        let resolutionNote = "MHC-DP ambiguity resolved from linked MHC-DQ call: \(original) -> \(resolved)."
        let notes = ([dpCall.notes].filter { !$0.isEmpty } + [resolutionNote]).joined(separator: " ")

        return GenotypeHaplotypeLocusCall(
            locus: dpCall.locus,
            sourceLocus: dpCall.sourceLocus,
            haplotype1: haplotype1,
            haplotype2: haplotype2,
            status: .called,
            matchedHaplotypes: selectedMatches,
            observedGenotypeCount: dpCall.observedGenotypeCount,
            observedGenotypes: dpCall.observedGenotypes,
            notes: notes
        )
    }

    private static func linkedDQFamilies(from dqCall: GenotypeHaplotypeLocusCall) -> [String?] {
        guard dqCall.status == .called || dqCall.status == .specialCase else { return [] }
        return [dqCall.haplotype1, dqCall.haplotype2].map { value in
            guard !value.isEmpty,
                  value != "-",
                  value != "Not assayed",
                  !value.hasPrefix("ERR:") else {
                return nil
            }
            return mcmFamily(value)
        }
    }

    private static func linkedMCMFamilies(from call: GenotypeHaplotypeLocusCall) -> [String] {
        guard call.status == .called || call.status == .specialCase else { return [] }
        return [call.haplotype1, call.haplotype2].compactMap { value in
            guard !value.isEmpty,
                  value != "-",
                  value != "Not assayed",
                  !value.hasPrefix("ERR:") else {
                return nil
            }
            return mcmFamily(value)
        }
    }

    private static func linkedMCMFamily(
        at index: Int,
        candidates: Set<String>,
        dqFamilies: [String?],
        usedFamilies: Set<String>
    ) -> String? {
        if dqFamilies.indices.contains(index),
           let sameSlot = dqFamilies[index],
           candidates.contains(sameSlot) {
            return sameSlot
        }
        let available = dqFamilies.compactMap { family -> String? in
            guard let family, candidates.contains(family), !usedFamilies.contains(family) else {
                return nil
            }
            return family
        }
        return Set(available).count == 1 ? available[0] : nil
    }

    private static func mcmFamily(_ value: String?) -> String? {
        guard let value else { return nil }
        let pattern = #"\bM[1-7]"#
        guard let range = value.range(of: pattern, options: .regularExpression) else {
            return nil
        }
        return String(value[range])
    }

    /// Apply the dropout evaluator: for each (sample, locus group), drop
    /// calls whose per-allele read count is below the effective threshold
    /// (global + per-locus override). Calls are kept by default when the
    /// evaluator is nil. This is the recalculation hook the per-locus EQ
    /// section needs to make haplotype calls "live."
    private static func applyDropout(
        _ calls: [ONTGenotypeCall],
        evaluator: GenotypeDropoutEvaluator?,
        definitionSet: GenotypeHaplotypeDefinitionSet
    ) -> [ONTGenotypeCall] {
        guard let evaluator else { return calls }
        // Build sample × locus-group totals once so the evaluator gets the
        // correct denominator for the ratio tests.
        var sampleTotals: [String: Int] = [:]
        var sampleLocusTotals: [String: [String: Int]] = [:]
        let canonicalDefinitionLocusByRawLocus = canonicalLocusLookup(for: definitionSet)
        for call in calls {
            let sample = normalizedSampleName(call.sample)
            let effectiveLocus = GenotypeHaplotypeLocusResolver.canonicalLocus(
                for: call,
                definitionSet: definitionSet
            )
            sampleTotals[sample, default: 0] += max(0, call.passedUniqueReads)
            sampleLocusTotals[sample, default: [:]][effectiveLocus, default: 0] += max(0, call.passedUniqueReads)
        }
        return calls.filter { call in
            let sample = normalizedSampleName(call.sample)
            let sampleTotal = sampleTotals[sample] ?? 0
            let effectiveLocus = GenotypeHaplotypeLocusResolver.canonicalLocus(
                for: call,
                definitionSet: definitionSet
            )
            let locusTotal = sampleLocusTotals[sample]?[effectiveLocus] ?? 0
            let rawLocus = GenotypeHaplotypeLocusResolver.canonicalLocusName(call.locusGroup)
            let canonicalLocus = canonicalDefinitionLocusByRawLocus[rawLocus]
                ?? effectiveLocus
            return !evaluator.isLowSupport(
                reads: call.passedUniqueReads,
                sampleTotal: sampleTotal,
                locusTotal: locusTotal,
                locus: canonicalLocus
            )
        }
    }

    private static func normalizedSampleName(_ sample: String) -> String {
        let cleaned = sample
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? sample : cleaned
    }

    private static func canonicalLocusLookup(
        for definitionSet: GenotypeHaplotypeDefinitionSet
    ) -> [String: String] {
        var lookup: [String: String] = [:]
        for definition in definitionSet.locusDefinitions {
            let definitionLocus = GenotypeHaplotypeLocusResolver.canonicalLocusName(definition.locus)
            lookup[definitionLocus] = definition.locus
            lookup[GenotypeHaplotypeLocusResolver.canonicalLocusName(definition.sourceLocus)] = definition.locus
            switch definitionLocus {
            case "MHC-DQ":
                lookup["MHC-DQA"] = definition.locus
                lookup["MHC-DQB"] = definition.locus
            case "MHC-DP":
                lookup["MHC-DPA"] = definition.locus
                lookup["MHC-DPB"] = definition.locus
            default:
                break
            }
        }
        return lookup
    }

    private static func callHaplotype(
        locusDefinition: GenotypeHaplotypeLocusDefinition,
        calls: [ONTGenotypeCall],
        locusObservedInRun: Bool
    ) -> GenotypeHaplotypeLocusCall {
        let observedGenotypeSet = Set(calls.map(\.genotype))
        let diagnosticCalls = calls.filter {
            GenotypeHaplotypeLocusResolver.diagnosticCall($0, belongsTo: locusDefinition)
        }
        let observedGenotypes = diagnosticCalls
            .map(\.genotype)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        var scoredMatches = locusDefinition.haplotypes.compactMap { haplotype -> ScoredHaplotypeMatch? in
            let observedDiagnostics = haplotype.diagnosticAlleles.filter { allele in
                diagnosticCalls.contains { call in
                    GenotypeHaplotypeDiagnosticMatcher.matches(
                        genotype: call.genotype,
                        diagnosticAllele: allele
                    )
                }
            }
            let requiredDiagnostics = requiredDiagnosticAlleles(for: haplotype)
            let observedRequiredDiagnostics = requiredDiagnostics.filter { allele in
                diagnosticCalls.contains { call in
                    GenotypeHaplotypeDiagnosticMatcher.matches(
                        genotype: call.genotype,
                        diagnosticAllele: allele
                    )
                }
            }
            // Haplotypes can opt into a "K of N" rule by setting
            // `minimumMatches`. The default behaviour (no override)
            // remains the strict "all alleles must be observed" rule
            // the notebook uses — preserves backwards compatibility for
            // any caller that hasn't specified a threshold.
            guard observedRequiredDiagnostics.count >= effectiveMinimumMatches(for: haplotype)
                    || usesMCMAClassIGAGSpecificRescue(
                        locusDefinition: locusDefinition,
                        haplotype: haplotype,
                        observedDiagnostics: observedDiagnostics
                    ) else { return nil }
            let readSupport = diagnosticCalls.reduce(0) { total, call in
                let supportsHaplotype = haplotype.diagnosticAlleles.contains { allele in
                    GenotypeHaplotypeDiagnosticMatcher.matches(
                        genotype: call.genotype,
                        diagnosticAllele: allele
                    )
                }
                return supportsHaplotype ? total + max(0, call.passedUniqueReads) : total
            }
            let hasCompletePrimaryEvidence = Self.hasCompletePrimaryEvidence(
                haplotype: haplotype,
                diagnosticCalls: diagnosticCalls
            )
            let match = GenotypeHaplotypeMatchedDefinition(
                name: haplotype.name,
                diagnosticAlleles: haplotype.diagnosticAlleles,
                observedDiagnosticAlleles: observedDiagnostics
            )
            return ScoredHaplotypeMatch(
                match: match,
                readSupport: readSupport,
                hasCompletePrimaryEvidence: hasCompletePrimaryEvidence
            )
        }
        var matched = scoredMatches.map(\.match)
        matched = trimMCMClassIARescueOvercalls(
            matched,
            locusDefinition: locusDefinition
        )
        scoredMatches = scoredMatches.filter { scored in
            matched.contains(where: { $0.name == scored.match.name })
        }

        var haplotype1: String
        var haplotype2: String
        var status: GenotypeHaplotypeCallStatus
        var notes = ""

        if matched.isEmpty, !locusObservedInRun, observedGenotypes.isEmpty {
            haplotype1 = "Not assayed"
            haplotype2 = "Not assayed"
            status = .notAssayed
            notes = "\(locusDefinition.locus) was not observed anywhere in this run for the active definition set. Treat this as assay/reference coverage not available, not as a sample-level haplotype failure."
        } else if matched.isEmpty {
            if usesMCMUndercalledA1063SpecialCase(locusDefinition: locusDefinition, observedGenotypes: observedGenotypeSet) {
                haplotype1 = "A1_063"
                haplotype2 = "-"
                status = .specialCase
                notes = "Notebook-compatible MCM MHC-A special case: A1_063 diagnostic sequence observed without a full M1A/M2A/M3A match."
            } else {
                haplotype1 = "ERR: NO HAP"
                haplotype2 = "ERR: NO HAP"
                status = .noHaplotype
            }
        } else if matched.count == 1 {
            haplotype1 = matched[0].name
            if usesMCMUndercalledA1063SpecialCase(locusDefinition: locusDefinition, observedGenotypes: observedGenotypeSet),
               !["M1A", "M2A", "M3A"].contains(where: { matched[0].name.contains($0) }) {
                haplotype2 = "A1_063"
                status = .specialCase
                notes = "Notebook-compatible MCM MHC-A special case: A1_063 observed in addition to one non-M1/M2/M3 haplotype."
            } else {
                haplotype2 = "-"
                status = .called
            }
        } else if matched.count == 2 {
            if let dominant = dominantMHCBSingletonHomozygousResolution(
                locusDefinition: locusDefinition,
                calls: calls,
                matched: matched
            ) {
                matched = dominant.matches
                haplotype1 = matched[0].name
                haplotype2 = "-"
                notes = dominant.note
            } else {
                haplotype1 = matched[0].name
                haplotype2 = matched[1].name
            }
            status = .called
        } else if let dominant = dominantTopTwoMatches(scoredMatches) {
            matched = dominant.matches
            haplotype1 = matched[0].name
            haplotype2 = matched[1].name
            status = .called
            notes = dominant.note
        } else {
            let joined = matched.map(\.name).joined(separator: ", ")
            haplotype1 = "ERR: TMH (\(joined))"
            haplotype2 = "ERR: TMH (\(joined))"
            status = .tooManyHaplotypes
        }

        if status != .notAssayed,
           diploidClassIILocusHasTooManyGenotypes(locusDefinition: locusDefinition, calls: calls) {
            if let dominant = dominantClassIITMGResolution(
                locusDefinition: locusDefinition,
                calls: calls
            ) {
                matched = dominant.matches
                haplotype1 = matched[0].name
                haplotype2 = matched.count > 1 ? matched[1].name : "-"
                status = .called
                notes = notes.isEmpty ? dominant.note : "\(notes) \(dominant.note)"
            } else {
                haplotype1 = "ERR: TMG"
                haplotype2 = "ERR: TMG"
                status = .tooManyGenotypes
            }
        }

        return GenotypeHaplotypeLocusCall(
            locus: locusDefinition.locus,
            sourceLocus: locusDefinition.sourceLocus,
            haplotype1: haplotype1,
            haplotype2: haplotype2,
            status: status,
            matchedHaplotypes: matched,
            observedGenotypeCount: observedGenotypes.count,
            observedGenotypes: observedGenotypes,
            notes: notes
        )
    }

    private struct ScoredHaplotypeMatch {
        let match: GenotypeHaplotypeMatchedDefinition
        let readSupport: Int
        let hasCompletePrimaryEvidence: Bool
    }

    private struct DominantHaplotypeMatches {
        let matches: [GenotypeHaplotypeMatchedDefinition]
        let note: String
    }

    private struct ClassIIHaplotypeScore {
        let match: GenotypeHaplotypeMatchedDefinition
        let readSupport: Int
        let observedAlleleReadSupport: [String: Int]
        let hasCompleteRequiredEvidence: Bool
    }

    private struct ClassIIResidualEvidence {
        let name: String
        let readSupport: Int
    }

    private struct HaplotypeSupportScore {
        let match: GenotypeHaplotypeMatchedDefinition
        let readSupport: Int
        let hasCompleteRequiredEvidence: Bool
    }

    private static func dominantTopTwoMatches(
        _ scoredMatches: [ScoredHaplotypeMatch]
    ) -> DominantHaplotypeMatches? {
        guard scoredMatches.count > 2 else { return nil }
        let rankedComplete = scoredMatches.enumerated()
            .filter { $0.element.hasCompletePrimaryEvidence }
            .sorted { lhs, rhs in
            if lhs.element.readSupport != rhs.element.readSupport {
                return lhs.element.readSupport > rhs.element.readSupport
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
        let selected = Array(rankedComplete.prefix(2))
        let selectedNames = Set(selected.map(\.match.name))
        let remaining = scoredMatches.filter { !selectedNames.contains($0.match.name) }
        guard selected.count == 2,
              selected[1].readSupport > 0,
              remaining.allSatisfy({ selected[1].readSupport > $0.readSupport * 10 }) else {
            return nil
        }
        let selectedText = selected
            .map { "\($0.match.name)=\($0.readSupport)" }
            .joined(separator: ", ")
        let suppressedText = remaining
            .map { "\($0.match.name)=\($0.readSupport)" }
            .joined(separator: ", ")
        let note = "Read-dominance deterministic call: top haplotypes \(selectedText) each exceed other genotype-matching read support by more than 10x"
            + (suppressedText.isEmpty ? "." : " (suppressed: \(suppressedText)).")
        return DominantHaplotypeMatches(matches: selected.map(\.match), note: note)
    }

    private static func dominantMHCBSingletonHomozygousResolution(
        locusDefinition: GenotypeHaplotypeLocusDefinition,
        calls: [ONTGenotypeCall],
        matched: [GenotypeHaplotypeMatchedDefinition]
    ) -> DominantHaplotypeMatches? {
        let definitionLocus = GenotypeHaplotypeLocusResolver.canonicalLocusName(locusDefinition.sourceLocus)
        guard definitionLocus == "MHC-B",
              matched.count == 2 else {
            return nil
        }
        let diagnosticCalls = calls.filter {
            GenotypeHaplotypeLocusResolver.diagnosticCall($0, belongsTo: locusDefinition)
        }
        let scores = haplotypeSupportScores(
            locusDefinition: locusDefinition,
            diagnosticCalls: diagnosticCalls
        )
        let scoresByName = Dictionary(uniqueKeysWithValues: scores.map { ($0.match.name, $0) })
        guard let first = scoresByName[matched[0].name],
              let second = scoresByName[matched[1].name] else {
            return nil
        }
        let dominant = first.readSupport >= second.readSupport ? first : second
        let weak = first.readSupport >= second.readSupport ? second : first
        let residual = scores.filter { $0.match.name != dominant.match.name }
        guard dominant.hasCompleteRequiredEvidence,
              dominant.readSupport >= 10,
              weak.readSupport <= 1,
              dominant.readSupport > weak.readSupport * 10,
              residual.allSatisfy({ $0.readSupport <= 1 }) else {
            return nil
        }
        let residualText = residual
            .map { "\($0.match.name)=\($0.readSupport)" }
            .joined(separator: ", ")
        let note = "MHC-B homozygous read-dominance deterministic call: selected \(dominant.match.name)=\(dominant.readSupport); all other haplotype support is singleton-level"
            + (residualText.isEmpty ? "." : " (singleton residual: \(residualText)).")
        return DominantHaplotypeMatches(matches: [dominant.match], note: note)
    }

    private static func haplotypeSupportScores(
        locusDefinition: GenotypeHaplotypeLocusDefinition,
        diagnosticCalls: [ONTGenotypeCall]
    ) -> [HaplotypeSupportScore] {
        locusDefinition.haplotypes.enumerated().compactMap { offset, haplotype -> (Int, HaplotypeSupportScore)? in
            let observedDiagnostics = haplotype.diagnosticAlleles.filter { allele in
                diagnosticCalls.contains { call in
                    GenotypeHaplotypeDiagnosticMatcher.matches(
                        genotype: call.genotype,
                        diagnosticAllele: allele
                    )
                }
            }
            guard !observedDiagnostics.isEmpty else { return nil }
            let requiredDiagnostics = requiredDiagnosticAlleles(for: haplotype)
            let observedRequiredDiagnostics = requiredDiagnostics.filter { allele in
                diagnosticCalls.contains { call in
                    GenotypeHaplotypeDiagnosticMatcher.matches(
                        genotype: call.genotype,
                        diagnosticAllele: allele
                    )
                }
            }
            let readSupport = diagnosticCalls.reduce(0) { total, call in
                let supportsHaplotype = haplotype.diagnosticAlleles.contains { allele in
                    GenotypeHaplotypeDiagnosticMatcher.matches(
                        genotype: call.genotype,
                        diagnosticAllele: allele
                    )
                }
                return supportsHaplotype ? total + max(0, call.passedUniqueReads) : total
            }
            let match = GenotypeHaplotypeMatchedDefinition(
                name: haplotype.name,
                diagnosticAlleles: haplotype.diagnosticAlleles,
                observedDiagnosticAlleles: observedDiagnostics
            )
            return (offset, HaplotypeSupportScore(
                match: match,
                readSupport: readSupport,
                hasCompleteRequiredEvidence: observedRequiredDiagnostics.count >= effectiveMinimumMatches(for: haplotype)
            ))
        }.sorted { lhs, rhs in
            if lhs.1.readSupport != rhs.1.readSupport {
                return lhs.1.readSupport > rhs.1.readSupport
            }
            return lhs.0 < rhs.0
        }.map(\.1)
    }

    private static func hasCompletePrimaryEvidence(
        haplotype: GenotypeHaplotypeDefinition,
        diagnosticCalls: [ONTGenotypeCall]
    ) -> Bool {
        let primaryAlleles = primaryAllelesForDominance(haplotype)
        guard !primaryAlleles.isEmpty else { return false }
        return primaryAlleles.allSatisfy { primaryAllele in
            diagnosticCalls.contains { call in
                GenotypeHaplotypeDiagnosticMatcher.matches(
                    genotype: call.genotype,
                    diagnosticAllele: primaryAllele
                )
            }
        }
    }

    private static func effectiveMinimumMatches(for haplotype: GenotypeHaplotypeDefinition) -> Int {
        let requiredAlleles = requiredDiagnosticAlleles(for: haplotype)
        guard !requiredAlleles.isEmpty else { return Int.max }
        return min(haplotype.effectiveMinimumMatches, requiredAlleles.count)
    }

    private static func requiredDiagnosticAlleles(for haplotype: GenotypeHaplotypeDefinition) -> [String] {
        guard let evidenceWeights = haplotype.evidenceWeights else {
            return haplotype.diagnosticAlleles
        }
        return haplotype.diagnosticAlleles.filter { allele in
            (evidenceWeights[allele] ?? 1.0) >= 1.0
        }
    }

    private static func primaryAllelesForDominance(_ haplotype: GenotypeHaplotypeDefinition) -> [String] {
        guard let primaryAlleles = haplotype.primaryAlleles, !primaryAlleles.isEmpty else {
            return requiredDiagnosticAlleles(for: haplotype)
        }
        let required = Set(requiredDiagnosticAlleles(for: haplotype))
        return primaryAlleles.filter { required.contains($0) }
    }

    private static func usesMCMAClassIGAGSpecificRescue(
        locusDefinition: GenotypeHaplotypeLocusDefinition,
        haplotype: GenotypeHaplotypeDefinition,
        observedDiagnostics: [String]
    ) -> Bool {
        guard locusDefinition.sourceLocus == "Mafa-A",
              ["M1A", "M2A", "M3A"].contains(haplotype.name),
              !observedDiagnostics.isEmpty else {
            return false
        }
        let expectedFamily = String(haplotype.name.prefix(2))
        return observedDiagnostics.contains { allele in
            mcmFamilies(inAlleleName: allele) == Set([expectedFamily])
        }
    }

    private static func trimMCMClassIARescueOvercalls(
        _ matched: [GenotypeHaplotypeMatchedDefinition],
        locusDefinition: GenotypeHaplotypeLocusDefinition
    ) -> [GenotypeHaplotypeMatchedDefinition] {
        guard locusDefinition.sourceLocus == "Mafa-A",
              matched.count > 2 else {
            return matched
        }
        let definitionsByName = Dictionary(uniqueKeysWithValues: locusDefinition.haplotypes.map { ($0.name, $0) })
        let strict = matched.filter { match in
            guard let definition = definitionsByName[match.name] else { return true }
            let observed = Set(match.observedDiagnosticAlleles)
            return definition.primaryAllelesForDominance.allSatisfy { observed.contains($0) }
        }
        guard strict.count >= 2 else {
            return matched
        }
        return Array(strict.prefix(2))
    }

    private static func mcmFamilies(inAlleleName allele: String) -> Set<String> {
        let pattern = #"M[1-7]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let range = NSRange(allele.startIndex..<allele.endIndex, in: allele)
        return Set(regex.matches(in: allele, range: range).compactMap { match in
            guard let tokenRange = Range(match.range, in: allele) else { return nil }
            return String(allele[tokenRange])
        })
    }

    private static func observedDefinitionLoci(
        calls: [ONTGenotypeCall],
        definitionSet: GenotypeHaplotypeDefinitionSet
    ) -> Set<String> {
        var observed = Set<String>()
        for call in calls {
            let raw = GenotypeHaplotypeLocusResolver.canonicalLocusName(call.locusGroup)
            for definition in definitionSet.locusDefinitions where
                GenotypeHaplotypeLocusResolver.rawCall(call, belongsTo: definition)
                    || raw == definition.locus
                    || raw == GenotypeHaplotypeLocusResolver.canonicalLocusName(definition.sourceLocus)
                    || GenotypeHaplotypeLocusResolver.diagnosticCall(call, belongsTo: definition) {
                observed.insert(definition.locus)
            }
        }
        return observed
    }

    private static func usesMCMUndercalledA1063SpecialCase(
        locusDefinition: GenotypeHaplotypeLocusDefinition,
        observedGenotypes: Set<String>
    ) -> Bool {
        locusDefinition.sourceLocus == "Mafa-A" && observedGenotypes.contains("05_M1M2M3_A1_063g")
    }

    private static func diploidClassIILocusHasTooManyGenotypes(
        locusDefinition: GenotypeHaplotypeLocusDefinition,
        calls: [ONTGenotypeCall]
    ) -> Bool {
        let definitionLocus = GenotypeHaplotypeLocusResolver.canonicalLocusName(locusDefinition.sourceLocus)
        let diploidLoci = Set(["MHC-DPA", "MHC-DPB", "MHC-DQA", "MHC-DQB", "MHC-DP", "MHC-DQ"])
        guard diploidLoci.contains(definitionLocus) else {
            return false
        }
        let rawCounts = Dictionary(grouping: calls.filter {
            GenotypeHaplotypeLocusResolver.rawCall($0, belongsTo: locusDefinition)
        }, by: { preciseClassIISourceLocus(for: $0) })
        return rawCounts.values.contains { $0.count > 2 }
    }

    private static func preciseClassIISourceLocus(for call: ONTGenotypeCall) -> String {
        GenotypeHaplotypeLocusResolver.metadataSourceLocus(for: call.genotype)
            ?? GenotypeHaplotypeLocusResolver.canonicalLocusName(call.locusGroup)
    }

    private static func dominantClassIITMGResolution(
        locusDefinition: GenotypeHaplotypeLocusDefinition,
        calls: [ONTGenotypeCall]
    ) -> DominantHaplotypeMatches? {
        let definitionLocus = GenotypeHaplotypeLocusResolver.canonicalLocusName(locusDefinition.sourceLocus)
        let classIILoci = Set(["MHC-DPA", "MHC-DPB", "MHC-DQA", "MHC-DQB", "MHC-DP", "MHC-DQ"])
        guard classIILoci.contains(definitionLocus) else {
            return nil
        }

        let diagnosticCalls = calls.filter {
            GenotypeHaplotypeLocusResolver.diagnosticCall($0, belongsTo: locusDefinition)
        }
        let scoredPotential = locusDefinition.haplotypes.enumerated().compactMap { offset, haplotype -> (Int, ClassIIHaplotypeScore)? in
            let observedDiagnostics = haplotype.diagnosticAlleles.filter { allele in
                diagnosticCalls.contains { call in
                    GenotypeHaplotypeDiagnosticMatcher.matches(
                        genotype: call.genotype,
                        diagnosticAllele: allele
                    )
                }
            }
            let requiredDiagnostics = requiredDiagnosticAlleles(for: haplotype)
            let observedRequiredDiagnostics = requiredDiagnostics.filter { allele in
                diagnosticCalls.contains { call in
                    GenotypeHaplotypeDiagnosticMatcher.matches(
                        genotype: call.genotype,
                        diagnosticAllele: allele
                    )
                }
            }
            guard !observedRequiredDiagnostics.isEmpty else { return nil }
            let alleleReadSupport = Dictionary(uniqueKeysWithValues: haplotype.diagnosticAlleles.compactMap { allele in
                let support = diagnosticCalls.reduce(0) { total, call in
                    GenotypeHaplotypeDiagnosticMatcher.matches(
                        genotype: call.genotype,
                        diagnosticAllele: allele
                    ) ? total + max(0, call.passedUniqueReads) : total
                }
                return support > 0 ? (allele, support) : nil
            })
            let readSupport = alleleReadSupport.values.reduce(0, +)
            let score = ClassIIHaplotypeScore(
                match: GenotypeHaplotypeMatchedDefinition(
                    name: haplotype.name,
                    diagnosticAlleles: haplotype.diagnosticAlleles,
                    observedDiagnosticAlleles: observedDiagnostics
                ),
                readSupport: readSupport,
                observedAlleleReadSupport: alleleReadSupport,
                hasCompleteRequiredEvidence: observedRequiredDiagnostics.count >= effectiveMinimumMatches(for: haplotype)
            )
            return (offset, score)
        }.sorted { lhs, rhs in
            if lhs.1.readSupport != rhs.1.readSupport {
                return lhs.1.readSupport > rhs.1.readSupport
            }
            return lhs.0 < rhs.0
        }.map(\.1)

        let completeScores = scoredPotential.filter {
            $0.hasCompleteRequiredEvidence && $0.readSupport >= 2
        }
        guard !completeScores.isEmpty else { return nil }

        for selectedCount in [2, 1] {
            guard completeScores.count >= selectedCount else { continue }
            let selected = Array(completeScores.prefix(selectedCount))
            let selectedNames = Set(selected.map(\.match.name))
            if selectedCount == 1,
               completeScores.count > 1,
               selected[0].readSupport <= completeScores[1].readSupport * 10 {
                continue
            }
            let selectedObservedAlleles = Set(selected.flatMap(\.match.observedDiagnosticAlleles))
            let residual = scoredPotential
                .filter { !selectedNames.contains($0.match.name) }
                .compactMap { score -> ClassIIResidualEvidence? in
                    let readSupport = score.observedAlleleReadSupport.reduce(0) { total, item in
                        selectedObservedAlleles.contains(item.key) ? total : total + item.value
                    }
                    return readSupport > 0
                        ? ClassIIResidualEvidence(name: score.match.name, readSupport: readSupport)
                        : nil
                }
                .sorted { lhs, rhs in
                    if lhs.readSupport != rhs.readSupport {
                        return lhs.readSupport > rhs.readSupport
                    }
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
            let minimumSelectedSupport = selected.map(\.readSupport).min() ?? 0
            guard minimumSelectedSupport > 0,
                  residual.allSatisfy({ minimumSelectedSupport > $0.readSupport * 10 }) else {
                continue
            }

            let selectedText = selected
                .map { "\($0.match.name)=\($0.readSupport)" }
                .joined(separator: ", ")
            let residualText = residual
                .map { "\($0.name)=\($0.readSupport)" }
                .joined(separator: ", ")
            let note = "Class II TMG read-dominance deterministic call: selected haplotypes \(selectedText) each exceed residual unshared genotype support by more than 10x"
                + (residualText.isEmpty ? "." : " (residual: \(residualText)).")
            return DominantHaplotypeMatches(
                matches: selected.map(\.match),
                note: note
            )
        }

        return nil
    }
}
