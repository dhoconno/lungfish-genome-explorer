import Foundation
import LungfishCore
import LungfishWorkflow

private func defaultRegion(_ c: BAMRegionExtractionConfig) async throws -> LungfishWorkflow.ExtractionResult { try await ReadExtractionService().extractByBAMRegion(config: c) }
private func defaultSource(_ c: ReadIDExtractionConfig) async throws -> LungfishWorkflow.ExtractionResult { try await ReadExtractionService().extractByReadIDs(config: c) }
private func defaultBAM(_ c: ReadIDBAMExtractionConfig) async throws -> ReadIDBAMExtractionResult { try await ReadExtractionService().extractByReadIDsFromBAM(config: c) }

/// Scientific extraction boundary for immutable alignment evidence. It has no
/// MappingResult dependency, so it cannot accidentally read a different BAM.
@MainActor
final class AlignmentScientificActionCoordinator {
    typealias Validator = (AlignmentActionContext) throws -> Void
    typealias RegionExtractor = (BAMRegionExtractionConfig) async throws -> LungfishWorkflow.ExtractionResult
    typealias SourceExtractor = (ReadIDExtractionConfig) async throws -> LungfishWorkflow.ExtractionResult
    typealias BAMExtractor = (ReadIDBAMExtractionConfig) async throws -> ReadIDBAMExtractionResult

    enum SelectedOutcome: Sendable {
        case sourceFASTQ(LungfishWorkflow.ExtractionResult, recordsWithoutSequence: Int)
        case bam(ReadIDBAMExtractionResult, recordsWithoutSequence: Int)
        var provenanceLabel: String { if case .sourceFASTQ = self { return "source-fastq" }; return "bam-derived" }
    }

    private let validator: Validator
    private let regionExtractor: RegionExtractor
    private let sourceExtractor: SourceExtractor
    private let bamExtractor: BAMExtractor

    init(
        validator: @escaping Validator = { try $0.validateCurrentSnapshots() },
        regionExtractor: @escaping RegionExtractor = defaultRegion,
        sourceExtractor: @escaping SourceExtractor = defaultSource,
        bamExtractor: @escaping BAMExtractor = defaultBAM
    ) {
        self.validator = validator; self.regionExtractor = regionExtractor
        self.sourceExtractor = sourceExtractor; self.bamExtractor = bamExtractor
    }

    func extractRegion(context: AlignmentActionContext, region: ResolvedAlignmentRegion, outputDirectory: URL, outputBaseName: String) async throws -> LungfishWorkflow.ExtractionResult {
        guard region.contig == context.contig, region.start >= 0, region.start < region.end, region.end <= context.contigLength else {
            throw AlignmentScientificActionError.invalidRegion
        }
        let config = BAMRegionExtractionConfig(
            bamURL: context.alignmentURL, indexURL: context.indexURL, decodingReferenceURL: context.decodingReferenceURL,
            regions: ["\(region.contig):\(region.start + 1)-\(region.end)"], fallbackToAll: false,
            minMapQ: context.filters.minimumMapQ, excludedFlags: Int(context.filters.excludedFlags), readGroups: context.filters.readGroups.sorted(),
            outputDirectory: outputDirectory, outputBaseName: outputBaseName, deduplicateReads: false
        )
        try validator(context)
        let result = try await regionExtractor(config)
        try validator(context)
        return result
    }

    func extractSelectedReads(context: AlignmentActionContext, records: [AlignedRead], outputDirectory: URL, outputBaseName: String) async throws -> SelectedOutcome {
        guard !records.isEmpty else { throw AlignmentScientificActionError.emptySelection }
        let names = Set(records.map(\.name))
        let missing = records.filter { $0.sequence.isEmpty || $0.sequence == "*" }.count
        try validator(context)
        switch context.sourceReads {
        case .sourceFASTQs(let urls) where !urls.isEmpty:
            let result = try await sourceExtractor(.init(sourceFASTQs: urls, readIDs: names, keepReadPairs: true, outputDirectory: outputDirectory, outputBaseName: outputBaseName))
            try validator(context)
            return .sourceFASTQ(result, recordsWithoutSequence: missing)
        default:
            let result = try await bamExtractor(.init(bamURL: context.alignmentURL, readIDs: names, includeSecondary: false, excludeDuplicates: false, outputDirectory: outputDirectory, outputBaseName: outputBaseName))
            try validator(context)
            return .bam(result, recordsWithoutSequence: missing)
        }
    }
}

enum AlignmentScientificActionError: LocalizedError, Sendable, Equatable {
    case invalidRegion
    case emptySelection
    case contextUnavailable
    var errorDescription: String? {
        switch self { case .invalidRegion: return "The selected alignment region is invalid."; case .emptySelection: return "Select at least one read."; case .contextUnavailable: return "Alignment evidence is unavailable." }
    }
}
