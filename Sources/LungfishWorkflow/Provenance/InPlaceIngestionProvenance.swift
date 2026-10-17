// InPlaceIngestionProvenance.swift - Merges an in-place FASTQ ingestion into the folder's provenance record
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Reads the provenance record that stands in the folder of a FASTQ file and merges an in-place
/// ingestion into it, so the ingestion keeps the file's earlier history (a download or an import)
/// and adds its own steps after it (Phase 2.10 lane A47 M3, ruling section 1).
///
/// `lungfish-cli fastq ingest` merges through it, and the app's sample sheet append uses its
/// `combinedWallTime`. A merge keeps the old record's identity, status and exit status, so a record
/// of a run that did not complete is never merged into.
package enum InPlaceIngestionProvenance {
    nonisolated package static func existingInPlaceIngestionProvenance(
        outputDirectory: URL,
        inputFiles: [URL]
    ) throws -> (envelope: ProvenanceEnvelope, sourceURL: URL?)? {
        let rootProvenanceURL = outputDirectory.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        if let envelope = try ProvenanceEnvelopeReader.load(fromSidecar: rootProvenanceURL) {
            return (envelope, rootProvenanceURL)
        }

        var candidates: [URL] = []
        for inputFile in inputFiles {
            candidates.append(ProvenanceRecorder.fileSidecarURL(for: inputFile))
            if let bundleSidecarURL = ProvenanceWriter.bundleOutputSidecarURL(for: inputFile, inBundle: outputDirectory) {
                candidates.append(bundleSidecarURL)
            }
        }

        var seen = Set<String>()
        for candidate in candidates where seen.insert(candidate.standardizedFileURL.path).inserted {
            guard let envelope = try ProvenanceEnvelopeReader.load(fromSidecar: candidate) else {
                continue
            }
            return (envelope, candidate)
        }
        return nil
    }

    nonisolated package static func mergedInPlaceIngestionEnvelope(
        existingEnvelope: ProvenanceEnvelope,
        sourceProvenanceURL: URL?,
        ingestionEnvelope: ProvenanceEnvelope,
        replacedInputFiles: [URL],
        finalFASTQURL: URL,
        finalFASTQDescriptor: ProvenanceFileDescriptor? = nil
    ) throws -> ProvenanceEnvelope {
        let pathMap = replacedOutputPathMap(
            in: existingEnvelope,
            replacedInputFiles: replacedInputFiles,
            finalFASTQURL: finalFASTQURL
        )
        // A caller that read the final file's digest already passes it, and the path rewrite takes it in place of
        // a new hash of a file that may be large (review A47 fix 6 (e)). The CLI leaf is the one caller and passes it.
        let rewrittenExisting = pathMap.isEmpty
            ? existingEnvelope
            : try GUIImportedProvenanceRehydrator.rewriteOutputDescriptors(
                in: existingEnvelope,
                pathMap: pathMap,
                sourceProvenancePath: sourceProvenanceURL?.path,
                finalDescriptor: finalFASTQDescriptor
            )
        let output = ingestionEnvelope.output ?? rewrittenExisting.output
        let outputs = deduplicatedProvenanceFiles(rewrittenExisting.outputs + ingestionEnvelope.outputs)
        let files = deduplicatedProvenanceFiles(rewrittenExisting.files + ingestionEnvelope.files)
        let options = ProvenanceOptions(
            explicit: rewrittenExisting.options.explicit.merging(ingestionEnvelope.options.explicit) { _, ingestion in
                ingestion
            },
            defaults: rewrittenExisting.options.defaults.merging(ingestionEnvelope.options.defaults) { _, ingestion in
                ingestion
            },
            resolvedDefaults: rewrittenExisting.options.resolvedDefaults.merging(
                ingestionEnvelope.options.resolvedDefaults
            ) { _, ingestion in
                ingestion
            }
        )

        return rewrittenExisting.with {
            $0.options = options
            $0.files = files
            $0.output = output
            $0.outputs = outputs
            $0.steps = rewrittenExisting.steps + ingestionEnvelope.steps
            $0.wallTimeSeconds = combinedWallTime(rewrittenExisting.wallTimeSeconds, ingestionEnvelope.wallTimeSeconds)
            // A record that did not complete keeps its own exit status, as the recorder's records do.
            $0.exitStatus = rewrittenExisting.status != .completed
                ? rewrittenExisting.exitStatus
                : (ingestionEnvelope.exitStatus ?? rewrittenExisting.exitStatus)
            $0.stderr = ingestionEnvelope.stderr ?? rewrittenExisting.stderr
        }
    }

    nonisolated private static func replacedOutputPathMap(
        in envelope: ProvenanceEnvelope,
        replacedInputFiles: [URL],
        finalFASTQURL: URL
    ) -> [String: String] {
        let finalPath = finalFASTQURL.standardizedFileURL.path
        let replacedPaths = Set(replacedInputFiles.map { $0.standardizedFileURL.path })
        guard !replacedPaths.isEmpty else { return [:] }

        let outputDescriptors = ([envelope.output].compactMap { $0 })
            + envelope.outputs
            + envelope.files.filter { $0.role == .output }
            + envelope.steps.flatMap(\.outputs)
        var pathMap: [String: String] = [:]
        for descriptor in outputDescriptors {
            let standardizedPath = URL(fileURLWithPath: descriptor.path).standardizedFileURL.path
            guard replacedPaths.contains(standardizedPath), standardizedPath != finalPath else {
                continue
            }
            pathMap[descriptor.path] = finalPath
            pathMap[standardizedPath] = finalPath
        }
        return pathMap
    }

    nonisolated package static func combinedWallTime(
        _ existing: TimeInterval?,
        _ ingestion: TimeInterval?
    ) -> TimeInterval? {
        switch (existing, ingestion) {
        case (.some(let existing), .some(let ingestion)):
            return existing + ingestion
        case (.some(let existing), .none):
            return existing
        case (.none, .some(let ingestion)):
            return ingestion
        case (.none, .none):
            return nil
        }
    }

    nonisolated private static func deduplicatedProvenanceFiles(
        _ descriptors: [ProvenanceFileDescriptor]
    ) -> [ProvenanceFileDescriptor] {
        var seen = Set<String>()
        var result: [ProvenanceFileDescriptor] = []
        for descriptor in descriptors {
            let key = "\(descriptor.role.rawValue)\u{0}\(descriptor.path)"
            if seen.insert(key).inserted {
                result.append(descriptor)
            }
        }
        return result
    }
}
