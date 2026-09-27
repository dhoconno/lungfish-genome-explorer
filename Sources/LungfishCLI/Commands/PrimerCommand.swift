import ArgumentParser
import Foundation
import LungfishCore
import LungfishWorkflow

struct PrimerCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "primers",
        abstract: "Build and inspect primer-scheme and analysis bundles",
        subcommands: [ImportSubcommand.self, SchemeFromAnalysisSubcommand.self, PrimerDesignCommand.self,
                      PrimerAnalysisCommand.self]
    )

    struct SchemeFromAnalysisSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "scheme-from-analysis",
            abstract: "Save a designed tiled scheme (PrimalScheme3, Olivar or tiled varVAMP) as a .lungfishprimers bundle for primer trimming",
            discussion: """
            The BED keeps the coordinates of the engine's design reference: the first alignment row for \
            PrimalScheme3, Olivar's generated reference, or varVAMP's ambiguous consensus. That reference is \
            written into the bundle as attachments/design-reference.fasta, and reads must be mapped to it \
            before the scheme can trim them. Use --list to see which results can be saved and why others cannot.
            """
        )

        @Argument(help: "Path to the saved .lungfishprimeranalysis bundle.")
        var analysisPath: String

        @Option(name: .customLong("result-id"), help: "Result UUID from --list. Required when more than one result can be saved.")
        var resultID: String?

        @Option(name: .customLong("output"), help: "Output .lungfishprimers bundle name or path.")
        var outputPath: String?

        @Option(name: .customLong("project"), help: "Optional Lungfish project; relative output is written under Primer Schemes/.")
        var projectPath: String?

        @Option(name: .customLong("display-name"), help: "Human-readable scheme name. Defaults to the analysis and result names.")
        var displayName: String?

        @Flag(name: .long, help: "List the results in the analysis and whether each can be saved, then exit.")
        var list = false

        func validate() throws {
            if let resultID, UUID(uuidString: resultID) == nil {
                throw ValidationError("--result-id must be a UUID from --list.")
            }
            guard list || outputPath != nil else {
                throw ValidationError("Pass --output <name>, or --list to see the results that can be saved.")
            }
        }

        func run() throws {
            if list {
                print(try listingOutput())
                return
            }
            let result = try execute(argv: CommandLine.arguments)
            print("Primer scheme bundle written to \(result.bundleURL.path)")
        }

        func listingOutput() throws -> String {
            let candidates = try PrimerSchemeFromAnalysisService.candidates(analysisURL: URL(fileURLWithPath: analysisPath))
            guard !candidates.isEmpty else {
                return "No result in this analysis can be saved as a primer scheme. Primer3 candidate pairs are not a tiled scheme."
            }
            return candidates.map { candidate in
                var lines = ["Result: \(candidate.label) (\(candidate.resultID.uuidString))", "Engine: \(candidate.engine)"]
                if let reason = candidate.refusalReason {
                    lines.append("Cannot be saved: \(reason)")
                } else {
                    lines += ["Reference: \(candidate.referenceID)",
                              "Primers: \(candidate.primerCount); amplicons: \(candidate.ampliconCount); pools: \(candidate.poolCount)",
                              candidate.referenceStatement]
                    lines += candidate.notes.map { "Note: \($0)" }
                }
                return lines.joined(separator: "\n")
            }.joined(separator: "\n\n")
        }

        func executeForTesting(argv: [String]) throws -> PrimerSchemeImportResult {
            try execute(argv: argv)
        }

        private func execute(argv: [String]) throws -> PrimerSchemeImportResult {
            guard let outputPath else { throw ValidationError("Pass --output <name>.") }
            return try PrimerSchemeFromAnalysisService.export(request: PrimerSchemeFromAnalysisRequest(
                analysisURL: URL(fileURLWithPath: analysisPath),
                resultID: resultID.flatMap(UUID.init(uuidString:)),
                outputURL: URL(fileURLWithPath: outputPath),
                projectURL: projectPath.map(URL.init(fileURLWithPath:)),
                displayName: displayName,
                argv: argv,
                workflowName: "lungfish primers scheme-from-analysis",
                toolVersion: LungfishAppVersion.cliToolVersion))
        }
    }

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
                    toolVersion: LungfishAppVersion.cliToolVersion
                )
            )
        }
    }
}
