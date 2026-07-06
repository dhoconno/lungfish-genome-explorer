// BundleAlignmentFilterService.swift - Shared bundle-centric alignment filtering
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

public enum BundleAlignmentFilterServiceError: Error, LocalizedError, Sendable, Equatable {
    case sourceTrackNotFound(String)
    case missingRequiredSAMTags([String], sourceTrackID: String)
    case invalidCountOutput(String)
    case preprocessingFailed(String)
    case samtoolsFailed(String)

    public var errorDescription: String? {
        switch self {
        case .sourceTrackNotFound(let trackID):
            return "Could not find alignment track '\(trackID)' in the bundle."
        case .missingRequiredSAMTags(let tags, let sourceTrackID):
            return "Alignment track '\(sourceTrackID)' is missing required SAM tags: \(tags.joined(separator: ", "))"
        case .invalidCountOutput(let output):
            return "samtools returned an invalid alignment count: \(output)"
        case .preprocessingFailed(let message):
            return "Alignment preprocessing failed: \(message)"
        case .samtoolsFailed(let message):
            return "samtools BAM filtering failed: \(message)"
        }
    }
}

public struct BundleAlignmentFilterResult: Sendable {
    public let bundleURL: URL
    public let mappingResultURL: URL?
    public let trackInfo: AlignmentTrackInfo
    public let commandHistory: [AlignmentCommandExecutionRecord]

    public init(
        bundleURL: URL,
        mappingResultURL: URL?,
        trackInfo: AlignmentTrackInfo,
        commandHistory: [AlignmentCommandExecutionRecord]
    ) {
        self.bundleURL = bundleURL
        self.mappingResultURL = mappingResultURL
        self.trackInfo = trackInfo
        self.commandHistory = commandHistory
    }
}

struct BundleAlignmentFilterProvenanceContext: Sendable {
    let target: ResolvedAlignmentFilterTarget
    let sourceTrack: AlignmentTrackInfo
    let sourceAlignmentPath: String
    let sourceIndexPath: String
    let referenceFastaPath: String?
    let outputTrackName: String
    let outputTrackIDWasExplicit: Bool
    let filterRequest: AlignmentFilterRequest
    let attachment: PreparedAlignmentAttachmentResult
    let commandHistory: [AlignmentCommandExecutionRecord]
    let startedAt: Date
    let completedAt: Date
}

typealias BundleAlignmentFilterProvenancePublisher = @Sendable (BundleAlignmentFilterProvenanceContext) throws -> Void

public final class BundleAlignmentFilterService: @unchecked Sendable {
    private let samtoolsRunner: any AlignmentSamtoolsRunning
    private let markdupPipeline: any AlignmentMarkdupPipelining
    private let attachmentService: PreparedAlignmentAttachmentService
    private let trackIDProvider: @Sendable () -> String
    private let provenancePublisher: BundleAlignmentFilterProvenancePublisher

    public init(
        samtoolsRunner: any AlignmentSamtoolsRunning = NativeToolSamtoolsRunner.shared,
        markdupPipeline: (any AlignmentMarkdupPipelining)? = nil,
        attachmentService: PreparedAlignmentAttachmentService = PreparedAlignmentAttachmentService()
    ) {
        self.samtoolsRunner = samtoolsRunner
        self.markdupPipeline = markdupPipeline ?? AlignmentMarkdupPipeline(samtoolsRunner: samtoolsRunner)
        self.attachmentService = attachmentService
        self.trackIDProvider = {
            "aln_\(String(UUID().uuidString.prefix(8)))"
        }
        self.provenancePublisher = Self.defaultProvenancePublisher
    }

    init(
        samtoolsRunner: any AlignmentSamtoolsRunning = NativeToolSamtoolsRunner.shared,
        markdupPipeline: (any AlignmentMarkdupPipelining)? = nil,
        attachmentService: PreparedAlignmentAttachmentService = PreparedAlignmentAttachmentService(),
        trackIDProvider: @escaping @Sendable () -> String,
        provenancePublisher: @escaping BundleAlignmentFilterProvenancePublisher = BundleAlignmentFilterService.defaultProvenancePublisher
    ) {
        self.samtoolsRunner = samtoolsRunner
        self.markdupPipeline = markdupPipeline ?? AlignmentMarkdupPipeline(samtoolsRunner: samtoolsRunner)
        self.attachmentService = attachmentService
        self.trackIDProvider = trackIDProvider
        self.provenancePublisher = provenancePublisher
    }

    public func deriveFilteredAlignment(
        target: AlignmentFilterTarget,
        sourceTrackID: String,
        outputTrackName: String,
        outputTrackID: String? = nil,
        filterRequest: AlignmentFilterRequest,
        progressHandler: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> BundleAlignmentFilterResult {
        let workflowStartedAt = Date()
        let resolvedTarget = try AlignmentFilterTargetResolver.resolve(target)
        let bundle = try await ReferenceBundle(url: resolvedTarget.bundleURL)
        guard let sourceTrack = bundle.alignmentTrack(id: sourceTrackID) else {
            throw BundleAlignmentFilterServiceError.sourceTrackNotFound(sourceTrackID)
        }

        let sourceAlignmentPath = try bundle.resolveAlignmentPath(sourceTrack)
        let sourceIndexPath = try bundle.resolveAlignmentIndexPath(sourceTrack)
        let referenceFastaPath = bundle.referenceFASTAPath()
        let outputTrackIDWasExplicit = outputTrackID != nil
        let resolvedOutputTrackID = try PreparedAlignmentAttachmentPathPolicy.normalizedOutputTrackID(
            outputTrackID ?? trackIDProvider()
        )
        let plan = try AlignmentFilterCommandBuilder.build(from: filterRequest)

        progressHandler?(0.05, "Checking required SAM tags...")
        try await preflightRequiredTags(
            plan.requiredSAMTags,
            plan: plan,
            inputPath: sourceAlignmentPath,
            sourceTrackID: sourceTrackID
        )

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-bam-filter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let sortedOutputURL = workDir.appendingPathComponent("\(sourceTrackID).filtered.sorted.bam")
        let unsortedOutputURL = workDir.appendingPathComponent("\(sourceTrackID).filtered.unsorted.bam")
        var currentInputURL = URL(fileURLWithPath: sourceAlignmentPath)
        var commandHistory: [AlignmentCommandExecutionRecord] = []
        let samtoolsVersion = await samtoolsRunner.samtoolsVersion()

        for step in plan.preprocessingSteps {
            switch step {
            case .samtoolsMarkdup(let removeDuplicates):
                let markdupOutputURL = workDir.appendingPathComponent("\(sourceTrackID).preprocessed.markdup.bam")
                progressHandler?(0.18, "Running duplicate preprocessing...")
                let result: AlignmentMarkdupPipelineResult
                do {
                    result = try await markdupPipeline.run(
                        inputURL: currentInputURL,
                        outputURL: markdupOutputURL,
                        removeDuplicates: removeDuplicates,
                        referenceFastaPath: referenceFastaPath,
                        progressHandler: progressHandler
                    )
                } catch {
                    throw BundleAlignmentFilterServiceError.preprocessingFailed(error.localizedDescription)
                }
                currentInputURL = result.outputURL
                commandHistory += result.commandHistory
            }
        }

        progressHandler?(0.55, "Filtering alignments...")
        let baseViewArguments = plan.commandArguments(appendingInputPath: currentInputURL.path)
        let viewArguments = insertingOutputPath(
            unsortedOutputURL.path,
            into: baseViewArguments,
            trailingArgumentCount: plan.trailingArguments.count
        )
        let viewExecution = try await runSamtoolsOrThrow(arguments: viewArguments, timeout: 3600)
        commandHistory.append(
            try alignmentCommandExecutionRecord(
                arguments: viewArguments,
                inputFile: currentInputURL.path,
                outputFile: unsortedOutputURL.path,
                toolVersion: samtoolsVersion,
                execution: viewExecution
            )
        )

        progressHandler?(0.72, "Sorting filtered BAM...")
        var sortArguments = ["sort", "-o", sortedOutputURL.path]
        if let referenceFastaPath {
            sortArguments += ["--reference", referenceFastaPath]
        }
        sortArguments.append(unsortedOutputURL.path)
        let sortExecution = try await runSamtoolsOrThrow(arguments: sortArguments, timeout: 3600)
        commandHistory.append(
            try alignmentCommandExecutionRecord(
                arguments: sortArguments,
                inputFile: unsortedOutputURL.path,
                outputFile: sortedOutputURL.path,
                toolVersion: samtoolsVersion,
                execution: sortExecution,
                referenceFiles: referenceFastaPath.map { [$0] } ?? []
            )
        )

        progressHandler?(0.84, "Indexing filtered BAM...")
        let indexArguments = ["index", sortedOutputURL.path]
        let indexExecution = try await runSamtoolsOrThrow(arguments: indexArguments, timeout: 3600)
        commandHistory.append(
            try alignmentCommandExecutionRecord(
                arguments: indexArguments,
                inputFile: sortedOutputURL.path,
                outputFile: sortedOutputURL.path + ".bai",
                toolVersion: samtoolsVersion,
                execution: indexExecution
            )
        )

        progressHandler?(0.9, "Attaching filtered BAM...")
        let publicationSnapshot = try ProvenancePublicationSnapshot(
            urls: filteredAlignmentPublicationArtifacts(
                bundleURL: resolvedTarget.bundleURL,
                outputTrackID: resolvedOutputTrackID
            ),
            backupNamePrefix: "lungfish-bam-filter"
        )
        defer { publicationSnapshot.discard() }

        do {
            let attachment = try await attachmentService.attach(
                request: PreparedAlignmentAttachmentRequest(
                    bundleURL: resolvedTarget.bundleURL,
                    stagedBAMURL: sortedOutputURL,
                    stagedIndexURL: URL(fileURLWithPath: sortedOutputURL.path + ".bai"),
                    outputTrackID: resolvedOutputTrackID,
                    outputTrackName: outputTrackName,
                    relativeDirectory: "alignments/filtered"
                )
            )

            try appendDerivationMetadata(
                metadataDBURL: attachment.metadataDBURL,
                sourceTrack: sourceTrack,
                sourceAlignmentPath: sourceAlignmentPath,
                sourceIndexPath: sourceIndexPath,
                filterRequest: filterRequest,
                preprocessingSteps: plan.preprocessingSteps,
                commandHistory: commandHistory,
                mappingResultURL: resolvedTarget.mappingResultURL
            )
            try provenancePublisher(BundleAlignmentFilterProvenanceContext(
                target: resolvedTarget,
                sourceTrack: sourceTrack,
                sourceAlignmentPath: sourceAlignmentPath,
                sourceIndexPath: sourceIndexPath,
                referenceFastaPath: referenceFastaPath,
                outputTrackName: outputTrackName,
                outputTrackIDWasExplicit: outputTrackIDWasExplicit,
                filterRequest: filterRequest,
                attachment: attachment,
                commandHistory: commandHistory,
                startedAt: workflowStartedAt,
                completedAt: Date()
            ))

            progressHandler?(1.0, "Filtered alignment attached.")
            return BundleAlignmentFilterResult(
                bundleURL: resolvedTarget.bundleURL,
                mappingResultURL: resolvedTarget.mappingResultURL,
                trackInfo: attachment.trackInfo,
                commandHistory: commandHistory
            )
        } catch {
            try? publicationSnapshot.restore()
            throw error
        }
    }

    private static func defaultProvenancePublisher(_ context: BundleAlignmentFilterProvenanceContext) throws {
        try BundleAlignmentFilterProvenanceWriter.write(
            target: context.target,
            sourceTrack: context.sourceTrack,
            sourceAlignmentPath: context.sourceAlignmentPath,
            sourceIndexPath: context.sourceIndexPath,
            referenceFastaPath: context.referenceFastaPath,
            outputTrackName: context.outputTrackName,
            outputTrackIDWasExplicit: context.outputTrackIDWasExplicit,
            filterRequest: context.filterRequest,
            attachment: context.attachment,
            commandHistory: context.commandHistory,
            startedAt: context.startedAt,
            completedAt: context.completedAt
        )
    }

    private func filteredAlignmentPublicationArtifacts(bundleURL: URL, outputTrackID: String) -> [URL] {
        let bamURL = bundleURL.appendingPathComponent("alignments/filtered/\(outputTrackID).bam")
        let indexURL = bundleURL.appendingPathComponent("alignments/filtered/\(outputTrackID).bam.bai")
        let metadataDBURL = bundleURL.appendingPathComponent("alignments/filtered/\(outputTrackID).stats.db")
        let payloadURLs = [
            bamURL,
            indexURL,
            metadataDBURL,
            bundleURL.appendingPathComponent(BundleManifest.filename),
        ]
        let outputSidecars = payloadURLs.compactMap {
            ProvenanceWriter.bundleOutputSidecarURL(for: $0, inBundle: bundleURL)
        }
        return payloadURLs
            + ProvenancePublicationArtifacts.bundleRootArtifacts(for: bundleURL)
            + outputSidecars.flatMap(ProvenancePublicationArtifacts.sidecarArtifacts(for:))
    }

    private func preflightRequiredTags(
        _ requiredSAMTags: [String],
        plan: AlignmentFilterCommandPlan,
        inputPath: String,
        sourceTrackID: String
    ) async throws {
        guard !requiredSAMTags.isEmpty else { return }

        let totalCount = try await alignmentCount(
            arguments: preflightCountArguments(for: plan, inputPath: inputPath, requiredTag: nil)
        )
        guard totalCount > 0 else { return }

        var missingTags: [String] = []
        for tag in requiredSAMTags.sorted() {
            let taggedCount = try await alignmentCount(
                arguments: preflightCountArguments(for: plan, inputPath: inputPath, requiredTag: tag)
            )
            if taggedCount != totalCount {
                missingTags.append(tag)
            }
        }

        if !missingTags.isEmpty {
            throw BundleAlignmentFilterServiceError.missingRequiredSAMTags(missingTags, sourceTrackID: sourceTrackID)
        }
    }

    private func alignmentCount(arguments: [String]) async throws -> Int {
        let execution = try await runSamtoolsOrThrow(arguments: arguments, timeout: 300)
        let result = execution.result
        guard let count = Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw BundleAlignmentFilterServiceError.invalidCountOutput(result.stdout)
        }
        return count
    }

    private func runSamtoolsOrThrow(
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> AlignmentNativeCommandExecution {
        let startedAt = Date()
        let result = try await samtoolsRunner.runSamtools(arguments: arguments, timeout: timeout)
        let completedAt = Date()
        guard result.isSuccess else {
            throw BundleAlignmentFilterServiceError.samtoolsFailed(
                result.stderr.isEmpty ? "samtools exited with \(result.exitCode)" : result.stderr
            )
        }
        return AlignmentNativeCommandExecution(
            result: result,
            startedAt: startedAt,
            completedAt: completedAt
        )
    }

    private func preflightCountArguments(
        for plan: AlignmentFilterCommandPlan,
        inputPath: String,
        requiredTag: String?
    ) -> [String] {
        var arguments = plan.commandArguments(appendingInputPath: inputPath)

        if let binaryIndex = arguments.firstIndex(of: "-b") {
            arguments.remove(at: binaryIndex)
        }

        if let identityExpression = plan.identityFilterExpression,
           let expressionIndex = arguments.firstIndex(of: "-e"),
           expressionIndex + 1 < arguments.count,
           arguments[expressionIndex + 1] == identityExpression {
            arguments.removeSubrange(expressionIndex...(expressionIndex + 1))
        }

        arguments.insert("-c", at: 1)

        if let requiredTag {
            let inputIndex = max(1, arguments.count - plan.trailingArguments.count - 1)
            arguments.insert(contentsOf: ["-e", "exists([\(requiredTag)])"], at: inputIndex)
        }

        return arguments
    }

    private func insertingOutputPath(
        _ outputPath: String,
        into arguments: [String],
        trailingArgumentCount: Int
    ) -> [String] {
        guard !arguments.isEmpty else { return arguments }
        var rewritten = arguments
        let inputIndex = max(1, rewritten.count - trailingArgumentCount - 1)
        rewritten.insert(contentsOf: ["-o", outputPath], at: inputIndex)
        return rewritten
    }

    private func appendDerivationMetadata(
        metadataDBURL: URL,
        sourceTrack: AlignmentTrackInfo,
        sourceAlignmentPath: String,
        sourceIndexPath: String,
        filterRequest: AlignmentFilterRequest,
        preprocessingSteps: [AlignmentFilterPreprocessingStep],
        commandHistory: [AlignmentCommandExecutionRecord],
        mappingResultURL: URL?
    ) throws {
        let metadataDB = try AlignmentMetadataDatabase.openForUpdate(at: metadataDBURL)

        metadataDB.setFileInfo("derivation_kind", value: "filtered_alignment")
        metadataDB.setFileInfo("derivation_source_track_id", value: sourceTrack.id)
        metadataDB.setFileInfo("derivation_source_track_name", value: sourceTrack.name)
        metadataDB.setFileInfo("derivation_source_manifest_path", value: sourceTrack.sourcePath)
        metadataDB.setFileInfo("derivation_source_alignment_path", value: sourceAlignmentPath)
        metadataDB.setFileInfo("derivation_source_alignment_index_path", value: sourceIndexPath)
        metadataDB.setFileInfo("derivation_duplicate_mode", value: filterRequest.duplicateMode?.rawValue ?? "none")
        metadataDB.setFileInfo("derivation_default_track_name", value: filterRequest.derivedAlignmentDefaultName)
        metadataDB.setFileInfo("derivation_filter_summary", value: filterRequest.derivedAlignmentSummary)
        metadataDB.setFileInfo("derivation_mapped_only", value: filterRequest.mappedOnly ? "true" : "false")
        metadataDB.setFileInfo("derivation_primary_only", value: filterRequest.primaryOnly ? "true" : "false")
        if let minimumMAPQ = filterRequest.minimumMAPQ {
            metadataDB.setFileInfo("derivation_minimum_mapq", value: "\(minimumMAPQ)")
        }
        if let identityFilter = filterRequest.identityFilter {
            metadataDB.setFileInfo("derivation_identity_filter", value: identityFilter.metadataValue)
        }
        metadataDB.setFileInfo(
            "derivation_preprocessing",
            value: preprocessingSteps.map(preprocessingDescription).joined(separator: " -> ")
        )
        metadataDB.setFileInfo(
            "derivation_command_chain",
            value: commandHistory.map(\.commandLine).joined(separator: " | ")
        )
        metadataDB.setFileInfo("derivation_target_kind", value: mappingResultURL == nil ? "bundle" : "mapping_result")
        if let mappingResultURL {
            metadataDB.setFileInfo("derivation_mapping_result_path", value: mappingResultURL.path)
        }
        if let region = filterRequest.region?.trimmingCharacters(in: .whitespacesAndNewlines),
           !region.isEmpty {
            metadataDB.setFileInfo("derivation_region", value: region)
        }

        var parentStep: Int?
        for command in commandHistory {
            parentStep = metadataDB.addProvenanceRecord(
                tool: command.tool,
                subcommand: command.subcommand,
                command: command.commandLine,
                inputFile: command.inputFile,
                outputFile: command.outputFile,
                exitCode: command.exitStatus.map { Int32($0) } ?? 0,
                parentStep: parentStep
            )
        }
    }

    private func preprocessingDescription(_ step: AlignmentFilterPreprocessingStep) -> String {
        switch step {
        case .samtoolsMarkdup(let removeDuplicates):
            return "samtools markdup(removeDuplicates=\(removeDuplicates))"
        }
    }
}
