import Foundation
import LungfishWorkflow

struct GenomeFetchProvenanceWriter {
    enum APIKeySource: String {
        case none
        case explicit
        case environment

        var isProvided: Bool {
            self != .none
        }

        var isCommandLine: Bool {
            self == .explicit
        }
    }

    struct BundleRequest {
        let bundleURL: URL
        let accession: String
        let assemblyAccession: String
        let organism: String
        let outputDirectory: URL
        let bundleName: String?
        let fastaOnly: Bool
        let noBundle: Bool
        let apiKeySource: APIKeySource
        let outputFormat: OutputFormat
        let quiet: Bool
        let fastaSourceURL: URL
        let downloadedFastaURL: URL
        let gffSourceURL: URL?
        let downloadedGFFURL: URL?
        let startedAt: Date
    }

    struct DirectOutputRequest {
        let accession: String
        let assemblyAccession: String
        let organism: String
        let outputDirectory: URL
        let bundleName: String?
        let fastaOnly: Bool
        let noBundle: Bool
        let apiKeySource: APIKeySource
        let outputFormat: OutputFormat
        let quiet: Bool
        let fastaSourceURL: URL
        let downloadedFastaURL: URL
        let gffSourceURL: URL?
        let downloadedGFFURL: URL?
        let finalFastaURL: URL
        let finalGFFURL: URL?
        let startedAt: Date
    }

    @discardableResult
    func writeBundle(_ request: BundleRequest) async throws -> ProvenanceEnvelope {
        let parameters = bundleParameters(for: request)
        return try await CLIProvenanceSupport.recordSingleStepRun(
            name: "lungfish fetch genome",
            parameters: parameters,
            defaults: provenanceDefaults(),
            resolved: parameters,
            toolName: "lungfish fetch genome",
            toolVersion: WorkflowRun.currentAppVersion,
            command: provenanceCommand(
                accession: request.accession,
                outputDirectory: request.outputDirectory,
                bundleName: request.bundleName,
                fastaOnly: request.fastaOnly,
                noBundle: request.noBundle,
                apiKeySource: request.apiKeySource,
                outputFormat: request.outputFormat,
                quiet: request.quiet
            ),
            inputs: inputRecords(
                fastaSourceURL: request.fastaSourceURL,
                downloadedFastaURL: request.downloadedFastaURL,
                gffSourceURL: request.gffSourceURL,
                downloadedGFFURL: request.downloadedGFFURL
            ),
            outputs: bundleOutputRecords(
                bundleURL: request.bundleURL
            ),
            exitCode: 0,
            wallTime: Date().timeIntervalSince(request.startedAt),
            stderr: nil,
            status: .completed,
            outputDirectory: request.bundleURL
        )
    }

    @discardableResult
    func writeDirectOutputs(_ request: DirectOutputRequest) async throws -> ProvenanceEnvelope {
        let parameters = directParameters(for: request)
        return try await CLIProvenanceSupport.recordSingleStepRun(
            name: "lungfish fetch genome",
            parameters: parameters,
            defaults: provenanceDefaults(),
            resolved: parameters,
            toolName: "lungfish fetch genome",
            toolVersion: WorkflowRun.currentAppVersion,
            command: provenanceCommand(
                accession: request.accession,
                outputDirectory: request.outputDirectory,
                bundleName: request.bundleName,
                fastaOnly: request.fastaOnly,
                noBundle: request.noBundle,
                apiKeySource: request.apiKeySource,
                outputFormat: request.outputFormat,
                quiet: request.quiet
            ),
            inputs: inputRecords(
                fastaSourceURL: request.fastaSourceURL,
                downloadedFastaURL: request.downloadedFastaURL,
                gffSourceURL: request.gffSourceURL,
                downloadedGFFURL: request.downloadedGFFURL
            ),
            outputs: directOutputRecords(for: request),
            exitCode: 0,
            wallTime: Date().timeIntervalSince(request.startedAt),
            stderr: nil,
            status: .completed,
            outputDirectory: request.outputDirectory
        )
    }

    private func bundleParameters(for request: BundleRequest) -> [String: ParameterValue] {
        baseParameters(
            accession: request.accession,
            assemblyAccession: request.assemblyAccession,
            organism: request.organism,
            outputDirectory: request.outputDirectory,
            bundleName: request.bundleName,
            fastaOnly: request.fastaOnly,
            noBundle: request.noBundle,
            apiKeySource: request.apiKeySource,
            annotationDownloaded: request.gffSourceURL != nil && request.downloadedGFFURL != nil,
            outputFormat: request.outputFormat,
            quiet: request.quiet
        ).merging(["outputBundle": .file(request.bundleURL)]) { _, new in new }
    }

    private func directParameters(for request: DirectOutputRequest) -> [String: ParameterValue] {
        var parameters = baseParameters(
            accession: request.accession,
            assemblyAccession: request.assemblyAccession,
            organism: request.organism,
            outputDirectory: request.outputDirectory,
            bundleName: request.bundleName,
            fastaOnly: request.fastaOnly,
            noBundle: request.noBundle,
            apiKeySource: request.apiKeySource,
            annotationDownloaded: request.gffSourceURL != nil && request.downloadedGFFURL != nil,
            outputFormat: request.outputFormat,
            quiet: request.quiet
        )
        parameters["outputBundle"] = .null
        parameters["outputFasta"] = .file(request.finalFastaURL)
        parameters["outputGFF"] = request.finalGFFURL.map(ParameterValue.file) ?? .null
        return parameters
    }

    private func baseParameters(
        accession: String,
        assemblyAccession: String,
        organism: String,
        outputDirectory: URL,
        bundleName: String?,
        fastaOnly: Bool,
        noBundle: Bool,
        apiKeySource: APIKeySource,
        annotationDownloaded: Bool,
        outputFormat: OutputFormat,
        quiet: Bool
    ) -> [String: ParameterValue] {
        [
            "accession": .string(accession),
            "assemblyAccession": .string(assemblyAccession),
            "organism": .string(organism),
            "outputDirectory": .file(outputDirectory),
            "bundleName": bundleName.map(ParameterValue.string) ?? .null,
            "fastaOnly": .boolean(fastaOnly),
            "noBundle": .boolean(noBundle),
            "apiKeyProvided": .boolean(apiKeySource.isProvided),
            "apiKeySource": .string(apiKeySource.rawValue),
            "annotationDownloaded": .boolean(annotationDownloaded),
            "outputFormat": .string(outputFormat.rawValue),
            "quiet": .boolean(quiet)
        ]
    }

    private func provenanceDefaults() -> [String: ParameterValue] {
        [
            "outputDirectory": .string("."),
            "outputBundle": .null,
            "outputFasta": .null,
            "outputGFF": .null,
            "bundleName": .null,
            "fastaOnly": .boolean(false),
            "noBundle": .boolean(false),
            "apiKeyProvided": .boolean(false),
            "apiKeySource": .string(APIKeySource.none.rawValue),
            "annotationDownloaded": .boolean(false),
            "outputFormat": .string(OutputFormat.text.rawValue),
            "quiet": .boolean(false)
        ]
    }

    private func provenanceCommand(
        accession: String,
        outputDirectory: URL,
        bundleName: String?,
        fastaOnly: Bool,
        noBundle: Bool,
        apiKeySource: APIKeySource,
        outputFormat: OutputFormat,
        quiet: Bool
    ) -> [String] {
        var command = [
            "lungfish", "fetch", "genome", accession,
            "--output-dir", outputDirectory.path
        ]
        if let bundleName {
            command += ["--name", bundleName]
        }
        if fastaOnly {
            command.append("--fasta-only")
        }
        if noBundle {
            command.append("--no-bundle")
        }
        if apiKeySource.isCommandLine {
            command += ["--api-key", "<redacted>"]
        }
        if outputFormat != .text {
            command += ["--format", outputFormat.rawValue]
        }
        if quiet {
            command.append("--quiet")
        }
        return command
    }

    private func inputRecords(
        fastaSourceURL: URL,
        downloadedFastaURL: URL,
        gffSourceURL: URL?,
        downloadedGFFURL: URL?
    ) -> [FileRecord] {
        var records = [
            remoteDownloadedFileRecord(
                sourceURL: fastaSourceURL,
                localURL: downloadedFastaURL,
                format: .fasta,
                role: .reference
            )
        ]
        if let gffSourceURL,
           let downloadedGFFURL {
            records.append(
                remoteDownloadedFileRecord(
                    sourceURL: gffSourceURL,
                    localURL: downloadedGFFURL,
                    format: .gff3,
                    role: .input
                )
            )
        }
        return records
    }

    private func bundleOutputRecords(bundleURL: URL) -> [FileRecord] {
        CLIProvenanceSupport.bundlePayloadURLs(in: bundleURL).map {
            ProvenanceRecorder.fileRecord(url: $0, role: .output)
        }
    }

    private func directOutputRecords(for request: DirectOutputRequest) -> [FileRecord] {
        var records = [
            ProvenanceRecorder.fileRecord(url: request.finalFastaURL.standardizedFileURL, format: .fasta, role: .output)
        ]
        if let finalGFFURL = request.finalGFFURL {
            records.append(ProvenanceRecorder.fileRecord(url: finalGFFURL.standardizedFileURL, format: .gff3, role: .output))
        }
        return records
    }

    private func remoteDownloadedFileRecord(
        sourceURL: URL,
        localURL: URL,
        format: FileFormat,
        role: FileRole
    ) -> FileRecord {
        let localRecord = ProvenanceRecorder.fileRecord(url: localURL, format: format, role: role)
        return FileRecord(
            path: sourceURL.absoluteString,
            sha256: localRecord.sha256,
            sizeBytes: localRecord.sizeBytes,
            format: format,
            role: role
        )
    }
}
