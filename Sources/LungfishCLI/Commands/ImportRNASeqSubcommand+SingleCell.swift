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

extension ImportCommand.RNASeqSubcommand.Plan {
    /// Reads the single-cell folders and returns the writer's request, the record's facts and a summary line.
    func singleCellRequest(sheet: RNASeqSampleSheet?) throws -> (RNASeqResultWriter.Request, [String: ParameterValue], String) {
        var folders: [SingleCellFolder] = []
        for url in inputs {
            try Task.checkCancellation()
            folders.append(try SingleCellFolderReader.read(folder: url))
        }
        let match = try RNASeqSampleSheet.match(sheet, fileIDs: folders.map(\.sample), byRun: true)
        for index in folders.indices { folders[index].sample = match.sampleIDs[index] }
        let ordered = match.records.compactMap { record in folders.first { $0.sample == record.id } }
        let request = try SingleCellFolderReader.request(ordered, name: name, samples: match.records, genomes: genomes)
        let cells = ordered.reduce(0) { $0 + $1.size.columns }
        let tool = ordered.first?.tool.rawValue ?? ""
        let summary = "\(ordered.count) \(tool) \(ordered.count == 1 ? "folder" : "folders") and \(cells) cells"
        return (request, SingleCellFolderReader.facts(ordered, genomes: genomes), summary)
    }
}
