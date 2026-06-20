import Foundation
import LungfishCore

struct AIHaplotypingPromptInputPayload: Sendable {
    let json: String
    let evidenceReferenceMap: [String: String]
    let evidenceEncoding: String
}

enum AIHaplotypingPromptInputEncoder {
    static let compactMCMEncoding = "mcm-mhc-miseq-observed-genotypes-v2"
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
            let sampleByID = Dictionary(uniqueKeysWithValues: fullRegistry.samples.map { ($0.id, $0.sample) })

            var referenceMap: [String: String] = [:]
            for sample in fullRegistry.samples { referenceMap[sample.id] = sample.id }

            var genotypeAliases: [String: [String]] = [:]
            let observations = fullRegistry.observations.enumerated().map { index, observation in
                let alias = "o\(index + 1)"
                referenceMap[alias] = observation.id
                let genotype = CompactGenotypeSummary.displayGenotype(genotype: observation.genotype)
                genotypeAliases[genotype, default: []].append(observation.id)
                return CompactObservation(
                    id: alias,
                    sample: sampleByID[observation.sampleID] ?? observation.sampleID,
                    genotype: genotype,
                    reads: observation.passedUniqueReads
                )
            }

            for (genotype, ids) in genotypeAliases where ids.count == 1 {
                referenceMap[genotype] = ids[0]
            }

            self.evidenceReferenceMap = referenceMap
            self.registry = CompactEvidenceRegistry(
                schemaVersion: fullRegistry.schemaVersion,
                encoding: compactMCMEncoding,
                evidenceIDs: (samples.map(\.id) + observations.map(\.id)).sorted(),
                samples: samples,
                observations: observations
            )
        }
    }

    private struct CompactEvidenceRegistry: Encodable {
        let schemaVersion: Int
        let encoding: String
        let evidenceIDs: [String]
        let samples: [CompactSample]
        let observations: [CompactObservation]
    }

    private struct CompactSample: Encodable {
        let id: String
        let sample: String
    }

    private struct CompactObservation: Encodable {
        let id: String
        let sample: String
        let genotype: String
        let reads: Int
    }

    private struct CompactGenotypeSummary {
        static func displayGenotype(genotype: String) -> String {
            let parts = genotype.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            let base = parts.first ?? genotype
            if base.contains("[") {
                return base
            }
            guard let source = metadataValue(in: Array(parts.dropFirst()), key: "source_loci"),
                  !source.isEmpty else {
                return base
            }
            return "\(base)[\(source)]"
        }

        private static func metadataValue(
            in parts: [String],
            key: String
        ) -> String? {
            for part in parts {
                guard let equals = part.firstIndex(of: "=") else { continue }
                let candidateKey = part[..<equals].trimmingCharacters(in: .whitespacesAndNewlines)
                guard candidateKey == key else { continue }
                return part[part.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return nil
        }
    }
}
