import Foundation
import LungfishCore
import LungfishIO

public struct GATKBundleVariantAttachmentRequest: Sendable {
    public let bundleURL: URL
    public let alignmentTrackID: String
    public let outputTrackID: String
    public let outputTrackName: String
    public let outputVCFURL: URL
    public let outputIndexURL: URL?
    public let executionProvenanceURL: URL?
    public let executionRequest: GATKPipelineExecutionRequest
    public let importProfile: VCFImportProfile

    public init(
        bundleURL: URL,
        alignmentTrackID: String,
        outputTrackID: String,
        outputTrackName: String,
        outputVCFURL: URL,
        outputIndexURL: URL? = nil,
        executionProvenanceURL: URL? = nil,
        executionRequest: GATKPipelineExecutionRequest,
        importProfile: VCFImportProfile = .auto
    ) {
        self.bundleURL = bundleURL
        self.alignmentTrackID = alignmentTrackID
        self.outputTrackID = outputTrackID
        self.outputTrackName = outputTrackName
        self.outputVCFURL = outputVCFURL
        self.outputIndexURL = outputIndexURL
        self.executionProvenanceURL = executionProvenanceURL
        self.executionRequest = executionRequest
        self.importProfile = importProfile
    }
}

public struct GATKBundleVariantAttachmentResult: Sendable, Equatable {
    public let trackInfo: VariantTrackInfo
    public let databaseURL: URL
    public let indexURL: URL
    public let provenanceURL: URL
    public let variantCount: Int

    public init(
        trackInfo: VariantTrackInfo,
        databaseURL: URL,
        indexURL: URL,
        provenanceURL: URL,
        variantCount: Int
    ) {
        self.trackInfo = trackInfo
        self.databaseURL = databaseURL
        self.indexURL = indexURL
        self.provenanceURL = provenanceURL
        self.variantCount = variantCount
    }
}

public enum GATKBundleVariantAttachmentError: Error, LocalizedError, Equatable {
    case duplicateTrackID(String)
    case missingAlignmentTrack(String)
    case missingBundleGenome
    case missingOutputVCF(String)
    case missingOutputIndex(String)
    case outputOutsideBundle(String)

    public var errorDescription: String? {
        switch self {
        case .duplicateTrackID(let trackID):
            return "Variant track ID already exists in bundle manifest: \(trackID)"
        case .missingAlignmentTrack(let trackID):
            return "Alignment track was not found in the bundle manifest: \(trackID)"
        case .missingBundleGenome:
            return "Bundle does not expose a reference genome."
        case .missingOutputVCF(let path):
            return "GATK did not create the expected VCF: \(path)"
        case .missingOutputIndex(let path):
            return "GATK did not create the expected VCF index: \(path)"
        case .outputOutsideBundle(let path):
            return "GATK output is not stored inside the target bundle: \(path)"
        }
    }
}

public actor GATKBundleVariantAttachmentService {
    public typealias DateProvider = @Sendable () -> Date

    private let fileManager: FileManager
    private let importCoordinator: VariantSQLiteImportCoordinator
    private let dateProvider: DateProvider

    public init(
        fileManager: FileManager = .default,
        importCoordinator: VariantSQLiteImportCoordinator = VariantSQLiteImportCoordinator(),
        dateProvider: @escaping DateProvider = Date.init
    ) {
        self.fileManager = fileManager
        self.importCoordinator = importCoordinator
        self.dateProvider = dateProvider
    }

    public func attach(
        request: GATKBundleVariantAttachmentRequest
    ) async throws -> GATKBundleVariantAttachmentResult {
        let manifest = try BundleManifest.load(from: request.bundleURL)
        guard !manifest.variants.contains(where: { $0.id == request.outputTrackID }) else {
            throw GATKBundleVariantAttachmentError.duplicateTrackID(request.outputTrackID)
        }
        guard let alignmentTrack = manifest.alignments.first(where: { $0.id == request.alignmentTrackID }) else {
            throw GATKBundleVariantAttachmentError.missingAlignmentTrack(request.alignmentTrackID)
        }
        guard let genome = manifest.genome else {
            throw GATKBundleVariantAttachmentError.missingBundleGenome
        }
        guard fileManager.fileExists(atPath: request.outputVCFURL.path) else {
            throw GATKBundleVariantAttachmentError.missingOutputVCF(request.outputVCFURL.path)
        }

        let indexURL = try resolveIndexURL(for: request)
        let vcfRelativePath = try bundleRelativePath(for: request.outputVCFURL, in: request.bundleURL)
        let indexRelativePath = try bundleRelativePath(for: indexURL, in: request.bundleURL)
        let variantsDir = request.bundleURL.appendingPathComponent("variants/gatk", isDirectory: true)
        try fileManager.createDirectory(at: variantsDir, withIntermediateDirectories: true)

        let databaseRelativePath = "variants/gatk/\(request.outputTrackID).db"
        let provenanceRelativePath = "variants/gatk/\(request.outputTrackID).lungfish-provenance.json"
        let databaseURL = request.bundleURL.appendingPathComponent(databaseRelativePath)
        let provenanceURL = request.bundleURL.appendingPathComponent(provenanceRelativePath)
        let manifestURL = request.bundleURL.appendingPathComponent(BundleManifest.filename)
        let originalManifestData = try Data(contentsOf: manifestURL)
        var createdURLs: [URL] = []

        let importStartedAt = dateProvider()
        do {
            let importResult = try await importCoordinator.importNormalizedVCF(
                request: VariantSQLiteImportRequest(
                    normalizedVCFURL: request.outputVCFURL,
                    outputDatabaseURL: databaseURL,
                    sourceFile: request.outputVCFURL.lastPathComponent,
                    importProfile: request.importProfile,
                    importSemantics: .standard,
                    materializeVariantInfo: true
                )
            )
            createdURLs.append(databaseURL)

            let database = try VariantDatabase(url: databaseURL, readWrite: true)
            let chromosomeMapping = mapVCFChromosomes(
                database.allChromosomes(),
                toBundleChromosomes: genome.chromosomes
            )
            if !chromosomeMapping.isEmpty {
                try database.renameChromosomes(chromosomeMapping)
            }
            try database.setMetadataValues(
                metadata(
                    request: request,
                    alignmentTrack: alignmentTrack,
                    vcfRelativePath: vcfRelativePath,
                    indexRelativePath: indexRelativePath,
                    databaseRelativePath: databaseRelativePath,
                    provenanceRelativePath: provenanceRelativePath
                )
            )
            let variantCount = database.totalVariantCount()
            let trackInfo = VariantTrackInfo(
                id: request.outputTrackID,
                name: request.outputTrackName,
                description: "GATK HaplotypeCaller variants from \(alignmentTrack.name)",
                path: vcfRelativePath,
                indexPath: indexRelativePath,
                databasePath: databaseRelativePath,
                variantType: .mixed,
                variantCount: variantCount == 0 ? importResult.variantCount : variantCount,
                source: request.executionRequest.workflowName,
                version: request.executionRequest.toolVersion
            )

            let updatedManifest = manifest.addingVariantTrack(trackInfo)
            try updatedManifest.save(to: request.bundleURL)
            let importCompletedAt = dateProvider()
            try writeAttachmentProvenance(
                request: request,
                manifest: updatedManifest,
                alignmentTrack: alignmentTrack,
                vcfURL: request.outputVCFURL,
                indexURL: indexURL,
                databaseURL: databaseURL,
                provenanceURL: provenanceURL,
                importStartedAt: importStartedAt,
                importCompletedAt: importCompletedAt,
                variantCount: trackInfo.variantCount ?? importResult.variantCount
            )
            createdURLs.append(provenanceURL)

            return GATKBundleVariantAttachmentResult(
                trackInfo: trackInfo,
                databaseURL: databaseURL,
                indexURL: indexURL,
                provenanceURL: provenanceURL,
                variantCount: trackInfo.variantCount ?? importResult.variantCount
            )
        } catch {
            for url in createdURLs {
                try? fileManager.removeItem(at: url)
            }
            try? originalManifestData.write(to: manifestURL, options: .atomic)
            throw error
        }
    }

    private func resolveIndexURL(for request: GATKBundleVariantAttachmentRequest) throws -> URL {
        if let outputIndexURL = request.outputIndexURL {
            guard fileManager.fileExists(atPath: outputIndexURL.path) else {
                throw GATKBundleVariantAttachmentError.missingOutputIndex(outputIndexURL.path)
            }
            return outputIndexURL
        }

        let candidates = [
            request.outputVCFURL.appendingPathExtension("tbi"),
            request.outputVCFURL.appendingPathExtension("idx"),
            request.outputVCFURL.deletingPathExtension().appendingPathExtension("idx"),
        ]
        if let indexURL = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }) {
            return indexURL
        }
        throw GATKBundleVariantAttachmentError.missingOutputIndex(candidates[0].path)
    }

    private func bundleRelativePath(for url: URL, in bundleURL: URL) throws -> String {
        let bundlePath = bundleURL.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        let prefix = bundlePath.hasSuffix("/") ? bundlePath : "\(bundlePath)/"
        guard filePath.hasPrefix(prefix) else {
            throw GATKBundleVariantAttachmentError.outputOutsideBundle(filePath)
        }
        return String(filePath.dropFirst(prefix.count))
    }

    private func metadata(
        request: GATKBundleVariantAttachmentRequest,
        alignmentTrack: AlignmentTrackInfo,
        vcfRelativePath: String,
        indexRelativePath: String,
        databaseRelativePath: String,
        provenanceRelativePath: String
    ) -> [String: String] {
        var values: [String: String] = [
            "variant_caller": request.executionRequest.toolName,
            "variant_caller_version": request.executionRequest.toolVersion,
            "variant_caller_command_line": request.executionRequest.commands.map(\.shellCommand).joined(separator: " && "),
            "source_alignment_track_id": alignmentTrack.id,
            "source_alignment_track_name": alignmentTrack.name,
            "source_alignment_relative_path": alignmentTrack.sourcePath,
            "artifact_vcf_path": vcfRelativePath,
            "artifact_index_path": indexRelativePath,
            "artifact_database_path": databaseRelativePath,
            "workflow_provenance_path": provenanceRelativePath,
            "call_semantics": VCFImportSemantics.standard.rawValue,
        ]
        if let checksum = alignmentTrack.checksumSHA256 {
            values["source_alignment_checksum_sha256"] = checksum
        }
        if let executionProvenanceURL = request.executionProvenanceURL {
            values["source_execution_provenance"] = executionProvenanceURL.path
        }
        return values
    }

    private func writeAttachmentProvenance(
        request: GATKBundleVariantAttachmentRequest,
        manifest: BundleManifest,
        alignmentTrack: AlignmentTrackInfo,
        vcfURL: URL,
        indexURL: URL,
        databaseURL: URL,
        provenanceURL: URL,
        importStartedAt: Date,
        importCompletedAt: Date,
        variantCount: Int
    ) throws {
        let manifestURL = request.bundleURL.appendingPathComponent(BundleManifest.filename)
        var inputs = [
            ProvenanceRecorder.fileRecord(url: vcfURL, format: .vcf, role: .input),
            ProvenanceRecorder.fileRecord(url: indexURL, role: .index),
        ]
        if let executionProvenanceURL = request.executionProvenanceURL,
           fileManager.fileExists(atPath: executionProvenanceURL.path) {
            inputs.append(ProvenanceRecorder.fileRecord(url: executionProvenanceURL, format: .json, role: .input))
        }

        let command = [
            "lungfish-app",
            "gatk-attach",
            "--bundle", request.bundleURL.path,
            "--alignment-track", request.alignmentTrackID,
            "--vcf", vcfURL.path,
            "--output-track", request.outputTrackID,
            "--name", request.outputTrackName,
            "--import-semantics", VCFImportSemantics.standard.rawValue,
            "--import-profile", request.importProfile.rawValue,
        ]
        let step = StepExecution(
            toolName: "lungfish gatk bundle attach",
            toolVersion: WorkflowRun.currentAppVersion,
            command: command,
            inputs: inputs,
            outputs: [
                ProvenanceRecorder.fileRecord(url: vcfURL, format: .vcf, role: .output),
                ProvenanceRecorder.fileRecord(url: indexURL, role: .index),
                ProvenanceRecorder.fileRecord(url: databaseURL, format: .unknown, role: .output),
                ProvenanceRecorder.fileRecord(url: manifestURL, format: .json, role: .output),
            ],
            exitCode: 0,
            wallTime: importCompletedAt.timeIntervalSince(importStartedAt),
            stderr: nil,
            startTime: importStartedAt,
            endTime: importCompletedAt
        )

        var parameters: [String: ParameterValue] = [
            "bundlePath": .string(request.bundleURL.path),
            "bundleIdentifier": .string(manifest.identifier),
            "bundleName": .string(manifest.name),
            "alignmentTrackID": .string(alignmentTrack.id),
            "alignmentTrackName": .string(alignmentTrack.name),
            "outputTrackID": .string(request.outputTrackID),
            "outputTrackName": .string(request.outputTrackName),
            "variantCaller": .string(request.executionRequest.toolName),
            "variantCallerVersion": .string(request.executionRequest.toolVersion),
            "variantCount": .integer(variantCount),
            "importProfile": .string(request.importProfile.rawValue),
            "importSemantics": .string(VCFImportSemantics.standard.rawValue),
            "shellCommand": .string(request.executionRequest.commands.map(\.shellCommand).joined(separator: " && ")),
        ]
        if let condaEnvironment = request.executionRequest.runtimeIdentity.condaEnvironment {
            parameters["condaEnvironment"] = .string(condaEnvironment)
        }
        if let executionProvenanceURL = request.executionProvenanceURL {
            parameters["sourceExecutionProvenance"] = .string(executionProvenanceURL.path)
        }
        for (key, value) in request.executionRequest.options {
            parameters["option.\(key)"] = .string(value)
        }
        for (key, value) in request.executionRequest.resolvedDefaults {
            parameters["default.\(key)"] = .string(value)
        }

        let run = WorkflowRun(
            name: "GATK HaplotypeCaller bundle attachment",
            startTime: importStartedAt,
            endTime: importCompletedAt,
            status: .completed,
            steps: [step],
            parameters: parameters
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(run).write(to: provenanceURL, options: .atomic)
    }
}
