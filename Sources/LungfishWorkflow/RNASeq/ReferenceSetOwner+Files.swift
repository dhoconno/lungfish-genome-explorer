// ReferenceSetOwner+Files.swift - Hashing, copying, tables, settling and the stage hold (Phase 5.1 lane RS-REFSET)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import LungfishCore
import LungfishIO

extension ReferenceSetOwner {
    /// Reads each input once for its sha256 and checks it against a named default. A genome inside a `.lungfishref`
    /// is read where the bundle's manifest names it, and nothing is written into the bundle.
    func hashInputs(_ request: ReferenceSetRequest) throws -> Hashed {
        var genome = request.genome
        var bundle: (path: String, md5: String?)?
        if genome.pathExtension == "lungfishref" {
            guard let info = try BundleManifest.load(from: genome).genome else {
                throw ReferenceSetError.invalidRequest("The reference bundle \(genome.lastPathComponent) holds no genome.")
            }
            bundle = (genome.path, info.md5Checksum)
            genome = genome.appendingPathComponent(info.path)
        }
        var descriptors: [ProvenanceFileDescriptor] = []
        // A link is followed once, here, so the file hashed is the file copied. A copy of the link itself would point
        // nowhere inside the stage. The record names the input as given.
        func hash(_ given: URL, expected: String?) throws -> (source: URL, sha: String) {
            let source = given.resolvingSymlinksInPath()
            guard FileManager.default.isReadableFile(atPath: source.path) else { throw ReferenceSetError.unreadable(given.path) }
            let sha = try ProvenanceFileHasher.sha256(of: source)
            if let expected, expected != sha {
                throw ReferenceSetError.checksumMismatch(file: given.lastPathComponent, expected: expected, found: sha)
            }
            descriptors.append(ProvenanceFileDescriptor(
                path: given.path, checksumSHA256: sha, fileSize: UInt64(max(source.fileSizeBytes, 0)), role: .input))
            return (source, sha)
        }
        let genomeRead = try hash(genome, expected: request.expected?.genomeSHA256)
        let annotationRead = try hash(request.annotation, expected: request.expected?.annotationSHA256)
        let reportRead = try request.assemblyReport.map { try hash($0, expected: nil) }
        let extraReads = try request.extras.map { extra in
            (fasta: try hash(extra.fasta, expected: nil), annotation: try extra.annotation.map { try hash($0, expected: nil) })
        }
        return Hashed(genome: genome, genomeSource: genomeRead.source, genomeSHA: genomeRead.sha, bundle: bundle,
                      annotationSource: annotationRead.source, annotationSHA: annotationRead.sha,
                      extraSources: extraReads.map { ($0.fasta.source, $0.annotation?.source) },
                      extraSHAs: extraReads.map { ($0.fasta.sha, $0.annotation?.sha) }, descriptors: descriptors,
                      reportSHA: reportRead?.sha)
    }

    /// Copies `source` to `relativePath` in the stage and checks the copy's sha256 against the first read.
    func copyChecked(_ source: URL, to relativePath: String, in stage: URL, sha: String) throws -> URL {
        let target = stage.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: target)
        let found = try ProvenanceFileHasher.sha256(of: target)
        guard found == sha else { throw ReferenceSetError.checksumMismatch(file: source.lastPathComponent, expected: sha, found: found) }
        return target
    }

    /// A plain copy that gffread can read. It lives in the stage's work folder, which goes before the rename.
    func plainCopy(of source: URL, as target: URL) throws -> URL {
        guard source.isGzipCompressed else {
            try FileManager.default.copyItem(at: source, to: target)
            return target
        }
        guard FileManager.default.createFile(atPath: target.path, contents: nil) else { throw ReferenceSetError.unreadable(target.path) }
        let handle = try FileHandle(forWritingTo: target)
        defer { try? handle.close() }
        try source.forEachChunkAutoDecompressing { chunk in
            try Task.checkCancellation()
            try handle.write(contentsOf: chunk)
        }
        return target
    }

    /// Appends `source` to `target` as it is, as `cat transcripts.fa ercc/ERCC92.fa` does (`seqc-gse47774/ref.sh:30`).
    func append(_ source: URL, to target: URL) throws {
        let handle = try FileHandle(forWritingTo: target)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try source.forEachChunkAutoDecompressing { chunk in try handle.write(contentsOf: chunk) }
        try handle.synchronize()
    }

    /// Refuses a name the FASTA or the transcript table holds twice, then a transcript id that one holds and the other
    /// lacks. It counts names, so two records of one name never pass as one.
    func checkTranscripts(_ fasta: URL, against ids: [String]) throws {
        let written = try ReferenceSetAnnotationReader.fastaRecords(fasta).map(\.name)
        var writtenSet = Set<String>()
        var idSet = Set<String>()
        var twice: [String] = []
        for name in written where !writtenSet.insert(name).inserted && !twice.contains(name) { twice.append(name) }
        for id in ids where !idSet.insert(id).inserted && !twice.contains(id) { twice.append(id) }
        guard twice.isEmpty else { throw ReferenceSetError.transcriptsWrittenTwice(twice) }
        let onlyInAnnotation = ids.filter { !writtenSet.contains($0) }
        let onlyInTranscripts = written.filter { !idSet.contains($0) }
        guard onlyInAnnotation.isEmpty, onlyInTranscripts.isEmpty else {
            throw ReferenceSetError.transcriptsDiffer(onlyInAnnotation: onlyInAnnotation, onlyInTranscripts: onlyInTranscripts)
        }
    }
}
