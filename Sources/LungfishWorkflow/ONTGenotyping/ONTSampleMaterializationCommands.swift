// ONTSampleMaterializationCommands.swift - The commands the ONT sample materializers record in each sample bundle
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Each ONT sample materializer writes one .lungfishfastq bundle per sample and
// records a command in the bundle's manifest (`operation.toolCommand`, which the
// Inspector shows with a Copy button). The three used to record
// `lungfish fastq ont-fluidigm-samples` or `lungfish fastq
// ont-pacbio-barcode-demux`, the legacy executable name with no arguments, so
// the command named neither the input, the barcode sheet nor a setting
// (findings R3 and R8). They now record the `lungfish-cli` command with the
// values the run read when one reproduces the run, and otherwise a
// `Lungfish.app` form with descriptive flags, which no shell runs. Only the
// recorded string changed. What the materializers compute did not.

import Foundation
import LungfishCore

extension ONTPacBioBarcodeDemuxMaterializationRequest {
    /// The `lungfish-cli fastq ont-pacbio-barcode-demux` argv that runs this
    /// request, with every value the run reads, in the order the command
    /// records its own argv.
    public var recordedCommandArguments: [String] {
        var arguments = [
            CLICommandIdentity.executableName, "fastq", "ont-pacbio-barcode-demux",
            inputURL.path,
            "--barcodes", barcodeDefinitionsURL.path,
            "--output", outputDirectory.path,
            "--threads", String(threads),
            "--chunk-jobs", String(chunkJobs),
            "--max-reads-per-slice", String(maxReadsPerSlice),
            "--max-bytes-per-cutadapt", String(maxInputBytesPerCutadapt),
        ]
        if force {
            arguments.append("--force")
        }
        return arguments
    }

    /// ``recordedCommandArguments`` as one shell-quoted command line, the
    /// `toolCommand` of every sample bundle.
    public var recordedCommandLine: String {
        recordedCommandArguments.map(shellEscape).joined(separator: " ")
    }
}

extension ONTFluidigmAmpliconMaterializationRequest {
    /// The command that runs this request.
    ///
    /// `lungfish-cli fastq ont-fluidigm-samples` runs this materializer with
    /// the default CS1 and CS2 primers, so a request with those primers
    /// records that command with every value the run reads. The reverse
    /// complement setting is always spelled out, because the command's default
    /// differs from this request's. The command takes `--threads`, which
    /// changes no output and which the request does not carry, so the command
    /// leaves it out. No option sets other primers, so a request with other
    /// primers records `Lungfish.app ont-fluidigm-samples` with the primers as
    /// descriptive flags.
    public var recordedCommandArguments: [String] {
        let usesTheCommandsPrimers = forwardPrimer == ONTFluidigmAmpliconMaterializer.defaultForwardPrimer
            && reversePrimer == ONTFluidigmAmpliconMaterializer.defaultReversePrimer
        var arguments = usesTheCommandsPrimers
            ? [CLICommandIdentity.executableName, "fastq", "ont-fluidigm-samples"]
            : ["Lungfish.app", "ont-fluidigm-samples"]
        arguments += [
            inputURL.path,
            "--barcodes", barcodeDefinitionsURL.path,
            "--output", outputDirectory.path,
            "--primer-mismatches", String(primerMismatches),
            "--minimum-insert-length", String(minimumInsertLength),
            canonicalizeReverseComplements
                ? "--canonicalize-reverse-complements"
                : "--no-canonicalize-reverse-complements",
        ]
        if !usesTheCommandsPrimers {
            arguments += ["--forward-primer", forwardPrimer, "--reverse-primer", reversePrimer]
        }
        if force {
            arguments.append("--force")
        }
        return arguments
    }

    /// ``recordedCommandArguments`` as one shell-quoted command line, the
    /// `toolCommand` of every sample bundle.
    public var recordedCommandLine: String {
        recordedCommandArguments.map(shellEscape).joined(separator: " ")
    }
}

extension ONTFluidigmSampleMaterializationRequest {
    /// The `Lungfish.app ont-fluidigm-whole-read-samples` form for this
    /// request, with every value the run reads as a descriptive flag.
    ///
    /// No `lungfish-cli` command runs this materializer. `fastq
    /// ont-fluidigm-samples`, the command the manifests named, runs
    /// `ONTFluidigmAmpliconMaterializer`, which cuts each read to its CS1 to
    /// CS2 insert, where this materializer keeps whole reads.
    public var recordedCommandArguments: [String] {
        var arguments = [
            "Lungfish.app", "ont-fluidigm-whole-read-samples",
            inputURL.path,
            "--barcodes", barcodeDefinitionsURL.path,
            "--output", outputDirectory.path,
            "--forward-primer", forwardPrimer,
            "--reverse-primer", reversePrimer,
        ]
        if force {
            arguments.append("--force")
        }
        return arguments
    }

    /// ``recordedCommandArguments`` as one shell-quoted command line, the
    /// `toolCommand` of every sample bundle.
    public var recordedCommandLine: String {
        recordedCommandArguments.map(shellEscape).joined(separator: " ")
    }
}
