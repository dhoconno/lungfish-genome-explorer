import Foundation
import LungfishCore
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
        /// Every file the run fetched for the bundle, each with the digest and size it arrived
        /// with, since the builder keeps no download (BIO B-3).
        let fetchedSources: [GenomeDownloadBundleBuilder.FetchedSource]
        let runClock: ProvenanceRunClock
    }

    /// `fetch genome --into-bundle`. The record goes in the target's `genome/` folder, beside the
    /// target's own root record, and names the genome and annotation files the merge put in.
    struct MergeRequest {
        let targetBundleURL: URL
        let accession: String
        let assemblyAccession: String
        let organism: String
        let apiKeySource: APIKeySource
        let outputFormat: OutputFormat
        let quiet: Bool
        let fetchedSources: [GenomeDownloadBundleBuilder.FetchedSource]
        let runClock: ProvenanceRunClock
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
        let runClock: ProvenanceRunClock
    }

    @discardableResult
    func writeBundle(_ request: BundleRequest) async throws -> ProvenanceEnvelope {
        let parameters = bundleParameters(for: request)
        return try await CLIProvenanceSupport.recordSingleStepRun(
            name: "lungfish fetch genome",
            parameters: parameters,
            defaults: provenanceDefaults(),
            resolved: parameters.merging(fetchedRecord(at: request.runClock.startedAt)) { _, entry in entry },
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
            inputs: fetchedSourceRecords(request.fetchedSources),
            outputs: bundleOutputRecords(
                bundleURL: request.bundleURL
            ),
            exitCode: 0,
            wallTime: request.runClock.elapsed,
            stderr: nil,
            status: .completed,
            outputDirectory: request.bundleURL
        )
    }

    @discardableResult
    func writeMerge(_ request: MergeRequest) async throws -> ProvenanceEnvelope {
        let target = request.targetBundleURL
        var parameters = baseParameters(
            accession: request.accession,
            assemblyAccession: request.assemblyAccession,
            organism: request.organism,
            outputDirectory: target.deletingLastPathComponent(),
            bundleName: nil,
            fastaOnly: false,
            noBundle: false,
            apiKeySource: request.apiKeySource,
            annotationDownloaded: request.fetchedSources.contains { $0.kind == .gff3 },
            outputFormat: request.outputFormat,
            quiet: request.quiet
        )
        parameters["intoBundle"] = .file(target)
        var defaults = provenanceDefaults()
        defaults["intoBundle"] = .null
        let recordFolder = target.appendingPathComponent("genome", isDirectory: true)
        // Each path is built from the target's own spelling, so the record names one folder one
        // way (A44 M2 review, F10).
        let merged = ["genome", "annotations"].flatMap { folder -> [URL] in
            let url = target.appendingPathComponent(folder, isDirectory: true)
            guard let names = FileManager.default.enumerator(atPath: url.path) else { return [] }
            return names.compactMap { $0 as? String }.map { url.appendingPathComponent($0) }.filter {
                (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                    && !$0.lastPathComponent.hasSuffix(ProvenanceRecorder.provenanceFilename)
            }.sorted { $0.path < $1.path }
        }
        return try await CLIProvenanceSupport.recordSingleStepRun(
            name: "lungfish fetch genome",
            parameters: parameters,
            defaults: defaults,
            resolved: parameters.merging(fetchedRecord(at: request.runClock.startedAt)) { _, entry in entry },
            toolName: "lungfish fetch genome",
            toolVersion: WorkflowRun.currentAppVersion,
            command: provenanceCommand(
                accession: request.accession,
                outputDirectory: target.deletingLastPathComponent(),
                bundleName: nil,
                fastaOnly: false,
                noBundle: false,
                apiKeySource: request.apiKeySource,
                outputFormat: request.outputFormat,
                quiet: request.quiet,
                intoBundle: target
            ),
            inputs: fetchedSourceRecords(request.fetchedSources),
            outputs: merged.map { ProvenanceRecorder.fileRecord(url: $0, role: .output) },
            exitCode: 0,
            wallTime: request.runClock.elapsed,
            stderr: nil,
            status: .completed,
            outputDirectory: recordFolder,
            writeFileSidecars: false
        )
    }

    @discardableResult
    func writeDirectOutputs(_ request: DirectOutputRequest) async throws -> ProvenanceEnvelope {
        let parameters = directParameters(for: request)
        return try await CLIProvenanceSupport.recordSingleStepRun(
            name: "lungfish fetch genome",
            parameters: parameters,
            defaults: provenanceDefaults(),
            resolved: parameters.merging(fetchedRecord(at: request.runClock.startedAt)) { _, entry in entry },
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
            wallTime: request.runClock.elapsed,
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
            annotationDownloaded: request.fetchedSources.contains { $0.kind == .gff3 },
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

    /// The run's fetch as a live snapshot of NCBI on the day of the run, in the shape of a Nextflow
    /// database entry (2.9 R3, A45 grant 4). The run keeps no file that lists what it fetched, so
    /// the entry names the date alone and the record's inputs name each fetched file with its digest.
    private func fetchedRecord(at date: Date) -> [String: ParameterValue] {
        NextflowDatabaseEntry(role: "fetchedRecord", status: .liveSnapshot, fetchedAt: date).resolvedDefaults
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
        quiet: Bool,
        intoBundle: URL? = nil
    ) -> [String] {
        var command = [CLICommandIdentity.executableName, "fetch", "genome", accession]
        if let intoBundle {
            command += ["--into-bundle", intoBundle.path]
        } else {
            command += ["--output-dir", outputDirectory.path]
        }
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

    /// Each fetched file under its source URL, with the digest and size it arrived with.
    private func fetchedSourceRecords(_ sources: [GenomeDownloadBundleBuilder.FetchedSource]) -> [FileRecord] {
        sources.map { source in
            let format: FileFormat
            let role: FileRole
            switch source.kind {
            case .fasta: (format, role) = (.fasta, .reference)
            case .gff3: (format, role) = (.gff3, .input)
            case .genBank: (format, role) = (.genBank, .reference)
            case .assemblyReport: (format, role) = (.text, .input)
            }
            return FileRecord(path: source.url.absoluteString, sha256: source.sha256, sizeBytes: source.sizeBytes, format: format, role: role)
        }
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
