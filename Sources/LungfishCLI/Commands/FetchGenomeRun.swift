// FetchGenomeRun.swift - One run of lungfish-cli fetch genome over one or more accessions
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// One `fetch genome` run (Phase 2.10 lane A44). An assembly accession builds through
/// `GenomeDownloadBundleBuilder` and a nucleotide accession through `GenBankDownloadBundleBuilder`,
/// the builders of the app's NCBI browser, so the CLI and the browser build the same bundle.
///
/// - An assembly bundle is built in a staging folder, the project's `.tmp` folder or a hidden
///   folder of the output folder outside a project, moved into the output folder with
///   `PortableRename` under the next free name (`_1`, `_2`, as the import names them), and then
///   given its record, which names each fetched file with its source URL, digest and size (B-3).
/// - A nucleotide bundle is built in the output folder itself, because its builder writes its
///   record during the build and the record names the bundle's own paths.
/// - The run checks for a cancel before each accession and between the builder's stages, and
///   removes the bundle it was building.
struct FetchGenomeRun: Sendable {
    let request: FetchGenomeRequest
    let reporter: FetchGenomeReporter

    func fetchAll() async -> FetchGenomeOutcome {
        var outcome = FetchGenomeOutcome()
        let runClock = ProvenanceRunClock()
        if request.intoBundleURL == nil {
            do {
                try FileManager.default.createDirectory(at: request.outputURL, withIntermediateDirectories: true)
            } catch {
                outcome.failures.append(.init(accession: "", message: "Could not create \(request.outputURL.path): \(error.localizedDescription)"))
                return outcome
            }
        }
        let service = NCBIService(apiKey: request.apiKey)
        let apiKeySource = await Self.apiKeySource(explicit: request.apiKey, service: service)
        let count = request.accessions.count
        for (index, accession) in request.accessions.enumerated() {
            if Task.isCancelled {
                outcome.cancelled = true
                break
            }
            reporter.beginAccession(accession, index: index, count: count, destination: request.intoBundleURL ?? request.outputURL)
            let progress = reporter.progressHandler(accession: accession, index: index, count: count)
            do {
                let output = try await fetch(accession, service: service, apiKeySource: apiKeySource, runClock: runClock, progress: progress)
                outcome.outputs.append(output)
                reporter.finishedAccession(output)
            } catch {
                if Task.isCancelled || error is CancellationError {
                    outcome.cancelled = true
                    break
                }
                let failure = FetchGenomeOutcome.Failure(accession: accession, message: Self.message(for: error))
                outcome.failures.append(failure)
                reporter.failedAccession(failure)
            }
        }
        return outcome
    }

    /// `none` when the service sends no key, which is always so against a stand-in origin.
    static func apiKeySource(explicit: String?, service: NCBIService) async -> GenomeFetchProvenanceWriter.APIKeySource {
        guard await service.resolvedAPIKey != nil else { return .none }
        return NCBIAPIKeyResolver.resolve(explicitAPIKey: explicit, environment: [:]) != nil ? .explicit : .environment
    }

    static func message(for error: Error) -> String {
        if let error = error as? CLIError { return error.localizedDescription }
        return (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    private func fetch(
        _ accession: String,
        service: NCBIService,
        apiKeySource: GenomeFetchProvenanceWriter.APIKeySource,
        runClock: ProvenanceRunClock,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> FetchGenomeOutput {
        if NCBIAccessionKind.classify(accession) == .nucleotide {
            if let target = request.intoBundleURL {
                return try await mergeNucleotide(accession, into: target, service: service, apiKeySource: apiKeySource, runClock: runClock, progress: progress)
            }
            return try await fetchNucleotide(accession, service: service, progress: progress)
        }
        reporter.info("Searching for assembly \(accession)...")
        let summary = try await Self.assemblySummary(for: accession, service: service)
        if let target = request.intoBundleURL {
            return try await mergeAssembly(accession, summary: summary, into: target, service: service, apiKeySource: apiKeySource, runClock: runClock, progress: progress)
        }
        if request.fastaOnly || request.noBundle {
            return try await FetchGenomeDirectFiles(request: request, reporter: reporter)
                .fetchAssemblyFiles(accession, summary: summary, service: service, apiKeySource: apiKeySource, runClock: runClock)
        }
        let staging = try Self.makeStagingFolder(for: request.outputURL)
        defer { try? FileManager.default.removeItem(at: staging) }
        let built = try await GenomeDownloadBundleBuilder(ncbiService: service).downloadAndBuildRecordingSources(
            assembly: summary, outputDirectory: staging, bundleName: request.name, progressHandler: progress)
        try Task.checkCancellation()
        let bundleURL = try Self.publish(built.bundleURL, into: request.outputURL)
        // A bundle in its final place is finished, so a cancel from here on does not undo it.
        do {
            try await GenomeFetchProvenanceWriter().writeBundle(.init(
                bundleURL: bundleURL,
                accession: accession,
                assemblyAccession: summary.assemblyAccession ?? accession,
                organism: summary.organism ?? summary.speciesName ?? "Unknown",
                outputDirectory: request.outputURL,
                bundleName: request.name,
                fastaOnly: false,
                noBundle: false,
                apiKeySource: apiKeySource,
                outputFormat: request.outputFormat,
                quiet: request.quiet,
                fetchedSources: built.sources,
                runClock: runClock
            ))
        } catch {
            try? FileManager.default.removeItem(at: bundleURL)
            throw error
        }
        return .bundle(bundleURL, record: Self.rootRecord(of: bundleURL))
    }

    private func fetchNucleotide(
        _ accession: String,
        service: NCBIService,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> FetchGenomeOutput {
        if request.fastaOnly || request.noBundle {
            return try await FetchGenomeDirectFiles(request: request, reporter: reporter)
                .fetchNucleotideFASTA(accession, service: service)
        }
        let scratch = try ProjectTempDirectory.createFromContext(prefix: ".lungfish-temp-", contextURL: request.outputURL)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let built = try await FetchGenomeNucleotideBundle(request: request, reporter: reporter)
            .build(accession, name: request.name, scratch: scratch, service: service, progress: progress)
        try Task.checkCancellation()
        let bundleURL = try Self.publish(built.bundleURL, into: request.outputURL)
        return .bundle(bundleURL, record: Self.rootRecord(of: bundleURL))
    }

    // MARK: - Into an existing bundle

    private func mergeAssembly(
        _ accession: String,
        summary: NCBIAssemblySummary,
        into target: URL,
        service: NCBIService,
        apiKeySource: GenomeFetchProvenanceWriter.APIKeySource,
        runClock: ProvenanceRunClock,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> FetchGenomeOutput {
        let staging = try Self.makeStagingFolder(for: target.deletingLastPathComponent())
        defer { try? FileManager.default.removeItem(at: staging) }
        let built = try await GenomeDownloadBundleBuilder(ncbiService: service).downloadAndBuildRecordingSources(
            assembly: summary, outputDirectory: staging, progressHandler: progress)
        return try await merge(
            built.bundleURL, into: target, accession: accession,
            assemblyAccession: summary.assemblyAccession ?? accession,
            organism: summary.organism ?? summary.speciesName ?? "Unknown",
            sources: built.sources, apiKeySource: apiKeySource, runClock: runClock)
    }

    private func mergeNucleotide(
        _ accession: String,
        into target: URL,
        service: NCBIService,
        apiKeySource: GenomeFetchProvenanceWriter.APIKeySource,
        runClock: ProvenanceRunClock,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> FetchGenomeOutput {
        let scratch = try Self.makeStagingFolder(for: target.deletingLastPathComponent())
        defer { try? FileManager.default.removeItem(at: scratch) }
        let built = try await FetchGenomeNucleotideBundle(request: request, reporter: reporter)
            .build(accession, name: nil, scratch: scratch, service: service, progress: progress)
        return try await merge(
            built.bundleURL, into: target, accession: accession, assemblyAccession: accession,
            organism: built.organism, sources: built.sources, apiKeySource: apiKeySource, runClock: runClock)
    }

    private func merge(
        _ built: URL,
        into target: URL,
        accession: String,
        assemblyAccession: String,
        organism: String,
        sources: [GenomeDownloadBundleBuilder.FetchedSource],
        apiKeySource: GenomeFetchProvenanceWriter.APIKeySource,
        runClock: ProvenanceRunClock
    ) async throws -> FetchGenomeOutput {
        try Task.checkCancellation()
        try ReferenceGenomeBundleMerge.merge(sourceBundleURL: built, into: target)
        let recordFolder = target.appendingPathComponent("genome", isDirectory: true)
        try await GenomeFetchProvenanceWriter().writeMerge(.init(
            targetBundleURL: target,
            accession: accession,
            assemblyAccession: assemblyAccession,
            organism: organism,
            apiKeySource: apiKeySource,
            outputFormat: request.outputFormat,
            quiet: request.quiet,
            fetchedSources: sources,
            runClock: runClock
        ))
        return .bundle(target, record: Self.rootRecord(of: recordFolder))
    }

    // MARK: - Helpers

    static func assemblySummary(for accession: String, service: NCBIService) async throws -> NCBIAssemblySummary {
        let searchResult = try await service.searchGenome(term: accession, retmax: 1)
        guard !searchResult.ids.isEmpty else {
            throw CLIError.networkError(reason: "Assembly not found: \(accession)")
        }
        guard let summary = try await service.assemblyEsummary(ids: searchResult.ids).first else {
            throw CLIError.networkError(reason: "Could not retrieve assembly metadata for \(accession)")
        }
        return summary
    }

    /// The project's `.tmp` folder when `directory` is inside a project, or else a hidden folder
    /// in `directory`, so the bundle moves into place by a rename on the same volume.
    static func makeStagingFolder(for directory: URL) throws -> URL {
        if let project = ProjectTempDirectory.findProjectRoot(directory) {
            return try ProjectTempDirectory.create(prefix: "fetch-genome-", in: project)
        }
        let folder = directory.appendingPathComponent(".fetch-genome-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Moves `staged` into `directory` under the next free name, never replacing a bundle.
    static func publish(_ staged: URL, into directory: URL) throws -> URL {
        let baseName = staged.deletingPathExtension().lastPathComponent
        for _ in 0..<32 {
            let destination = BundleBuildHelpers.makeUniqueBundleURL(baseName: baseName, in: directory)
            do {
                try PortableRename.exclusive(staged, to: destination)
                return destination
            } catch where FileManager.default.fileExists(atPath: destination.path) {
                continue // Another writer took the name between the check and the rename.
            } catch {
                // Another volume, such as the system's temporary folder beside an external drive.
                try FileManager.default.moveItem(at: staged, to: destination)
                return destination
            }
        }
        throw CLIError.outputWriteFailed(path: directory.path, reason: "No free bundle name for \(baseName)")
    }

    static func rootRecord(of folder: URL) -> URL? {
        let record = folder.appendingPathComponent(BundleKindDescriptor.SidecarNaming.rootRecordFileName)
        return FileManager.default.fileExists(atPath: record.path) ? record : nil
    }
}
