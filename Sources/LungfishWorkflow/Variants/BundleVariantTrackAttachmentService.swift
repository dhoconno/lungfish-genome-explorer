import Foundation
import LungfishCore
import LungfishIO

public enum BundleVariantTrackAttachmentError: Error, LocalizedError {
    case duplicateTrackID(String)
    case missingAlignmentTrack(String)
    case missingBundleGenome
    case missingArtifact(URL)
    case conflictingContigLengths(String)

    public var errorDescription: String? {
        switch self {
        case .duplicateTrackID(let trackID):
            return "Variant track ID already exists in bundle manifest: \(trackID)"
        case .missingAlignmentTrack(let trackID):
            return "Alignment track was not found in the bundle manifest: \(trackID)"
        case .missingBundleGenome:
            return "Bundle does not expose a reference genome."
        case .missingArtifact(let url):
            return "Required staged artifact is missing: \(url.path)"
        case .conflictingContigLengths(let chromosome):
            return "Staged variant database contains conflicting contig lengths for remapped chromosome '\(chromosome)'."
        }
    }
}

public actor BundleVariantTrackAttachmentService {
    public typealias ManifestSaver = @Sendable (BundleManifest, URL) throws -> Void
    public typealias DateProvider = @Sendable () -> Date

    private let fileManager: FileManager
    private let manifestSaver: ManifestSaver
    private let dateProvider: DateProvider

    public init(
        fileManager: FileManager = .default,
        manifestSaver: @escaping ManifestSaver = BundleVariantTrackAttachmentService.atomicManifestSave(manifest:bundleURL:),
        dateProvider: @escaping DateProvider = Date.init
    ) {
        self.fileManager = fileManager
        self.manifestSaver = manifestSaver
        self.dateProvider = dateProvider
    }

    public func attach(
        request: BundleVariantTrackAttachmentRequest
    ) async throws -> BundleVariantTrackAttachmentResult {
        let manifest = try BundleManifest.load(from: request.bundleURL)
        guard !manifest.variants.contains(where: { $0.id == request.outputTrackID }) else {
            throw BundleVariantTrackAttachmentError.duplicateTrackID(request.outputTrackID)
        }
        guard let alignmentTrack = manifest.alignments.first(where: { $0.id == request.alignmentTrackID }) else {
            throw BundleVariantTrackAttachmentError.missingAlignmentTrack(request.alignmentTrackID)
        }
        guard let genome = manifest.genome else {
            throw BundleVariantTrackAttachmentError.missingBundleGenome
        }
        let manifestURL = request.bundleURL.appendingPathComponent(BundleManifest.filename)
        let originalManifestData = try Data(contentsOf: manifestURL)

        for artifactURL in [request.stagedVCFGZURL, request.stagedTabixURL, request.stagedDatabaseURL] {
            guard fileManager.fileExists(atPath: artifactURL.path) else {
                throw BundleVariantTrackAttachmentError.missingArtifact(artifactURL)
            }
        }

        let variantsDir = request.bundleURL.appendingPathComponent("variants", isDirectory: true)
        try fileManager.createDirectory(at: variantsDir, withIntermediateDirectories: true)

        let finalVCFRelativePath = "variants/\(request.outputTrackID).vcf.gz"
        let finalTBIRelativePath = "variants/\(request.outputTrackID).vcf.gz.tbi"
        let finalDBRelativePath = "variants/\(request.outputTrackID).db"
        let finalProvenanceRelativePath = "variants/\(request.outputTrackID).lungfish-provenance.json"
        let finalVCFURL = request.bundleURL.appendingPathComponent(finalVCFRelativePath)
        let finalTBIURL = request.bundleURL.appendingPathComponent(finalTBIRelativePath)
        let finalDBURL = request.bundleURL.appendingPathComponent(finalDBRelativePath)
        let finalProvenanceURL = request.bundleURL.appendingPathComponent(finalProvenanceRelativePath)

        var promotedURLs: [URL] = []
        do {
            let stagedInputRecords = [
                ProvenanceRecorder.fileRecord(url: request.stagedVCFGZURL, format: .vcf, role: .input),
                ProvenanceRecorder.fileRecord(url: request.stagedTabixURL, role: .index),
                ProvenanceRecorder.fileRecord(url: request.stagedDatabaseURL, role: .input),
            ]
            try promoteArtifact(from: request.stagedVCFGZURL, to: finalVCFURL)
            promotedURLs.append(finalVCFURL)
            try promoteArtifact(from: request.stagedTabixURL, to: finalTBIURL)
            promotedURLs.append(finalTBIURL)
            try promoteArtifact(from: request.stagedDatabaseURL, to: finalDBURL)
            promotedURLs.append(finalDBURL)

            let variantDatabase = try VariantDatabase(url: finalDBURL, readWrite: true)
            try normalizeDatabaseChromosomes(database: variantDatabase, bundleChromosomes: genome.chromosomes)
            let actualVariantCount = variantDatabase.totalVariantCount()
            try variantDatabase.setMetadataValues(
                makeProvenanceMetadata(
                    request: request,
                    manifest: manifest,
                    alignmentTrack: alignmentTrack,
                    finalVCFRelativePath: finalVCFRelativePath,
                    finalTBIRelativePath: finalTBIRelativePath,
                    finalDBRelativePath: finalDBRelativePath,
                    finalProvenanceRelativePath: finalProvenanceRelativePath
                )
            )

            let trackInfo = VariantTrackInfo(
                id: request.outputTrackID,
                name: request.outputTrackName,
                description: "\(request.caller.displayName) variants from \(alignmentTrack.name)",
                path: finalVCFRelativePath,
                indexPath: finalTBIRelativePath,
                databasePath: finalDBRelativePath,
                variantType: .mixed,
                variantCount: actualVariantCount,
                source: request.caller.displayName,
                version: request.variantCallerVersion
            )

            try writeWorkflowProvenance(
                request: request,
                manifest: manifest,
                alignmentTrack: alignmentTrack,
                finalVCFURL: finalVCFURL,
                finalTBIURL: finalTBIURL,
                finalDBURL: finalDBURL,
                finalProvenanceURL: finalProvenanceURL,
                stagedInputRecords: stagedInputRecords
            )
            promotedURLs.append(finalProvenanceURL)
            let updatedManifest = manifest.addingVariantTrack(trackInfo)
            try manifestSaver(updatedManifest, request.bundleURL)

            return BundleVariantTrackAttachmentResult(
                trackInfo: trackInfo,
                finalVCFGZURL: finalVCFURL,
                finalTabixURL: finalTBIURL,
                finalDatabaseURL: finalDBURL,
                provenanceURL: finalProvenanceURL
            )
        } catch {
            for url in promotedURLs {
                try? fileManager.removeItem(at: url)
            }
            try? originalManifestData.write(to: manifestURL, options: .atomic)
            throw error
        }
    }

    public static func atomicManifestSave(
        manifest: BundleManifest,
        bundleURL: URL
    ) throws {
        let manifestURL = bundleURL.appendingPathComponent(BundleManifest.filename)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL, options: .atomic)
    }

    private func promoteArtifact(from sourceURL: URL, to destinationURL: URL) throws {
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.moveItem(at: sourceURL, to: destinationURL)
    }

    private func normalizeDatabaseChromosomes(
        database: VariantDatabase,
        bundleChromosomes: [ChromosomeInfo]
    ) throws {
        let originalContigLengths = database.contigLengths()
        let mapping = mapVCFChromosomes(Array(originalContigLengths.keys), toBundleChromosomes: bundleChromosomes)
        let remappedContigLengths = try remapContigLengths(originalContigLengths, mapping: mapping)
        if !mapping.isEmpty {
            try database.renameChromosomes(mapping)
        }

        if !remappedContigLengths.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: remappedContigLengths.mapValues { NSNumber(value: $0) }),
           let json = String(data: data, encoding: .utf8) {
            try database.setMetadataValues(["contig_lengths": json])
        }
    }

    private func remapContigLengths(
        _ originalContigLengths: [String: Int64],
        mapping: [String: String]
    ) throws -> [String: Int64] {
        var remapped: [String: Int64] = [:]
        for (originalName, length) in originalContigLengths {
            let normalizedName = mapping[originalName] ?? originalName
            if let existingLength = remapped[normalizedName], existingLength != length {
                throw BundleVariantTrackAttachmentError.conflictingContigLengths(normalizedName)
            }
            remapped[normalizedName] = length
        }
        return remapped
    }

    private func makeProvenanceMetadata(
        request: BundleVariantTrackAttachmentRequest,
        manifest: BundleManifest,
        alignmentTrack: AlignmentTrackInfo,
        finalVCFRelativePath: String,
        finalTBIRelativePath: String,
        finalDBRelativePath: String,
        finalProvenanceRelativePath: String
    ) -> [String: String] {
        let formatter = ISO8601DateFormatter()
        return [
            "variant_caller": request.caller.rawValue,
            "variant_caller_version": request.variantCallerVersion,
            "variant_caller_parameters_json": request.variantCallerParametersJSON,
            "variant_caller_command_line": request.variantCallerCommandLine,
            "source_alignment_track_id": alignmentTrack.id,
            "source_alignment_track_name": alignmentTrack.name,
            "source_alignment_relative_path": alignmentTrack.sourcePath,
            "source_alignment_checksum_sha256": alignmentTrack.checksumSHA256 ?? "",
            "reference_bundle_id": manifest.identifier,
            "reference_bundle_name": manifest.name,
            "reference_staged_fasta_sha256": request.referenceStagedFASTASHA256,
            "artifact_vcf_path": finalVCFRelativePath,
            "artifact_tbi_path": finalTBIRelativePath,
            "artifact_database_path": finalDBRelativePath,
            "workflow_provenance_path": finalProvenanceRelativePath,
            "call_semantics": request.caller.callSemantics,
            "created_at": formatter.string(from: dateProvider()),
        ]
    }

    private func writeWorkflowProvenance(
        request: BundleVariantTrackAttachmentRequest,
        manifest: BundleManifest,
        alignmentTrack: AlignmentTrackInfo,
        finalVCFURL: URL,
        finalTBIURL: URL,
        finalDBURL: URL,
        finalProvenanceURL: URL,
        stagedInputRecords: [FileRecord]
    ) throws {
        let completedAt = dateProvider()
        let provenance = request.workflowProvenance ?? VariantCallingWorkflowProvenance(
            workflowName: "lungfish variants call",
            workflowVersion: WorkflowRun.currentAppVersion,
            command: request.variantCallerCommandLine.isEmpty
                ? ["lungfish", "variants", "call"]
                : ["sh", "-lc", request.variantCallerCommandLine],
            startedAt: completedAt,
            completedAt: completedAt,
            parameters: [:],
            steps: []
        )

        var steps = provenance.steps.map { $0.stepExecution() }
        let parentStep = steps.last?.id
        let attachmentStartedAt = provenance.completedAt
        let attachmentStep = StepExecution(
            toolName: "lungfish-cli",
            toolVersion: provenance.workflowVersion,
            command: provenance.command,
            inputs: stagedInputRecords,
            outputs: [
                ProvenanceRecorder.fileRecord(url: finalVCFURL, format: .vcf, role: .output),
                ProvenanceRecorder.fileRecord(url: finalTBIURL, role: .index),
                ProvenanceRecorder.fileRecord(url: finalDBURL, role: .output),
            ],
            exitCode: 0,
            wallTime: completedAt.timeIntervalSince(attachmentStartedAt),
            stderr: nil,
            dependsOn: parentStep.map { [$0] } ?? [],
            startTime: attachmentStartedAt,
            endTime: completedAt
        )
        steps.append(attachmentStep)

        var parameters: [String: ParameterValue] = provenance.parameters.mapValues { .string($0) }
        parameters["bundlePath"] = .string(request.bundleURL.standardizedFileURL.path)
        parameters["bundleIdentifier"] = .string(manifest.identifier)
        parameters["bundleName"] = .string(manifest.name)
        parameters["alignmentTrackID"] = .string(alignmentTrack.id)
        parameters["alignmentTrackName"] = .string(alignmentTrack.name)
        parameters["caller"] = .string(request.caller.rawValue)
        parameters["outputTrackID"] = .string(request.outputTrackID)
        parameters["outputTrackName"] = .string(request.outputTrackName)
        parameters["variantCallerVersion"] = .string(request.variantCallerVersion)
        parameters["referenceStagedFASTASHA256"] = .string(request.referenceStagedFASTASHA256)
        parameters["containerRuntime"] = parameters["containerRuntime"] ?? .string("none")

        let run = WorkflowRun(
            name: provenance.workflowName,
            startTime: provenance.startedAt,
            endTime: completedAt,
            status: .completed,
            appVersion: provenance.workflowVersion,
            hostOS: WorkflowRun.currentHostOS,
            steps: steps,
            parameters: parameters
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(run).write(to: finalProvenanceURL, options: .atomic)
    }
}
