import ArgumentParser
import Foundation
import LungfishWorkflow

struct ProvenanceCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "provenance",
        abstract: "Inspect provenance recorded in Lungfish bundles",
        subcommands: [
            BibliographySubcommand.self,
            ExportSubcommand.self,
            VerifySubcommand.self,
        ]
    )

    static func resolveProvenanceURL(_ url: URL) throws -> URL {
        try resolveProvenanceSource(url).sidecarURL
    }

    static func resolveProvenanceSource(_ url: URL) throws -> (sidecarURL: URL, envelope: ProvenanceEnvelope) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw CLIError.inputFileNotFound(path: url.path)
        }
        guard isDirectory.boolValue else {
            if let envelope = ProvenanceRecorder.loadEnvelope(fromSidecar: url) {
                return (url, envelope)
            }
            if let resolved = ProvenanceRecorder.findProvenanceEnvelope(for: url) {
                return resolved
            }
            throw CLIError.inputFileNotFound(path: ProvenanceRecorder.fileSidecarURL(for: url).path)
        }

        if let resolved = ProvenanceRecorder.findProvenanceEnvelope(for: url) {
            return resolved
        }
        throw CLIError.inputFileNotFound(
            path: url.appendingPathComponent(ProvenanceRecorder.provenanceFilename).path
        )
    }

    static func resolveVerifiableURL(
        _ url: URL,
        signatureURL: URL? = nil,
        publicKeyURL: URL? = nil
    ) throws -> URL {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw CLIError.inputFileNotFound(path: url.path)
        }
        guard !isDirectory.boolValue else {
            return try resolveProvenanceURL(url)
        }
        if isProvenanceSidecarURL(url)
            || signatureURL != nil
            || publicKeyURL != nil
            || hasDefaultSigningArtifacts(for: url) {
            return url
        }
        return try resolveProvenanceURL(url)
    }

    private static func isProvenanceSidecarURL(_ url: URL) -> Bool {
        url.lastPathComponent == ProvenanceRecorder.provenanceFilename
            || url.lastPathComponent.hasSuffix(".lungfish-provenance.json")
    }

    private static func hasDefaultSigningArtifacts(for url: URL) -> Bool {
        FileManager.default.fileExists(atPath: ProvenanceSigningConfiguration.signatureURL(for: url).path)
            && FileManager.default.fileExists(atPath: ProvenanceSigningConfiguration.publicKeyURL(for: url).path)
    }

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
            let signatureURL = signature.map { URL(fileURLWithPath: $0) }
            let publicKeyURL = publicKey.map { URL(fileURLWithPath: $0) }
            let provenanceURL = try ProvenanceCommand.resolveVerifiableURL(
                URL(fileURLWithPath: file),
                signatureURL: signatureURL,
                publicKeyURL: publicKeyURL
            )
            do {
                let result = try ProvenanceSignatureVerifier.verify(
                    provenanceURL: provenanceURL,
                    signatureURL: signatureURL,
                    publicKeyURL: publicKeyURL
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
    }

    struct ExportSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "export",
            abstract: "Export reproducible reports from a Lungfish provenance sidecar"
        )

        @Argument(help: "Provenance sidecar file, bundle, or output directory")
        var input: String

        @Option(
            name: [.customLong("format"), .customLong("export-format"), .customShort("f")],
            help: "Export format: shell, python, nextflow, snakemake, methods, json"
        )
        var exportFormat: String

        @Option(name: .customLong("output"), help: "Output directory for the export bundle")
        var output: String

        func run() async throws {
            let inputURL = URL(fileURLWithPath: input)
            let outputURL = URL(fileURLWithPath: output)
            do {
                let provenanceSource = try ProvenanceCommand.resolveProvenanceSource(inputURL)
                let selectedExportFormat = try ProvenanceExportFormat.cliValue(exportFormat)
                let fallbackArgv = [
                    "lungfish", "provenance", "export",
                    input,
                    "--export-format", exportFormat,
                    "--output", output
                ]
                let exportArgv = Self.exportArgv(
                    processArguments: CommandLine.arguments,
                    fallback: fallbackArgv
                )
                let bundle = try ProvenanceExporter().exportBundle(
                    provenanceSource.envelope,
                    format: selectedExportFormat,
                    to: outputURL,
                    sourceSidecarURL: provenanceSource.sidecarURL,
                    sourceRootURL: inputURL,
                    exportArgv: exportArgv
                )
                print("Exported provenance \(selectedExportFormat.rawValue) to \(bundle.primaryArtifactURL.path)")
                for artifact in bundle.signedReportArtifactURLs {
                    print("Wrote signed report artifact to \(artifact.path)")
                }
                for sidecar in bundle.copiedSidecarURLs {
                    print("Wrote provenance artifact to \(sidecar.path)")
                }
            } catch let error as CLIError {
                throw error
            } catch {
                throw CLIError.workflowFailed(reason: error.localizedDescription)
            }
        }

        static func exportArgv(processArguments: [String], fallback: [String]) -> [String] {
            guard let provenanceIndex = processArguments.firstIndex(of: "provenance"),
                  processArguments.indices.contains(processArguments.index(after: provenanceIndex)),
                  processArguments[processArguments.index(after: provenanceIndex)] == "export" else {
                return fallback
            }
            return processArguments
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
            return try? ProvenanceEnvelopeReader.decode(data).legacyWorkflowRun()
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
