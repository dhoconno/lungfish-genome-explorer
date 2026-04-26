import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

enum MappingConsensusExportRequestBuilderError: Error {
    case noTargetChromosome
}

struct MappingConsensusExportRequest: Equatable {
    let chromosome: String
    let start: Int
    let end: Int
    let recordName: String
    let suggestedName: String
    let mode: AlignmentConsensusMode
    let minDepth: Int
    let minMapQ: Int
    let minBaseQ: Int
    let excludeFlags: UInt16
    let useAmbiguity: Bool
    let showDeletions: Bool
    let showInsertions: Bool
}

enum MappingConsensusExportRequestBuilder {
    struct ExplicitRegion: Equatable {
        let chromosome: String
        let start: Int
        let end: Int
        let label: String
    }

    static func build(
        sampleName: String,
        selectedContig: MappingContigSummary?,
        fallbackChromosome: ChromosomeInfo?,
        explicitRegion: ExplicitRegion? = nil,
        consensusMode: AlignmentConsensusMode,
        consensusMinDepth: Int,
        consensusMinMapQ: Int,
        consensusMinBaseQ: Int,
        excludeFlags: UInt16,
        useAmbiguity: Bool
    ) throws -> MappingConsensusExportRequest {
        if let explicitRegion {
            let start = max(0, explicitRegion.start)
            let end = max(start + 1, explicitRegion.end)
            let displayStart = start + 1
            let safeLabel = sanitizedNameComponent(explicitRegion.label)
            let labelSuffix = safeLabel.isEmpty ? "" : "-\(safeLabel)"
            let recordLabel = explicitRegion.label.trimmingCharacters(in: .whitespacesAndNewlines)
            let recordSuffix = recordLabel.isEmpty ? "" : " \(recordLabel)"
            return MappingConsensusExportRequest(
                chromosome: explicitRegion.chromosome,
                start: start,
                end: end,
                recordName: "\(sampleName) \(explicitRegion.chromosome):\(displayStart)-\(end)\(recordSuffix) consensus",
                suggestedName: "\(sampleName)-\(explicitRegion.chromosome)-\(displayStart)-\(end)\(labelSuffix)-consensus",
                mode: consensusMode,
                minDepth: consensusMinDepth,
                minMapQ: consensusMinMapQ,
                minBaseQ: consensusMinBaseQ,
                excludeFlags: excludeFlags,
                useAmbiguity: useAmbiguity,
                showDeletions: false,
                showInsertions: true
            )
        }

        if let contig = selectedContig {
            return MappingConsensusExportRequest(
                chromosome: contig.contigName,
                start: 0,
                end: contig.contigLength,
                recordName: "\(sampleName) \(contig.contigName) consensus",
                suggestedName: "\(sampleName)-\(contig.contigName)-consensus",
                mode: consensusMode,
                minDepth: consensusMinDepth,
                minMapQ: consensusMinMapQ,
                minBaseQ: consensusMinBaseQ,
                excludeFlags: excludeFlags,
                useAmbiguity: useAmbiguity,
                showDeletions: false,
                showInsertions: true
            )
        }

        guard let chromosome = fallbackChromosome else {
            throw MappingConsensusExportRequestBuilderError.noTargetChromosome
        }

        return MappingConsensusExportRequest(
            chromosome: chromosome.name,
            start: 0,
            end: Int(chromosome.length),
            recordName: "\(sampleName) \(chromosome.name) consensus",
            suggestedName: "\(sampleName)-\(chromosome.name)-consensus",
            mode: consensusMode,
            minDepth: consensusMinDepth,
            minMapQ: consensusMinMapQ,
            minBaseQ: consensusMinBaseQ,
            excludeFlags: excludeFlags,
            useAmbiguity: useAmbiguity,
            showDeletions: false,
            showInsertions: true
        )
    }

    private static func sanitizedNameComponent(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .split { !$0.isLetter && !$0.isNumber && $0 != "_" && $0 != "-" }
            .joined(separator: "-")
    }
}
