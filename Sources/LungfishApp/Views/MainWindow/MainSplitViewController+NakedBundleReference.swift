// MainSplitViewController+NakedBundleReference.swift - The reference download of a variant-only bundle
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishWorkflow
import os.log

extension MainSplitViewController {
    /// Silently downloads reference genome for a naked (variant-only) bundle.
    ///
    /// Tries two strategies in order:
    /// 1. NCBI Assembly search (gives full genome FASTA + GFF3 annotations)
    /// 2. GenBank nucleotide fetch by accession (fallback for single-contig organisms)
    ///
    /// The row locks the bundle (review ruling M3-3). Once the app has found the accession, the row
    /// records the `fetch genome` command that reproduces the run (ruling M3-1), and the CLI merges
    /// the reference in. On completion the viewer reloads the bundle.
    func downloadReferenceForNakedBundle(
        inferredRef: ReferenceInference.Result,
        ncbiAccessions: [String],
        bundleURL: URL
    ) {
        guard canWriteProjectOutputs(workflowName: "Reference download") else { return }
        let assemblyName = inferredRef.assembly ?? ncbiAccessions.first ?? "Reference"

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
                        operationID: downloadID
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
                    self?.reloadMergedReferenceBundle(at: bundleURL)

                } catch is CancellationError {
                    // The CLI child stopped on the row's Cancel.
                    mainSplitPerformOnMainRunLoop {
                        _ = DownloadCenter.shared.acknowledgeCancellation(id: downloadID)
                    }
                    // A variant-only bundle has no genome, so a genome after a cancel is the child's
                    // finished merge. The child checks for a cancel once, before it swaps the folders
                    // and saves the manifest, so a later Cancel still merges, and the viewer, which
                    // shows the variant-only manifest, has to reload it.
                    if (try? BundleManifest.load(from: bundleURL))?.genome != nil {
                        self?.reloadMergedReferenceBundle(at: bundleURL)
                    }
                } catch {
                    let errorMessage = error.localizedDescription
                    mainSplitPerformOnMainRunLoop {
                        _ = DownloadCenter.shared.fail(id: downloadID, detail: errorMessage)
                    }
                    mainSplitLogger.error("downloadReferenceForNakedBundle: Failed - \(errorMessage)")
                }
            }
        }
    }

    /// Shows the bundle at `bundleURL` in the viewer again, on the main queue, once a reference is
    /// merged into it. The site's detached task calls it after a merge that completed and after a
    /// cancel that came too late to stop one.
    private nonisolated func reloadMergedReferenceBundle(at bundleURL: URL) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.displayReferenceBundleViewportFromSidebar(at: bundleURL)
            }
        }
    }

    /// Finds the reference of the variant-only bundle at `bundleURL` and merges it in, for the row
    /// `operationID`, and returns false when no reference was found. The app searches NCBI as
    /// before Phase 2.10 (review ruling M3-1), so the search by organism and assembly name stays a
    /// read of the app's, and the record names the accession fetched. Once the accession is known,
    /// an assembly's or the GenBank record's, `recordCommand` gets the `fetch genome` command that
    /// reproduces the run, which refines the row's placeholder
    /// (``nakedBundleReferencePlaceholderCommand(bundleURL:)``), before the CLI launches it.
    /// `cliURLOverride` names the CLI a test launches.
    nonisolated static func downloadNakedBundleReference(
        inferredRef: ReferenceInference.Result,
        ncbiAccessions: [String],
        bundleURL: URL,
        operationID downloadID: UUID,
        cliURLOverride: URL? = nil,
        recordCommand: @escaping @Sendable (String) async -> Void
    ) async throws -> Bool {
        // Strategy 1: an NCBI assembly. The CLI fetches it by its accession, so a summary with no
        // accession counts as no assembly found.
        if let summary = try await findAssembly(inferredRef: inferredRef, downloadID: downloadID) {
            let accession = summary.assemblyAccession.flatMap { $0.isEmpty ? nil : $0 }
            if let accession {
                try await fetchIntoBundle(
                    accession, bundleURL: bundleURL, downloadID: downloadID,
                    cliURLOverride: cliURLOverride, recordCommand: recordCommand)
                return true
            }
        }

        // Strategy 2: the GenBank record of the VCF's first versioned RefSeq accession. `fetch
        // genome <accession> --into-bundle` builds the record's bundle (lane A44 M3, BIO's second
        // ruling).
        guard let firstAccession = ncbiAccessions.first else { return false }
        mainSplitPerformOnMainRunLoop {
            _ = DownloadCenter.shared.update(id: downloadID, progress: 0.15, detail: "Fetching \(firstAccession) from GenBank\u{2026}")
        }
        try await fetchIntoBundle(
            firstAccession, bundleURL: bundleURL, downloadID: downloadID,
            cliURLOverride: cliURLOverride, recordCommand: recordCommand)
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

    /// The command the row begins with, the run's command with `<derived>` for the accession the
    /// run finds, the placeholder the FASTQ rows of docs/contracts/CLI-EQUIVALENCE.md record for a
    /// value resolved after `begin`. The run refines it with `setCommand` (the manager's ruling on
    /// note 4 of lane A44 M3), and a run that finds no reference keeps it.
    nonisolated static func nakedBundleReferencePlaceholderCommand(bundleURL: URL) -> String {
        nakedBundleReferenceCommand(accession: "<derived>", bundleURL: bundleURL)
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
}
