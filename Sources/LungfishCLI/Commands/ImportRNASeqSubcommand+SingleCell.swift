// ImportRNASeqSubcommand+SingleCell.swift - `import rnaseq` on Cell Ranger and STARsolo folders (Phase 5.2 lane RS-SC-IMPORT)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// A single-cell import takes Cell Ranger `outs/` folders or STARsolo run folders, never both and never with bulk inputs.
// The folder readers check each matrix's header and size line before the writer starts, and the writer reads each kept
// matrix once in its stage into `cells.sqlite` (`docs/formats/rnaseq-bundle.md`, Single cell).

import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

extension ImportCommand.RNASeqSubcommand {
    static let mixedWords = "Bulk and single-cell inputs cannot share one result. "
        + "Import the salmon folders or the count table in one run and the Cell Ranger or STARsolo folders in another."

    /// The words of a single-cell refusal before anything is read, or nil when the inputs and options agree.
    static func singleCellRefusal(inputs: [URL], hasTx2Gene: Bool, unit: String?, genomes: [String]) -> String? {
        let singleCell = inputs.filter(SingleCellFolderReader.isSingleCellFolder)
        guard !singleCell.isEmpty else {
            return genomes.isEmpty ? nil : "--genome names the genomes of a single-cell matrix and takes no bulk input."
        }
        guard singleCell.count == inputs.count else { return mixedWords }
        if hasTx2Gene { return "--tx2gene sums the transcripts of salmon folders and takes no single-cell folder." }
        if unit != nil { return "Cell Ranger and STARsolo state their own unit, so --unit takes only a count table." }
        return nil
    }
}

extension ImportCommand.RNASeqSubcommand {
    /// The words of a refusal of `--reference-set` and `--not-host-bam`, or nil when they agree with the inputs.
    static func notHostRefusal(isSingleCell: Bool, hasSet: Bool, bams: [String]) -> String? {
        guard hasSet || !bams.isEmpty else { return nil }
        guard isSingleCell else {
            return "--reference-set and --not-host-bam count the not-host RNA of Cell Ranger and STARsolo folders and take no bulk input."
        }
        guard hasSet else { return "--not-host-bam needs --reference-set, the set whose not-host records the BAM was aligned to." }
        if let bad = bams.first(where: { !$0.contains("=") || $0.hasPrefix("=") || $0.hasSuffix("=") }) {
            return SingleCellNotHostError.malformedBAMOption(bad).errorDescription
        }
        return nil
    }

    /// Each `<sample>=<path>` of `--not-host-bam`, in the order given.
    static func notHostBAMs(_ values: [String]) -> [(sample: String, url: URL)] {
        values.compactMap { value in
            guard let cut = value.firstIndex(of: "=") else { return nil }
            return (String(value[..<cut]), URL(fileURLWithPath: String(value[value.index(after: cut)...])).standardizedFileURL)
        }
    }
}

extension ImportCommand.RNASeqSubcommand.Plan {
    /// The single-cell request, with the not-host pass when a reference set is named. The pass runs before the writer,
    /// so the result and its `cells.sqlite` are written once (`docs/formats/rnaseq-bundle.md`, Not-host RNA).
    func fullRequest() async throws -> (RNASeqResultWriter.Request, [String: ParameterValue], String) {
        guard isSingleCell, let referenceSet else { return try request() }
        let sheet = try self.sheet.map(RNASeqSampleSheet.read)
        let read = try singleCellFolders(sheet: sheet)
        let ordered = read.folders
        var (request, facts, summary) = try singleCellRequest(sheet: sheet, read: read)
        let set = try SingleCellNotHostPass.readSet(referenceSet)
        request.referenceSet = .init(id: set.manifest.id, layout: set.manifest.layout.kind == "deposit" ? .deposit : .lge)
        request.genes = .referenceSetTable(url: set.genesTable, keeping: ordered.first?.featureIDs ?? [])
        let kept = Set(ordered.first?.featureIDs ?? [])
        request.notHost = set.notHostFeatures.filter(kept.contains)
        facts["notHostReferenceSet"] = .string(set.manifest.id)
        guard !set.extras.isEmpty else { return (request, facts, summary) }
        let (result, notHostFacts) = try await SingleCellNotHostPass.run(
            ordered, set: set, bams: Dictionary(notHostBAMs.map { ($0.sample, $0.url) }, uniquingKeysWith: { first, _ in first }))
        request.notHostCells = result
        facts.merge(notHostFacts) { _, new in new }
        let flagged = result.samples.flatMap(\.calls).filter { SingleCellNotHostFlag.words(for: result.extras[$0.extra].kind) == $0.flag }.count
        return (request, facts, summary + ", \(flagged) flagged above ambient" + Self.notHostLeftOutNote(result.samples))
    }

    /// The import line's words for each library whose BAM held alignments and counted none, or holds barcodes that the raw
    /// list lacks, so that a library read as no not-host RNA for want of a count says so (BIO-NOTHOST-BARCODE item 4).
    static func notHostLeftOutNote(_ samples: [SingleCellNotHostSample]) -> String {
        samples.filter(\.needsACheck).map { sample -> String in
            let left = "left out \(sample.alignmentsMultimapped) not at NH 1, \(sample.alignmentsWithoutBarcode) without a CB or UB "
                + "and \(sample.barcodesNotInRawList) barcodes not in the raw list"
            return "; \(sample.sample) counted \(sample.alignmentsCounted) alignments, \(left), so check the BAM's tags and barcodes"
        }.joined()
    }

    /// Reads the single-cell folders in the order of the sample sheet.
    func singleCellFolders(sheet: RNASeqSampleSheet?) throws -> (folders: [SingleCellFolder], records: [RNASeqSampleRecord]) {
        var folders: [SingleCellFolder] = []
        for url in inputs {
            try Task.checkCancellation()
            folders.append(try SingleCellFolderReader.read(folder: url))
        }
        let match = try RNASeqSampleSheet.match(sheet, fileIDs: folders.map(\.sample), byRun: true)
        for index in folders.indices { folders[index].sample = match.sampleIDs[index] }
        return (match.records.compactMap { record in folders.first { $0.sample == record.id } }, match.records)
    }

    /// Reads the single-cell folders and returns the writer's request, the record's facts and a summary line.
    func singleCellRequest(
        sheet: RNASeqSampleSheet?, read given: (folders: [SingleCellFolder], records: [RNASeqSampleRecord])? = nil
    ) throws -> (RNASeqResultWriter.Request, [String: ParameterValue], String) {
        let (ordered, records) = try given ?? singleCellFolders(sheet: sheet)
        let request = try SingleCellFolderReader.request(ordered, name: name, samples: records, genomes: genomes)
        let cells = ordered.reduce(0) { $0 + $1.size.columns }
        let tool = ordered.first?.tool.rawValue ?? ""
        let summary = "\(ordered.count) \(tool) \(ordered.count == 1 ? "folder" : "folders") and \(cells) cells"
        return (request, SingleCellFolderReader.facts(ordered, genomes: genomes), summary)
    }
}
