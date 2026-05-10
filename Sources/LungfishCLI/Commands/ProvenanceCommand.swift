import ArgumentParser
import Foundation
import LungfishWorkflow

struct ProvenanceCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "provenance",
        abstract: "Inspect provenance recorded in Lungfish bundles",
        subcommands: [
            BibliographySubcommand.self,
        ]
    )

    struct BibliographySubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "bibliography",
            abstract: "Generate a citation list from a bundle's provenance"
        )

        @Argument(help: "Bundle or output directory containing Lungfish provenance")
        var bundle: String

        func run() async throws {
            let bundleURL = URL(fileURLWithPath: bundle)
            guard FileManager.default.fileExists(atPath: bundleURL.path) else {
                throw CLIError.inputFileNotFound(path: bundle)
            }

            guard let provenance = loadProvenance(from: bundleURL) else {
                throw CLIError.workflowFailed(
                    reason: "No Lungfish provenance sidecar found in \(bundleURL.path)"
                )
            }

            let bibliography = ToolBibliographyCatalog.bibliography(for: provenance)
            printBibliography(bibliography, bundleURL: bundleURL)
        }

        private func loadProvenance(from bundleURL: URL) -> WorkflowRun? {
            if let rootSidecar = ProvenanceRecorder.load(from: bundleURL) {
                return rootSidecar
            }

            for candidate in provenanceCandidates(for: bundleURL) {
                if let run = decodeWorkflowRun(at: candidate) {
                    return run
                }
            }

            return nil
        }

        private func provenanceCandidates(for bundleURL: URL) -> [URL] {
            let provenanceDirectory = bundleURL.appendingPathComponent("provenance", isDirectory: true)
            var candidates = [
                provenanceDirectory.appendingPathComponent("bundle.lungfish-provenance.json"),
                bundleURL.appendingPathComponent("bundle.lungfish-provenance.json"),
            ]

            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: provenanceDirectory,
                includingPropertiesForKeys: nil
            ) else {
                return candidates
            }

            let sidecars = contents
                .filter { url in
                    url.pathExtension == "json" || url.lastPathComponent.hasSuffix(".lungfish-provenance.json")
                }
                .sorted { $0.path < $1.path }

            for sidecar in sidecars where !candidates.contains(sidecar) {
                candidates.append(sidecar)
            }

            return candidates
        }

        private func decodeWorkflowRun(at url: URL) -> WorkflowRun? {
            guard let data = try? Data(contentsOf: url) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(WorkflowRun.self, from: data)
        }

        private func printBibliography(_ bibliography: ProvenanceBibliographyResult, bundleURL: URL) {
            print("Bibliography for bundle: \(bundleURL.path)")
            print("")

            if bibliography.citations.isEmpty {
                print("No known tool citations were matched from this provenance record.")
            } else {
                for citation in bibliography.citations {
                    print("- \(citation.displayName): \(citation.citation)\(citationSuffix(for: citation))")
                }
            }

            guard !bibliography.unmatchedTools.isEmpty else { return }

            print("")
            print("Tools without known citations")
            for tool in bibliography.unmatchedTools {
                print("- \(tool.toolName) \(tool.toolVersion)")
            }
        }

        private func citationSuffix(for citation: ToolCitation) -> String {
            var parts: [String] = []
            if let doi = citation.doi {
                parts.append("DOI: \(doi)")
            }
            if let url = citation.url {
                parts.append(url)
            }
            return parts.isEmpty ? "" : " " + parts.joined(separator: " ")
        }
    }
}
