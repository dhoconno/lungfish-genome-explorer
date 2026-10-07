// DemultiplexingPipeline+Preflight.swift - The refusals of a demultiplex run, made before it writes anything
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

extension DemultiplexingPipeline {
    /// Makes every refusal ``run(config:progress:)`` makes before it writes
    /// anything, so a caller can check a run before it deletes earlier
    /// results. `lungfish-cli fastq demultiplex --replace` deleted its output
    /// folder and then met these refusals inside the run (L5 item 0).
    ///
    /// It refuses a kit without barcodes, a missing input, a sample-assigned
    /// asymmetric kit with no barcode pair it can resolve, an exact-bare run
    /// with a kit the engine cannot match, a cutadapt run whose output is not
    /// inside a project (its work folder lives in the project), and a kit
    /// that gives cutadapt no adapter (a combinatorial kit without sample
    /// assignments, a dual kit without second barcodes, or empty sequences).
    /// It runs no tool and writes only a scratch adapter file it removes.
    public func preflight(config: DemultiplexConfig) async throws {
        guard !config.barcodeKit.barcodes.isEmpty else {
            throw DemultiplexError.noBarcodes
        }
        let inputFASTQ = resolveInputFASTQ(config.inputURL)
        guard FileManager.default.fileExists(atPath: inputFASTQ.path) else {
            throw DemultiplexError.inputFileNotFound(inputFASTQ)
        }
        if config.symmetryMode == .asymmetric && !config.sampleAssignments.isEmpty {
            let resolvesABarcodePair = config.sampleAssignments.contains { assignment in
                resolveSequence(
                    explicitSequence: assignment.forwardSequence,
                    barcodeID: assignment.forwardBarcodeID,
                    kit: config.barcodeKit
                ) != nil && resolveSequence(
                    explicitSequence: assignment.reverseSequence,
                    barcodeID: assignment.reverseBarcodeID,
                    kit: config.barcodeKit
                ) != nil
            }
            guard resolvesABarcodePair else {
                throw DemultiplexError.combinatorialRequiresSampleAssignments
            }
            return
        }
        if config.engine == .exactBareBarcode {
            guard supportsExactBareBarcodeDemux(config) else {
                throw DemultiplexError.exactBareBarcodeUnsupported
            }
            return
        }
        guard ProjectTempDirectory.findProjectRoot(config.outputDirectory) != nil else {
            throw ProjectTempError.projectContextRequired(contextURL: config.outputDirectory)
        }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-demux-preflight-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let adapters = try await createAdapterConfiguration(for: config, workDirectory: scratch)
        try requireAdapterSequences(in: adapters.adapterFASTA, kitName: config.barcodeKit.displayName)
    }

    /// Refuses an adapter FASTA without a sequence, on which cutadapt fails
    /// with a message that does not name the kit.
    func requireAdapterSequences(in adapterFASTA: URL, kitName: String) throws {
        let fastaContent = try String(contentsOf: adapterFASTA, encoding: .utf8)
        let sequences = fastaContent.split(separator: "\n").filter { !$0.hasPrefix(">") && !$0.isEmpty }
        if sequences.isEmpty || sequences.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            throw DemultiplexError.emptyAdapterSequences(kitName: kitName)
        }
    }
}
