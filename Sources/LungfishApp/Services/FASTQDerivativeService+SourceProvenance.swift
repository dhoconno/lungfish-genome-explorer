// FASTQDerivativeService+SourceProvenance.swift - The source files a dashboard derivative records
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

// MARK: - Source provenance

extension FASTQDerivativeService {

    /// The durable record of the source the derivative read: a single-file
    /// bundle's file, a full derivative's payload, or the bundle itself with
    /// a checksum over every file it holds, which is what a bundle that holds
    /// several files (an ONT import) or a virtual derivative amounts to. The
    /// first file alone used to stand for a multi-file bundle (R8, lane 1x).
    func durableSourceInputRecord(
        for sourceBundleURL: URL,
        sequenceFormat: SequenceFormat
    ) throws -> FileRecord {
        if !FASTQBundle.isDerivedBundle(sourceBundleURL),
           !sourceBundleHoldsSeveralFiles(sourceBundleURL),
           let primaryURL = FASTQBundle.resolvePrimarySequenceURL(for: sourceBundleURL) {
            return ProvenanceRecorder.fileRecord(
                url: primaryURL,
                format: provenanceFileFormat(for: sequenceFormat),
                role: .input
            )
        }

        if let manifest = FASTQBundle.loadDerivedManifest(in: sourceBundleURL) {
            switch manifest.payload {
            case .full(let fastqFilename):
                if let payloadURL = try? FASTQBundle.validatedBundleMemberURL(
                    for: fastqFilename,
                    in: sourceBundleURL,
                    field: "payload.full.fastqFilename"
                ), FileManager.default.fileExists(atPath: payloadURL.path) {
                    return ProvenanceRecorder.fileRecord(url: payloadURL, format: .fastq, role: .input)
                }
            case .fullFASTA(let fastaFilename):
                if let payloadURL = try? FASTQBundle.validatedBundleMemberURL(
                    for: fastaFilename,
                    in: sourceBundleURL,
                    field: "payload.fullFASTA.fastaFilename"
                ), FileManager.default.fileExists(atPath: payloadURL.path) {
                    return ProvenanceRecorder.fileRecord(url: payloadURL, format: .fasta, role: .input)
                }
            default:
                break
            }
        }

        return try durableBundleInputRecord(
            for: sourceBundleURL,
            format: provenanceFileFormat(for: sequenceFormat)
        )
    }

    /// Whether a physical bundle lists several files in `source-files.json`.
    func sourceBundleHoldsSeveralFiles(_ bundleURL: URL) -> Bool {
        FASTQBundle.isMultiFileBundle(bundleURL)
            && (FASTQBundle.resolveAllFASTQURLs(for: bundleURL)?.count ?? 0) > 1
    }

    /// Every root file the derivative read, each with the bundle it belongs
    /// to as its origin (R8): the members of a physical bundle, the payload
    /// files of a full derivative, or the root bundle's files of a virtual
    /// one, resolved as the materializer resolves them
    /// (`FASTQBundle.rootSequenceURLs`).
    func derivativeRootFileDescriptors(for sourceBundleURL: URL) throws -> [ProvenanceFileDescriptor] {
        var fileURLs: [URL] = []
        var originURL = sourceBundleURL
        if let manifest = FASTQBundle.loadDerivedManifest(in: sourceBundleURL) {
            switch manifest.payload {
            case .full, .fullFASTA, .fullPaired, .fullMixed:
                fileURLs = derivativePayloadURLs(in: sourceBundleURL, manifest: manifest)
            case .demuxGroup:
                fileURLs = []
            case .subset, .trim, .demuxedVirtual, .orientMap:
                let rootBundleURL = FASTQBundle.resolveBundle(
                    relativePath: manifest.rootBundleRelativePath,
                    from: sourceBundleURL
                )
                originURL = rootBundleURL
                fileURLs = (try? FASTQBundle.rootSequenceURLs(
                    rootFASTQFilename: manifest.rootFASTQFilename,
                    in: rootBundleURL
                )) ?? []
            }
        } else {
            fileURLs = FASTQBundle.resolveAllFASTQURLs(for: sourceBundleURL) ?? []
        }
        let fm = FileManager.default
        return try fileURLs
            .filter { fm.fileExists(atPath: $0.path) }
            .map { url in
                let format: FileFormat
                switch SequenceFormat.from(url: url) {
                case .fasta: format = .fasta
                case .fastq: format = .fastq
                case .none: format = .unknown
                }
                return try ProvenanceFileDescriptor.file(
                    url: url,
                    format: format,
                    role: .input,
                    originPath: originURL.standardizedFileURL.path
                )
            }
    }

    func durableBundleInputRecord(for bundleURL: URL, format: FileFormat) throws -> FileRecord {
        let manifest = try ProvenanceFileHasher.directoryManifest(for: bundleURL, role: .input)
        let sizeBytes = manifest.files.reduce(UInt64(0)) { partial, descriptor in
            partial + (descriptor.fileSize ?? 0)
        }
        let digestInput = manifest.files
            .map { descriptor in
                [
                    descriptor.path,
                    descriptor.checksumSHA256 ?? "",
                    String(descriptor.fileSize ?? 0),
                ].joined(separator: "\t")
            }
            .joined(separator: "\n")
        let digest = SHA256.hash(data: Data(digestInput.utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        return FileRecord(
            path: bundleURL.path,
            sha256: digest,
            sizeBytes: sizeBytes,
            format: format,
            role: .input
        )
    }

    func provenanceFileFormat(for sequenceFormat: SequenceFormat) -> FileFormat {
        switch sequenceFormat {
        case .fasta:
            return .fasta
        case .fastq:
            return .fastq
        }
    }

    /// The step that wrote the source's execution file for the run: a `cat`
    /// of a multi-file bundle's members, or a `lungfish-cli fastq
    /// materialize` of a virtual bundle, as `lungfish-cli` records the same
    /// step for its own runs. Empty when the source was read in place or the
    /// file is unknown (R8, lane 1x).
    func sourceMaterializationSteps(
        sourceBundleURL: URL,
        replayContext: FASTQDerivativeNativeReplayContext,
        startedAt: Date,
        completedAt: Date
    ) -> [ProvenanceStep] {
        guard let sourceExecutionURL = replayContext.sourceExecutionURL,
              FileManager.default.fileExists(atPath: sourceExecutionURL.path) else {
            return []
        }
        let steps = (try? CLISequenceInputMaterialization.materializationProvenanceSteps(
            workflowVersion: WorkflowRun.currentAppVersion,
            originalInputURLs: [sourceBundleURL],
            executionInputURLs: [sourceExecutionURL],
            startedAt: startedAt,
            endedAt: completedAt
        )) ?? []
        // The file the step wrote sits in the run's temporary folder, so the
        // step gets no durable replay and no output record, as a native step
        // that read a temporary file gets none. Its argv keeps the paths it
        // ran with and its inputs name every file it read.
        return steps.map { step in
            ProvenanceStep(
                id: step.id,
                toolName: step.toolName,
                toolVersion: step.toolVersion,
                githubReleaseVersion: step.githubReleaseVersion,
                argv: step.argv,
                durableReplayArgv: nil,
                reproducibleCommand: "",
                resolvedOptions: step.resolvedOptions,
                runtimeIdentity: step.runtimeIdentity,
                inputs: step.inputs,
                outputs: [],
                exitStatus: step.exitStatus,
                wallTimeSeconds: step.wallTimeSeconds,
                peakMemoryBytes: step.peakMemoryBytes,
                stderr: step.stderr,
                dependsOn: step.dependsOn,
                startedAt: step.startedAt,
                completedAt: step.completedAt
            )
        }
    }
}
