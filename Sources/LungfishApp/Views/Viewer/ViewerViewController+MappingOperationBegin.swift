// ViewerViewController+MappingOperationBegin.swift - Operations panel registration for mapping viewport launches
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishKit
import LungfishWorkflow

/// The begin helpers for the launches in the baselined
/// ViewerViewController+Mapping.swift (finding R4). Each one registers a row
/// through `OperationReporting` and calls `launch` only when the row started,
/// so a test can check the row and its command without touching
/// `OperationCenter.shared`. They live here, not beside their launch sites, so
/// the baselined file does not grow (scripts/ratchets/file-size.sh).
extension ViewerViewController {
    /// Registers the alignment consensus row and, only when it starts, calls
    /// `launch` with the operation ID. The row locks no bundle.
    ///
    /// CLI parity gap. No lungfish-cli command calls a consensus from a BAM or
    /// CRAM alignment. The closest is `msa consensus`, which reads a
    /// `.lungfishmsa` bundle. The row keeps recording the
    /// `Lungfish.app alignment consensus` description it has always recorded.
    /// That text does not start with `lungfish-cli` and does not parse. A
    /// command that calls a consensus from an alignment would replace it.
    @discardableResult
    static func beginAlignmentConsensusGenerationOperation(
        region: ResolvedAlignmentRegion,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let result = reporter.begin(
            title: "Generate Alignment Consensus",
            detail: "Calling evidence-only consensus…",
            operationType: .export,
            cliCommand: "Lungfish.app alignment consensus --scope \(region.scope.rawValue) --region \(region.contig):\(region.start)-\(region.end) --reference-fill never"
        )
        switch result {
        case .started(let operationID):
            launch(operationID)
        case .refused:
            break // The panel already shows the refused row. Nothing was launched.
        }
        return result
    }

    /// Registers the overlapping-reads row and, only when it starts, calls
    /// `launch` with the operation ID. The row locks no bundle and records the
    /// `lungfish-cli extract reads --by-region` command for the configuration
    /// the run uses.
    @discardableResult
    static func beginOverlappingReadsExtractionOperation(
        annotationName: String,
        config: BAMRegionExtractionConfig,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let result = reporter.begin(
            title: "Extract Overlapping Reads",
            detail: "Extracting reads overlapping \(annotationName)…",
            operationType: .taxonomyExtraction,
            cliCommand: overlappingReadsExtractionCLICommand(config: config)
        )
        switch result {
        case .started(let operationID):
            launch(operationID)
        case .refused:
            break // The panel already shows the refused row. Nothing was launched.
        }
        return result
    }

    /// The `lungfish-cli extract reads --by-region` command that reproduces a
    /// run of `ReadExtractionService.extractByBAMRegion` with this
    /// configuration. The run writes `<outputBaseName>.fastq` in the output
    /// directory, so the command names that file in `-o`. The annotation
    /// action sets no map quality, flag or read group filter, and its
    /// duplicate exclusion is the command's default, so the command needs no
    /// option for them. The run passes the mapping's index, and the command
    /// names none because the CLI finds the BAM's companion index, the same
    /// file. The shared service hands each coordinate region, such as
    /// `chr1:11-25`, to samtools as given, so the run and the command write
    /// the same reads, the ones that overlap the annotation's blocks.
    static func overlappingReadsExtractionCLICommand(config: BAMRegionExtractionConfig) -> String {
        var args = ["--by-region", "--bam", config.bamURL.path]
        for region in config.regions {
            args += ["--region", region]
        }
        let outputName = "\(ExtractionBundleNaming.sanitizeFilename(config.outputBaseName)).fastq"
        args += ["-o", config.outputDirectory.appendingPathComponent(outputName).path]
        return OperationCenter.buildCLICommand(subcommand: "extract reads", args: args)
    }
}
