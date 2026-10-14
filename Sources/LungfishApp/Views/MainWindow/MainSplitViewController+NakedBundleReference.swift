// MainSplitViewController+NakedBundleReference.swift - The reference download of a variant-only bundle
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishWorkflow
import os.log

/// The route of the reference download of a variant-only bundle (Phase 2.10 lane A44 M3, panel
/// decision C4). The app finds the reference on both routes (review ruling M3-1).
enum NakedBundleReferenceRoute: String, Sendable, Equatable, CaseIterable {
    /// The route before lane A44 M3, kept for one release as the escape the hidden key names (C4).
    /// The app builds the assembly's bundle in process in the project's `.tmp` folder and merges its
    /// genome and annotations into the variant-only bundle. It writes no provenance record, the
    /// declared difference that keeps the key, and goes in 2.11.
    case legacy
    /// One `lungfish-cli fetch genome <accession> --into-bundle <bundle> --format json` child for
    /// the assembly the app found, which merges the reference into the bundle and records what it
    /// fetched. The GenBank fallback stays in process on both routes for now.
    case cli
}

/// Reads the route of the reference download from the defaults it is given, so a test passes its
/// own suite and never touches the user's defaults.
struct NakedBundleReferenceRouteSettings {
    /// The hidden key. It holds `cli` or `legacy`, or a Boolean that is true for the CLI route, for
    /// example `defaults write <app id> VariantOnlyReferenceDownloadRoute legacy`.
    static let defaultsKey = "VariantOnlyReferenceDownloadRoute"
    /// The route of a key that is unset or holds a value this reader does not know.
    static let defaultRoute: NakedBundleReferenceRoute = .legacy

    let defaults: UserDefaults

    var route: NakedBundleReferenceRoute {
        switch defaults.object(forKey: Self.defaultsKey) {
        case let name as String:
            return NakedBundleReferenceRoute(rawValue: name.lowercased()) ?? Self.defaultRoute
        case let usesCLI as Bool:
            return usesCLI ? .cli : .legacy
        default:
            return Self.defaultRoute
        }
    }
}

extension MainSplitViewController {
    /// Silently downloads reference genome for a naked (variant-only) bundle.
    ///
    /// Tries two strategies in order:
    /// 1. NCBI Assembly search (gives full genome FASTA + GFF3 annotations)
    /// 2. GenBank nucleotide fetch by accession (fallback for single-contig organisms)
    ///
    /// The row locks the bundle (review ruling M3-3). Once the app has found an assembly, the row
    /// records the `fetch genome` command that reproduces the run (ruling M3-1), and the route the
    /// hidden key names (``NakedBundleReferenceRouteSettings``) merges the assembly in. On
    /// completion the viewer reloads the bundle.
    func downloadReferenceForNakedBundle(
        inferredRef: ReferenceInference.Result,
        ncbiAccessions: [String],
        bundleURL: URL
    ) {
        guard canWriteProjectOutputs(workflowName: "Reference download") else { return }
        let assemblyName = inferredRef.assembly ?? ncbiAccessions.first ?? "Reference"
        let route = NakedBundleReferenceRouteSettings(defaults: .standard).route

        Self.beginNakedBundleReferenceDownloadOperation(
            assemblyName: assemblyName,
            bundleURL: bundleURL,
            routeContext: operationRouteContext
        ) { downloadID in
            Task.detached { [weak self] in
                do {
                    let found = try await Self.downloadNakedBundleReference(
                        inferredRef: inferredRef,
                        ncbiAccessions: ncbiAccessions,
                        bundleURL: bundleURL,
                        operationID: downloadID,
                        route: route
                    ) { command in
                        await performOnMainRunLoopAsync { DownloadCenter.shared.setCommand(id: downloadID, command: command) }
                    }
                    guard found else {
                        mainSplitPerformOnMainRunLoop {
                            _ = DownloadCenter.shared.fail(id: downloadID, detail: "No reference found for '\(assemblyName)'")
                        }
                        return
                    }

                    mainSplitPerformOnMainRunLoop {
                        _ = DownloadCenter.shared.complete(id: downloadID, detail: "Reference genome added to bundle")
                    }

                    mainSplitLogger.info("downloadReferenceForNakedBundle: Genome merged into \(bundleURL.lastPathComponent, privacy: .public)")

                    // Reload the bundle in the viewer after the downloaded reference is merged.
                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated {
                            self?.displayReferenceBundleViewportFromSidebar(at: bundleURL)
                        }
                    }

                } catch is CancellationError {
                    // The CLI child stopped on the row's Cancel.
                    mainSplitPerformOnMainRunLoop {
                        _ = DownloadCenter.shared.acknowledgeCancellation(id: downloadID)
                    }
                } catch {
                    let errorMessage = "\(error)"
                    mainSplitPerformOnMainRunLoop {
                        _ = DownloadCenter.shared.fail(id: downloadID, detail: errorMessage)
                    }
                    mainSplitLogger.error("downloadReferenceForNakedBundle: Failed - \(errorMessage)")
                }
            }
        }
    }

    /// Finds the reference of the variant-only bundle at `bundleURL` and merges it in by `route`,
    /// for the row `operationID`, and returns false when no reference was found. Both routes search
    /// NCBI in the app as before Phase 2.10 (review ruling M3-1), so the search by organism and
    /// assembly name stays a read of the app's, and the record names the accession fetched. Once
    /// an assembly's accession is known, `recordCommand` gets the `fetch genome` command that
    /// reproduces the run, before the CLI route launches it. `cliURLOverride` names the CLI a test
    /// launches.
    nonisolated static func downloadNakedBundleReference(
        inferredRef: ReferenceInference.Result,
        ncbiAccessions: [String],
        bundleURL: URL,
        operationID downloadID: UUID,
        route: NakedBundleReferenceRoute,
        cliURLOverride: URL? = nil,
        recordCommand: @escaping @Sendable (String) async -> Void
    ) async throws -> Bool {
        // Strategy 1: an NCBI assembly. The CLI fetches it by its accession, so on that route a
        // summary with no accession counts as no assembly found.
        if let summary = try await findAssembly(inferredRef: inferredRef, downloadID: downloadID) {
            let accession = summary.assemblyAccession.flatMap { $0.isEmpty ? nil : $0 }
            switch route {
            case .legacy:
                if let accession {
                    await recordCommand(nakedBundleReferenceCommand(accession: accession, bundleURL: bundleURL))
                }
                try await mergeAssemblyInProcess(summary, into: bundleURL, downloadID: downloadID)
                return true
            case .cli:
                if let accession {
                    try await fetchIntoBundle(
                        accession, bundleURL: bundleURL, downloadID: downloadID,
                        cliURLOverride: cliURLOverride, recordCommand: recordCommand)
                    return true
                }
            }
        }

        // Strategy 2: the GenBank record of the VCF's first versioned RefSeq accession. It runs in
        // process on both routes and records no command, because `fetch genome <accession>
        // --into-bundle` builds the record's bundle with differences BIO has not signed
        // (cli-parity-gap variant-only-reference-genbank-fallback).
        guard let firstAccession = ncbiAccessions.first else { return false }
        mainSplitPerformOnMainRunLoop {
            _ = DownloadCenter.shared.update(id: downloadID, progress: 0.15, detail: "Fetching \(firstAccession) from GenBank\u{2026}")
        }
        try await mergeGenBankRecordInProcess(firstAccession, into: bundleURL, downloadID: downloadID)
        return true
    }

    /// The arguments of the `lungfish-cli` child that adds `accession`'s genome and annotations to
    /// `bundleURL`, which the row records as its command (ruling M3-1). They never hold the NCBI
    /// key, which reaches the child through its environment (SWIFT 6).
    nonisolated static func nakedBundleReferenceFetchArguments(accession: String, bundleURL: URL) -> [String] {
        ["fetch", "genome", accession, "--into-bundle", bundleURL.path, "--format", "json"]
    }

    /// The command the row records for `accession`, the child's arguments after `lungfish-cli`.
    nonisolated static func nakedBundleReferenceCommand(accession: String, bundleURL: URL) -> String {
        let arguments = nakedBundleReferenceFetchArguments(accession: accession, bundleURL: bundleURL)
        return OperationCenter.buildCLICommand(subcommand: "fetch genome", args: Array(arguments.dropFirst(2)))
    }

    /// The CLI route. Records the child's command on the row, then runs `fetch genome <accession>
    /// --into-bundle <bundle>` with the NCBI key in its environment, its events on the row and the
    /// row's Cancel as its SIGTERM, as a genome row of the NCBI browser does (`GenomeRowCLIDownload`).
    private nonisolated static func fetchIntoBundle(
        _ accession: String,
        bundleURL: URL,
        downloadID: UUID,
        cliURLOverride: URL?,
        recordCommand: @escaping @Sendable (String) async -> Void
    ) async throws {
        await recordCommand(nakedBundleReferenceCommand(accession: accession, bundleURL: bundleURL))
        let child = GenomeRowCLIDownload(operationID: downloadID, index: 0, totalCount: 1, cliURLOverride: cliURLOverride)
        _ = try await child.run(
            nakedBundleReferenceFetchArguments(accession: accession, bundleURL: bundleURL),
            apiKey: await NCBIService().resolvedAPIKey)
    }

    /// The NCBI assembly summary for `inferredRef`, searched as before Phase 2.10, by the VCF's
    /// assembly accession or else by organism and assembly name. Nil when NCBI has none.
    private nonisolated static func findAssembly(
        inferredRef: ReferenceInference.Result,
        downloadID: UUID
    ) async throws -> NCBIAssemblySummary? {
        guard let assembly = inferredRef.assembly else { return nil }

        let searchTerm: String
        if let accession = inferredRef.accession {
            searchTerm = accession
        } else {
            searchTerm = "\(inferredRef.organism ?? assembly)[Organism] AND \(assembly)[Assembly Name]"
        }

        let ncbi = NCBIService()

        mainSplitPerformOnMainRunLoop {
            _ = DownloadCenter.shared.update(id: downloadID, progress: 0.05, detail: "Searching NCBI Assembly for \(assembly)\u{2026}")
        }

        let ids = try await ncbi.esearch(database: .assembly, term: searchTerm, retmax: 5)
        guard !ids.isEmpty else {
            mainSplitLogger.info("tryAssemblyDownload: No assembly found for '\(searchTerm, privacy: .public)', will try GenBank fallback")
            return nil
        }

        mainSplitPerformOnMainRunLoop {
            _ = DownloadCenter.shared.update(id: downloadID, progress: 0.1, detail: "Getting assembly info\u{2026}")
        }

        let summaries = try await ncbi.assemblyEsummary(ids: ids)
        guard let assemblySummary = summaries.first else {
            mainSplitLogger.info("tryAssemblyDownload: No assembly summary for ids=\(ids, privacy: .public), will try GenBank fallback")
            return nil
        }
        return assemblySummary
    }

    /// The in-process route of an assembly, as before Phase 2.10. `GenomeDownloadViewModel` builds
    /// the bundle in the project's `.tmp` folder, and its genome and annotations are merged in.
    private nonisolated static func mergeAssemblyInProcess(
        _ assemblySummary: NCBIAssemblySummary,
        into bundleURL: URL,
        downloadID: UUID
    ) async throws {
        let tempDir = try ProjectTempDirectory.createFromContext(prefix: "ref-", contextURL: bundleURL)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        mainSplitPerformOnMainRunLoop {
            _ = DownloadCenter.shared.update(id: downloadID, progress: 0.15, detail: "Downloading genome files\u{2026}")
        }

        let viewModel = GenomeDownloadViewModel()
        let sourceBundleURL = try await viewModel.downloadAndBuild(
            assembly: assemblySummary,
            outputDirectory: tempDir
        ) { progress, message in
            let scaledProgress = 0.15 + progress * 0.8
            mainSplitPerformOnMainRunLoop {
                _ = DownloadCenter.shared.update(id: downloadID, progress: scaledProgress, detail: message)
            }
        }

        try mergeGenomeIntoBundle(sourceBundleURL: sourceBundleURL, targetBundleURL: bundleURL)
    }

    /// The in-process route of the GenBank fallback, as before Phase 2.10.
    /// `GenBankBundleDownloadViewModel` builds the record's bundle in the project's `.tmp` folder,
    /// and its genome and annotations are merged in.
    private nonisolated static func mergeGenBankRecordInProcess(
        _ accession: String,
        into bundleURL: URL,
        downloadID: UUID
    ) async throws {
        let tempDir = try ProjectTempDirectory.createFromContext(prefix: "ref-", contextURL: bundleURL)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let genBankVM = GenBankBundleDownloadViewModel()
        let genBankBundleURL = try await genBankVM.downloadAndBuild(
            accession: accession,
            outputDirectory: tempDir
        ) { progress, message in
            let scaledProgress = 0.15 + progress * 0.8
            mainSplitPerformOnMainRunLoop {
                _ = DownloadCenter.shared.update(id: downloadID, progress: scaledProgress, detail: message)
            }
        }

        try mergeGenomeIntoBundle(
            sourceBundleURL: genBankBundleURL,
            targetBundleURL: bundleURL
        )
    }

    /// Merges genome files from a fully-built temp bundle into a naked (variant-only) bundle.
    private nonisolated static func mergeGenomeIntoBundle(sourceBundleURL: URL, targetBundleURL: URL) throws {
        let fm = FileManager.default

        // Load source manifest to get genome info and annotation tracks
        let sourceManifest = try BundleManifest.load(from: sourceBundleURL)

        // Copy genome directory (remove existing first, ignore if absent)
        let sourceGenomeDir = sourceBundleURL.appendingPathComponent("genome")
        let targetGenomeDir = targetBundleURL.appendingPathComponent("genome")
        try? fm.removeItem(at: targetGenomeDir)
        try fm.copyItem(at: sourceGenomeDir, to: targetGenomeDir)

        // Copy annotation files (remove existing first, ignore if absent)
        let sourceAnnoDir = sourceBundleURL.appendingPathComponent("annotations")
        let targetAnnoDir = targetBundleURL.appendingPathComponent("annotations")
        try? fm.removeItem(at: targetAnnoDir)
        if fm.fileExists(atPath: sourceAnnoDir.path) {
            try fm.copyItem(at: sourceAnnoDir, to: targetAnnoDir)
        }

        // Update target manifest: add genome + annotations from source, keep
        // existing variants/alignments/tracks/warnings/recordStore. Built with
        // `mergingGenomeAndAnnotations` so every field the source doesn't
        // explicitly contribute round-trips unchanged — signal
        // tracks, warnings, browserSummary, originBundlePath and recordStore
        // on the target bundle are not dropped by this merge.
        let targetManifest = try BundleManifest.load(from: targetBundleURL)
        let updatedManifest = targetManifest.mergingGenomeAndAnnotations(
            from: sourceManifest,
            preferredName: sourceManifest.name
        )
        try updatedManifest.save(to: targetBundleURL)
    }
}
