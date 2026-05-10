import ArgumentParser
import Foundation
import LungfishWorkflow

struct ProvenanceCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "provenance",
        abstract: "Inspect provenance recorded in Lungfish bundles",
        subcommands: [
            BibliographySubcommand.self,
            VerifySubcommand.self,
        ]
    )

    struct VerifySubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "verify",
            abstract: "Verify a signed Lungfish provenance sidecar"
        )

        @Argument(help: "Provenance sidecar file, bundle, or output directory")
        var file: String

        @Option(name: .customLong("signature"), help: "Signature artifact path; defaults to <sidecar>.signature.json")
        var signature: String?

        @Option(name: .customLong("public-key"), help: "Public key artifact path; defaults to <sidecar>.pub")
        var publicKey: String?

        func run() async throws {
            let provenanceURL = try Self.resolveProvenanceURL(URL(fileURLWithPath: file))
            do {
                let result = try ProvenanceSignatureVerifier.verify(
                    provenanceURL: provenanceURL,
                    signatureURL: signature.map { URL(fileURLWithPath: $0) },
                    publicKeyURL: publicKey.map { URL(fileURLWithPath: $0) }
                )
                print("Signature valid")
                print("Provider: \(result.provider)")
                print("Provenance SHA-256: \(result.provenanceSHA256)")
                print("Signature: \(result.signatureURL.path)")
                print("Public key: \(result.publicKeyURL.path)")
            } catch {
                throw CLIError.workflowFailed(reason: error.localizedDescription)
            }
        }

        private static func resolveProvenanceURL(_ url: URL) throws -> URL {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                throw CLIError.inputFileNotFound(path: url.path)
            }
            guard isDirectory.boolValue else { return url }

            let rootSidecar = url.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
            if FileManager.default.fileExists(atPath: rootSidecar.path) {
                return rootSidecar
            }
            let provenanceSidecar = url
                .appendingPathComponent("provenance", isDirectory: true)
                .appendingPathComponent("bundle.lungfish-provenance.json")
            if FileManager.default.fileExists(atPath: provenanceSidecar.path) {
                return provenanceSidecar
            }
            throw CLIError.inputFileNotFound(path: rootSidecar.path)
        }
    }

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
