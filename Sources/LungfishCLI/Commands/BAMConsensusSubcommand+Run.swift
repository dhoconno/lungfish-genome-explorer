// BAMConsensusSubcommand+Run.swift - The work of lungfish-cli bam consensus
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

extension BAMConsensusSubcommand {
    /// The run, as its options give it.
    struct Plan: Sendable {
        let invocation: AlignmentConsensusInvocation
        let destination: AlignmentConsensusPublicationDestination

        /// Why the run cannot start, found before anything runs, or nil.
        func refusal() -> String? {
            let fileManager = FileManager.default
            var inputs = [("--alignment", invocation.alignmentURL), ("--index", invocation.indexURL)]
            if let referenceURL = invocation.decodingReferenceURL { inputs.append(("--decoding-reference", referenceURL)) }
            for (option, url) in inputs where !fileManager.fileExists(atPath: url.path) {
                return "No file at \(url.path). Pass an existing file as \(option)."
            }
            let indexes: [String: [String]] = ["bam": ["bai", "csi"], "cram": ["crai", "csi"]]
            let alignmentExtension = invocation.alignmentURL.pathExtension.lowercased()
            guard let allowed = indexes[alignmentExtension] else {
                return "--alignment must be a .bam or .cram file."
            }
            guard allowed.contains(invocation.indexURL.pathExtension.lowercased()) else {
                return "--index must be a .\(allowed.joined(separator: " or .")) index for a .\(alignmentExtension) file."
            }
            let finalURL = destination.finalURL
            var isDirectory: ObjCBool = false
            let folder = finalURL.deletingLastPathComponent()
            guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return "The folder \(folder.path) does not exist. Create it or pass another --output."
            }
            let sidecar = ProvenanceRecorder.fileSidecarURL(for: finalURL)
            let sidecarTaken = !destination.isBundle && fileManager.fileExists(atPath: sidecar.path)
                && !AlignmentConsensusPublicationService.isCancelledRecord(at: sidecar)
            if fileManager.fileExists(atPath: finalURL.path) || sidecarTaken {
                return AlignmentConsensusPublicationError.destinationExists(finalURL).localizedDescription
            }
            return nil
        }
    }

    /// How a run that was not cancelled and did not fail ended.
    enum Outcome: Sendable {
        case published(AlignmentConsensusPublicationResult, [AlignmentConsensusExecutionRecord])
        case refused(String, [AlignmentConsensusExecutionRecord])
    }

    /// Hashes the evidence, reads the contig's length, calls the consensus and publishes it. A
    /// cancel stops each hash and each samtools run, and is checked again before the publication.
    static func consensus(_ plan: Plan) async throws -> Outcome {
        let invocation = plan.invocation
        let alignmentSnapshot = try await snapshot(invocation.alignmentURL)
        let indexSnapshot = try await snapshot(invocation.indexURL)
        var referenceSnapshot: AlignmentEvidenceFileSnapshot?
        if let referenceURL = invocation.decodingReferenceURL {
            referenceSnapshot = try await snapshot(referenceURL)
        }
        try Task.checkCancellation()
        let region = invocation.region
        let provider = AlignmentDataProvider(
            alignmentPath: invocation.alignmentURL.path,
            indexPath: invocation.indexURL.path,
            format: invocation.alignmentURL.pathExtension.lowercased() == "cram" ? .cram : .bam,
            referenceFastaPath: invocation.decodingReferenceURL?.path
        )
        let contigLength: Int
        switch AlignmentRegionOnEvidence.contigLength(of: region.contig, end: region.end, inHeader: try await provider.fetchHeader()) {
        case .success(let length): contigLength = length
        case .failure(let refusal): return .refused(refusal.message, [])
        }
        let context = try AlignmentActionContext(
            identity: .init(workflow: "bam consensus", resultID: invocation.resultID, sampleID: invocation.recordName, evidenceID: region.contig),
            alignmentURL: invocation.alignmentURL,
            indexURL: invocation.indexURL,
            decodingReferenceURL: invocation.decodingReferenceURL,
            contig: region.contig,
            contigLength: contigLength,
            alignmentSnapshot: alignmentSnapshot,
            indexSnapshot: indexSnapshot,
            decodingReferenceSnapshot: referenceSnapshot,
            filters: invocation.consensusRequest.filters,
            outputCapability: .userSelectedDestination,
            sourceReads: .bamFallback,
            presentationLabel: invocation.recordName
        )
        let result = try await provider.fetchConsensus(invocation.consensusRequest)
        try Task.checkCancellation()
        if result.allLowDepth, !invocation.allowAllLowDepth {
            return .refused(AlignmentConsensusPublicationService.allLowDepthRefusal, result.executionRecords)
        }
        // The evidence must still be the bytes the run hashed (the second scientific gate).
        try await context.validateCurrentSnapshots()
        try Task.checkCancellation()
        let publication = try AlignmentConsensusPublicationService().publish(AlignmentConsensusPublicationRequest(
            context: context,
            region: region,
            consensusRequest: invocation.consensusRequest,
            result: result,
            recordName: invocation.recordName,
            destination: plan.destination,
            allowAllLowDepth: invocation.allowAllLowDepth
        ))
        return .published(publication, result.executionRecords)
    }

    /// The size and digest of `url`, hashed once a run through the shared digest cache. The hash
    /// checks for a cancel between its reads.
    private static func snapshot(_ url: URL) async throws -> AlignmentEvidenceFileSnapshot {
        let identity = try AlignmentEvidenceFileIdentity.current(of: url)
        let sha256 = try await AlignmentEvidenceDigestCache.shared.digest(for: identity) {
            try ProvenanceFileHasher.sha256(of: url) { try Task.checkCancellation() }
        }
        return AlignmentEvidenceFileSnapshot(url: url, byteCount: identity.byteCount, sha256: sha256)
    }

    /// What the row logged at error for a failed run before, the samtools runs or the publication.
    static func failureLog(_ error: any Error) -> [String] {
        switch error {
        case let failure as AlignmentConsensusPublicationFailure:
            return [failure.attempt.durableLogMessage]
        case AlignmentFetchError.consensusExecutionFailed(let records),
             AlignmentFetchError.consensusCoordinateMismatchWithRecords(let records):
            return records.map { "\($0.reproducibleCommand)\n\($0.stderr ?? "")" }
        default:
            return []
        }
    }
}
