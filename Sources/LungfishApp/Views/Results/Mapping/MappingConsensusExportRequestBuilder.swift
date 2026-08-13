import Foundation
import LungfishIO

/// Presentation metadata paired with the immutable scientific request.  The
/// scientific request is deliberately built from the evidence context and an
/// already-resolved region; it has no viewport, annotation, or table fallback.
struct MappingConsensusExportRequest: Equatable {
    let consensusRequest: AlignmentConsensusRequest
    let region: ResolvedAlignmentRegion
    let recordName: String
    let suggestedName: String

    var chromosome: String { consensusRequest.chromosome }
    var start: Int { consensusRequest.start }
    var end: Int { consensusRequest.end }
    var mode: AlignmentConsensusMode { consensusRequest.mode }
    var minDepth: Int { consensusRequest.filters.minimumDepth }
    var minMapQ: Int { consensusRequest.filters.minimumMapQ }
    var minBaseQ: Int { consensusRequest.filters.minimumBaseQuality }
    var excludeFlags: UInt16 { consensusRequest.filters.excludedFlags }
    var useAmbiguity: Bool { consensusRequest.useAmbiguity }
    var showDeletions: Bool { consensusRequest.deletionPolicy == .n }
    var showInsertions: Bool { consensusRequest.insertionPolicy == .include }
}

enum MappingConsensusExportRequestBuilder {
    static func build(
        sampleName: String,
        context: AlignmentActionContext,
        region: ResolvedAlignmentRegion,
        consensusMode: AlignmentConsensusMode,
        useAmbiguity: Bool
    ) throws -> MappingConsensusExportRequest {
        guard region.contig == context.contig,
              region.start >= 0,
              region.end > region.start,
              region.end <= context.contigLength else {
            throw AlignmentConsensusScopeError.emptySelection(
                contig: region.contig,
                start: region.start,
                end: region.end
            )
        }

        let request = AlignmentConsensusRequestFactory.build(
            context: context,
            region: region,
            consensusMode: consensusMode,
            useAmbiguity: useAmbiguity
        )
        let displayStart = region.start + 1
        let isWholeContig = region.scope == .wholeContig
        let selectedScopeLabel = region.scope == .selectedRegion ? "selected" : region.scope.rawValue
        let scopeLabel = isWholeContig ? "" : " \(selectedScopeLabel)"
        let nameSuffix = isWholeContig ? "" : "-\(region.scope.rawValue)"
        let coordinateLabel = isWholeContig ? "" : ":\(displayStart)-\(region.end)"
        return .init(
            consensusRequest: request,
            region: region,
            recordName: "\(sampleName) \(region.contig)\(coordinateLabel)\(scopeLabel) consensus",
            suggestedName: "\(sampleName)-\(region.contig)\(isWholeContig ? "" : "-\(displayStart)-\(region.end)")\(nameSuffix)-consensus"
        )
    }
}

/// The sole builder for scientific BAM/CRAM consensus requests. Consensus is
/// always a one-base-per-reference-coordinate projection: insertions are
/// omitted and deletions are represented as N. Display-only indel preferences
/// must never alter this evidence-only request.
enum AlignmentConsensusRequestFactory {
    static func build(
        context: AlignmentActionContext,
        region: ResolvedAlignmentRegion,
        consensusMode: AlignmentConsensusMode,
        useAmbiguity: Bool
    ) -> AlignmentConsensusRequest {
        AlignmentConsensusRequest(
            chromosome: region.contig,
            start: region.start,
            end: region.end,
            filters: context.filters,
            mode: consensusMode,
            useAmbiguity: useAmbiguity,
            insertionPolicy: .omit,
            deletionPolicy: .n
        )
    }
}
