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
    /// On completion, updates the bundle's manifest with genome info
    /// and reloads the bundle in the viewer.
    func downloadReferenceForNakedBundle(
        inferredRef: ReferenceInference.Result,
        ncbiAccessions: [String],
        bundleURL: URL
    ) {
        guard canWriteProjectOutputs(workflowName: "Reference download") else { return }
        let assemblyName = inferredRef.assembly ?? ncbiAccessions.first ?? "Reference"

        Self.beginNakedBundleReferenceDownloadOperation(
            assemblyName: assemblyName,
            routeContext: operationRouteContext
        ) { downloadID in
            Task.detached { [weak self] in
                do {
                    let tempDir = try ProjectTempDirectory.createFromContext(
                        prefix: "ref-", contextURL: bundleURL)
                    defer { try? FileManager.default.removeItem(at: tempDir) }

                    // Strategy 1: Try NCBI Assembly search
                    let tempBundleURL = try await Self.tryAssemblyDownload(
                        inferredRef: inferredRef,
                        outputDirectory: tempDir,
                        downloadID: downloadID
                    )

                    if let sourceBundleURL = tempBundleURL {
                        // Assembly download succeeded — merge into naked bundle
                        try Self.mergeGenomeIntoBundle(
                            sourceBundleURL: sourceBundleURL,
                            targetBundleURL: bundleURL
                        )
                    } else if let firstAccession = ncbiAccessions.first {
                        // Strategy 2: Fall back to GenBank nucleotide fetch
                        mainSplitPerformOnMainRunLoop {
                            _ = DownloadCenter.shared.update(id: downloadID, progress: 0.15, detail: "Fetching \(firstAccession) from GenBank\u{2026}")
                        }

                        let genBankVM = GenBankBundleDownloadViewModel()
                        let genBankBundleURL = try await genBankVM.downloadAndBuild(
                            accession: firstAccession,
                            outputDirectory: tempDir
                        ) { progress, message in
                            let scaledProgress = 0.15 + progress * 0.8
                            mainSplitPerformOnMainRunLoop {
                                _ = DownloadCenter.shared.update(id: downloadID, progress: scaledProgress, detail: message)
                            }
                        }

                        try Self.mergeGenomeIntoBundle(
                            sourceBundleURL: genBankBundleURL,
                            targetBundleURL: bundleURL
                        )
                    } else {
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

    /// Attempts to download reference via NCBI Assembly search.
    /// Returns the temp bundle URL on success, or nil if no assembly found.
    private nonisolated static func tryAssemblyDownload(
        inferredRef: ReferenceInference.Result,
        outputDirectory: URL,
        downloadID: UUID
    ) async throws -> URL? {
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

        mainSplitPerformOnMainRunLoop {
            _ = DownloadCenter.shared.update(id: downloadID, progress: 0.15, detail: "Downloading genome files\u{2026}")
        }

        let viewModel = GenomeDownloadViewModel()
        let bundleURL = try await viewModel.downloadAndBuild(
            assembly: assemblySummary,
            outputDirectory: outputDirectory
        ) { progress, message in
            let scaledProgress = 0.15 + progress * 0.8
            mainSplitPerformOnMainRunLoop {
                _ = DownloadCenter.shared.update(id: downloadID, progress: scaledProgress, detail: message)
            }
        }

        return bundleURL
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
