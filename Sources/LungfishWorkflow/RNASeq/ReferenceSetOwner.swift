// ReferenceSetOwner.swift - The one owner of `<storage root>/rnaseq-reference-sets/` (Phase 5.1 lane RS-REFSET)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// It creates, settles and discards every set (`docs/formats/reference-set.md`, section The one owner). It hashes each
// input as it reads it and takes the id from the hashes, so a published set of the same id is reused with no gffread.
// Otherwise it builds in `.<id>.lungfishrefset.creating-<UUID>`, held by an exclusive flock on that folder, copies the
// inputs and checks their sha256 again, derives the tables and the transcript FASTA, publishes the manifest through
// `DurableReplace`, writes the root record last and renames the stage into place with `RENAME_EXCL`. Before a build it
// removes each stage that no running build holds, and nothing else.

import Darwin
import Foundation
import LungfishCore
import LungfishIO

/// What writes the transcript FASTA. The default is gffread, and tests pass a stand-in.
public protocol ReferenceSetTranscriptDeriving: Sendable {
    func toolVersion() async throws -> String
    func writeTranscripts(genome: URL, annotation: URL, to output: URL) async throws
}

/// gffread through `NativeToolRunner`, `-w <out> -g <genome> <gtf>` and no other flag (`seqc-gse47774/ref.sh:25`).
public struct GffreadTranscriptDeriver: ReferenceSetTranscriptDeriving {
    public init() {}

    public func toolVersion() async throws -> String {
        guard let version = await NativeToolRunner.shared.getToolVersion(.gffread) else {
            throw ReferenceSetError.toolFailed("gffread is not installed. Install the RNA-seq pack in the Plugin Manager.")
        }
        return version
    }

    public func writeTranscripts(genome: URL, annotation: URL, to output: URL) async throws {
        let result = try await NativeToolRunner.shared.run(.gffread, arguments: ["-w", output.path, "-g", genome.path, annotation.path])
        guard result.isSuccess else {
            throw ReferenceSetError.toolFailed("gffread stopped with exit status \(result.exitCode): \(result.stderr)")
        }
    }
}

public struct ReferenceSetOutcome: Sendable {
    public var url: URL
    public var manifest: ReferenceSetManifest
    /// True when a published set of the same id was used and nothing was built.
    public var reused: Bool
}

public struct ReferenceSetOwner: Sendable {
    public static let folderName = "rnaseq-reference-sets"
    public let setsFolder: URL
    let deriver: any ReferenceSetTranscriptDeriving
    let provenanceWriter: ProvenanceWriter

    public init(
        storageRoot: URL, deriver: any ReferenceSetTranscriptDeriving = GffreadTranscriptDeriver(),
        provenanceWriter: ProvenanceWriter = ProvenanceWriter()
    ) {
        setsFolder = ManagedStorageLocation(rootURL: storageRoot).rootURL.appendingPathComponent(Self.folderName, isDirectory: true)
        self.deriver = deriver
        self.provenanceWriter = provenanceWriter
    }

    /// The input files after the id is known, each with the sha256 of its first read.
    /// Each input as given, whose name its copy takes, and the file it names with links followed, which is hashed
    /// and copied.
    struct Hashed {
        var genome: URL
        var genomeSource: URL
        var genomeSHA: String
        var bundle: (path: String, md5: String?)?
        var annotationSource: URL
        var annotationSHA: String
        var extraSources: [(fasta: URL, annotation: URL?)]
        var extraSHAs: [(fasta: String, annotation: String?)]
        var descriptors: [ProvenanceFileDescriptor]
    }

    public func build(_ request: ReferenceSetRequest, argv: [String] = []) async throws -> ReferenceSetOutcome {
        let started = Date()
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: setsFolder, withIntermediateDirectories: true)
        removeAbandonedStages()

        let hashed = try hashInputs(request)
        let version = try await deriver.toolVersion()
        var contents = [
            ReferenceSetID.Content(role: "genome", fileName: hashed.genome.lastPathComponent, sha256: hashed.genomeSHA),
            ReferenceSetID.Content(role: "annotation", fileName: request.annotation.lastPathComponent, sha256: hashed.annotationSHA),
        ]
        for (extra, sha) in zip(request.extras, hashed.extraSHAs) {
            contents.append(.init(role: "extra", fileName: extra.name, sha256: sha.fasta))
            if let annotation = extra.annotation, let annotationSHA = sha.annotation {
                contents.append(.init(role: "extra annotation", fileName: annotation.lastPathComponent, sha256: annotationSHA))
            }
        }
        let id = ReferenceSetID.make(
            species: request.species, assembly: request.assemblyName, annotationSource: request.annotationSource,
            annotationRelease: request.annotationRelease, layout: request.layout, contents: contents, deriveVersion: version)
        let finalURL = setsFolder.appendingPathComponent("\(id).\(ReferenceSetManifest.folderExtension)", isDirectory: true)
        if fileManager.fileExists(atPath: finalURL.path) { return try settled(finalURL, id: id) }

        let hold = try ReferenceSetStageHold.make(in: setsFolder, id: id)
        defer { hold.release() }
        var renaming = false
        do {
            let manifest = try await fill(hold.url, id: id, request: request, hashed: hashed, version: version)
            let envelope = makeEnvelope(manifest, finalURL: finalURL, argv: argv, inputs: hashed.descriptors, version: version, started: started)
            try provenanceWriter.write(envelope, to: hold.url, bundleLayoutRoot: finalURL)
            renaming = true
            try PortableRename.exclusive(hold.url, to: finalURL)
            return ReferenceSetOutcome(url: finalURL, manifest: manifest, reused: false)
        } catch {
            try? fileManager.removeItem(at: hold.url)
            // Another build of the same id won the rename, so its set is used after the manifest check.
            if renaming, fileManager.fileExists(atPath: finalURL.path) { return try settled(finalURL, id: id) }
            throw error
        }
    }
}
