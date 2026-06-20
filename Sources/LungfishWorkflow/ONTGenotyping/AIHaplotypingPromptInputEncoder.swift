import Foundation
import LungfishCore

struct AIHaplotypingPromptInputPayload: Sendable {
    let json: String
    let evidenceReferenceMap: [String: String]
    let evidenceEncoding: String
}

enum AIHaplotypingPromptInputEncoder {
    static let compactMCMEncoding = "mcm-mhc-miseq-compact-v1"
    static let fullEncoding = "full-v1"

    static func payload(
        chunk: AIHaplotypingEvidenceChunk,
        expectedRun: AIHaplotypingRunMetadata,
        runContext: AIHaplotypingRunContext,
        knowledgePack: AIHaplotypingKnowledgePack?,
        compactMCMEvidence: Bool
    ) throws -> AIHaplotypingPromptInputPayload {
        if compactMCMEvidence {
            let compactRegistry = CompactMCMRegistry(fullRegistry: chunk.registry)
            return try canonicalPayload(
                CompactPromptInput(
                    chunkID: chunk.id,
                    expectedRun: expectedRun,
                    runContext: runContext,
                    knowledgePack: knowledgePack,
                    evidenceRegistry: compactRegistry.registry
                ),
                evidenceReferenceMap: compactRegistry.evidenceReferenceMap,
                evidenceEncoding: compactMCMEncoding
            )
        }

        return try canonicalPayload(
            FullPromptInput(
                chunkID: chunk.id,
                expectedRun: expectedRun,
                runContext: runContext,
                knowledgePack: knowledgePack,
                evidenceRegistry: chunk.registry
            ),
            evidenceReferenceMap: [:],
            evidenceEncoding: fullEncoding
        )
    }

    private static func canonicalPayload<T: Encodable>(
        _ input: T,
        evidenceReferenceMap: [String: String],
        evidenceEncoding: String
    ) throws -> AIHaplotypingPromptInputPayload {
        let data = AIHaplotypingCanonicalJSON.canonicalData(of: input)
        guard let json = String(data: data, encoding: .utf8) else {
            throw AIProviderError.decodingError("AI haplotyping prompt input was not UTF-8.")
        }
        return AIHaplotypingPromptInputPayload(
            json: json,
            evidenceReferenceMap: evidenceReferenceMap,
            evidenceEncoding: evidenceEncoding
        )
    }

    private struct FullPromptInput: Encodable {
        let chunkID: String
        let expectedRun: AIHaplotypingRunMetadata
        let runContext: AIHaplotypingRunContext
        let knowledgePack: AIHaplotypingKnowledgePack?
        let evidenceRegistry: AIHaplotypingEvidenceRegistry
    }

    private struct CompactPromptInput: Encodable {
        let chunkID: String
        let expectedRun: AIHaplotypingRunMetadata
        let runContext: AIHaplotypingRunContext
        let knowledgePack: AIHaplotypingKnowledgePack?
        let evidenceRegistry: CompactEvidenceRegistry
    }

    private struct CompactMCMRegistry {
        let registry: CompactEvidenceRegistry
        let evidenceReferenceMap: [String: String]

        init(fullRegistry: AIHaplotypingEvidenceRegistry) {
            let samples = fullRegistry.samples.map { CompactSample(id: $0.id, sample: $0.sample) }
            let loci = fullRegistry.loci.map { CompactLocus(id: $0.id, locus: $0.locus) }
            let sampleByID = Dictionary(uniqueKeysWithValues: fullRegistry.samples.map { ($0.id, $0.sample) })
            let locusByID = Dictionary(uniqueKeysWithValues: fullRegistry.loci.map { ($0.id, $0.locus) })

            var referenceMap: [String: String] = [:]
            for sample in fullRegistry.samples { referenceMap[sample.id] = sample.id }
            for locus in fullRegistry.loci { referenceMap[locus.id] = locus.id }

            var targetAliases: [String: [String]] = [:]
            var genotypeAliases: [String: [String]] = [:]
            let observations = fullRegistry.observations.enumerated().map { index, observation in
                let alias = "o\(index + 1)"
                referenceMap[alias] = observation.id
                let genotypeSummary = CompactGenotypeSummary(genotype: observation.genotype)
                if let target = genotypeSummary.target {
                    targetAliases[target, default: []].append(observation.id)
                }
                genotypeAliases[genotypeSummary.displayGenotype, default: []].append(observation.id)
                return CompactObservation(
                    id: alias,
                    sample: sampleByID[observation.sampleID] ?? observation.sampleID,
                    locus: locusByID[observation.locusID] ?? observation.locusID,
                    target: genotypeSummary.target,
                    genotype: genotypeSummary.displayGenotype,
                    source: genotypeSummary.source,
                    haps: genotypeSummary.haplotypes,
                    reads: observation.passedUniqueReads
                )
            }

            for (target, ids) in targetAliases where ids.count == 1 {
                referenceMap[target] = ids[0]
            }
            for (genotype, ids) in genotypeAliases where ids.count == 1 {
                referenceMap[genotype] = ids[0]
            }

            let currentCalls = fullRegistry.currentCalls.enumerated().map { index, call in
                let alias = "c\(index + 1)"
                referenceMap[alias] = call.id
                return CompactCurrentCall(
                    id: alias,
                    sample: call.sample,
                    locus: call.locus,
                    slot: call.slot,
                    haplotypeLabel: call.haplotypeLabel
                )
            }
            let manualReviews = fullRegistry.manualReviews.enumerated().map { index, review in
                let alias = "m\(index + 1)"
                referenceMap[alias] = review.id
                return CompactManualReview(
                    id: alias,
                    sample: review.sample,
                    locus: review.locus,
                    slot: review.slot,
                    overrideCall: review.overrideCall,
                    rationale: review.rationale
                )
            }

            self.evidenceReferenceMap = referenceMap
            self.registry = CompactEvidenceRegistry(
                schemaVersion: fullRegistry.schemaVersion,
                encoding: compactMCMEncoding,
                evidenceIDs: (samples.map(\.id) + loci.map(\.id) + observations.map(\.id) + currentCalls.map(\.id) + manualReviews.map(\.id)).sorted(),
                samples: samples,
                loci: loci,
                observations: observations,
                currentCalls: currentCalls,
                manualReviews: manualReviews
            )
        }
    }

    private struct CompactEvidenceRegistry: Encodable {
        let schemaVersion: Int
        let encoding: String
        let evidenceIDs: [String]
        let samples: [CompactSample]
        let loci: [CompactLocus]
        let observations: [CompactObservation]
        let currentCalls: [CompactCurrentCall]
        let manualReviews: [CompactManualReview]
    }

    private struct CompactSample: Encodable {
        let id: String
        let sample: String
    }

    private struct CompactLocus: Encodable {
        let id: String
        let locus: String
    }

    private struct CompactObservation: Encodable {
        let id: String
        let sample: String
        let locus: String
        let target: String?
        let genotype: String
        let source: String?
        let haps: [String]
        let reads: Int
    }

    private struct CompactCurrentCall: Encodable {
        let id: String
        let sample: String
        let locus: String
        let slot: String
        let haplotypeLabel: String
    }

    private struct CompactManualReview: Encodable {
        let id: String
        let sample: String
        let locus: String
        let slot: String
        let overrideCall: String
        let rationale: String
    }

    private struct CompactGenotypeSummary {
        let target: String?
        let displayGenotype: String
        let source: String?
        let haplotypes: [String]

        init(genotype: String) {
            let parts = genotype.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            let base = parts.first ?? genotype
            let metadata = Dictionary(
                uniqueKeysWithValues: parts.dropFirst().compactMap { part -> (String, String)? in
                    guard let equals = part.firstIndex(of: "=") else { return nil }
                    let key = String(part[..<equals]).trimmingCharacters(in: .whitespacesAndNewlines)
                    let value = String(part[part.index(after: equals)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !key.isEmpty else { return nil }
                    return (key, value)
                }
            )
            let target = Self.targetIdentifier(in: base)
            let source = metadata["source_loci"] ?? Self.bracketedSource(in: base)
            let haplotypes = (metadata["haplotypes"] ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            self.target = target
            self.source = source
            self.haplotypes = haplotypes
            if let target, let source, !source.isEmpty {
                self.displayGenotype = "\(target)[\(source)]"
            } else if let target {
                self.displayGenotype = target
            } else {
                self.displayGenotype = base
            }
        }

        private static func targetIdentifier(in text: String) -> String? {
            guard let range = text.range(of: #"MCM_MHC_MiSeq_(\d{4})"#, options: .regularExpression) else {
                return nil
            }
            let match = String(text[range])
            return String(match.suffix(4))
        }

        private static func bracketedSource(in text: String) -> String? {
            guard let open = text.firstIndex(of: "["),
                  let close = text[open...].firstIndex(of: "]"),
                  open < close else {
                return nil
            }
            let start = text.index(after: open)
            return String(text[start..<close])
        }
    }
}
