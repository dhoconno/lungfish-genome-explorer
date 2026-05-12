import ArgumentParser
import Foundation
import LungfishWorkflow

struct PrimerCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "primers",
        abstract: "Build and inspect primer-scheme bundles",
        subcommands: [ImportSubcommand.self]
    )

    struct ImportSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "import",
            abstract: "Import a BED primer scheme as a .lungfishprimers bundle"
        )

        @Option(name: .customLong("bed"), help: "Primer scheme BED file.")
        var bedPath: String

        @Option(name: .customLong("fasta"), help: "Optional primer FASTA to copy into the bundle.")
        var fastaPath: String?

        @Option(name: .customLong("output"), help: "Output .lungfishprimers bundle name or path.")
        var outputPath: String

        @Option(name: .customLong("project"), help: "Optional Lungfish project; relative output is written under Primer Schemes/.")
        var projectPath: String?

        @Option(name: .customLong("reference-accession"), help: "Canonical reference accession. Defaults to the first BED column.")
        var referenceAccession: String?

        @Option(name: .customLong("display-name"), help: "Human-readable scheme name. Defaults to the output stem.")
        var displayName: String?

        @Option(name: .customLong("equivalent-accession"), help: "Additional equivalent reference accession. Repeatable.")
        var equivalentAccessions: [String] = []

        @Option(name: .customLong("attachment"), help: "Extra documentation file to copy under attachments/. Repeatable.")
        var attachments: [String] = []

        func run() throws {
            let result = try execute(argv: CommandLine.arguments)
            print("Primer scheme bundle written to \(result.bundleURL.path)")
        }

        func executeForTesting(argv: [String]) throws -> PrimerSchemeImportResult {
            try execute(argv: argv)
        }

        private func execute(argv: [String]) throws -> PrimerSchemeImportResult {
            try PrimerSchemeImportService.importBundle(
                request: PrimerSchemeImportRequest(
                    bedURL: URL(fileURLWithPath: bedPath),
                    fastaURL: fastaPath.map(URL.init(fileURLWithPath:)),
                    attachments: attachments.map(URL.init(fileURLWithPath:)),
                    outputURL: URL(fileURLWithPath: outputPath),
                    projectURL: projectPath.map(URL.init(fileURLWithPath:)),
                    displayName: displayName,
                    canonicalAccession: referenceAccession,
                    equivalentAccessions: equivalentAccessions,
                    argv: argv,
                    workflowName: "lungfish primers import",
                    toolVersion: "lungfish-cli 0.4.0-alpha.14"
                )
            )
        }
    }
}
