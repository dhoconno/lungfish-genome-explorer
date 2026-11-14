// ReferenceSetOwner+Build.swift - The steps inside a set's stage (Phase 5.1 lane RS-REFSET)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

extension ReferenceSetOwner {
    /// Copies and checks the inputs, derives the tables and the transcript FASTA, removes the work folder and publishes
    /// the manifest. The root record and the rename follow in `build`.
    func fill(_ stage: URL, id: String, request: ReferenceSetRequest, hashed: Hashed, version: String) async throws -> ReferenceSetManifest {
        let work = stage.appendingPathComponent(".work", isDirectory: true)
        let derived = stage.appendingPathComponent("derived", isDirectory: true)
        for folder in [work, derived] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }

        let genomeCopy = try copyChecked(hashed.genome, to: "genome/\(hashed.genome.lastPathComponent)", in: stage, sha: hashed.genomeSHA)
        let annotationCopy = try copyChecked(
            request.annotation, to: "annotation/\(request.annotation.lastPathComponent)", in: stage, sha: hashed.annotationSHA)
        let plainGenome = try plainCopy(of: genomeCopy, as: work.appendingPathComponent("genome.fa"))
        let plainAnnotation = try plainCopy(of: annotationCopy, as: work.appendingPathComponent("annotation.gtf"))
        let genomeRecords = try ReferenceSetAnnotationReader.fastaRecords(plainGenome)
        let genomeNames = Set(genomeRecords.map(\.name))

        var read = try ReferenceSetAnnotationReader.read(plainAnnotation, addExon: request.layout == .lge, notHost: false)
        let missing = read.sequenceNames.filter { !genomeNames.contains($0) }
        guard missing.isEmpty else { throw ReferenceSetError.namesMissingFromGenome(missing) }
        let mitochondrial = try ReferenceSetAnnotationReader.mitochondrialContigs(
            named: request.mitochondrialContigs, report: request.assemblyReport, genome: genomeRecords,
            annotationNames: read.sequenceNames)

        let transcripts = derived.appendingPathComponent("transcripts.fa")
        try await deriver.writeTranscripts(genome: plainGenome, annotation: plainAnnotation, to: transcripts)

        var extras: [ReferenceSetManifest.Extra] = []
        for (index, (extra, sha)) in zip(request.extras, hashed.extraSHAs).enumerated() {
            let suffix = extra.fasta.isGzipCompressed ? "fa.gz" : "fa"
            let fasta = try copyChecked(extra.fasta, to: "extras/\(extra.name).\(suffix)", in: stage, sha: sha.fasta)
            let plainFASTA = try plainCopy(of: fasta, as: work.appendingPathComponent("extra-\(index).fa"))
            let records = try ReferenceSetAnnotationReader.fastaRecords(plainFASTA)
            let clashes = records.map(\.name).filter(genomeNames.contains)
            guard clashes.isEmpty else {
                throw ReferenceSetError.invalidRequest("The extra \(extra.name) names sequences the genome holds too: "
                    + "\(ReferenceSetError.listed(clashes)). Nothing was renamed.")
            }
            var annotationPath: String?
            let extraRead: ReferenceSetAnnotationRead
            if let annotation = extra.annotation, let annotationSHA = sha.annotation {
                guard request.layout != .lge else {
                    throw ReferenceSetError.invalidRequest("LGE's layout counts each record of the extra \(extra.name) as one "
                        + "feature, so the extra takes no annotation. A deposit's own features need the deposit layout.")
                }
                let gtfSuffix = annotation.isGzipCompressed ? "gtf.gz" : "gtf"
                annotationPath = "extras/\(extra.name).\(gtfSuffix)"
                let copied = try copyChecked(annotation, to: annotationPath!, in: stage, sha: annotationSHA)
                let plain = try plainCopy(of: copied, as: work.appendingPathComponent("extra-\(index).gtf"))
                extraRead = try ReferenceSetAnnotationReader.read(plain, addExon: false, notHost: true)
                let recordNames = Set(records.map(\.name))
                let absent = extraRead.sequenceNames.filter { !recordNames.contains($0) }
                guard absent.isEmpty else { throw ReferenceSetError.namesMissingFromGenome(absent) }
                let piece = work.appendingPathComponent("extra-\(index).transcripts.fa")
                try await deriver.writeTranscripts(genome: plainFASTA, annotation: plain, to: piece)
                try append(piece, to: transcripts)
            } else {
                extraRead = ReferenceSetAnnotationReader.recordFeatures(records, biotype: extra.kind.rawValue)
                try append(plainFASTA, to: transcripts)
            }
            read.genes += extraRead.genes
            read.transcriptGenes += extraRead.transcriptGenes
            read.dropped += extraRead.dropped
            extras.append(.init(
                name: extra.name, kind: extra.kind, path: "extras/\(extra.name).\(suffix)", sha256: sha.fasta,
                annotationPath: annotationPath, annotationSHA256: annotationPath == nil ? nil : sha.annotation,
                records: records.map(\.name), notHost: true))
        }
        try checkTranscripts(transcripts, against: read.transcriptGenes.map(\.transcript))
        try FileManager.default.removeItem(at: work)

        let tables = try writeTables(read, into: derived, version: version)
        let manifest = ReferenceSetManifest(
            schemaVersion: ReferenceSetManifest.currentSchemaVersion, id: id, name: request.name, species: request.species,
            assembly: .init(name: request.assemblyName, accession: request.assemblyAccession, sourceURL: request.assemblySourceURL),
            annotation: .init(source: request.annotationSource, release: request.annotationRelease,
                              path: "annotation/\(request.annotation.lastPathComponent)", sha256: hashed.annotationSHA),
            genome: .init(path: "genome/\(hashed.genome.lastPathComponent)", sha256: hashed.genomeSHA,
                          referenceBundle: hashed.bundle?.path, referenceBundleMD5: hashed.bundle?.md5),
            extras: extras, layout: request.layout.manifestLayout, mitochondrialContigs: mitochondrial, masks: [],
            derived: tables,
            derivation: .init(exonsAdded: read.exonsAdded, keptWithoutExon: read.keptWithoutExon, droppedFeatures: read.dropped))
        try DurableReplace.replace(try manifest.encoded(), named: ReferenceSetManifest.filename, in: stage)
        return manifest
    }
}
