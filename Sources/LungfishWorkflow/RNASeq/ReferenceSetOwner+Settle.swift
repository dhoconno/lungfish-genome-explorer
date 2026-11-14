// ReferenceSetOwner+Settle.swift - The tables, the record, settling and the stage sweep (Phase 5.1 lane RS-REFSET)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import LungfishCore
import LungfishIO

extension ReferenceSetOwner {
    static let geneColumns = ["gene_id", "name", "biotype", "contig", "length", "not_host", "mask", "unreliable"]
    /// The GTF that LGE writes in the stage's work folder, the only GTF gffread reads.
    static let gffreadGTFName = "lge-annotation.gtf"
    static let withoutFeaturesName = "genes-without-features.tsv"

    /// `derived/genes.tsv` with the columns the result's reader reads, `derived/transcripts.tsv`, and
    /// `derived/genes-without-features.tsv` with each gene that has no exon line and no CDS line.
    func writeTables(
        _ read: ReferenceSetAnnotationRead, into derived: URL, version: String
    ) throws -> (ReferenceSetManifest.Derived, ReferenceSetManifest.ListedFile) {
        let featureless = "gene_id\tcontig\tbiotype\n" + read.withoutFeatures.map { $0 + "\n" }.joined()
        try DurableReplace.replace(Data(featureless.utf8), named: Self.withoutFeaturesName, in: derived)
        let listed = ReferenceSetManifest.ListedFile(
            path: "derived/\(Self.withoutFeaturesName)",
            sha256: try ProvenanceFileHasher.sha256(of: derived.appendingPathComponent(Self.withoutFeaturesName)),
            count: read.withoutFeatures.count)
        var genes = Self.geneColumns.joined(separator: "\t") + "\n"
        for gene in read.genes {
            genes += [gene.id, gene.name, gene.biotype, gene.contig, String(gene.length), gene.notHost ? "true" : "false", "", ""]
                .joined(separator: "\t") + "\n"
        }
        var pairs = "transcript_id\tgene_id\n"
        for pair in read.transcriptGenes { pairs += "\(pair.transcript)\t\(pair.gene)\n" }
        try DurableReplace.replace(Data(genes.utf8), named: "genes.tsv", in: derived)
        try DurableReplace.replace(Data(pairs.utf8), named: "transcripts.tsv", in: derived)
        func entry(_ name: String, tool: String, version: String) throws -> ReferenceSetManifest.DerivedFile {
            let url = derived.appendingPathComponent(name)
            return .init(path: "derived/\(name)", sha256: try ProvenanceFileHasher.sha256(of: url), size: url.fileSizeBytes,
                         tool: tool, version: version)
        }
        let tables = ReferenceSetManifest.Derived(
            transcripts: try entry("transcripts.fa", tool: "gffread", version: version),
            genes: try entry("genes.tsv", tool: "lungfish", version: WorkflowRun.currentAppVersion),
            transcriptGenes: try entry("transcripts.tsv", tool: "lungfish", version: WorkflowRun.currentAppVersion))
        return (tables, listed)
    }

    /// Settles a published set: its manifest names this id and every file it names is there at its size.
    func settled(_ url: URL, id: String) throws -> ReferenceSetOutcome {
        let manifest = try ReferenceSetManifest.load(from: url)
        guard manifest.id == id else { throw ReferenceSetError.publishedSetDiffers(id: id, file: ReferenceSetManifest.filename) }
        for file in manifest.namedFiles where !FileManager.default.fileExists(atPath: url.appendingPathComponent(file.path).path) {
            throw ReferenceSetError.publishedSetDiffers(id: id, file: file.path)
        }
        for file in [manifest.derived.transcripts, manifest.derived.genes, manifest.derived.transcriptGenes]
        where url.appendingPathComponent(file.path).fileSizeBytes != file.size {
            throw ReferenceSetError.publishedSetDiffers(id: id, file: file.path)
        }
        return ReferenceSetOutcome(url: url, manifest: manifest, reused: true)
    }

    func makeEnvelope(
        _ manifest: ReferenceSetManifest, finalURL: URL, argv: [String], inputs: [ProvenanceFileDescriptor],
        version: String, started: Date
    ) -> ProvenanceEnvelope {
        var outputs = [manifest.derived.transcripts, manifest.derived.genes, manifest.derived.transcriptGenes].map {
            ProvenanceFileDescriptor(path: finalURL.appendingPathComponent($0.path).path, checksumSHA256: $0.sha256,
                                     fileSize: UInt64(max($0.size, 0)), role: .output)
        }
        let listed = finalURL.appendingPathComponent(manifest.derivation.genesWithoutFeatures.path)
        outputs.append(ProvenanceFileDescriptor(
            path: listed.path, checksumSHA256: manifest.derivation.genesWithoutFeatures.sha256, role: .output))
        let step = ProvenanceStep(
            toolName: "gffread", toolVersion: version,
            argv: ["gffread", "-w", "derived/transcripts.fa", "-g", "genome.fa", Self.gffreadGTFName], exitStatus: 0,
            managedToolID: ManagedToolID(rawValue: "gffread"))
        return ProvenanceEnvelope(
            workflowName: "RNA-seq reference set", toolName: "lungfish-cli", toolVersion: WorkflowRun.currentAppVersion,
            argv: argv, files: inputs, outputs: outputs, steps: [step], wallTimeSeconds: Date().timeIntervalSince(started),
            exitStatus: 0, status: .completed)
    }

    /// Removes each `.<name>.lungfishrefset.creating-<UUID>` folder whose flock no running build holds, and nothing else.
    func removeAbandonedStages() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: setsFolder.path)) ?? []
        for name in names where name.hasPrefix(".") && name.contains(".\(ReferenceSetManifest.folderExtension).creating-") {
            let stage = setsFolder.appendingPathComponent(name, isDirectory: true)
            let descriptor = open(stage.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard descriptor >= 0 else { continue }
            defer { close(descriptor) }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { continue }
            try? FileManager.default.removeItem(at: stage)
        }
    }
}

/// A build's stage and the exclusive flock that marks it as held while the build runs.
final class ReferenceSetStageHold: @unchecked Sendable {
    let url: URL
    private var descriptor: Int32

    private init(url: URL, descriptor: Int32) {
        self.url = url
        self.descriptor = descriptor
    }

    static func make(in folder: URL, id: String) throws -> ReferenceSetStageHold {
        // A sweep of another build can take a stage between its mkdir and its flock, so a lost stage is made again.
        for _ in 0..<3 {
            let url = folder.appendingPathComponent(
                ".\(id).\(ReferenceSetManifest.folderExtension).creating-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            if descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                return ReferenceSetStageHold(url: url, descriptor: descriptor)
            }
            if descriptor >= 0 { close(descriptor) }
        }
        throw ReferenceSetError.invalidRequest("Lungfish could not hold a staging folder in \(folder.path).")
    }

    func release() {
        guard descriptor >= 0 else { return }
        close(descriptor)
        descriptor = -1
    }

    deinit { release() }
}
