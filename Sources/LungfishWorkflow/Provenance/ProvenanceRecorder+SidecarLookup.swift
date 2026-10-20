// ProvenanceRecorder+SidecarLookup.swift - Finds the canonical provenance sidecar that applies to a file or bundle
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
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
        findProvenanceReading(for: url).map { (sidecarURL: $0.sidecarURL, envelope: $0.reading.envelope) }
    }

    /// Finds the same record as `findProvenanceEnvelope(for:)`, in the same walk, with what the
    /// reader made of it: the shape that decoded it, whether it states its status and whether its
    /// date was invented. A typed mapping record reads as `.typedRecord`.
    public static func findProvenanceReading(
        for url: URL
    ) -> (sidecarURL: URL, reading: ProvenanceEnvelopeReader.Reading)? {
        findProvenanceReading(for: url, sharedFolders: [], listing: { _, _ in })
    }

    /// Receives each folder the sidecar lookup lists and the number of entries the listing returned,
    /// once the listing is done, so a test can prove which folders one lookup read and how much it
    /// read. A folder that cannot be listed is not reported. The public entry points pass a closure
    /// that does nothing.
    typealias SidecarListingObserver = (_ folder: URL, _ entryCount: Int) -> Void

    /// The walk of `findProvenanceReading(for:)` with its two seams. `sharedFolders` names the folders
    /// a lookup with no project may probe and never list. Nothing reads it yet, and the public entry
    /// points pass none. A test passes its own folders and never the real home or temp folder.
    static func findProvenanceReading(
        for url: URL,
        sharedFolders: [URL],
        listing: SidecarListingObserver
    ) -> (sidecarURL: URL, reading: ProvenanceEnvelopeReader.Reading)? {
        let standardizedURL = url.standardizedFileURL
        let selectedIsDirectory = isDirectory(standardizedURL)

        if selectedIsDirectory {
            if let nestedOperation = singleNestedOperationProvenanceCandidate(
                for: standardizedURL,
                listing: listing
            ) {
                return nestedOperation
            }
            for candidate in directorySidecarCandidates(for: standardizedURL, listing: listing) {
                if let reading = readRecord(fromSidecar: candidate) {
                    return (candidate, reading)
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
                if let reading = readRecord(fromSidecar: candidate) {
                    return (candidate, reading)
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
               let reading = readRecord(fromSidecar: bundleSidecar),
               provenanceEnvelope(reading.envelope, produced: standardizedURL) {
                return (bundleSidecar, reading)
            }

            for candidate in directorySidecarCandidates(for: dir, listing: listing) {
                guard let reading = readRecord(fromSidecar: candidate) else { continue }
                if selectedIsDirectory && !checkedSelectedDirectory {
                    return (candidate, reading)
                }
                if provenanceEnvelope(reading.envelope, produced: standardizedURL) {
                    return (candidate, reading)
                }
            }
            if let mappingProvenance = mappingProvenanceCandidate(for: dir) {
                if selectedIsDirectory && !checkedSelectedDirectory {
                    return mappingProvenance
                }
                if provenanceEnvelope(mappingProvenance.reading.envelope, produced: standardizedURL) {
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

    /// What the tolerant reader makes of one candidate, or nil when it reads nothing there.
    private static func readRecord(fromSidecar sidecarURL: URL) -> ProvenanceEnvelopeReader.Reading? {
        (try? ProvenanceEnvelopeReader.read(fromSidecar: sidecarURL)) ?? nil
    }

    /// A Viral Recon result folder holds the copied outputs for one sample. The
    /// run's provenance is written next to the raw pipeline results, which the
    /// folder's `viralrecon-result.json` names in `rawResultsPath`.
    private static func viralReconRunProvenanceCandidate(
        for directory: URL
    ) -> (sidecarURL: URL, reading: ProvenanceEnvelopeReader.Reading)? {
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
        guard let reading = readRecord(fromSidecar: sidecar) else { return nil }
        return (sidecar, reading)
    }

    private static func singleNestedOperationProvenanceCandidate(
        for directory: URL,
        listing: SidecarListingObserver
    ) -> (sidecarURL: URL, reading: ProvenanceEnvelopeReader.Reading)? {
        guard ProvenanceWriter.isBundleDirectory(directory) else {
            return nil
        }
        let candidates: [(sidecarURL: URL, reading: ProvenanceEnvelopeReader.Reading)] =
            nestedOperationSidecarCandidates(for: directory, listing: listing).compactMap { sidecarURL in
                guard let reading = readRecord(fromSidecar: sidecarURL),
                      provenanceEnvelopeProducedDescendant(reading.envelope, of: directory) else {
                    return nil
                }
                return (sidecarURL: sidecarURL, reading: reading)
            }
        return candidates.count == 1 ? candidates[0] : nil
    }

    /// A saved `mapping-provenance.json` keeps its own schema and reads as a typed record, never
    /// as the Older record format. Its status is derived from its exit status.
    private static func mappingProvenanceCandidate(
        for directory: URL
    ) -> (sidecarURL: URL, reading: ProvenanceEnvelopeReader.Reading)? {
        let sidecarURL = directory.appendingPathComponent(MappingProvenance.filename)
        guard FileManager.default.fileExists(atPath: sidecarURL.path),
              let provenance = MappingProvenance.load(from: directory) else {
            return nil
        }
        let reading = ProvenanceEnvelopeReader.Reading(
            envelope: provenance.recordedEnvelope(sourceDirectory: directory),
            shape: .typedRecord,
            statusWasRecorded: false,
            createdAtWasInvented: false
        )
        return (sidecarURL, reading)
    }

    /// The folder's own record and roll-ups first, then root files named like a record, then the
    /// records of operations on the folder. The last two can belong to another operation, so when
    /// the folder's own record was interrupted only the first group is offered.
    private static func directorySidecarCandidates(
        for directory: URL,
        listing: SidecarListingObserver
    ) -> [URL] {
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
        let listed = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        if let listed { listing(directory, listed.count) }
        let contents = listed ?? []
        guard !canonicalRecordWasInterrupted(in: directory, names: contents.map(\.lastPathComponent)) else {
            return canonicalCandidates
        }

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
        ] + nestedOperationSidecarCandidates(for: directory, listing: listing)
        return canonicalCandidates + workflowNamedRootSidecarCandidates(in: contents) + operationCandidates
    }

    /// Root files named like a record, for a folder that holds no canonical record.
    private static func workflowNamedRootSidecarCandidates(in contents: [URL]) -> [URL] {
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

    /// Whether the folder's own `.lungfish-provenance.json` exists and reads as no JSON object,
    /// which is every file the tolerant reader refuses, or is missing beside its own swap
    /// tombstone, staged copy or the aside a released writer left. An interrupted write leaves
    /// one of these states, and a read runs no recovery, so it only looks.
    private static func canonicalRecordWasInterrupted(in directory: URL, names: [String]) -> Bool {
        let canonical = directory.appendingPathComponent(provenanceFilename)
        if FileManager.default.fileExists(atPath: canonical.path) {
            guard let data = try? Data(contentsOf: canonical) else { return true }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] == nil
        }
        let ownPrefix = ".\(provenanceFilename)"
        let leftoverInfixes = [
            PortableRename.swapTombstoneInfix,
            DurableReplace.stageInfix,
            ProvenanceWriter.releasedDisplacedInfix,
        ]
        return names.contains { name in
            leftoverInfixes.contains { name.hasPrefix(ownPrefix + $0) }
        }
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

    private static func nestedOperationSidecarCandidates(
        for directory: URL,
        listing: SidecarListingObserver
    ) -> [URL] {
        guard ProvenanceWriter.isBundleDirectory(directory) else {
            return []
        }
        let variantsURL = directory.appendingPathComponent("variants", isDirectory: true)
        let annotationsURL = directory.appendingPathComponent("annotations", isDirectory: true)
        let alignmentsURL = directory.appendingPathComponent("alignments", isDirectory: true)
        return operationSidecars(in: variantsURL, listing: listing)
            + operationSidecars(
                in: variantsURL.appendingPathComponent("gatk", isDirectory: true),
                listing: listing
            )
            + operationSidecars(in: annotationsURL, recursive: true, listing: listing)
            + operationSidecars(in: alignmentsURL, recursive: true, listing: listing)
    }

    private static func operationSidecars(
        in directory: URL,
        recursive: Bool = false,
        listing: SidecarListingObserver
    ) -> [URL] {
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
            if isDirectory(directory) { listing(directory, urls.count) }
        } else {
            guard let contents = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: keys
            ) else {
                return []
            }
            listing(directory, contents.count)
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
