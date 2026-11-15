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

        let genomeCopy = try copyChecked(
            hashed.genomeSource, to: "genome/\(hashed.genome.lastPathComponent)", in: stage, sha: hashed.genomeSHA)
        let annotationCopy = try copyChecked(
            hashed.annotationSource, to: "annotation/\(request.annotation.lastPathComponent)", in: stage, sha: hashed.annotationSHA)
        let plainGenome = try plainCopy(of: genomeCopy, as: work.appendingPathComponent("genome.fa"))
        let genomeRecords = try ReferenceSetAnnotationReader.fastaRecords(plainGenome)
        let genomeNames = Set(genomeRecords.map(\.name))

        // gffread reads only the GTF that LGE writes here, never the annotation as given.
        let gtf = work.appendingPathComponent(Self.gffreadGTFName)
        var read = try ReferenceSetAnnotationReader.read(
            annotationCopy, addExon: request.layout == .lge, notHost: false, writingGTFTo: gtf)
        let missing = read.sequenceNames.filter { !genomeNames.contains($0) }
        guard missing.isEmpty else { throw ReferenceSetError.namesMissingFromGenome(missing) }
        let mitochondrial = try ReferenceSetAnnotationReader.mitochondrialContigs(
            named: request.mitochondrialContigs, report: request.assemblyReport, genome: genomeRecords,
            annotationNames: read.sequenceNames)

        let transcripts = derived.appendingPathComponent("transcripts.fa")
        try await deriver.writeTranscripts(genome: plainGenome, annotation: gtf, to: transcripts)

        var extras: [ReferenceSetManifest.Extra] = []
        var masks: [ReferenceSetManifest.Mask] = []
        var countingParts: [ReferenceSetCountingGTF.ExtraPart] = []
        for (index, extra) in request.extras.enumerated() {
            let (sha, source) = (hashed.extraSHAs[index], hashed.extraSources[index])
            let suffix = extra.fasta.isGzipCompressed ? "fa.gz" : "fa"
            let fasta = try copyChecked(source.fasta, to: "extras/\(extra.name).\(suffix)", in: stage, sha: sha.fasta)
            let plainFASTA = try plainCopy(of: fasta, as: work.appendingPathComponent("extra-\(index).fa"))
            let records = try ReferenceSetAnnotationReader.fastaRecords(plainFASTA)
            let clashes = records.map(\.name).filter(genomeNames.contains)
            guard clashes.isEmpty else {
                throw ReferenceSetError.invalidRequest("The extra \(extra.name) names sequences the genome holds too: "
                    + "\(ReferenceSetError.listed(clashes)). Nothing was renamed.")
            }
            var annotationPath: String?
            let extraRead: ReferenceSetAnnotationRead
            if let given = extra.annotation, let annotation = source.annotation, let annotationSHA = sha.annotation {
                guard request.layout != .lge else {
                    throw ReferenceSetError.invalidRequest("LGE's layout counts each record of the extra \(extra.name) as one "
                        + "feature, so the extra takes no annotation. A deposit's own features need the deposit layout.")
                }
                let gtfSuffix = given.isGzipCompressed ? "gtf.gz" : "gtf"
                annotationPath = "extras/\(extra.name).\(gtfSuffix)"
                let copied = try copyChecked(annotation, to: annotationPath!, in: stage, sha: annotationSHA)
                let extraGTF = work.appendingPathComponent("extra-\(index).\(Self.gffreadGTFName)")
                extraRead = try ReferenceSetAnnotationReader.read(copied, addExon: false, notHost: true, writingGTFTo: extraGTF)
                let recordNames = Set(records.map(\.name))
                let absent = extraRead.sequenceNames.filter { !recordNames.contains($0) }
                guard absent.isEmpty else { throw ReferenceSetError.namesMissingFromGenome(absent) }
                let piece = work.appendingPathComponent("extra-\(index).transcripts.fa")
                try await deriver.writeTranscripts(genome: plainFASTA, annotation: extraGTF, to: piece)
                try append(piece, to: transcripts)
                countingParts.append(.gtf(extraGTF))
            } else {
                extraRead = ReferenceSetAnnotationReader.recordFeatures(records, biotype: extra.kind.rawValue)
                try append(plainFASTA, to: transcripts)
                countingParts.append(.records(records))
            }
            read.genes += extraRead.genes
            read.transcriptGenes += extraRead.transcriptGenes
            read.dropped += extraRead.dropped
            read.keptWithoutExon += extraRead.keptWithoutExon
            read.renamed += extraRead.renamed
            read.withoutFeatures += extraRead.withoutFeatures
            extras.append(.init(
                name: extra.name, kind: extra.kind, path: "extras/\(extra.name).\(suffix)", sha256: sha.fasta,
                annotationPath: annotationPath, annotationSHA256: annotationPath == nil ? nil : sha.annotation,
                records: records.map(\.name), notHost: true))
            if let given = extra.mask, let mask = hashed.masks[index] {
                masks.append(try copyMask(
                    mask.source, given: given, sha: mask.sha, extra: extra.name, records: records.map(\.name), in: stage))
            }
        }
        try checkTranscripts(transcripts, against: read.transcriptGenes.map(\.transcript))
        // The GTF that STAR, STARsolo and featureCounts read: the one gffread read, then each extra's lines.
        try ReferenceSetCountingGTF.write(
            host: gtf, extras: countingParts, to: derived.appendingPathComponent(ReferenceSetCountingGTF.fileName))
        try FileManager.default.removeItem(at: work)

        let (written, withoutFeatures) = try writeTables(read, into: derived, version: version)
        var tables = written
        tables.countingGTF = try ReferenceSetCountingGTF.checkedEntry(in: derived)
        let manifest = ReferenceSetManifest(
            schemaVersion: ReferenceSetManifest.currentSchemaVersion, id: id, name: request.name, species: request.species,
            assembly: .init(name: request.assemblyName, accession: request.assemblyAccession, sourceURL: request.assemblySourceURL),
            annotation: .init(source: request.annotationSource, release: request.annotationRelease,
                              path: "annotation/\(request.annotation.lastPathComponent)", sha256: hashed.annotationSHA),
            genome: .init(path: "genome/\(hashed.genome.lastPathComponent)", sha256: hashed.genomeSHA,
                          referenceBundle: hashed.bundle?.path, referenceBundleMD5: hashed.bundle?.md5),
            extras: extras, layout: request.layout.manifestLayout, mitochondrialContigs: mitochondrial, masks: masks,
            derived: tables,
            derivation: .init(exonsAdded: read.exonsAdded, keptWithoutExon: read.keptWithoutExon, droppedFeatures: read.dropped,
                              renamedTranscripts: read.renamed, genesWithoutFeatures: withoutFeatures))
        try DurableReplace.replace(try manifest.encoded(), named: ReferenceSetManifest.filename, in: stage)
        return manifest
    }
}
