// BAMImportService+Provenance.swift - The import record BAMImportService writes beside an attached alignment
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

/// The canonical provenance record of a BAM import, with its argv and its explicit options. It lives apart
/// from BAMImportService.swift, which sat at the 800-line limit of scripts/ratchets/file-size.sh.
extension BAMImportService {
    static func writeImportProvenance(
        bamURL: URL,
        bundleURL: URL,
        trackId: String,
        trackName: String,
        sourceFormat: AlignmentFormat,
        outputFormat: AlignmentFormat,
        alignmentURL: URL,
        indexURL: URL,
        metadataDBURL: URL,
        provenanceURL: URL,
        metadataDBRelativePath: String,
        sourceRelativePath: String,
        indexRelativePath: String,
        provenanceRelativePath: String,
        indexWasCreated: Bool,
        wasSorted: Bool,
        sortInvocation: TimedNativeToolResult?,
        indexInvocation: TimedNativeToolResult?,
        cloneStartedAt: Date? = nil,
        cloneCompletedAt: Date? = nil,
        startedAt: Date,
        completedAt: Date,
        explicitTrackName: String?,
        provenanceCommand: [String]?
    ) throws {
        let appVersion = WorkflowRun.currentAppVersion
        let argv = provenanceCommand ?? importProvenanceArgv(bamURL: bamURL, bundleURL: bundleURL, name: explicitTrackName)
        let input = try ProvenanceFileDescriptor.file(
            url: bamURL,
            format: fileFormat(for: sourceFormat),
            role: .input
        )
        let alignmentOutput = try ProvenanceFileDescriptor.file(
            url: alignmentURL,
            format: fileFormat(for: outputFormat),
            role: .output,
            originPath: bamURL.path
        )
        let indexOutput = try ProvenanceFileDescriptor.file(url: indexURL, role: .index)
        let metadataOutput = try ProvenanceFileDescriptor.file(url: metadataDBURL, format: .unknown, role: .output)

        var files = [input, alignmentOutput, indexOutput, metadataOutput]
        var referenceInputs: [ProvenanceFileDescriptor] = []
        if let referencePath = findReferenceFASTA(in: bundleURL) {
            let reference = try ProvenanceFileDescriptor.file(
                url: URL(fileURLWithPath: referencePath),
                format: .fasta,
                role: .reference
            )
            files.append(reference)
            referenceInputs.append(reference)
        }

        // Either samtools sorted and indexed the copy, or the copy is a clone
        // of an already sorted, indexed source (a mapping run's own BAM).
        var materializationSteps: [ProvenanceStep] = []
        if let sortInvocation, let indexInvocation {
            materializationSteps.append(ProvenanceStep(
                toolName: "samtools",
                toolVersion: "unknown",
                argv: sortInvocation.result.arguments,
                inputs: [input] + referenceInputs,
                outputs: [alignmentOutput],
                exitStatus: Int(sortInvocation.result.exitCode),
                wallTimeSeconds: sortInvocation.wallTimeSeconds,
                stderr: nonEmpty(sortInvocation.result.stderr),
                startedAt: sortInvocation.startedAt,
                completedAt: sortInvocation.completedAt
            ))
            materializationSteps.append(ProvenanceStep(
                toolName: "samtools",
                toolVersion: "unknown",
                argv: indexInvocation.result.arguments,
                inputs: [alignmentOutput] + referenceInputs,
                outputs: [indexOutput],
                exitStatus: Int(indexInvocation.result.exitCode),
                wallTimeSeconds: indexInvocation.wallTimeSeconds,
                stderr: nonEmpty(indexInvocation.result.stderr),
                startedAt: indexInvocation.startedAt,
                completedAt: indexInvocation.completedAt
            ))
        } else {
            materializationSteps.append(ProvenanceStep(
                toolName: "Lungfish.app",
                toolVersion: appVersion,
                argv: argv + ["--clone-sorted-alignment"],
                inputs: [input],
                outputs: [alignmentOutput, indexOutput],
                exitStatus: 0,
                wallTimeSeconds: cloneStartedAt.flatMap { start in cloneCompletedAt?.timeIntervalSince(start) },
                stderr: nil,
                startedAt: cloneStartedAt ?? startedAt,
                completedAt: cloneCompletedAt ?? completedAt
            ))
        }
        let metadataStep = ProvenanceStep(
            toolName: "Lungfish.app",
            toolVersion: appVersion,
            argv: argv + ["--collect-alignment-metadata", "--metadata-db", metadataDBURL.path],
            inputs: [alignmentOutput, indexOutput],
            outputs: [metadataOutput],
            exitStatus: 0,
            wallTimeSeconds: nil,
            stderr: nil
        )

        let envelope = ProvenanceEnvelope(
            createdAt: startedAt,
            workflowName: "lungfish app bam import",
            workflowVersion: appVersion,
            toolName: "Lungfish.app",
            toolVersion: appVersion,
            argv: argv,
            durableReplayArgv: argv,
            options: ProvenanceOptions(
                explicit: explicitOptions(
                    bamURL: bamURL,
                    bundleURL: bundleURL,
                    explicitTrackName: explicitTrackName
                ),
                defaults: [
                    "name": .string(bamURL.deletingPathExtension().lastPathComponent),
                    "sort": .boolean(wasSorted),
                    "index": .boolean(indexWasCreated),
                    "outputDirectory": .string("alignments"),
                ],
                resolvedDefaults: [
                    "trackId": .string(trackId),
                    "trackName": .string(trackName),
                    "sourceFormat": .string(sourceFormat.rawValue),
                    "outputFormat": .string(outputFormat.rawValue),
                    "sourcePathInBundle": .string(sourceRelativePath),
                    "indexPathInBundle": .string(indexRelativePath),
                    "metadataDBPath": .string(metadataDBRelativePath),
                    "importProvenancePath": .string(provenanceRelativePath),
                    "indexWasCreated": .boolean(indexWasCreated),
                    "wasSorted": .boolean(wasSorted),
                ]
            ),
            runtimeIdentity: ProvenanceRuntimeIdentity(),
            files: files,
            output: alignmentOutput,
            outputs: [alignmentOutput, indexOutput, metadataOutput],
            steps: materializationSteps + [metadataStep],
            wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
            exitStatus: 0,
            stderr: nonEmpty(
                [sortInvocation?.result.stderr, indexInvocation?.result.stderr]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
            )
        )
        try ProvenanceWriter().write(envelope, toSidecar: provenanceURL)
    }

    /// The command a record names when the caller passes none, the `import bam` leaf that attaches the same file to
    /// the same bundle (Phase 2.12 lane 12.06, BIO 4). Records written before 2.12 name the app's retired
    /// `--bam-import-helper` re-launch instead. They keep it as history, and the export plan does not replay it.
    /// A caller that imports into a staging bundle has the staged path remapped at publication, as the mapping
    /// viewer does (`MappingViewerBundlePublicationService.remappedEnvelope`). The record's two in-app steps append
    /// marker flags to this argv (`--clone-sorted-alignment` and `--collect-alignment-metadata`), which no command
    /// accepts, and `ProvenanceExportPlan.inAppMarkerFlags` reads them so that no export replays those steps.
    private static func importProvenanceArgv(bamURL: URL, bundleURL: URL, name: String?) -> [String] {
        var argv = [CLICommandIdentity.executableName, "import", "bam", bamURL.path, "--output-dir", bundleURL.path]
        if let name {
            argv += ["--name", name]
        }
        return argv
    }

    private static func explicitOptions(
        bamURL: URL,
        bundleURL: URL,
        explicitTrackName: String?
    ) -> [String: ParameterValue] {
        var options: [String: ParameterValue] = [
            "bamPath": .file(bamURL),
            "bundlePath": .file(bundleURL),
        ]
        if let explicitTrackName {
            options["name"] = .string(explicitTrackName)
        }
        return options
    }

    private static func fileFormat(for format: AlignmentFormat) -> FileFormat {
        switch format {
        case .bam: return .bam
        case .cram: return .cram
        case .sam: return .sam
        }
    }

    private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : value
    }
}
