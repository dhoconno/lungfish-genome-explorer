// GATKCommand+CommandLine.swift - The command line a gatk run records as its own
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishWorkflow

/// A `gatk` subcommand that can say the `lungfish-cli` command that runs its options again.
protocol GATKCLICommandLineRecording: ParsableCommand {
    /// The `lungfish-cli gatk` command that runs these options again, every option written out in
    /// the order of `--help`. A parse cannot tell a typed default from an untyped one, so an option
    /// that has a default is written with its value and a replay does not change when a default
    /// does. An option with no value and a flag that is off are left out.
    func canonicalArguments() -> [String]
}

extension GATKCLICommandLineRecording {
    /// `request` as its record names the command that ran. That is the command line this process was
    /// started with when it names this subcommand (`gatk <subcommand>`, as typed), else
    /// ``canonicalArguments()`` (a test runs the command inside another process, where `arguments`
    /// names the test runner).
    func recorded(
        _ request: GATKPipelineExecutionRequest,
        arguments: [String] = CommandLine.arguments
    ) -> GATKPipelineExecutionRequest {
        let words = arguments.dropFirst()
        let namesThisCommand = zip(words, words.dropFirst()).contains { $0 == "gatk" && $1 == Self._commandName }
        return request.recording(cliCommandLine: namesThisCommand ? arguments : canonicalArguments())
    }
}

extension GATKCLIExecutableSubcommand {
    /// `lungfish-cli gatk <subcommand>` and the run mode the command was given.
    fileprivate var canonicalPrefix: [String] {
        var prefix = [CLICommandIdentity.executableName, "gatk", Self._commandName]
        if execute { prefix.append("--execute") }
        if dryRun { prefix.append("--dry-run") }
        return prefix
    }
}

extension GATKCLICommand.HaplotypeCallerSubcommand {
    func canonicalArguments() -> [String] {
        var arguments = canonicalPrefix
        arguments += [
            "--reference", reference, "--bam", bam, "--output", output,
            "--emit-ref-confidence", emitReferenceConfidence, "--ploidy", String(ploidy),
        ]
        if let intervals { arguments += ["--intervals", intervals] }
        arguments += [
            "--pcr-indel-model", pcrIndelModel, "--stand-call-conf", String(standCallConf),
            "--max-alternate-alleles", String(maxAlternateAlleles), "--pair-hmm-threads", String(pairHMMThreads),
        ]
        if !extraArgs.isEmpty { arguments += ["--extra-args", extraArgs] }
        return arguments
    }
}

extension GATKCLICommand.JointGenotypeSubcommand {
    func canonicalArguments() -> [String] {
        var arguments = canonicalPrefix
        arguments += ["--reference", reference]
        for gvcf in gvcfs { arguments += ["--gvcf", gvcf] }
        arguments += ["--output", output, "--intermediate", intermediate, "--combine-strategy", combineStrategy]
        if let intervals { arguments += ["--intervals", intervals] }
        if !extraArgs.isEmpty { arguments += ["--extra-args", extraArgs] }
        return arguments
    }
}

extension GATKCLICommand.FilterSubcommand {
    func canonicalArguments() -> [String] {
        var arguments = canonicalPrefix
        arguments += ["--vcf", vcf, "--preset", preset, "--output", output]
        if !extraArgs.isEmpty { arguments += ["--extra-args", extraArgs] }
        return arguments
    }
}

extension GATKCLICommand.SelectSubcommand {
    func canonicalArguments() -> [String] {
        var arguments = canonicalPrefix
        arguments += ["--vcf", vcf]
        if let sample { arguments += ["--sample", sample] }
        if let type { arguments += ["--type", type] }
        if let intervals { arguments += ["--intervals", intervals] }
        arguments += ["--output", output]
        if !extraArgs.isEmpty { arguments += ["--extra-args", extraArgs] }
        return arguments
    }
}

extension GATKCLICommand.VariantsToTableSubcommand {
    func canonicalArguments() -> [String] {
        var arguments = canonicalPrefix
        arguments += ["--vcf", vcf, "--fields", fields, "--output", output]
        if !extraArgs.isEmpty { arguments += ["--extra-args", extraArgs] }
        return arguments
    }
}

extension GATKCLICommand.BQSRSubcommand {
    func canonicalArguments() -> [String] {
        var arguments = canonicalPrefix
        arguments += ["--reference", reference, "--bam", bam]
        for site in knownSites { arguments += ["--known-sites", site] }
        arguments += ["--recal-table", recalTable, "--output", output]
        if let intervals { arguments += ["--intervals", intervals] }
        arguments += ["--create-output-bam-index", String(createOutputBAMIndex)]
        if !extraArgs.isEmpty { arguments += ["--extra-args", extraArgs] }
        return arguments
    }
}

extension GATKCLICommand.MarkDuplicatesSubcommand {
    func canonicalArguments() -> [String] {
        var arguments = canonicalPrefix
        for input in bams { arguments += ["--bam", input] }
        arguments += ["--output", output, "--metrics", metrics, "--create-index", String(createIndex)]
        if removeDuplicates { arguments.append("--remove-duplicates") }
        if let validationStringency { arguments += ["--validation-stringency", validationStringency] }
        if !extraArgs.isEmpty { arguments += ["--extra-args", extraArgs] }
        return arguments
    }
}

extension GATKCLICommand.ValidateSamSubcommand {
    func canonicalArguments() -> [String] {
        var arguments = canonicalPrefix
        arguments += ["--bam", bam]
        if let output { arguments += ["--output", output] }
        if let reference { arguments += ["--reference", reference] }
        arguments += [
            "--mode", mode, "--validate-index", String(validateIndex), "--ignore-warnings", String(ignoreWarnings),
        ]
        if !extraArgs.isEmpty { arguments += ["--extra-args", extraArgs] }
        return arguments
    }
}

extension GATKCLICommand.LeftAlignSubcommand {
    func canonicalArguments() -> [String] {
        var arguments = canonicalPrefix
        arguments += ["--reference", reference, "--vcf", vcf, "--output", output]
        if let intervals { arguments += ["--intervals", intervals] }
        if splitMultiAllelics { arguments.append("--split-multi-allelics") }
        arguments += ["--max-indel-length", String(maxIndelLength), "--max-leading-bases", String(maxLeadingBases)]
        if !extraArgs.isEmpty { arguments += ["--extra-args", extraArgs] }
        return arguments
    }
}

extension GATKCLICommand.CollectMetricsSubcommand {
    func canonicalArguments() -> [String] {
        var arguments = canonicalPrefix
        arguments += ["--vcf", vcf, "--output-prefix", outputPrefix, "--dbsnp", dbsnp]
        if let sequenceDictionary { arguments += ["--sequence-dictionary", sequenceDictionary] }
        if gvcfInput { arguments.append("--gvcf-input") }
        if !extraArgs.isEmpty { arguments += ["--extra-args", extraArgs] }
        return arguments
    }
}
