import ArgumentParser
import Foundation
import LungfishCore
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
        let resolved = try resolveProvenanceReading(url)
        return (resolved.sidecarURL, resolved.reading.envelope)
    }

    /// The record for a sidecar, data file, bundle or folder, with the shape the reader decoded it in.
    ///
    /// A file is read as a sidecar first, as `ProvenanceRecorder.loadEnvelope(fromSidecar:)` reads it,
    /// and otherwise found by `ProvenanceRecorder.findProvenanceReading(for:)`. A typed mapping record
    /// goes to the finder first, because only the finder converts it and reads it as a typed record,
    /// which is never the Older record format (plan decision V6).
    static func resolveProvenanceReading(_ url: URL) throws -> (sidecarURL: URL, reading: ProvenanceEnvelopeReader.Reading) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw CLIError.inputFileNotFound(path: url.path)
        }
        guard isDirectory.boolValue else {
            if MappingProvenance.isRecordFilename(url.lastPathComponent),
               let resolved = ProvenanceRecorder.findProvenanceReading(for: url) {
                return resolved
            }
            if let reading = (try? ProvenanceEnvelopeReader.read(fromSidecar: url)) ?? nil {
                // Any JSON object reads as a primitive record, so a data file such as
                // `<reads>.lungfish-meta.json` gives way to the record that lists it as an output.
                if reading.shape == .primitive, let resolved = ProvenanceRecorder.findProvenanceReading(for: url) {
                    return resolved
                }
                return (url, reading)
            }
            if let resolved = ProvenanceRecorder.findProvenanceReading(for: url) {
                return resolved
            }
            throw CLIError.inputFileNotFound(path: ProvenanceRecorder.fileSidecarURL(for: url).path)
        }

        if let resolved = ProvenanceRecorder.findProvenanceReading(for: url) {
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
                throw CLIError.wrapping(error)
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

        @Flag(
            name: .customLong("allow-unpinned"),
            help: "Write a shell, Python, Nextflow or Snakemake export even when LGE cannot pin a step's tool version, and name each such step in the script and its export record"
        )
        var allowUnpinned = false

        func run() async throws {
            let request = ExportRequest(
                input: input, exportFormat: exportFormat, output: output, allowUnpinned: allowUnpinned,
                processArguments: CommandLine.arguments
            )
            // The first SIGTERM cancels the export. The report is built in a staging folder, so a cancel stops at the
            // checkpoint before anything reaches the output, removes the staging folder and exits 125 (decision
            // MGR-12.38-B9, item 4). `--format` names the report format here, so the leaf has no `GlobalOptions` and
            // cannot run under `ViewerExportLeaf.run`.
            let outcome = await runCancellingOnSIGTERM { try Self.exportReport(request) }
            switch outcome {
            case .success(let lines):
                for line in lines {
                    print(line)
                }
            case .failure(let error) where error is CancellationError:
                print(ViewerExportLeaf.cancelledMessage)
                throw CLIExitCode.cancelled.exitCode
            case .failure(let error as CLIError):
                throw error
            case .failure(let error):
                throw CLIError.wrapping(error)
            }
        }

        /// What `run()` hands the SIGTERM scope, which holds only values that can cross to its task.
        struct ExportRequest: Sendable {
            let input: String
            let exportFormat: String
            let output: String
            let allowUnpinned: Bool
            let processArguments: [String]
        }

        /// Resolves the source, runs the pin gate before anything is written, builds the report in a staging folder and
        /// publishes it. Returns the lines the command prints.
        static func exportReport(_ request: ExportRequest) throws -> [String] {
            let inputURL = URL(fileURLWithPath: request.input)
            let outputURL = URL(fileURLWithPath: request.output)
            let provenanceSource = try ProvenanceCommand.resolveProvenanceReading(inputURL)
            let selectedExportFormat = try ProvenanceExportFormat.cliValue(request.exportFormat)
            let exporter = ProvenanceExporter()
            // Plan decision S7. The gate runs before anything is written, never inside exportBundle.
            let gate = exporter.pinGate(
                for: provenanceSource.reading.envelope,
                shape: provenanceSource.reading.shape,
                format: selectedExportFormat,
                sourceSidecarURL: provenanceSource.sidecarURL,
                sourceRootURL: inputURL
            )
            guard gate.permitsExport(allowUnpinned: request.allowUnpinned) else {
                throw CLIError.validationFailed(errors: gate.refusalLines)
            }
            var fallbackArgv = [
                CLICommandIdentity.executableName, "provenance", "export",
                request.input,
                "--export-format", request.exportFormat,
                "--output", request.output
            ]
            if request.allowUnpinned {
                fallbackArgv.append(ProvenanceExporter.allowUnpinnedFlag)
            }
            let exportArgv = Self.exportArgv(processArguments: request.processArguments, fallback: fallbackArgv)
            let bundle = try stageAndPublish(outputURL: outputURL) { stagingURL in
                try exporter.exportBundle(
                    provenanceSource.reading.envelope,
                    format: selectedExportFormat,
                    to: stagingURL,
                    sourceSidecarURL: provenanceSource.sidecarURL,
                    sourceRootURL: inputURL,
                    exportArgv: exportArgv,
                    allowUnpinned: request.allowUnpinned,
                    recordedAs: outputURL
                )
            }
            return ["Exported provenance \(selectedExportFormat.rawValue) to \(bundle.primaryArtifactURL.path)"]
                + bundle.signedReportArtifactURLs.map { "Wrote signed report artifact to \($0.path)" }
                + bundle.copiedSidecarURLs.map { "Wrote provenance artifact to \($0.path)" }
        }

        /// Builds in a hidden sibling of a new `outputURL`, or in a hidden folder inside an existing one, named as the
        /// shared export code names its temporary files, reaches the cancel checkpoint, then publishes (decision
        /// MGR-12.38-B9, items 2 and 3). A new folder takes one exclusive rename. An existing folder keeps today's
        /// merge, so the files the report does not write stay. The staging folder is removed on every end.
        static func stageAndPublish<Staged>(outputURL: URL, stage: (URL) throws -> Staged) throws -> Staged {
            let fileManager = FileManager.default
            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(atPath: outputURL.path, isDirectory: &isDirectory)
            if exists, !isDirectory.boolValue {
                throw CLIError.validationFailed(errors: ["The output \(outputURL.path) is a file. Choose a folder."])
            }
            // A new folder stages beside itself, so that one rename publishes it. An existing folder stages inside
            // itself, on the volume the files land on and where the user could already write, so a parent that is not
            // writable (a volume root, the home folder) or a symlink to another volume works as it did when the leaf
            // wrote straight into the folder.
            let stagingName = ".\(outputURL.lastPathComponent).\(UUID().uuidString).export.tmp"
            let stagingURL = (exists ? outputURL : outputURL.deletingLastPathComponent())
                .appendingPathComponent(stagingName, isDirectory: true)
            defer { try? fileManager.removeItem(at: stagingURL) }
            let staged = try stage(stagingURL)
            try ViewerExportLeaf.checkpointAfterStaging()
            if exists {
                try publishMerging(stagingURL, into: outputURL)
            } else {
                _ = try PortableRename.exclusive(stagingURL, to: outputURL)
            }
            return staged
        }

        /// Moves each staged file to its relative path in the existing folder `outputURL`, replacing a file of the same
        /// name and creating folders as needed, with the export record last. A staged folder against a file of the
        /// same name in `outputURL`, or the reverse, fails before anything in `outputURL` changes.
        static func publishMerging(_ stagingURL: URL, into outputURL: URL) throws {
            let fileManager = FileManager.default
            var folders: [String] = []
            var files: [String] = []
            for relative in try fileManager.subpathsOfDirectory(atPath: stagingURL.path).sorted() {
                let attributes = try fileManager.attributesOfItem(atPath: stagingURL.appendingPathComponent(relative).path)
                if (attributes[.type] as? FileAttributeType) == .typeDirectory {
                    folders.append(relative)
                } else {
                    files.append(relative)
                }
            }
            func isFolder(_ relative: String) -> Bool? {
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: outputURL.appendingPathComponent(relative).path, isDirectory: &isDirectory) else {
                    return nil
                }
                return isDirectory.boolValue
            }
            for relative in folders where isFolder(relative) == false {
                throw CLIError.workflowFailed(reason: "The output holds a file named \(relative), where the export needs a folder.")
            }
            for relative in files where isFolder(relative) == true {
                throw CLIError.workflowFailed(reason: "The output holds a folder named \(relative), where the export needs a file.")
            }
            let recordURL = stagingURL.appendingPathComponent("provenance", isDirectory: true)
                .appendingPathComponent(ProvenanceRecorder.provenanceFilename)
            let last = [
                ProvenanceSigningConfiguration.signatureURL(for: recordURL),
                ProvenanceSigningConfiguration.publicKeyURL(for: recordURL),
                recordURL,
            ].map { "provenance/" + $0.lastPathComponent }
            for relative in folders {
                try fileManager.createDirectory(
                    at: outputURL.appendingPathComponent(relative, isDirectory: true), withIntermediateDirectories: true
                )
            }
            for relative in files.filter({ !last.contains($0) }) + last.filter({ files.contains($0) }) {
                let source = stagingURL.appendingPathComponent(relative).path
                let destination = outputURL.appendingPathComponent(relative).path
                guard rename(source, destination) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        }

        static func exportArgv(processArguments: [String], fallback: [String]) -> [String] {
            guard let provenanceIndex = processArguments.firstIndex(of: "provenance"),
                  processArguments.indices.contains(processArguments.index(after: provenanceIndex)),
                  processArguments[processArguments.index(after: provenanceIndex)] == "export" else {
                return fallback
            }
            // Every export leaf records `lungfish-cli` first (`ViewerExportInvocation.canonicalArgv()`), whatever path
            // launched it, so a replay line reads the same on every machine.
            return [CLICommandIdentity.executableName] + processArguments.dropFirst()
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
            return (try? ProvenanceEnvelopeReader.load(fromSidecar: url))??.legacyWorkflowRun()
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
