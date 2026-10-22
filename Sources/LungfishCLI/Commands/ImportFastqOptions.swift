// ImportFastqOptions.swift - The settings of a FASTQ import, one group that import fastq and fetch sra download --bundle share
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishWorkflow

/// The flags that choose how reads import, the ones `CLIImportRunner.buildCLIArguments` writes for
/// the app's Import FASTQ sheet (Phase 2.10 lane A45 M3, ruling A45-M3 section 1).
///
/// `import fastq` and `fetch sra download --bundle` embed this one group, so the names, the values
/// and the help text of a setting are written once. The app's SRA row passes the sheet's choices
/// to the second command as these flags. The names `--platform`, `--pairing`, `--quality-binning`,
/// `--compression`, `--recipe`, `--no-optimize-storage` and `--clumping-tool` are
/// `CLIImportRunner.buildCLIArguments`' own.
struct ImportFastqOptions: ParsableArguments {
    @Option(
        name: .customLong("platform"),
        help: ArgumentHelp(
            "Sequencing platform: auto, illumina, ont, pacbio, element, mgi, ultima, unknown",
            discussion: """
            auto infers each sample's platform from its read headers (and a BAM \
            file's @RG PL) and prints the evidence. Reads whose platform cannot \
            be inferred are recorded as unknown, never as Illumina. A given value \
            is recorded as given, even when the reads suggest another platform.
            """
        )
    )
    var platform: String = "auto"

    @Option(
        name: .customLong("pairing"),
        help: ArgumentHelp(
            "Read pairing: auto, single, paired, interleaved",
            discussion: """
            auto and paired match R1/R2 files by name, inside one folder first. \
            Mates in two folders pair only when no other listed file has either \
            name. When one does, a warning names the files. They also join a run's \
            file named for the run alone, such as SRR1.fastq beside SRR1_1.fastq and \
            SRR1_2.fastq, to that pair as unpaired reads, by the same folder rule, \
            when the first reads of the pair are named as mates, the first read of \
            that file is not from their fragment, and no two adjacent reads among \
            the first 1,000 of that file are mates. Otherwise the import skips that \
            file and a warning says why. The import fails the sample when two \
            adjacent reads later in that file are mates. \
            For any other file with no mate file, they read its records and \
            record interleaved mates when every record is followed by its mate, \
            otherwise single-end. single imports every file as its own single-end \
            sample, even when a mate is detected. interleaved imports every file on \
            its own and records it as interleaved mates.
            """
        )
    )
    var pairing: String = "auto"

    @Option(
        name: .customLong("quality-binning"),
        help: ArgumentHelp(
            "Quality binning: illumina4 (7 quality levels, the default), eightLevel (~21 quality levels), none",
            discussion: """
            Every import bins quality scores with illumina4 on every platform unless \
            this option or the recipe names another value. Binning saves space and is \
            lossy. The original scores cannot be recovered once the original files are \
            removed. Pass --quality-binning none to keep every score as the reads have it.
            """
        )
    )
    var qualityBinning: String?

    @Option(
        name: .customLong("compression"),
        help: "Compression level: fast, balanced, maximum"
    )
    var compression: String = "balanced"

    @Option(
        name: .customLong("recipe"),
        help: ArgumentHelp(
            "Processing recipe: \(ImportCommand.FastqSubcommand.recipeHelpNames()), or none",
            discussion: ImportCommand.FastqSubcommand.recipeHelpDiscussion()
        )
    )
    var recipe: String = "none"

    /// The binning the import runs, as `--quality-binning` names it. The option comes first, then the recipe's
    /// declared value, then the import default. A command that records this value replays the same whatever the
    /// default is (lane C2-BINNING).
    var resolvedQualityBinning: String {
        if let qualityBinning { return qualityBinning }
        if recipe.lowercased() != "none",
           let resolved = try? ImportCommand.FastqSubcommand.resolveImportRecipe(named: recipe, switchOptions: switchOptions),
           let declared = resolved.newRecipe?.qualityBinning {
            return declared.rawValue
        }
        return QualityBinningScheme.importDefault.rawValue
    }

    @Flag(
        name: .customLong("remove-duplicates"),
        inversion: .prefixedNo,
        help: "Remove duplicate reads. Replaces the recipe's setting."
    )
    var removeDuplicates: Bool?

    @Flag(
        name: .customLong("remove-ribosomal-rna"),
        inversion: .prefixedNo,
        help: ArgumentHelp(
            "Remove ribosomal RNA reads. Replaces the recipe's setting.",
            discussion: "Removal is final for a stored import. Only a reimport from the raw files brings the removed reads back."
        )
    )
    var removeRibosomalRNA: Bool?

    /// The recipe switches an option set, by switch id (CHTC lane C2-MERGED). A recipe without one of these
    /// switches refuses the option by name.
    var switchOptions: [String: Bool] {
        var options: [String: Bool] = [:]
        options["removeDuplicates"] = removeDuplicates
        options["removeRibosomalRNA"] = removeRibosomalRNA
        return options
    }

    /// The options that give ``switchOptions``, for a command that passes the settings on.
    var switchOptionArguments: [String] {
        switchOptions.sorted { $0.key < $1.key }.map { ($0.value ? "--" : "--no-") + RecipeSwitch.optionName(for: $0.key) }
    }

    @Flag(
        name: .customLong("no-optimize-storage"),
        help: "Skip read reordering for storage optimization"
    )
    var noOptimizeStorage: Bool = false

    @Option(
        name: .customLong("clumping-tool"),
        help: "Storage optimization tool: auto, bbtools, trim-galore, none (default: platform-specific)"
    )
    var clumpingTool: String?
}
