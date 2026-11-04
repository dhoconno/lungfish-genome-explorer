// GUIImportedProvenanceRehydrator+PlainFolder.swift - A plain result folder is its own provenance root
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.2 lane COPYFOLDER, row COPY-PLAIN-FOLDER-SIDECAR and ruling BIO-COPY-DIGESTLESS. A TaxTriage, Kraken 2,
// EsViritu, NVD or NAO-MGS result is a plain folder (no `lungfish*` extension) that holds its own record at its root. The
// enclosing project is the provenance root of a `lungfish*` bundle only, and taking it for a plain folder's root never
// finds the record inside the folder. A relocated copy of such a folder reads the record where the run wrote it, so its
// project-relative paths resolve against the source project. It compares the files the record names at the run level with
// the files in the copy, lets the item's own folder be listed without a digest, and leaves every other file to the
// byte comparison of the copier (`CrossProjectItemCopier.verifyStagedBytes`).

import Foundation

extension GUIImportedProvenanceRehydrator {
    /// Whether both folders are plain folders that hold a record at their root.
    static func foldersHoldTheirOwnRecord(source: URL, destination: URL) -> Bool {
        [source, destination].allSatisfy { folder in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) && isDirectory.boolValue
                && !ProvenanceWriter.isBundleDirectory(folder)
                && FileManager.default.fileExists(
                    atPath: folder.appendingPathComponent(ProvenanceRecorder.provenanceFilename).path
                )
        }
    }

    /// The roots of a relocated copy. Plain folders that hold their records are their own roots, and any other item
    /// keeps the roots it always had.
    static func relocatedRoots(source: URL, destination: URL, ownsRecord: Bool) throws -> (source: URL, destination: URL) {
        guard ownsRecord else { return (provenanceRoot(for: source), try finalProvenanceRoot(for: destination)) }
        return (source.standardizedFileURL, destination.standardizedFileURL)
    }

    /// The outputs the record names at the run level, which are `output`, `outputs` and the `files` with role output, one
    /// entry for each path, checksum and size. A step keeps files as they were when it ran, so a plain folder's copy
    /// compares the run level, which names what the result still holds.
    static func runLevelOutputDescriptors(from envelope: ProvenanceEnvelope) -> [ProvenanceFileDescriptor] {
        var descriptors: [ProvenanceFileDescriptor] = []
        if let output = envelope.output { descriptors.append(output) }
        descriptors.append(contentsOf: envelope.outputs)
        descriptors.append(contentsOf: envelope.files.filter { $0.role == .output })
        var seen = Set<String>()
        return descriptors.compactMap { presentBytes(of: $0, in: envelope) }.filter {
            seen.insert("\($0.path)\u{0}\($0.checksumSHA256 ?? "")\u{0}\($0.fileSize.map(String.init) ?? "")").inserted
        }
    }

    /// The entry that describes the file now (ruling BIO-COPY-CHANGED-FILES items 2 and 3). A record may name a file at its
    /// run level with the bytes the run left, though a later step of the same record marked it in place, named the new bytes
    /// and named the old ones as removed. The record is true about the file, so the file is compared with the step that last
    /// wrote it. A file the record does not account for keeps its run-level digest and stays refused. An entry without a
    /// checksum, and an entry that no removal step of the record names with that path and checksum, comes back as it is.
    /// Otherwise the answer is the last entry of any step's outputs with the same path, a size and another checksum, or nil
    /// when no step names other bytes.
    static func presentBytes(of descriptor: ProvenanceFileDescriptor, in envelope: ProvenanceEnvelope) -> ProvenanceFileDescriptor? {
        guard let removed = descriptor.checksumSHA256 else { return descriptor }
        let accounted = envelope.steps.contains { step in
            step.resolvedOptions["operation"] == .string(RecordedRemovalStep.operation)
                && step.inputs.contains { $0.path == descriptor.path && $0.checksumSHA256 == removed }
        }
        guard accounted else { return descriptor }
        var present: ProvenanceFileDescriptor?
        for step in envelope.steps {
            for output in step.outputs where output.path == descriptor.path && output.fileSize != nil {
                if let checksum = output.checksumSHA256, checksum != removed { present = output }
            }
        }
        return present
    }

    /// The record a relocated copy rewrites (ruling BIO-COPY-CHANGED-FILES item 4). For a plain folder that holds its own
    /// record, `output`, `outputs` and the `files` with role output name the bytes each file holds now, so the copy's record
    /// says what its files are and a second copy passes the same check. Any other item keeps its record as it is.
    static func envelopeNamingPresentBytes(_ envelope: ProvenanceEnvelope, ownsRecord: Bool) -> ProvenanceEnvelope {
        guard ownsRecord else { return envelope }
        var present = envelope
        present.output = envelope.output.flatMap { presentBytes(of: $0, in: envelope) }
        present.outputs = envelope.outputs.compactMap { presentBytes(of: $0, in: envelope) }
        present.files = envelope.files.compactMap { $0.role == .output ? presentBytes(of: $0, in: envelope) : $0 }
        return present
    }

    /// Compares each listed output with the file at its mapped place. `itemFolder` is the copy of a plain folder that holds
    /// its own record. The import writers list that folder as the place they wrote to, with no checksum and no size, and
    /// every file inside it is compared on its own, so only that one entry may lack both. Any other entry without a
    /// checksum and a size is refused, and so is a listed file that is gone.
    static func validateMappedOutputIntegrity(
        _ descriptors: [ProvenanceFileDescriptor],
        pathMap: [String: String], itemFolder: String? = nil, cancellationCheck: () throws -> Void
    ) throws {
        for descriptor in descriptors {
            guard let expectedChecksum = descriptor.checksumSHA256,
                  let expectedFileSize = descriptor.fileSize else {
                if let itemFolder, descriptor.checksumSHA256 == nil, descriptor.fileSize == nil,
                   mappedPath(for: descriptor.path, in: pathMap) == itemFolder {
                    continue
                }
                throw GUIImportedProvenanceRehydratorError.sourceOutputIntegrityMissing(descriptor.path)
            }
            guard let finalPath = mappedPath(for: descriptor.path, in: pathMap) else {
                continue
            }
            let finalURL = URL(fileURLWithPath: finalPath)
            guard FileManager.default.fileExists(atPath: finalURL.path) else {
                throw GUIImportedProvenanceRehydratorError.sourceOutputMissing(descriptor.path)
            }
            let actualChecksum = try ProvenanceFileHasher.sha256(of: finalURL, cancellationCheck: cancellationCheck)
            let actualFileSize = try ProvenanceFileHasher.fileSize(of: finalURL)
            guard expectedChecksum == actualChecksum, expectedFileSize == actualFileSize else {
                throw GUIImportedProvenanceRehydratorError.sourceOutputIntegrityMismatch(descriptor.path)
            }
        }
    }
}
