import ArgumentParser
import Foundation
import LungfishWorkflow

extension TwelveSResultExportFormat: ExpressibleByArgument {}
extension TwelveSExportChimeraFilter: ExpressibleByArgument {}

struct FastqTwelveSExportSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "12s-export",
        abstract: "Export 12S amplicon result species rows to CSV, TSV, or Excel"
    )

    @Option(name: .customLong("bundle"), help: "Input .lungfish12s result bundle")
    var bundle: String

    @Option(name: .customLong("export-format"), help: "Export format: csv, tsv, xlsx")
    var format: TwelveSResultExportFormat

    @Option(name: .customLong("output"), help: "Output report path")
    var output: String

    @Option(name: .customLong("min-exact-reads"), help: "Minimum exact reads required for a species row")
    var minimumExactReads: Int = 0

    @Option(name: .customLong("filter"), help: "Case-insensitive species, common-name, taxon, or alternate-match text filter")
    var filterText: String = ""

    @Option(name: .customLong("taxon-group"), parsing: .upToNextOption, help: "Taxon group(s) to include, for example Mammal or Fish")
    var taxonGroups: [String] = []

    @Option(name: .customLong("exclude-taxon-group"), parsing: .upToNextOption, help: "Taxon group(s) to exclude")
    var excludedTaxonGroups: [String] = []

    @Flag(name: .customLong("exclude-human"), help: "Exclude Homo sapiens / taxid 9606 rows")
    var excludeHuman: Bool = false

    @Flag(name: .customLong("require-alternate-matches"), help: "Only export species rows with alternate exact species labels")
    var requireAlternateMatches: Bool = false

    @Option(name: .customLong("min-unresolved-reads"), help: "Minimum read count for unresolved rows in Excel export")
    var minimumUnresolvedReads: Int = 0

    @Option(name: .customLong("chimera-status"), help: "Unresolved chimera status filter for Excel export")
    var chimeraFilter: TwelveSExportChimeraFilter = .all

    @Flag(name: .customLong("force"), help: "Replace an existing output file")
    var force: Bool = false

    func run() async throws {
        let result = try await TwelveSResultExportWorkflow().export(configurationForTesting())
        FileHandle.standardError.write(Data("12S export written to \(result.outputURL.path)\n".utf8))
    }

    func configurationForTesting() -> TwelveSResultExportConfiguration {
        TwelveSResultExportConfiguration(
            bundleURL: URL(fileURLWithPath: bundle),
            outputURL: URL(fileURLWithPath: output),
            format: format,
            minimumExactReads: minimumExactReads,
            filterText: filterText,
            taxonGroups: taxonGroups,
            excludedTaxonGroups: excludedTaxonGroups,
            excludeHuman: excludeHuman,
            requireAlternateMatches: requireAlternateMatches,
            minimumUnresolvedReads: minimumUnresolvedReads,
            chimeraFilter: chimeraFilter,
            forceOverwrite: force,
            argv: replayArgv()
        )
    }

    private func replayArgv() -> [String] {
        var argv = [
            "lungfish-cli", "fastq", "12s-export",
            "--bundle", bundle,
            "--export-format", format.rawValue,
            "--output", output,
        ]
        if minimumExactReads != 0 {
            argv += ["--min-exact-reads", String(minimumExactReads)]
        }
        if !filterText.isEmpty {
            argv += ["--filter", filterText]
        }
        for group in taxonGroups {
            argv += ["--taxon-group", group]
        }
        for group in excludedTaxonGroups {
            argv += ["--exclude-taxon-group", group]
        }
        if excludeHuman {
            argv.append("--exclude-human")
        }
        if requireAlternateMatches {
            argv.append("--require-alternate-matches")
        }
        if minimumUnresolvedReads != 0 {
            argv += ["--min-unresolved-reads", String(minimumUnresolvedReads)]
        }
        if chimeraFilter != .all {
            argv += ["--chimera-status", chimeraFilter.rawValue]
        }
        if force {
            argv.append("--force")
        }
        return argv
    }
}

struct FastqTwelveSExportUnresolvedSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "12s-export-unresolved",
        abstract: "Export unresolved 12S sequence clusters above a read threshold to FASTA"
    )

    @Option(name: .customLong("bundle"), help: "Input .lungfish12s result bundle")
    var bundle: String

    @Option(name: .customLong("min-reads"), help: "Minimum identical-read count for unresolved sequence export")
    var minimumReads: Int = 5

    @Option(name: .customLong("output"), help: "Output FASTA path")
    var output: String

    @Option(name: .customLong("metadata-output"), help: "Optional TSV metadata output path")
    var metadataOutput: String?

    @Flag(name: .customLong("include-chimera-candidates"), help: "Include candidate or confirmed chimeras")
    var includeChimeraCandidates: Bool = false

    @Option(name: .customLong("sequence-id"), parsing: .upToNextOption, help: "Specific unresolved sequence ID(s) to export")
    var sequenceIDs: [String] = []

    @Flag(name: .customLong("force"), help: "Replace existing output files")
    var force: Bool = false

    func run() async throws {
        let result = try await TwelveSUnresolvedFastaExportWorkflow().export(configurationForTesting())
        FileHandle.standardError.write(Data("12S unresolved FASTA written to \(result.outputURL.path)\n".utf8))
    }

    func configurationForTesting() -> TwelveSUnresolvedFastaExportConfiguration {
        TwelveSUnresolvedFastaExportConfiguration(
            bundleURL: URL(fileURLWithPath: bundle),
            outputURL: URL(fileURLWithPath: output),
            metadataURL: metadataOutput.map { URL(fileURLWithPath: $0) },
            minimumReads: minimumReads,
            includeChimeraCandidates: includeChimeraCandidates,
            sequenceIDs: sequenceIDs,
            forceOverwrite: force,
            argv: replayArgv()
        )
    }

    private func replayArgv() -> [String] {
        var argv = [
            "lungfish-cli", "fastq", "12s-export-unresolved",
            "--bundle", bundle,
            "--min-reads", String(minimumReads),
            "--output", output,
        ]
        if let metadataOutput {
            argv += ["--metadata-output", metadataOutput]
        }
        if includeChimeraCandidates {
            argv.append("--include-chimera-candidates")
        }
        for sequenceID in sequenceIDs {
            argv += ["--sequence-id", sequenceID]
        }
        if force {
            argv.append("--force")
        }
        return argv
    }
}
