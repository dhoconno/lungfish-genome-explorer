// ProvenanceRecorder+SidecarLookup.swift - Finds the canonical provenance sidecar that applies to a file or bundle
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

extension ProvenanceRecorder {

    /// Loads a canonical provenance envelope from a directory's sidecar file.
    ///
    /// - Parameter directory: Directory containing `.lungfish-provenance.json`
    /// - Returns: The decoded canonical envelope, or nil if no readable sidecar exists
    public static func loadEnvelope(from directory: URL) -> ProvenanceEnvelope? {
        try? ProvenanceEnvelopeReader.load(from: directory)
    }

    /// Loads a canonical provenance envelope from a specific sidecar file.
    ///
    /// File-producing CLI commands may write `output.ext.lungfish-provenance.json`
    /// beside the output to avoid one directory-level sidecar overwriting
    /// another output's provenance.
    public static func loadEnvelope(fromSidecar sidecarURL: URL) -> ProvenanceEnvelope? {
        try? ProvenanceEnvelopeReader.load(fromSidecar: sidecarURL)
    }

    /// Loads a provenance record from a directory's sidecar file.
    ///
    /// - Parameter directory: Directory containing `.lungfish-provenance.json`
    /// - Returns: The decoded workflow run, or nil if no sidecar exists
    public static func load(from directory: URL) -> WorkflowRun? {
        loadEnvelope(from: directory)?.legacyWorkflowRun()
    }

    /// Searches for a provenance record by walking up from a file path.
    ///
    /// Looks for `.lungfish-provenance.json` in the file's directory,
    /// then parent, up to 5 levels.
    ///
    /// - Parameter filePath: Path to a derivative file
    /// - Returns: The workflow run that produced it, or nil
    public static func findProvenance(forFile filePath: URL) -> WorkflowRun? {
        findProvenanceEnvelope(for: filePath)?.envelope.legacyWorkflowRun()
    }

    /// Finds the canonical provenance sidecar that applies to a selected file or bundle directory.
    ///
    /// GUI menu actions often operate on a selected `.lungfish*` bundle directory rather than an
    /// individual payload file. This lookup checks bundle roots, documented `provenance/` roll-ups,
    /// exact file sidecars, and nearby parent-directory sidecars while still rejecting unrelated
    /// parent provenance for regular files.
    public static func findProvenanceEnvelope(
        for url: URL
    ) -> (sidecarURL: URL, envelope: ProvenanceEnvelope)? {
        let standardizedURL = url.standardizedFileURL
        let selectedIsDirectory = isDirectory(standardizedURL)

        if selectedIsDirectory {
            if let nestedOperation = singleNestedOperationProvenanceCandidate(for: standardizedURL) {
                return nestedOperation
            }
            for candidate in directorySidecarCandidates(for: standardizedURL) {
                if let envelope = loadEnvelope(fromSidecar: candidate) {
                    return (candidate, envelope)
                }
            }
            if let mappingProvenance = mappingProvenanceCandidate(for: standardizedURL) {
                return mappingProvenance
            }
        } else if standardizedURL.lastPathComponent == MappingProvenance.filename,
                  let mappingProvenance = mappingProvenanceCandidate(
                    for: standardizedURL.deletingLastPathComponent()
                  ) {
            return mappingProvenance
        } else {
            for candidate in fileSidecarCandidates(for: standardizedURL) {
                if let envelope = loadEnvelope(fromSidecar: candidate) {
                    return (candidate, envelope)
                }
            }
        }

        if selectedIsDirectory, let viralRecon = viralReconRunProvenanceCandidate(for: standardizedURL) {
            return viralRecon
        }

        var dir = selectedIsDirectory ? standardizedURL : standardizedURL.deletingLastPathComponent()
        var checkedSelectedDirectory = false
        for _ in 0..<5 {
            if let bundleSidecar = ProvenanceWriter.bundleOutputSidecarURL(for: standardizedURL, inBundle: dir),
               let envelope = loadEnvelope(fromSidecar: bundleSidecar),
               provenanceEnvelope(envelope, produced: standardizedURL) {
                return (bundleSidecar, envelope)
            }

            for candidate in directorySidecarCandidates(for: dir) {
                guard let envelope = loadEnvelope(fromSidecar: candidate) else { continue }
                if selectedIsDirectory && !checkedSelectedDirectory {
                    return (candidate, envelope)
                }
                if provenanceEnvelope(envelope, produced: standardizedURL) {
                    return (candidate, envelope)
                }
            }
            if let mappingProvenance = mappingProvenanceCandidate(for: dir) {
                if selectedIsDirectory && !checkedSelectedDirectory {
                    return mappingProvenance
                }
                if provenanceEnvelope(mappingProvenance.envelope, produced: standardizedURL) {
                    return mappingProvenance
                }
            }
            checkedSelectedDirectory = checkedSelectedDirectory || selectedIsDirectory
            let parent = dir.deletingLastPathComponent()
            if parent == dir { break }
            dir = parent
        }
        return nil
    }

    /// A Viral Recon result folder holds the copied outputs for one sample. The
    /// run's provenance is written next to the raw pipeline results, which the
    /// folder's `viralrecon-result.json` names in `rawResultsPath`.
    private static func viralReconRunProvenanceCandidate(
        for directory: URL
    ) -> (sidecarURL: URL, envelope: ProvenanceEnvelope)? {
        let resultURL = directory.appendingPathComponent("viralrecon-result.json")
        guard let data = try? Data(contentsOf: resultURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawResultsPath = json["rawResultsPath"] as? String,
              !rawResultsPath.isEmpty else {
            return nil
        }
        let rawResults = rawResultsPath.hasPrefix("@/")
            ? FASTQBundle.resolveBundle(relativePath: rawResultsPath, from: directory)
            : URL(fileURLWithPath: rawResultsPath).standardizedFileURL
        let sidecar = rawResults.appendingPathComponent(provenanceFilename)
        guard let envelope = loadEnvelope(fromSidecar: sidecar) else { return nil }
        return (sidecar, envelope)
    }

    private static func singleNestedOperationProvenanceCandidate(
        for directory: URL
    ) -> (sidecarURL: URL, envelope: ProvenanceEnvelope)? {
        guard ProvenanceWriter.isBundleDirectory(directory) else {
            return nil
        }
        let candidates: [(sidecarURL: URL, envelope: ProvenanceEnvelope)] =
            nestedOperationSidecarCandidates(for: directory).compactMap { sidecarURL in
                guard let envelope = loadEnvelope(fromSidecar: sidecarURL),
                      provenanceEnvelopeProducedDescendant(envelope, of: directory) else {
                    return nil
                }
                return (sidecarURL: sidecarURL, envelope: envelope)
            }
        return candidates.count == 1 ? candidates[0] : nil
    }

    private static func mappingProvenanceCandidate(
        for directory: URL
    ) -> (sidecarURL: URL, envelope: ProvenanceEnvelope)? {
        let sidecarURL = directory.appendingPathComponent(MappingProvenance.filename)
        guard FileManager.default.fileExists(atPath: sidecarURL.path),
              let provenance = MappingProvenance.load(from: directory) else {
            return nil
        }
        return (sidecarURL, provenance.canonicalEnvelope(sourceDirectory: directory))
    }

    private static func directorySidecarCandidates(for directory: URL) -> [URL] {
        let operationCandidates = [
            directory
                .appendingPathComponent("assembly", isDirectory: true)
                .appendingPathComponent("provenance.json"),
            directory
                .appendingPathComponent("metadata", isDirectory: true)
                .appendingPathComponent("annotation-edit-provenance.json"),
            directory
                .appendingPathComponent("annotations", isDirectory: true)
                .appendingPathComponent("manual-annotation-provenance.json"),
            directory.appendingPathComponent("extraction-metadata.json"),
        ] + nestedOperationSidecarCandidates(for: directory)

        let canonicalCandidates = [
            directory.appendingPathComponent(provenanceFilename),
            directory
                .appendingPathComponent(ProvenanceWriter.bundleProvenanceDirectoryName, isDirectory: true)
                .appendingPathComponent(ProvenanceWriter.bundleRollupFilename),
            directory.appendingPathComponent(ProvenanceWriter.bundleRollupFilename),
            directory
                .appendingPathComponent(ProvenanceWriter.bundleProvenanceDirectoryName, isDirectory: true)
                .appendingPathComponent(provenanceFilename),
        ]
        return canonicalCandidates + workflowNamedRootSidecarCandidates(for: directory) + operationCandidates
    }

    private static func workflowNamedRootSidecarCandidates(for directory: URL) -> [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            return []
        }
        let canonicalFilenames: Set<String> = [
            provenanceFilename,
            ProvenanceWriter.bundleRollupFilename,
            MappingProvenance.filename,
        ]
        return contents
            .filter { url in
                let filename = url.lastPathComponent
                guard !canonicalFilenames.contains(filename) else { return false }
                guard filename.hasSuffix(".lungfish-provenance.json")
                    || filename.hasSuffix("-provenance.json") else {
                    return false
                }
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
                return values?.isRegularFile == true
            }
            .sorted { $0.path < $1.path }
    }

    private static func fileSidecarCandidates(for fileURL: URL) -> [URL] {
        [fileSidecarURL(for: fileURL)]
            + alignmentArtifactSidecarCandidates(for: fileURL)
            + variantTrackSidecarCandidates(for: fileURL)
    }

    private static func alignmentArtifactSidecarCandidates(for fileURL: URL) -> [URL] {
        let alignmentURL = primaryAlignmentArtifactURL(for: fileURL)
        return [
            alignmentURL.deletingPathExtension().appendingPathExtension("primer-trim-provenance.json"),
            alignmentURL.deletingPathExtension().appendingPathExtension("adopt-mapping-provenance.json"),
        ]
    }

    private static func primaryAlignmentArtifactURL(for fileURL: URL) -> URL {
        let filename = fileURL.lastPathComponent
        if filename.hasSuffix(".bam.bai")
            || filename.hasSuffix(".bam.csi")
            || filename.hasSuffix(".cram.crai") {
            return fileURL.deletingPathExtension()
        }
        return fileURL
    }

    private static func variantTrackSidecarCandidates(for fileURL: URL) -> [URL] {
        guard let trackID = variantTrackID(forArtifactFilename: fileURL.lastPathComponent) else {
            return []
        }
        return [
            fileURL
                .deletingLastPathComponent()
                .appendingPathComponent("\(trackID).lungfish-provenance.json")
        ]
    }

    private static func variantTrackID(forArtifactFilename filename: String) -> String? {
        let suffixes = [
            ".vcf.gz.tbi",
            ".vcf.gz.csi",
            ".vcf.gz.idx",
            ".vcf.gz",
            ".vcf.tbi",
            ".vcf.idx",
            ".vcf",
            ".bcf.csi",
            ".bcf",
            ".db",
        ]
        for suffix in suffixes where filename.hasSuffix(suffix) {
            let trackID = String(filename.dropLast(suffix.count))
            return trackID.isEmpty ? nil : trackID
        }
        return nil
    }

    private static func nestedOperationSidecarCandidates(for directory: URL) -> [URL] {
        guard ProvenanceWriter.isBundleDirectory(directory) else {
            return []
        }
        let variantsURL = directory.appendingPathComponent("variants", isDirectory: true)
        let annotationsURL = directory.appendingPathComponent("annotations", isDirectory: true)
        let alignmentsURL = directory.appendingPathComponent("alignments", isDirectory: true)
        return operationSidecars(in: variantsURL)
            + operationSidecars(in: variantsURL.appendingPathComponent("gatk", isDirectory: true))
            + operationSidecars(in: annotationsURL, recursive: true)
            + operationSidecars(in: alignmentsURL, recursive: true)
    }

    private static func operationSidecars(in directory: URL, recursive: Bool = false) -> [URL] {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey]
        let urls: [URL]
        if recursive {
            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            ) else {
                return []
            }
            urls = enumerator.compactMap { $0 as? URL }
        } else {
            guard let contents = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: keys
            ) else {
                return []
            }
            urls = contents
        }
        return urls
            .filter { url in
                guard isOperationProvenanceSidecarFilename(url.lastPathComponent) else { return false }
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
                return values?.isRegularFile == true
            }
            .sorted { $0.path < $1.path }
    }

    private static func isOperationProvenanceSidecarFilename(_ filename: String) -> Bool {
        filename == provenanceFilename
            || filename == MappingProvenance.filename
            || filename == "annotation-edit-provenance.json"
            || filename == "manual-annotation-provenance.json"
            || filename == "extraction-metadata.json"
            || filename.hasSuffix(".lungfish-provenance.json")
            || filename.hasSuffix("-provenance.json")
    }

    private static func provenanceEnvelope(_ envelope: ProvenanceEnvelope, produced url: URL) -> Bool {
        let selectedPath = url.standardizedFileURL.path
        return envelope.outputs.contains { descriptor in
            let outputURL = URL(fileURLWithPath: descriptor.path).standardizedFileURL
            return outputURL.path == selectedPath
                || selectedPath.hasPrefix(outputURL.path + "/")
        } || envelope.steps.flatMap(\.outputs).contains { descriptor in
            let outputURL = URL(fileURLWithPath: descriptor.path).standardizedFileURL
            return outputURL.path == selectedPath
                || selectedPath.hasPrefix(outputURL.path + "/")
        }
    }

    private static func provenanceEnvelopeProducedDescendant(
        _ envelope: ProvenanceEnvelope,
        of directory: URL
    ) -> Bool {
        let directoryPath = directory.standardizedFileURL.path
        let descriptors = envelope.outputs + envelope.steps.flatMap(\.outputs)
        return descriptors.contains { descriptor in
            URL(fileURLWithPath: descriptor.path)
                .standardizedFileURL
                .path
                .hasPrefix(directoryPath + "/")
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    public static func fileSidecarURL(for outputURL: URL) -> URL {
        URL(fileURLWithPath: "\(outputURL.path).lungfish-provenance.json")
    }
}
