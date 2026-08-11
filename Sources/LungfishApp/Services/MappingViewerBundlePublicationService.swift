import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

enum MappingViewerBundlePublicationError: Error, LocalizedError {
    case missingCanonicalProvenance(URL)
    case missingViewerBundle(URL)
    case invalidViewerPayloadPath(String)
    case missingViewerPayload(URL)
    case rollbackFailed(URL, String)

    var errorDescription: String? {
        switch self {
        case .missingCanonicalProvenance(let url):
            return "Canonical mapping provenance is missing at \(url.path)."
        case .missingViewerBundle(let url):
            return "The prepared mapping viewer bundle is missing at \(url.path)."
        case .invalidViewerPayloadPath(let path):
            return "The mapping viewer bundle declares an unsafe payload path: \(path)."
        case .missingViewerPayload(let url):
            return "The mapping viewer bundle payload is missing at \(url.path)."
        case .rollbackFailed(let url, let detail):
            return "Could not restore \(url.lastPathComponent) after mapping viewer publication failed: \(detail)"
        }
    }
}

enum MappingViewerBundlePublicationService {
    private static let mappingResultFilename = "mapping-result.json"

    static func publish(
        result: MappingResult,
        resultDirectoryURL: URL,
        sourceReferenceBundleURL: URL,
        viewerBundleURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let resultDirectory = resultDirectoryURL.standardizedFileURL
        let sourceBundle = sourceReferenceBundleURL.standardizedFileURL
        let viewerBundle = viewerBundleURL.standardizedFileURL
        let mappingResultURL = resultDirectory.appendingPathComponent(mappingResultFilename)
        let mappingProvenanceURL = resultDirectory.appendingPathComponent(MappingProvenance.filename)
        let canonicalProvenanceURL = resultDirectory.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        let snapshots = try [mappingResultURL, mappingProvenanceURL, canonicalProvenanceURL].map {
            SidecarSnapshot(url: $0, data: fileManager.fileExists(atPath: $0.path) ? try Data(contentsOf: $0) : nil)
        }

        do {
            try result.save(to: resultDirectory)
            if let provenance = MappingProvenance.load(from: resultDirectory) {
                try provenance
                    .withViewerBundleURL(viewerBundle)
                    .withSourceReferenceBundleURL(sourceBundle)
                    .save(to: resultDirectory)
            }
            try rewriteCanonicalProvenance(
                result: result,
                resultDirectoryURL: resultDirectory,
                sourceReferenceBundleURL: sourceBundle,
                viewerBundleURL: viewerBundle,
                fileManager: fileManager
            )
        } catch {
            do {
                try restore(snapshots, fileManager: fileManager)
            } catch let rollbackError {
                throw MappingViewerBundlePublicationError.rollbackFailed(
                    resultDirectory,
                    rollbackError.localizedDescription
                )
            }
            throw error
        }
    }

    private static func rewriteCanonicalProvenance(
        result: MappingResult,
        resultDirectoryURL: URL,
        sourceReferenceBundleURL: URL,
        viewerBundleURL: URL,
        fileManager: FileManager
    ) throws {
        let canonicalURL = resultDirectoryURL.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        guard let envelope = try ProvenanceEnvelopeReader.load(from: resultDirectoryURL) else {
            throw MappingViewerBundlePublicationError.missingCanonicalProvenance(canonicalURL)
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: viewerBundleURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw MappingViewerBundlePublicationError.missingViewerBundle(viewerBundleURL)
        }

        let mappingResultURL = resultDirectoryURL.appendingPathComponent(mappingResultFilename)
        let mappingResultDescriptor = try ProvenanceFileDescriptor.file(
            url: mappingResultURL,
            format: .json,
            role: .output
        )
        let viewerDescriptors = try viewerOutputDescriptors(
            viewerBundleURL: viewerBundleURL,
            fileManager: fileManager
        )
        let publicationOutputs = deduplicated([mappingResultDescriptor] + viewerDescriptors)
        let refreshedFiles = try envelope.files.map {
            try refreshedMappingResultDescriptor($0, mappingResultURL: mappingResultURL)
        }
        let refreshedOutputs = try envelope.outputs.map {
            try refreshedMappingResultDescriptor($0, mappingResultURL: mappingResultURL)
        }
        let refreshedPrimaryOutput = try envelope.output.map {
            try refreshedMappingResultDescriptor($0, mappingResultURL: mappingResultURL)
        }
        let refreshedSteps = try envelope.steps.map { step in
            ProvenanceStep(
                id: step.id,
                toolName: step.toolName,
                toolVersion: step.toolVersion,
                githubReleaseVersion: step.githubReleaseVersion,
                argv: step.argv,
                durableReplayArgv: step.durableReplayArgv,
                reproducibleCommand: step.reproducibleCommand,
                resolvedOptions: step.resolvedOptions,
                runtimeIdentity: step.runtimeIdentity,
                inputs: step.inputs,
                outputs: try step.outputs.map {
                    try refreshedMappingResultDescriptor($0, mappingResultURL: mappingResultURL)
                },
                exitStatus: step.exitStatus,
                wallTimeSeconds: step.wallTimeSeconds,
                peakMemoryBytes: step.peakMemoryBytes,
                stderr: step.stderr,
                dependsOn: step.dependsOn,
                startedAt: step.startedAt,
                completedAt: step.completedAt
            )
        }

        let argv = [
            "Lungfish.app",
            "prepare-mapping-viewer-bundle",
            "--mapping-result", resultDirectoryURL.path,
            "--source-reference-bundle", sourceReferenceBundleURL.path,
            "--viewer-bundle", viewerBundleURL.path,
        ]
        let inputs = try sourceInputDescriptors(
            sourceBundleURL: sourceReferenceBundleURL,
            fileManager: fileManager
        ) + [
            try ProvenanceFileDescriptor.file(url: result.bamURL, format: .bam, role: .input),
            try ProvenanceFileDescriptor.file(url: result.baiURL, format: .unknown, role: .index),
        ]
        let publicationStep = ProvenanceStep(
            toolName: "Lungfish.app",
            toolVersion: WorkflowRun.currentAppVersion,
            argv: argv,
            durableReplayArgv: argv,
            resolvedOptions: [
                "mappingResult": .file(resultDirectoryURL),
                "sourceReferenceBundle": .file(sourceReferenceBundleURL),
                "viewerBundle": .file(viewerBundleURL),
            ],
            runtimeIdentity: ProvenanceRuntimeIdentity(),
            inputs: inputs,
            outputs: publicationOutputs,
            exitStatus: 0,
            dependsOn: refreshedSteps.last.map { [$0.id] } ?? []
        )
        let updatedOptions = ProvenanceOptions(
            explicit: envelope.options.explicit,
            defaults: envelope.options.defaults,
            resolvedDefaults: envelope.options.resolvedDefaults.merging([
                "sourceReferenceBundle": .file(sourceReferenceBundleURL),
                "viewerBundle": .file(viewerBundleURL),
            ]) { _, finalValue in finalValue }
        )
        let updatedEnvelope = ProvenanceEnvelope(
            schemaVersion: envelope.schemaVersion,
            id: envelope.id,
            createdAt: envelope.createdAt,
            workflowName: envelope.workflowName,
            workflowVersion: envelope.workflowVersion,
            toolName: envelope.toolName,
            toolVersion: envelope.toolVersion,
            githubReleaseVersion: envelope.githubReleaseVersion,
            tool: envelope.tool,
            argv: envelope.argv,
            durableReplayArgv: envelope.durableReplayArgv,
            reproducibleCommand: envelope.reproducibleCommand,
            options: updatedOptions,
            runtimeIdentity: envelope.runtimeIdentity,
            files: deduplicated(refreshedFiles + inputs + publicationOutputs),
            output: refreshedPrimaryOutput,
            outputs: deduplicated(refreshedOutputs + publicationOutputs),
            steps: refreshedSteps + [publicationStep],
            wallTimeSeconds: envelope.wallTimeSeconds,
            exitStatus: envelope.exitStatus,
            stderr: envelope.stderr,
            signatures: [],
            legacyWorkflowRun: nil
        )

        try ProvenanceWriter(signingProvider: nil).write(updatedEnvelope, to: resultDirectoryURL)
    }

    private static func sourceInputDescriptors(
        sourceBundleURL: URL,
        fileManager: FileManager
    ) throws -> [ProvenanceFileDescriptor] {
        let manifestURL = sourceBundleURL.appendingPathComponent(BundleManifest.filename)
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw MappingViewerBundlePublicationError.missingViewerPayload(manifestURL)
        }
        let manifest = try BundleManifest.load(from: sourceBundleURL)
        var descriptors = [
            ProvenanceFileDescriptor(path: sourceBundleURL.path, role: .reference),
            try ProvenanceFileDescriptor.file(url: manifestURL, format: .json, role: .reference),
        ]
        if let genome = manifest.genome {
            descriptors.append(try descriptor(
                relativePath: genome.path,
                format: .fasta,
                role: .reference,
                bundleURL: sourceBundleURL,
                fileManager: fileManager
            ))
            if !genome.indexPath.isEmpty {
                descriptors.append(try descriptor(
                    relativePath: genome.indexPath,
                    format: .unknown,
                    role: .index,
                    bundleURL: sourceBundleURL,
                    fileManager: fileManager
                ))
            }
            if let gzipIndexPath = genome.gzipIndexPath, !gzipIndexPath.isEmpty {
                descriptors.append(try descriptor(
                    relativePath: gzipIndexPath,
                    format: .unknown,
                    role: .index,
                    bundleURL: sourceBundleURL,
                    fileManager: fileManager
                ))
            }
        }
        return deduplicated(descriptors)
    }

    private static func viewerOutputDescriptors(
        viewerBundleURL: URL,
        fileManager: FileManager
    ) throws -> [ProvenanceFileDescriptor] {
        let manifestURL = viewerBundleURL.appendingPathComponent("manifest.json")
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw MappingViewerBundlePublicationError.missingViewerPayload(manifestURL)
        }
        let manifest = try BundleManifest.load(from: viewerBundleURL)
        var descriptors = [
            ProvenanceFileDescriptor(path: viewerBundleURL.path, role: .output),
            try ProvenanceFileDescriptor.file(url: manifestURL, format: .json, role: .output),
        ]
        for track in manifest.alignments {
            descriptors.append(try descriptor(
                relativePath: track.sourcePath,
                format: track.format == .cram ? .cram : .bam,
                role: .output,
                bundleURL: viewerBundleURL,
                fileManager: fileManager
            ))
            if !track.indexPath.isEmpty {
                descriptors.append(try descriptor(
                    relativePath: track.indexPath,
                    format: .unknown,
                    role: .index,
                    bundleURL: viewerBundleURL,
                    fileManager: fileManager
                ))
            }
            if let metadataPath = track.metadataDBPath {
                descriptors.append(try descriptor(
                    relativePath: metadataPath,
                    format: .sqlite,
                    role: .output,
                    bundleURL: viewerBundleURL,
                    fileManager: fileManager
                ))
            }
        }
        return deduplicated(descriptors)
    }

    private static func descriptor(
        relativePath: String,
        format: FileFormat,
        role: FileRole,
        bundleURL: URL,
        fileManager: FileManager
    ) throws -> ProvenanceFileDescriptor {
        let root = bundleURL.standardizedFileURL
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
        guard candidate.pathComponents.count > root.pathComponents.count,
              candidate.pathComponents.starts(with: root.pathComponents) else {
            throw MappingViewerBundlePublicationError.invalidViewerPayloadPath(relativePath)
        }
        guard fileManager.fileExists(atPath: candidate.path) else {
            throw MappingViewerBundlePublicationError.missingViewerPayload(candidate)
        }
        return try ProvenanceFileDescriptor.file(url: candidate, format: format, role: role)
    }

    private static func refreshedMappingResultDescriptor(
        _ descriptor: ProvenanceFileDescriptor,
        mappingResultURL: URL
    ) throws -> ProvenanceFileDescriptor {
        guard URL(fileURLWithPath: descriptor.path).standardizedFileURL == mappingResultURL.standardizedFileURL else {
            return descriptor
        }
        return try ProvenanceFileDescriptor.file(
            url: mappingResultURL,
            format: descriptor.format ?? .json,
            role: descriptor.role,
            originPath: descriptor.originPath,
            sourceProvenancePath: descriptor.sourceProvenancePath
        )
    }

    private static func deduplicated(
        _ descriptors: [ProvenanceFileDescriptor]
    ) -> [ProvenanceFileDescriptor] {
        var seen: Set<String> = []
        return descriptors.filter { seen.insert($0.path).inserted }
    }

    private static func restore(
        _ snapshots: [SidecarSnapshot],
        fileManager: FileManager
    ) throws {
        for snapshot in snapshots {
            if let data = snapshot.data {
                try data.write(to: snapshot.url, options: .atomic)
            } else if fileManager.fileExists(atPath: snapshot.url.path) {
                try fileManager.removeItem(at: snapshot.url)
            }
        }
    }

    private struct SidecarSnapshot {
        let url: URL
        let data: Data?
    }
}
