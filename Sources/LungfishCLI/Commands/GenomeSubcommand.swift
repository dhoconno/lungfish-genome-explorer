// GenomeSubcommand.swift - Download genome assemblies and nucleotide records from NCBI as indexed bundles
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

// MARK: - Genome Subcommand

/// Downloads genome assemblies and nucleotide records from NCBI and builds one indexed bundle for
/// each, through the builders the app's NCBI browser uses (Phase 2.10 lane A44). FetchGenomeRun.swift
/// holds the run and FetchGenomeReporter.swift its events and human text.
struct GenomeSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "genome",
        abstract: "Download genomes from NCBI and create indexed bundles",
        discussion: """
            Downloads each genome from NCBI, with its FASTA sequence and GFF3
            annotations, and builds one .lungfishref bundle for each accession.

            Assembly accessions (GCF_/GCA_) are resolved through the assembly
            database and built as the app's genome download builds them, in a
            bundle named '<organism> - <assembly name>'. Any other accession is
            fetched from nucleotide as its GenBank record, which is the exact
            record requested, and built as the app's GenBank download builds it,
            in a bundle named by the accession. --name names the bundle of one
            accession instead.

            An assembly bundle is built in the project's .tmp folder, or in a
            hidden folder of --output-dir outside a project, and then moved into
            --output-dir. A bundle never replaces another. The next free name
            adds _1, _2 and so on. Each bundle holds a provenance record that
            names every file fetched with its digest and size.

            --into-bundle adds the genome and annotations of one accession to an
            existing .lungfishref bundle, such as a bundle imported from a VCF
            with no reference, and keeps its variants and tracks.

            With --format json the command prints CLIEvent lines on standard
            output and its human text on standard error, and its complete event
            names each bundle. SIGTERM stops the run, removes the bundle it was
            building and exits 125. The NCBI key comes from --api-key or from
            the NCBI_API_KEY environment variable.

            The bundle contains:
            - Compressed, indexed FASTA (bgzip + samtools faidx)
            - SQLite annotation database (converted from GFF3)
            - Manifest with metadata

            Examples:
              lungfish-cli fetch genome GCF_003047895.1 --output-dir ./genomes
              lungfish-cli fetch genome GCF_003047895.1 GCF_000001405.40 --output-dir ./genomes
              lungfish-cli fetch genome MN908947.3 --output-dir ./genomes
              lungfish-cli fetch genome GCF_000001405.40 --name "Human GRCh38" --output-dir ./
              lungfish-cli fetch genome GCF_003047895.1 --fasta-only --output-dir ./
              lungfish-cli fetch genome NC_045512.2 --into-bundle ./variants.lungfishref
            """
    )

    @Argument(help: "Assembly (GCF_003047895.1) or nucleotide (MN908947.3) accessions, one bundle each")
    var accessions: [String]

    @Option(
        name: .customLong("output-dir"),
        help: "Output directory for the bundles (default: current directory)"
    )
    var outputDir: String = "."

    @Option(
        name: .long,
        help: "Bundle name for one accession (default: derived from the assembly or record)"
    )
    var name: String?

    @Option(
        name: .customLong("into-bundle"),
        help: "Add the genome and annotations of one accession to this existing .lungfishref bundle"
    )
    var intoBundle: String?

    @Flag(
        name: .customLong("fasta-only"),
        help: "Download only the FASTA sequence (no annotations, no bundle)"
    )
    var fastaOnly: Bool = false

    @Flag(
        name: .customLong("no-bundle"),
        help: "Download files but don't create a .lungfishref bundle"
    )
    var noBundle: Bool = false

    @Option(
        name: .customLong("api-key"),
        help: "NCBI API key for higher rate limits (default: the NCBI_API_KEY environment variable)"
    )
    var apiKey: String?

    @OptionGroup var globalOptions: GlobalOptions

    func validate() throws {
        if accessions.count > 1, name != nil {
            throw ValidationError("--name names one bundle, so it takes one accession.")
        }
        if intoBundle != nil {
            guard accessions.count == 1 else {
                throw ValidationError("--into-bundle adds one genome, so it takes one accession.")
            }
            guard name == nil, !fastaOnly, !noBundle else {
                throw ValidationError("--into-bundle builds no bundle of its own, so it takes no --name, --fasta-only or --no-bundle.")
            }
        }
    }

    func run() async throws {
        let reporter = FetchGenomeReporter(
            eventsOn: globalOptions.outputFormat == .json,
            quiet: globalOptions.quiet,
            useColors: globalOptions.useColors
        )
        let run = FetchGenomeRun(request: FetchGenomeRequest(command: self), reporter: reporter)
        reporter.start(accessions: accessions)

        // SIGTERM (the Operations panel's Cancel) cancels the run, so the bundle it was building is
        // removed before the command exits 125. It listens before the task starts, and a SIGTERM
        // caught before then cancels the task as soon as it exists. A second SIGTERM ends the
        // command at once. A bundle already published stays, with its record.
        let pendingCancel = PendingTaskCancel<FetchGenomeOutcome>()
        let termination = SIGTERMCancellation(cancelling: pendingCancel, secondSignalEndsProcess: true)
        let task = Task { await run.fetchAll() }
        pendingCancel.attach(task)
        let outcome = await task.value
        termination.end()
        try reporter.finish(outcome)
    }
}

/// The options of one `fetch genome` run, resolved to URLs.
struct FetchGenomeRequest: Sendable {
    let accessions: [String]
    let outputURL: URL
    let name: String?
    let intoBundleURL: URL?
    let fastaOnly: Bool
    let noBundle: Bool
    let apiKey: String?
    let outputFormat: OutputFormat
    let quiet: Bool

    init(command: GenomeSubcommand) {
        accessions = command.accessions
        outputURL = URL(fileURLWithPath: command.outputDir).standardizedFileURL
        name = command.name
        intoBundleURL = command.intoBundle.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
        fastaOnly = command.fastaOnly
        noBundle = command.noBundle
        apiKey = command.apiKey
        outputFormat = command.globalOptions.outputFormat
        quiet = command.globalOptions.quiet
    }
}
