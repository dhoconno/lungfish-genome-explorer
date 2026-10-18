// ExtractSequenceSubcommand+Records.swift - extract sequence with no region, the whole sequences a viewer's FASTA export names
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

extension ExtractSequenceSubcommand {
    /// Refuses a run that names no sequence, mixes the ways to name one, or carries an option the records run would
    /// drop (the same rule the FASTA run applies to bundle options). It runs before anything else, and so before the
    /// leaf's start line.
    func validateRecordsRun() throws {
        var problems: [String] = []
        if regionArgument != nil {
            problems.append("A region and --sequence or --selection are two ways to say what to extract. Give one.")
        }
        if sequenceNames.isEmpty && selection == nil {
            problems.append("Give a region such as chr1:1000-2000, or name whole sequences with --sequence or --selection.")
        }
        if !sequenceNames.isEmpty && selection != nil {
            problems.append("--sequence and --selection both name the sequences. Give one.")
        }
        let toBundle = output.map { URL(fileURLWithPath: $0).pathExtension.lowercased() == "lungfishref" } ?? false
        if bundle || toBundle || name != nil || !samples.isEmpty || noSamples || featureName != nil
            || featureType != nil || strand != nil || concatenateExons || nextFreeName || sourceDocument != nil {
            problems.append("--bundle, a .lungfishref output and the bundle options take a region. Leave them out of a run that names sequences.")
        }
        if reverseComplement || flank != 0 || flank5 != nil || flank3 != nil {
            problems.append("--reverse-complement and --flank describe a region. A run that names sequences writes them as stored.")
        }
        if let lineWidthArgument, lineWidthArgument < 1 {
            problems.append("--line-width must be at least 1.")
        }
        if output == nil {
            problems.append("-o is required when sequences are named.")
        }
        guard problems.isEmpty else {
            throw CLIError.validationFailed(errors: problems)
        }
    }

    /// The records run under the viewer export leaf's rules (ARCH ruling 1.6). A refusal exits 3, a failure 64 and a
    /// cancel 125, and with `--format json` standard output holds only events.
    func runRecords() async throws {
        let command = self
        try await ViewerExportLeaf.run(globalOptions: globalOptions, startMessage: "Extracting FASTA records.") { _ in
            try command.exportRecords()
        }
    }

    /// The invocation this parse stands for, which the record's argv comes from.
    func recordsInvocation() -> ViewerExportInvocation {
        FASTARecordsExport.invocation(
            sourceURL: URL(fileURLWithPath: input),
            sequences: sequenceNames,
            selectionURL: selection.map { URL(fileURLWithPath: $0) },
            lineWidth: lineWidthArgument,
            outputURL: URL(fileURLWithPath: output ?? ""),
            force: force,
            emitsEvents: globalOptions.outputFormat == .json
        )
    }

    /// The export. It refuses before it writes, reads the FASTA file and the selection file it was given, and writes
    /// the named records as stored with their record in one transaction. The record names those two files as its
    /// inputs, each with its digest (BIO 6).
    func exportRecords() throws -> ViewerExportLeafOutcome {
        let runClock = ProvenanceRunClock()
        let invocation = recordsInvocation()
        let sourceURL = URL(fileURLWithPath: invocation.input)
        let selectionURL = invocation.selection.map { URL(fileURLWithPath: $0) }
        let outputURL = URL(fileURLWithPath: invocation.output)
        let inputs = [sourceURL] + (selectionURL.map { [$0] } ?? [])

        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw ViewerExportRefusal("No FASTA file at \(sourceURL.path). Pass the file the sequences are in.")
        }
        guard FASTARecordsExport.fastaExtensions.contains(sourceURL.pathExtension.lowercased()) else {
            throw ViewerExportRefusal(
                "\(sourceURL.lastPathComponent) is not a plain FASTA file (.fa, .fasta, .fna or .faa). Decompress it first."
            )
        }
        if let selectionURL, !FileManager.default.fileExists(atPath: selectionURL.path) {
            throw ViewerExportRefusal("No selection file at \(selectionURL.path). Pass the file the app wrote for this export.")
        }
        try ViewerExportLeaf.refuseUnsafeOutput(outputURL, inputs: inputs, force: force)

        var names = sequenceNames
        if let selectionURL {
            do {
                names = try ViewerExportSelection.read(from: selectionURL).identities
            } catch {
                throw ViewerExportRefusal("The selection file at \(selectionURL.path) cannot be read. \(error)")
            }
            guard !names.isEmpty else {
                throw ViewerExportRefusal("The selection file at \(selectionURL.path) names no sequence. Export again from the app.")
            }
        }
        let document = FASTARecordsExport.document(from: try Data(contentsOf: sourceURL))
        guard document.preambleLength == 0, !document.records.isEmpty else {
            throw ViewerExportRefusal("\(sourceURL.lastPathComponent) holds no FASTA records, or text before its first header.")
        }
        let records: [FASTARecordsExport.Record]
        do {
            records = try FASTARecordsExport.resolve(names, in: document)
        } catch let missing as FASTARecordsExport.NameNotFound {
            throw ViewerExportRefusal("\(missing.localizedDescription) File: \(sourceURL.lastPathComponent).")
        }
        var payload = Data()
        for record in records {
            let stored = document.bytes(of: record)
            payload.append(lineWidthArgument.map { FASTARecordsExport.rewrapped(stored, lineWidth: $0) } ?? stored)
        }

        var explicitOptions: [String: ParameterValue] = ["outputPath": .file(outputURL)]
        if let lineWidthArgument {
            explicitOptions["lineWidth"] = .integer(lineWidthArgument)
        }
        if let selectionURL {
            explicitOptions["selection"] = .file(selectionURL)
        } else {
            explicitOptions["sequences"] = .array(names.map { .string($0) })
        }
        if force {
            explicitOptions["force"] = .boolean(true)
        }
        try Task.checkCancellation()
        try ScientificFileExportProvenance.writeAtomically(.cliLeaf(
            workflowName: FASTARecordsExport.workflowName,
            sourceURLs: inputs,
            outputURL: outputURL,
            outputFormat: .fasta,
            argv: invocation.canonicalArgv(),
            explicitOptions: explicitOptions,
            resolved: [
                "recordCount": .integer(records.count),
                "outputByteCount": .integer(payload.count),
            ],
            runClock: runClock
        )) { stagedURL in
            try payload.write(to: stagedURL, options: .atomic)
            try ViewerExportLeaf.checkpointAfterStaging()
        }
        let noun = records.count == 1 ? "sequence" : "sequences"
        return ViewerExportLeafOutcome(
            outputURL: outputURL,
            message: "Wrote \(records.count) \(noun) to \(outputURL.lastPathComponent)"
        )
    }
}
