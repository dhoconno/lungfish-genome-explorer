import Foundation
import LungfishCore
import LungfishWorkflow
import LungfishKit
import LungfishIO

private func defaultRegionStage(_ config: BAMRegionExtractionConfig) async throws -> AlignmentReadExtractionTransaction {
    try await AlignmentReadExtractionStager().stageRegion(config: config)
}
private func defaultSourceStage(_ config: ReadIDExtractionConfig, _ missing: Int, _ message: String?) async throws -> AlignmentReadExtractionTransaction {
    try await AlignmentReadExtractionStager().stageReadIDsFromSourceFASTQs(config: config, recordsWithoutSequence: missing, missingSequenceMessage: message)
}
private func defaultBAMStage(_ config: ReadIDBAMExtractionConfig, _ missing: Int, _ message: String?) async throws -> AlignmentReadExtractionTransaction {
    try await AlignmentReadExtractionStager().stageReadIDsFromBAM(config: config, recordsWithoutSequence: missing, missingSequenceMessage: message)
}
private func defaultPublish(_ request: AlignmentReadExtractionPublicationRequest) async throws -> AlignmentReadExtractionPublicationResult {
    try AlignmentReadExtractionPublisher().publish(request)
}
private func defaultConsensusFetch(
    _ context: AlignmentActionContext,
    _ request: AlignmentConsensusRequest
) async throws -> AlignmentConsensusResult {
    let format: AlignmentFormat = context.alignmentURL.pathExtension.lowercased() == "cram" ? .cram : .bam
    return try await AlignmentDataProvider(
        alignmentPath: context.alignmentURL.path,
        indexPath: context.indexURL.path,
        format: format,
        referenceFastaPath: context.decodingReferenceURL?.path
    ).fetchConsensus(request)
}
private func defaultConsensusPublish(
    _ request: AlignmentConsensusPublicationRequest
) throws -> AlignmentConsensusPublicationResult {
    try AlignmentConsensusPublicationService().publish(request)
}
private func defaultDestination(
    capability: AlignmentOutputCapability,
    outputBaseName: String
) throws -> AlignmentReadExtractionPublicationDestination {
    switch capability {
    case .projectDerivedRoot(let root):
        let name = ExtractionBundleNaming.sanitizeFilename(outputBaseName)
        let finalURL = root.appendingPathComponent("alignment-read-extractions", isDirectory: true)
            .appendingPathComponent("\(name)-\(UUID().uuidString).lungfishfastq", isDirectory: true)
        return .bundle(finalURL)
    case .userSelectedDestination:
        throw AlignmentScientificActionError.destinationUnavailable("Choose an output destination before extracting reads.")
    }
}

@MainActor
struct AlignmentScientificActionReporter {
    enum Terminal: Equatable { case success(AlignmentReadExtractionPublicationResult), failure(String), cancelled(String) }
    let start: (_ title: String, _ detail: String) -> UUID
    let installCancellation: (_ id: UUID, _ cancellation: @escaping @Sendable () -> Void) -> Void
    let log: (_ id: UUID, _ message: String) -> Void
    let finish: (_ id: UUID, _ terminal: Terminal) -> Void

    static let operationCenter = operationCenter(routeContext: nil)

    static func operationCenter(routeContext: OperationRouteContext?, center: OperationCenter = .shared) -> Self {
        Self(
        start: { title, detail in
            center.start(title: title, detail: detail, operationType: .taxonomyExtraction, routeContext: routeContext)
        },
        installCancellation: { id, cancellation in
            center.setCancelCallback(for: id, callback: cancellation)
        },
        log: { id, message in
            center.log(id: id, level: .info, message: message)
        },
        finish: { id, terminal in
            switch terminal {
            case .success(let result):
                if result.finalURL.pathExtension.lowercased() == FASTQBundle.directoryExtension {
                    _ = center.complete(id: id, detail: "Alignment read extraction published", bundleURLs: [result.finalURL])
                } else {
                    let finalURLs = Array(Set(result.outputURLs + [result.finalURL, result.provenanceURL])).sorted { $0.path < $1.path }
                    _ = center.complete(id: id, detail: "Alignment read extraction published", outputURLs: finalURLs)
                }
            case .failure(let message):
                _ = center.fail(id: id, detail: "Alignment read extraction failed", errorMessage: message)
            case .cancelled:
                center.acknowledgeCancellation(id: id)
            }
        }
    )
    }
}

/// Scientific extraction boundary for immutable alignment evidence. Workflow
/// owns all temporary payloads; this coordinator returns final publications only.
@MainActor
final class AlignmentScientificActionCoordinator {
    typealias Validator = (AlignmentActionContext) throws -> Void
    typealias RegionStager = (BAMRegionExtractionConfig) async throws -> AlignmentReadExtractionTransaction
    typealias SourceStager = (ReadIDExtractionConfig, Int, String?) async throws -> AlignmentReadExtractionTransaction
    typealias BAMStager = (ReadIDBAMExtractionConfig, Int, String?) async throws -> AlignmentReadExtractionTransaction
    typealias Publisher = (AlignmentReadExtractionPublicationRequest) async throws -> AlignmentReadExtractionPublicationResult
    typealias DestinationResolver = (AlignmentOutputCapability, String) throws -> AlignmentReadExtractionPublicationDestination
    typealias ConsensusFetcher = (AlignmentActionContext, AlignmentConsensusRequest) async throws -> AlignmentConsensusResult
    typealias ConsensusPublisher = (AlignmentConsensusPublicationRequest) throws -> AlignmentConsensusPublicationResult

    private let validator: Validator
    private let regionStager: RegionStager
    private let sourceStager: SourceStager
    private let bamStager: BAMStager
    private let publisher: Publisher
    private let destinationResolver: DestinationResolver
    private let consensusFetcher: ConsensusFetcher
    private let consensusPublisher: ConsensusPublisher

    init(
        validator: @escaping Validator = { try $0.validateCurrentSnapshots() },
        regionStager: @escaping RegionStager = defaultRegionStage,
        sourceStager: @escaping SourceStager = defaultSourceStage,
        bamStager: @escaping BAMStager = defaultBAMStage,
        publisher: @escaping Publisher = defaultPublish,
        destinationResolver: @escaping DestinationResolver = defaultDestination,
        consensusFetcher: @escaping ConsensusFetcher = defaultConsensusFetch,
        consensusPublisher: @escaping ConsensusPublisher = defaultConsensusPublish
    ) {
        self.validator = validator
        self.regionStager = regionStager
        self.sourceStager = sourceStager
        self.bamStager = bamStager
        self.publisher = publisher
        self.destinationResolver = destinationResolver
        self.consensusFetcher = consensusFetcher
        self.consensusPublisher = consensusPublisher
    }

    struct ConsensusGeneration: Sendable {
        let context: AlignmentActionContext
        let exportRequest: MappingConsensusExportRequest
        let result: AlignmentConsensusResult

        var fastaRecord: String { ">\(exportRequest.recordName)\n\(result.sequence)\n" }
        var requiresAllLowDepthWarning: Bool { result.allLowDepth }
        var allLowDepthWarningMessage: String {
            "Every position in the requested region is below the minimum depth of \(exportRequest.consensusRequest.filters.minimumDepth). The consensus will contain only N characters. You can continue without filling from the reference."
        }
        var summary: String {
            let request = exportRequest.consensusRequest
            let filters = request.filters
            let groups = filters.readGroups.isEmpty ? "all" : filters.readGroups.sorted().joined(separator: ",")
            return [
                "Scope: \(exportRequest.region.scope.rawValue)",
                "Region: \(exportRequest.region.contig):\(exportRequest.region.start + 1)-\(exportRequest.region.end)",
                "Caller: \(request.mode.rawValue)",
                "Minimum depth/MAPQ/base quality: \(filters.minimumDepth)/\(filters.minimumMapQ)/\(filters.minimumBaseQuality)",
                "Excluded flags: \(filters.excludedFlags)",
                "Read groups: \(groups)",
                "Low-depth policy: N",
                "Reference-fill policy: never",
            ].joined(separator: "\n")
        }
    }

    func generateConsensus(
        context: AlignmentActionContext,
        exportRequest: MappingConsensusExportRequest
    ) async throws -> ConsensusGeneration {
        guard exportRequest.region.contig == context.contig,
              exportRequest.consensusRequest.chromosome == context.contig,
              exportRequest.consensusRequest.filters == context.filters else {
            throw AlignmentScientificActionError.invalidRegion
        }
        try validator(context)
        try Task.checkCancellation()
        let result = try await consensusFetcher(context, exportRequest.consensusRequest)
        try Task.checkCancellation()
        return .init(context: context, exportRequest: exportRequest, result: result)
    }

    func publishConsensus(
        _ generation: ConsensusGeneration,
        destination: AlignmentConsensusPublicationDestination
    ) async throws -> AlignmentConsensusPublicationResult {
        try Task.checkCancellation()
        try validator(generation.context)
        try Task.checkCancellation()
        return try consensusPublisher(.init(
            context: generation.context,
            region: generation.exportRequest.region,
            consensusRequest: generation.exportRequest.consensusRequest,
            result: generation.result,
            recordName: generation.exportRequest.recordName,
            destination: destination
        ))
    }

    /// Resolves a final destination before either scientific validation gate.
    /// User-selected destinations are delegated to the AppKit composition root.
    func resolveDestination(
        for capability: AlignmentOutputCapability,
        outputBaseName: String
    ) throws -> AlignmentReadExtractionPublicationDestination {
        try destinationResolver(capability, outputBaseName)
    }

    /// Resolves destinations that require user interaction before any
    /// Operation Center row or scientific subprocess is started.
    func resolveDestination(
        for capability: AlignmentOutputCapability,
        outputBaseName: String,
        userDestinationChooser: (String) async -> URL?
    ) async throws -> AlignmentReadExtractionPublicationDestination {
        switch capability {
        case .projectDerivedRoot:
            return try destinationResolver(capability, outputBaseName)
        case .userSelectedDestination:
            guard let chosenURL = await userDestinationChooser(outputBaseName) else {
                throw AlignmentScientificActionError.destinationCancelled(
                    "Alignment read extraction was cancelled before launch."
                )
            }
            return .bundle(normalizedBundleURL(chosenURL))
        }
    }

    /// Registers one visible operation before validation/staging. The adapter is
    /// deliberately injected so AppKit/OperationCenter composition stays out of
    /// the scientific transaction boundary and every terminal transition is
    /// owned by this single launch wrapper.
    @discardableResult
    func launchRegion(
        context: AlignmentActionContext,
        region: ResolvedAlignmentRegion,
        destination: AlignmentReadExtractionPublicationDestination,
        outputBaseName: String,
        reporter: AlignmentScientificActionReporter
    ) -> Task<Void, Never> {
        let operationID = reporter.start("Extract Reads in Selected Region", "Preparing alignment read extraction…")
        reporter.log(operationID, "alignment evidence: \(evidenceIdentityLabel(context.identity))")
        let task = Task {
            do {
                let result = try await self.extractRegion(context: context, region: region, destination: destination, outputBaseName: outputBaseName)
                for record in result.executionRecords { reporter.log(operationID, "argv: \(record.argv.joined(separator: " "))\n\(record.stderr ?? "")") }
                reporter.finish(operationID, .success(result))
            } catch is CancellationError {
                reporter.finish(operationID, .cancelled("Alignment read extraction cancelled."))
            } catch let failure as AlignmentReadExtractionFailure where failure.kind == .cancelled {
                for record in failure.executionRecords { reporter.log(operationID, "argv: \(record.argv.joined(separator: " "))\n\(record.stderr ?? "")") }
                reporter.finish(operationID, .cancelled(failure.message))
            } catch {
                if let failure = error as? AlignmentReadExtractionFailure {
                    for record in failure.executionRecords { reporter.log(operationID, "argv: \(record.argv.joined(separator: " "))\n\(record.stderr ?? "")") }
                }
                reporter.finish(operationID, .failure(error.localizedDescription))
            }
        }
        reporter.installCancellation(operationID) { task.cancel() }
        return task
    }

    @discardableResult
    func launchSelectedReads(
        context: AlignmentActionContext,
        records: [AlignedRead],
        destination: AlignmentReadExtractionPublicationDestination,
        outputBaseName: String,
        reporter: AlignmentScientificActionReporter
    ) -> Task<Void, Never> {
        let operationID = reporter.start("Extract Selected Reads", "Preparing selected-read extraction…")
        reporter.log(operationID, "alignment evidence: \(evidenceIdentityLabel(context.identity))")
        let task = Task {
            do {
                let result = try await self.extractSelectedReads(context: context, records: records, destination: destination, outputBaseName: outputBaseName)
                for record in result.executionRecords { reporter.log(operationID, "argv: \(record.argv.joined(separator: " "))\n\(record.stderr ?? "")") }
                reporter.finish(operationID, .success(result))
            } catch is CancellationError {
                reporter.finish(operationID, .cancelled("Alignment read extraction cancelled."))
            } catch let failure as AlignmentReadExtractionFailure where failure.kind == .cancelled {
                for record in failure.executionRecords { reporter.log(operationID, "argv: \(record.argv.joined(separator: " "))\n\(record.stderr ?? "")") }
                reporter.finish(operationID, .cancelled(failure.message))
            } catch {
                if let failure = error as? AlignmentReadExtractionFailure {
                    for record in failure.executionRecords { reporter.log(operationID, "argv: \(record.argv.joined(separator: " "))\n\(record.stderr ?? "")") }
                }
                reporter.finish(operationID, .failure(error.localizedDescription))
            }
        }
        reporter.installCancellation(operationID) { task.cancel() }
        return task
    }

    func extractRegion(
        context: AlignmentActionContext,
        region: ResolvedAlignmentRegion,
        destination: AlignmentReadExtractionPublicationDestination,
        outputBaseName: String
    ) async throws -> AlignmentReadExtractionPublicationResult {
        guard region.contig == context.contig, region.start >= 0, region.start < region.end, region.end <= context.contigLength else {
            throw AlignmentScientificActionError.invalidRegion
        }
        let config = BAMRegionExtractionConfig(
            bamURL: context.alignmentURL, indexURL: context.indexURL, decodingReferenceURL: context.decodingReferenceURL,
            regions: ["\(region.contig):\(region.start + 1)-\(region.end)"], fallbackToAll: false,
            minMapQ: context.filters.minimumMapQ, excludedFlags: Int(context.filters.excludedFlags), readGroups: context.filters.readGroups.sorted(),
            outputDirectory: destination.finalURL.deletingLastPathComponent(), outputBaseName: outputBaseName, deduplicateReads: false
        )
        let provenance = provenance(context: context, argv: ["Lungfish.app", "alignment", "extract-region", region.contig, "\(region.start)", "\(region.end)"])
        try validator(context) // scientific gate 1: immediately before staging
        let transaction = try await regionStager(config)
        do {
            do {
                try validator(context) // scientific gate 2: immediately before publication
            } catch {
                throw staleInputFailure(error, context: context, transaction: transaction)
            }
            return try await publisher(.init(transaction: transaction, destination: destination, provenance: provenance))
        } catch {
            transaction.cleanup()
            throw error
        }
    }

    func extractSelectedReads(
        context: AlignmentActionContext,
        records: [AlignedRead],
        destination: AlignmentReadExtractionPublicationDestination,
        outputBaseName: String
    ) async throws -> AlignmentReadExtractionPublicationResult {
        guard !records.isEmpty else { throw AlignmentScientificActionError.emptySelection }
        let names = Set(records.map(\.name))
        let missing = records.filter { $0.sequence.isEmpty || $0.sequence == "*" }.count
        let missingMessage = missing == 0 ? nil : "\(missing) selected alignment record(s) did not contain sequence."
        let transaction: AlignmentReadExtractionTransaction
        try validator(context)
        switch context.sourceReads {
        case .sourceFASTQs(let urls) where !urls.isEmpty:
            transaction = try await sourceStager(.init(sourceFASTQs: urls, readIDs: names, keepReadPairs: true, outputDirectory: destination.finalURL.deletingLastPathComponent(), outputBaseName: outputBaseName), missing, missingMessage)
        default:
            transaction = try await bamStager(.init(bamURL: context.alignmentURL, readIDs: names, includeSecondary: false, excludeDuplicates: false, outputDirectory: destination.finalURL.deletingLastPathComponent(), outputBaseName: outputBaseName), missing, missingMessage)
        }
        do {
            do {
                try validator(context)
            } catch {
                throw staleInputFailure(error, context: context, transaction: transaction)
            }
            return try await publisher(.init(transaction: transaction, destination: destination, provenance: provenance(context: context, argv: ["Lungfish.app", "alignment", "extract-selected-reads"])))
        } catch {
            transaction.cleanup()
            throw error
        }
    }

    private func provenance(context: AlignmentActionContext, argv: [String]) -> AlignmentReadExtractionProvenance {
        .init(workflowName: "lungfish alignment read extraction", argv: argv, inputURLs: [context.alignmentURL, context.indexURL] + (context.decodingReferenceURL.map { [$0] } ?? []))
    }

    private func staleInputFailure(
        _ error: Error,
        context: AlignmentActionContext,
        transaction: AlignmentReadExtractionTransaction
    ) -> AlignmentReadExtractionFailure {
        AlignmentReadExtractionFailure(
            kind: .staleInput,
            message: "Alignment evidence changed before publication (\(evidenceIdentityLabel(context.identity));alignment=\(context.alignmentURL.path)): \(error.localizedDescription)",
            executionRecords: transaction.executionRecords
        )
    }

    private func evidenceIdentityLabel(_ identity: AlignmentEvidenceIdentity) -> String {
        "workflow=\(identity.workflow);resultID=\(identity.resultID);sampleID=\(identity.sampleID);evidenceID=\(identity.evidenceID)"
    }

    private func normalizedBundleURL(_ url: URL) -> URL {
        let normalized = url.standardizedFileURL
        guard normalized.pathExtension.lowercased() != FASTQBundle.directoryExtension else {
            if normalized.pathExtension == FASTQBundle.directoryExtension {
                return normalized
            }
            return normalized.deletingPathExtension()
                .appendingPathExtension(FASTQBundle.directoryExtension)
        }
        guard normalized.pathExtension.isEmpty else {
            return normalized.deletingPathExtension()
                .appendingPathExtension(FASTQBundle.directoryExtension)
        }
        return normalized.appendingPathExtension(FASTQBundle.directoryExtension)
    }
}

enum AlignmentScientificActionError: LocalizedError, Sendable, Equatable {
    case invalidRegion
    case emptySelection
    case contextUnavailable
    case destinationUnavailable(String)
    case destinationCancelled(String)
    var errorDescription: String? {
        switch self {
        case .invalidRegion: return "The selected alignment region is invalid."
        case .emptySelection: return "Select at least one read."
        case .contextUnavailable: return "Alignment evidence is unavailable."
        case .destinationUnavailable(let message), .destinationCancelled(let message): return message
        }
    }
}
