// SequenceViewerView+Alignment.swift - Extracted from SequenceViewerView.swift (pure mechanical split, no behavior change)
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import LungfishCore
import LungfishIO
import UniformTypeIdentifiers
import Quartz
import PDFKit
import os.log

extension SequenceViewerView {

    // MARK: - Alignment Chromosome Aliasing

    /// Translates a reference chromosome name to the BAM/CRAM chromosome name.
    /// Returns the original name if no alias is needed.
    func alignmentChromosomeName(for refChrom: String) -> String {
        alignmentChromosomeAliasMap[refChrom] ?? refChrom
    }

    /// Builds a map from reference chromosome names to BAM/CRAM chromosome names.
    ///
    /// BAM files often use different chromosome naming from the reference
    /// (e.g., "MN908947.3" vs "MN908947", or "chr1" vs "1").
    /// This method reads the AlignmentMetadataDatabase (populated from samtools idxstats
    /// at import time) and matches chromosomes by exact sequence length.
    static func buildAlignmentChromosomeAliasMap(
        bundleChromosomes: [ChromosomeInfo],
        alignmentTracks: [AlignmentTrackInfo],
        bundleURL: URL,
        sequenceViewerLogger: Logger
    ) -> [String: String] {
        let refChromNames = Set(bundleChromosomes.map(\.name))

        // Collect BAM chromosome names and lengths from metadata databases
        var bamChromLengths: [String: Int64] = [:]
        for track in alignmentTracks {
            guard let dbRelPath = track.metadataDBPath else { continue }
            let dbURL = bundleURL.appendingPathComponent(dbRelPath)
            guard let db = try? AlignmentMetadataDatabase(url: dbURL) else { continue }
            for stat in db.chromosomeStats() {
                bamChromLengths[stat.chromosome] = stat.length
            }
        }

        guard !bamChromLengths.isEmpty else { return [:] }

        let bamChromNames = Set(bamChromLengths.keys)

        // Check if all BAM chromosomes already match reference names
        let unmatched = bamChromNames.subtracting(refChromNames)
        if unmatched.isEmpty { return [:] }

        // Build alias map: ref name → BAM name, matching by exact length
        var aliasMap: [String: String] = [:]
        var usedBAMChroms = Set<String>()

        for chrom in bundleChromosomes {
            // Skip if BAM already has this exact name
            if bamChromNames.contains(chrom.name) { continue }

            // Find a BAM chromosome with matching length
            var bestMatch: String?
            for bamChrom in unmatched where !usedBAMChroms.contains(bamChrom) {
                guard let bamLength = bamChromLengths[bamChrom] else { continue }
                if bamLength == chrom.length {
                    bestMatch = bamChrom
                    break
                }
            }

            if let match = bestMatch {
                aliasMap[chrom.name] = match
                usedBAMChroms.insert(match)
            }
        }

        if !aliasMap.isEmpty {
            sequenceViewerLogger.info("buildAlignmentChromosomeAliasMap: Built \(aliasMap.count) aliases (e.g., \(aliasMap.first?.key ?? "") → \(aliasMap.first?.value ?? ""))")
        }

        return aliasMap
    }

    /// Fetches variant annotations asynchronously from the VariantDatabase.
    /// Runs SQLite queries on a background thread, converts to SequenceAnnotation,
    /// and merges with the annotation rendering pipeline.
    static let variantFetchQueue = DispatchQueue(label: "com.lungfish.variantFetch", qos: .userInteractive)

    func fetchVariantsAsync(bundle: ReferenceBundle, region: GenomicRegion) {
        let variantTrackIds = bundle.variantTrackIds
        guard !variantTrackIds.isEmpty else { return }

        variantFetchGeneration += 1
        let thisGeneration = variantFetchGeneration
        isFetchingVariants = true
        let fetchStart = Date()

        let chromLength = bundle.chromosomeLength(named: region.chromosome) ?? Int64(region.end + 1000)
        let visibleSpan = region.end - region.start
        let expandAmount = max(50_000, visibleSpan * 2)
        let expandedStart = max(0, region.start - expandAmount)
        let expandedEnd = min(Int(chromLength), region.end + expandAmount)
        let expandedRegion = GenomicRegion(chromosome: region.chromosome, start: expandedStart, end: expandedEnd)

        let aliasMapSnapshot = variantChromosomeAliasMap
        let trackChromosomeMapSnapshot = variantTrackChromosomeMap

        sequenceViewerLogger.info("fetchVariantsAsync: gen=\(thisGeneration), Fetching variants for \(expandedRegion.description)")

        Self.variantFetchQueue.async { [weak self] in
            var allVariantAnnotations: [SequenceAnnotation] = []
            for trackId in variantTrackIds {
                guard let trackInfo = bundle.variantTrack(id: trackId),
                      let dbPath = trackInfo.databasePath else { continue }
                guard let dbURL = try? BundleManifest.validatedBundleMemberURL(
                    for: dbPath,
                    in: bundle.url,
                    field: "variants[\(trackId)].databasePath"
                ) else { continue }
                guard FileManager.default.fileExists(atPath: dbURL.path) else { continue }

                do {
                    let db = try VariantDatabase(url: dbURL)
                    let availableChromosomes = trackChromosomeMapSnapshot[trackId] ?? Set(db.allChromosomes())
                    let queryChromosomes = resolveVariantChromosomeCandidates(
                        requestedChromosome: region.chromosome,
                        availableChromosomes: availableChromosomes,
                        aliasMap: aliasMapSnapshot
                    )

                    var records: [VariantDatabaseRecord] = []
                    var resolvedChromosome = region.chromosome
                    for queryChrom in queryChromosomes {
                        let queried = db.query(
                            chromosome: queryChrom,
                            start: expandedStart,
                            end: expandedEnd
                        )
                        if !queried.isEmpty {
                            records = queried
                            resolvedChromosome = queryChrom
                            break
                        }
                    }

                    if resolvedChromosome != region.chromosome {
                        sequenceViewerLogger.info(
                            "fetchVariantsAsync: Track \(trackId, privacy: .public) resolved chromosome '\(region.chromosome, privacy: .public)' -> '\(resolvedChromosome, privacy: .public)'"
                        )
                    }

                    if !records.isEmpty {
                        let annotations = records.map { record -> SequenceAnnotation in
                            var annotation = record.toAnnotation()
                            // Keep rendering coordinates in the active reference chromosome namespace.
                            annotation.chromosome = region.chromosome
                            annotation.qualifiers["variant_track_id"] = AnnotationQualifier(trackId)
                            return annotation
                        }
                        allVariantAnnotations.append(contentsOf: annotations)
                    }
                } catch {
                    sequenceViewerLogger.error("fetchVariantsAsync: Failed to fetch variants for track \(trackId): \(error.localizedDescription)")
                }
            }

            let count = allVariantAnnotations.count
            sequenceViewerLogger.info("fetchVariantsAsync[RUNLOOP_V2]: gen=\(thisGeneration), background done, \(count) variants found")

            Self.enqueueMainRunLoop { [weak self] in
                sequenceViewerLogger.info("fetchVariantsAsync[RUNLOOP_V2]: gen=\(thisGeneration), main-runloop callback executing")
                guard let viewer = self else {
                    sequenceViewerLogger.error("fetchVariantsAsync: self is nil in main-runloop callback, \(count) variants lost")
                    return
                }
                guard thisGeneration == viewer.variantFetchGeneration else {
                    sequenceViewerLogger.info("fetchVariantsAsync: Discarding stale result gen=\(thisGeneration) (current=\(viewer.variantFetchGeneration))")
                    return
                }
                guard viewer.currentReferenceBundle?.url.standardizedFileURL == bundle.url.standardizedFileURL else {
                    sequenceViewerLogger.info("fetchVariantsAsync: Discarding stale result for replaced reference bundle")
                    return
                }
                let elapsed = Date().timeIntervalSince(fetchStart)
                viewer.cachedVariantAnnotations = allVariantAnnotations
                viewer.cachedVariantRegion = expandedRegion
                viewer.invalidateFilteredVariantCache()
                viewer.isFetchingVariants = false
                viewer.invalidateAnnotationTile()
                sequenceViewerLogger.info("fetchVariantsAsync: Cached \(count) variant annotations in \(elapsed, format: .fixed(precision: 3))s")
                viewer.setNeedsDisplay(viewer.bounds)

                // Notify variant table drawer of updated viewport variants.
                // Send the reference chromosome label; drawer-side query logic resolves DB aliases.
                NotificationCenter.default.post(
                    name: .viewportVariantsUpdated,
                    object: viewer,
                    userInfo: viewer.windowScopedUserInfo([
                        NotificationUserInfoKey.chromosome: region.chromosome,
                        NotificationUserInfoKey.start: region.start,
                        NotificationUserInfoKey.end: region.end,
                        "variantCount": count,
                    ])
                )
            }
        }
    }

    // MARK: - Read Alignment Fetching

    /// Fetches sparse depth points asynchronously from samtools depth for coverage-tier rendering.
    ///
    /// This decouples zoomed-out coverage from full SAM read parsing.
    func fetchDepthAsync(bundle: ReferenceBundle, region: GenomicRegion) {
        guard !alignmentDataProviders.isEmpty else { return }

        let chromLength = bundle.chromosomeLength(named: region.chromosome) ?? Int64(region.end + 1000)
        let visibleSpan = region.end - region.start
        let expandAmount = max(5_000, visibleSpan) // 1x viewport padding for panning
        let expandedStart = max(0, region.start - expandAmount)
        let expandedEnd = min(Int(chromLength), region.end + expandAmount)
        let expandedRegion = GenomicRegion(chromosome: region.chromosome, start: expandedStart, end: expandedEnd)

        let providers = activeAlignmentProviders()
        guard !providers.isEmpty else { return }
        let token = beginDepthFetch(
            bundleURL: bundle.url,
            trackID: visibleAlignmentTrackIDSetting,
            region: expandedRegion
        )
        let tokenGeneration = token.generation
        let tokenIdentity = token.identity
        let bamChromosome = alignmentChromosomeName(for: region.chromosome)
        let mapQFilter = max(0, max(minMapQSetting, consensusMinMapQSetting))
        let baseQFilter = max(0, consensusMinBaseQSetting)
        let excludeFlags = excludeFlagsSetting

        sequenceViewerLogger.info(
            "fetchDepthAsync: gen=\(tokenGeneration), Fetching depth for \(expandedRegion.description) (BAM chrom: \(bamChromosome), minMAPQ: \(mapQFilter), minBQ: \(baseQFilter), flags: 0x\(String(excludeFlags, radix: 16)))"
        )

        Task.detached { [weak self] in
            var depthByPosition: [Int: Int] = [:]
            depthByPosition.reserveCapacity(8192)

            for (_, provider) in providers {
                do {
                    var points = try await provider.fetchDepth(
                        chromosome: bamChromosome,
                        start: expandedStart,
                        end: expandedEnd,
                        minMapQ: mapQFilter,
                        minBaseQ: baseQFilter,
                        excludeFlags: excludeFlags
                    )

                    if points.isEmpty, bamChromosome != region.chromosome {
                        let fallback = try await provider.fetchDepth(
                            chromosome: region.chromosome,
                            start: expandedStart,
                            end: expandedEnd,
                            minMapQ: mapQFilter,
                            minBaseQ: baseQFilter,
                            excludeFlags: excludeFlags
                        )
                        if !fallback.isEmpty {
                            sequenceViewerLogger.info(
                                "fetchDepthAsync: Fallback chromosome lookup succeeded for '\(region.chromosome, privacy: .public)' after empty alias query '\(bamChromosome, privacy: .public)'"
                            )
                            points = fallback
                        }
                    }

                    for point in points where point.depth > 0 {
                        depthByPosition[point.position, default: 0] += point.depth
                    }
                } catch {
                    sequenceViewerLogger.error("fetchDepthAsync: Failed to fetch depth: \(error)")
                }
            }

            let mergedPoints = depthByPosition
                .map { ReadTrackRenderer.CoveragePoint(position: $0.key, depth: $0.value) }
                .sorted { $0.position < $1.position }

            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let viewer = self else { return }
                    let token = AsyncRequestToken(generation: tokenGeneration, identity: tokenIdentity)
                    guard viewer.commitDepthFetch(token, points: mergedPoints, region: expandedRegion) else {
                        sequenceViewerLogger.info("fetchDepthAsync: Discarding stale result gen=\(tokenGeneration)")
                        return
                    }
                    sequenceViewerLogger.info("fetchDepthAsync: Cached \(mergedPoints.count) depth points")
                    viewer.setNeedsDisplay(viewer.bounds)
                }
            }
        }
    }

    /// Returns a stable cache signature for consensus options.
    func currentConsensusOptionsSignature() -> String {
        [
            consensusModeSetting.rawValue,
            showConsensusTrackSetting ? "1" : "0",
            consensusUseAmbiguitySetting ? "1" : "0",
            String(max(0, max(minMapQSetting, consensusMinMapQSetting))),
            String(max(0, consensusMinBaseQSetting)),
            String(max(1, consensusMinDepthSetting)),
            String(excludeFlagsSetting),
        ].joined(separator: "|")
    }

    /// Fetches consensus sequence asynchronously for the current alignment region.
    func fetchConsensusAsync(bundle: ReferenceBundle, region: GenomicRegion) {
        guard showConsensusTrackSetting else { return }
        guard !alignmentDataProviders.isEmpty else { return }
        let currentScale = viewController?.referenceFrame?.scale
            ?? (Double(max(region.end - region.start, 1)) / max(Double(max(bounds.width, 1)), 1.0))
        guard currentScale < showLettersThreshold else { return }

        let chromLength = bundle.chromosomeLength(named: region.chromosome) ?? Int64(region.end + 1000)
        let visibleSpan = region.end - region.start
        let expandAmount = max(5_000, visibleSpan)
        let expandedStart = max(0, region.start - expandAmount)
        let expandedEnd = min(Int(chromLength), region.end + expandAmount)
        let expandedRegion = GenomicRegion(chromosome: region.chromosome, start: expandedStart, end: expandedEnd)

        let providers = activeAlignmentProviders()
        guard let provider = providers.first?.provider else { return }
        let token = beginConsensusFetch(
            bundleURL: bundle.url,
            trackID: visibleAlignmentTrackIDSetting,
            region: expandedRegion
        )
        let tokenGeneration = token.generation
        let tokenIdentity = token.identity
        let bamChromosome = alignmentChromosomeName(for: region.chromosome)
        let mapQFilter = max(0, max(minMapQSetting, consensusMinMapQSetting))
        let baseQFilter = max(0, consensusMinBaseQSetting)
        let minDepth = max(1, consensusMinDepthSetting)
        let excludeFlags = excludeFlagsSetting
        let mode = consensusModeSetting
        let useAmbiguity = consensusUseAmbiguitySetting
        let optionsSignature = currentConsensusOptionsSignature()

        sequenceViewerLogger.info(
            "fetchConsensusAsync: gen=\(tokenGeneration), Fetching consensus for \(expandedRegion.description) (BAM chrom: \(bamChromosome), mode: \(mode.rawValue), minMAPQ: \(mapQFilter), minBQ: \(baseQFilter), minDepth: \(minDepth))"
        )

        Task.detached { [weak self] in
            var result = AlignmentDataProvider.ConsensusFASTAResult(sequence: "", headerStart: nil)
            do {
                result = try await provider.fetchConsensus(
                    chromosome: bamChromosome,
                    start: expandedStart,
                    end: expandedEnd,
                    mode: mode,
                    minMapQ: mapQFilter,
                    minBaseQ: baseQFilter,
                    minDepth: minDepth,
                    excludeFlags: excludeFlags,
                    useAmbiguity: useAmbiguity,
                    showDeletions: true,
                    showInsertions: false
                )
                if result.sequence.isEmpty, bamChromosome != region.chromosome {
                    let fallback = try await provider.fetchConsensus(
                        chromosome: region.chromosome,
                        start: expandedStart,
                        end: expandedEnd,
                        mode: mode,
                        minMapQ: mapQFilter,
                        minBaseQ: baseQFilter,
                        minDepth: minDepth,
                        excludeFlags: excludeFlags,
                        useAmbiguity: useAmbiguity,
                        showDeletions: true,
                        showInsertions: false
                    )
                    if !fallback.sequence.isEmpty {
                        sequenceViewerLogger.info(
                            "fetchConsensusAsync: Fallback chromosome lookup succeeded for '\(region.chromosome, privacy: .public)' after empty alias query '\(bamChromosome, privacy: .public)'"
                        )
                        result = fallback
                    }
                }
            } catch {
                sequenceViewerLogger.error("fetchConsensusAsync: Failed to fetch consensus: \(error)")
            }

            let consensus = result.sequence
            let headerStart = result.headerStart

            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let viewer = self else { return }
                    let token = AsyncRequestToken(generation: tokenGeneration, identity: tokenIdentity)
                    guard viewer.consensusFetchGate.isCurrent(token) else {
                        sequenceViewerLogger.info("fetchConsensusAsync: Discarding stale result gen=\(tokenGeneration)")
                        return
                    }
                    // Determine the actual start position of the consensus output.
                    // The FASTA header (e.g., ">chr:101-200") tells us the 1-based start.
                    // If the header start matches our requested start, all is well.
                    // If it differs, samtools clipped to the data range and we must use
                    // the actual start to avoid a positional shift in rendering.
                    let actualStart: Int
                    if let headerStart {
                        actualStart = headerStart
                        if headerStart != expandedStart {
                            sequenceViewerLogger.warning(
                                "fetchConsensusAsync: Header start (\(headerStart)) differs from requested start (\(expandedStart)) — using header value"
                            )
                        }
                    } else {
                        actualStart = expandedStart
                    }

                    let expectedLength = expandedEnd - expandedStart
                    if !consensus.isEmpty && consensus.count != expectedLength {
                        sequenceViewerLogger.warning(
                            "fetchConsensusAsync: Consensus length (\(consensus.count)) differs from expected (\(expectedLength)) for region \(expandedRegion.description)"
                        )
                    }

                    let normalizedConsensus: String?
                    if consensus.isEmpty {
                        normalizedConsensus = nil
                    } else {
                        // Normalize to the requested window so consensus and reference rows
                        // always span identical genomic widths in the viewport.
                        normalizedConsensus = viewer.normalizedConsensusSequence(
                            consensus,
                            sourceStart: actualStart,
                            targetStart: expandedStart,
                            targetEnd: expandedEnd
                        )
                    }
                    let committedRegion = GenomicRegion(
                        chromosome: expandedRegion.chromosome,
                        start: expandedStart,
                        end: expandedEnd
                    )
                    guard viewer.commitConsensusFetch(
                        token,
                        sequence: normalizedConsensus,
                        region: committedRegion,
                        optionsSignature: optionsSignature
                    ) else {
                        sequenceViewerLogger.info("fetchConsensusAsync: Discarding stale normalized result gen=\(token.generation)")
                        return
                    }
                    sequenceViewerLogger.info(
                        "fetchConsensusAsync: Cached consensus sourceStart=\(actualStart) sourceLength=\(consensus.count) normalizedLength=\(viewer.cachedConsensusSequence?.count ?? 0) headerStart=\(headerStart.map(String.init) ?? "nil")"
                    )
                    viewer.setNeedsDisplay(viewer.bounds)
                }
            }
        }
    }

    func fetchConsensusSequenceForExport(request: MappingConsensusExportRequest) async throws -> String {
        guard let provider = activeAlignmentProviders().first?.provider else {
            throw NSError(
                domain: "Lungfish",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "No alignment provider loaded"]
            )
        }

        let primaryChromosome = alignmentChromosomeName(for: request.chromosome)
        var result = try await provider.fetchConsensus(
            chromosome: primaryChromosome,
            start: request.start,
            end: request.end,
            mode: request.mode,
            minMapQ: request.minMapQ,
            minBaseQ: request.minBaseQ,
            minDepth: request.minDepth,
            excludeFlags: request.excludeFlags,
            useAmbiguity: request.useAmbiguity,
            showDeletions: request.showDeletions,
            showInsertions: request.showInsertions
        )

        if result.sequence.isEmpty, primaryChromosome != request.chromosome {
            let fallback = try await provider.fetchConsensus(
                chromosome: request.chromosome,
                start: request.start,
                end: request.end,
                mode: request.mode,
                minMapQ: request.minMapQ,
                minBaseQ: request.minBaseQ,
                minDepth: request.minDepth,
                excludeFlags: request.excludeFlags,
                useAmbiguity: request.useAmbiguity,
                showDeletions: request.showDeletions,
                showInsertions: request.showInsertions
            )
            if !fallback.sequence.isEmpty {
                result = fallback
            }
        }

        return result.sequence
    }

    /// Draws consensus sequence row below the coverage strip.
    func drawConsensusTrack(
        sequenceString: String?,
        region: GenomicRegion?,
        frame: ReferenceFrame,
        context: CGContext,
        rect: CGRect
    ) {
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        ("Consensus" as NSString).draw(
            at: CGPoint(x: 4, y: rect.minY + 2),
            withAttributes: labelAttrs
        )

        guard let sequenceString,
              let region,
              region.chromosome == frame.chromosome else {
            context.setStrokeColor(NSColor.systemGray.withAlphaComponent(0.45).cgColor)
            context.setLineWidth(1)
            context.move(to: CGPoint(x: rect.minX, y: rect.midY))
            context.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            context.strokePath()
            return
        }

        guard let slice = visibleSequenceSlice(
            sequenceString: sequenceString,
            cachedRegion: region,
            frame: frame
        ) else {
            context.setStrokeColor(NSColor.systemGray.withAlphaComponent(0.55).cgColor)
            context.setLineWidth(1)
            context.move(to: CGPoint(x: rect.minX, y: rect.midY))
            context.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            context.strokePath()
            return
        }

        let scale = frame.scale
        let inset = frame.leadingInset
        if inset > 0 {
            context.saveGState()
            let clipRect = CGRect(
                x: inset,
                y: rect.minY,
                width: max(0, bounds.width - inset),
                height: rect.height
            )
            context.clip(to: clipRect)
        }

        defer {
            if inset > 0 {
                context.restoreGState()
            }
        }

        if scale < showLettersThreshold {
            drawBasesWithLetters(
                slice.sequence,
                startPosition: slice.startPosition,
                frame: frame,
                context: context,
                rowRect: rect,
                font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
            )
        } else {
            context.setStrokeColor(NSColor.systemGray.withAlphaComponent(0.55).cgColor)
            context.setLineWidth(1)
            context.move(to: CGPoint(x: rect.minX, y: rect.midY))
            context.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            context.strokePath()
        }
    }

    /// Fetches aligned reads asynchronously from samtools for the visible region.
    /// Uses the same generation counter pattern as other fetch methods.
    /// AlignmentDataProvider.fetchReads() is async, so we use Task.detached to avoid
    /// blocking the viewport actor, then return via the GCD main queue.
    func fetchReadsAsync(bundle: ReferenceBundle, region: GenomicRegion) {
        guard !alignmentDataProviders.isEmpty else { return }

        let chromLength = bundle.chromosomeLength(named: region.chromosome) ?? Int64(region.end + 1000)
        let visibleSpan = region.end - region.start
        let currentScale = viewController?.referenceFrame?.scale
            ?? (Double(max(visibleSpan, 1)) / max(Double(max(bounds.width, 1)), 1.0))
        guard ReadViewportPolicy.allowsIndividualReads(scale: currentScale) else { return }

        let tier = ReadViewportPolicy.zoomTier(scale: currentScale)
        let expandAmount: Int
        switch tier {
        case .coverage:
            expandAmount = max(10_000, visibleSpan * 2)
        case .packed:
            expandAmount = max(20_000, visibleSpan * 2)
        case .base:
            expandAmount = max(20_000, visibleSpan * 2)
        }
        let expandedStart = max(0, region.start - expandAmount)
        let expandedEnd = min(Int(chromLength), region.end + expandAmount)
        let expandedRegion = GenomicRegion(chromosome: region.chromosome, start: expandedStart, end: expandedEnd)

        let providers = activeAlignmentProviders()
        guard !providers.isEmpty else { return }
        let token = beginReadFetch(
            bundleURL: bundle.url,
            trackID: visibleAlignmentTrackIDSetting,
            region: expandedRegion
        )
        let tokenGeneration = token.generation
        let tokenIdentity = token.identity
        // Translate reference chromosome name to BAM chromosome name (e.g., MN908947 → MN908947.3)
        let bamChromosome = alignmentChromosomeName(for: region.chromosome)
        let mapQFilter = minMapQSetting
        let excludeFlags = excludeFlagsSetting
        let readGroupFilter = selectedReadGroupsSetting
        let maxReadsPerTrack: Int = limitReadRowsSetting ? 250_000 : Int.max

        sequenceViewerLogger.info("fetchReadsAsync: gen=\(tokenGeneration), Fetching reads for \(expandedRegion.description) (BAM chrom: \(bamChromosome), tier: \(String(describing: tier)), minMAPQ: \(mapQFilter), maxReads/track: \(maxReadsPerTrack), flags: 0x\(String(excludeFlags, radix: 16)))")

        Task.detached { [weak self] in
            var allReads: [AlignedRead] = []
            for (_, provider) in providers {
                do {
                    var reads = try await provider.fetchReads(
                        chromosome: bamChromosome,
                        start: expandedStart,
                        end: expandedEnd,
                        excludeFlags: excludeFlags,
                        minMapQ: mapQFilter,
                        maxReads: maxReadsPerTrack,
                        readGroups: readGroupFilter
                    )
                    if reads.isEmpty, bamChromosome != region.chromosome {
                        let fallbackReads = try await provider.fetchReads(
                            chromosome: region.chromosome,
                            start: expandedStart,
                            end: expandedEnd,
                            excludeFlags: excludeFlags,
                            minMapQ: mapQFilter,
                            maxReads: maxReadsPerTrack,
                            readGroups: readGroupFilter
                        )
                        if !fallbackReads.isEmpty {
                            sequenceViewerLogger.info("fetchReadsAsync: Fallback chromosome lookup succeeded for '\(region.chromosome, privacy: .public)' after empty alias query '\(bamChromosome, privacy: .public)'")
                            reads = fallbackReads
                        }
                    }
                    allReads.append(contentsOf: reads)
                } catch {
                    sequenceViewerLogger.error("fetchReadsAsync: Failed to fetch reads: \(error)")
                }
            }

            let count = allReads.count
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let viewer = self else { return }
                    let token = AsyncRequestToken(generation: tokenGeneration, identity: tokenIdentity)
                    guard viewer.commitReadFetch(token, reads: allReads, region: expandedRegion) else {
                        sequenceViewerLogger.info("fetchReadsAsync: Discarding stale result gen=\(tokenGeneration)")
                        return
                    }
                    sequenceViewerLogger.info("fetchReadsAsync: Cached \(count) reads")
                    viewer.setNeedsDisplay(viewer.bounds)
                }
            }
        }
    }

    func activeAlignmentProviders() -> [(trackId: String, provider: AlignmentDataProvider)] {
        guard let visibleAlignmentTrackIDSetting,
              alignmentDataProviders.contains(where: { $0.trackId == visibleAlignmentTrackIDSetting }) else {
            return alignmentDataProviders
        }

        return alignmentDataProviders.filter { $0.trackId == visibleAlignmentTrackIDSetting }
    }

    static func alignmentFileMenuEntries(
        bundle: ReferenceBundle?,
        activeTrackIds: [String]
    ) -> [AlignmentFileMenuEntry] {
        guard let bundle else { return [] }

        return activeTrackIds.compactMap { trackId in
            guard let track = bundle.alignmentTrack(id: trackId),
                  let resolvedPath = try? bundle.resolveAlignmentPath(track) else {
                return nil
            }
            return AlignmentFileMenuEntry(
                trackId: trackId,
                title: track.name,
                url: URL(fileURLWithPath: resolvedPath)
            )
        }
    }

    /// Fetches genotype data asynchronously for the visible region.
    /// Queries the VariantDatabase for per-sample genotype calls to populate the genotype track.
    /// Uses the same generation counter pattern as other fetch methods.
    static let genotypeFetchQueue = DispatchQueue(label: "com.lungfish.genotypeFetch", qos: .userInitiated)

    func fetchGenotypesAsync(bundle: ReferenceBundle, region: GenomicRegion) {
        let variantTrackIds = bundle.variantTrackIds
        guard !variantTrackIds.isEmpty else { return }

        genotypeFetchGeneration += 1
        let thisGeneration = genotypeFetchGeneration
        isFetchingGenotypes = true
        let fetchStart = Date()

        // Query a tight viewport-centered window for genotypes.
        // Using a large expanded window with LIMIT can starve the visible viewport
        // at dense loci (first-N rows may all be outside what the user can see).
        let chromLength = bundle.chromosomeLength(named: region.chromosome) ?? Int64(region.end + 1000)
        let visibleSpan = region.end - region.start
        let expandAmount = min(10_000, max(1_000, visibleSpan / 2))
        let expandedStart = max(0, region.start - expandAmount)
        let expandedEnd = min(Int(chromLength), region.end + expandAmount)
        let expandedRegion = GenomicRegion(chromosome: region.chromosome, start: expandedStart, end: expandedEnd)
        let displayState = sampleDisplayState

        let aliasMapSnapshot = variantChromosomeAliasMap
        let trackChromosomeMapSnapshot = variantTrackChromosomeMap

        // Capture bundle URL and track info for background thread
        let bundleURL = bundle.url

        sequenceViewerLogger.info("fetchGenotypesAsync: gen=\(thisGeneration), Fetching genotypes for \(expandedRegion.description)")

        Self.genotypeFetchQueue.async { [weak self] in
            var allSites: [VariantSite] = []
            var variantDBByTrackId: [String: VariantDatabase] = [:]
            var sampleNames: [String] = []
            var sampleNameSet = Set<String>()
            var sampleMetadata: [String: [String: String]] = [:]

            for trackId in variantTrackIds {
                guard let trackInfo = bundle.variantTrack(id: trackId),
                      let dbPath = trackInfo.databasePath else { continue }
                guard let dbURL = try? BundleManifest.validatedBundleMemberURL(
                    for: dbPath,
                    in: bundleURL,
                    field: "variants[\(trackId)].databasePath"
                ) else { continue }
                guard FileManager.default.fileExists(atPath: dbURL.path) else { continue }

                do {
                    let db = try VariantDatabase(url: dbURL)
                    variantDBByTrackId[trackId] = db
                    let availableChromosomes = trackChromosomeMapSnapshot[trackId] ?? Set(db.allChromosomes())
                    let queryChromosomes = resolveVariantChromosomeCandidates(
                        requestedChromosome: region.chromosome,
                        availableChromosomes: availableChromosomes,
                        aliasMap: aliasMapSnapshot
                    )
                    var regionData: [(variant: VariantDatabaseRecord, genotypes: [GenotypeRecord])] = []
                    var resolvedChromosome = region.chromosome
                    for queryChrom in queryChromosomes {
                        let queried = db.genotypesInRegion(
                            chromosome: queryChrom,
                            start: expandedRegion.start,
                            end: expandedRegion.end,
                            limit: 5_000
                        )
                        if !queried.isEmpty {
                            regionData = queried
                            resolvedChromosome = queryChrom
                            break
                        }
                    }
                    if resolvedChromosome != region.chromosome {
                        sequenceViewerLogger.info(
                            "fetchGenotypesAsync: Track \(trackId, privacy: .public) resolved chromosome '\(region.chromosome, privacy: .public)' -> '\(resolvedChromosome, privacy: .public)'"
                        )
                    }

                    // For multi-reference / multi-source VCF imports, keep only samples that
                    // have data on this chromosome so unrelated source files don't clutter rows.
                    let chromosomeScopedSamples = db.sampleNames(chromosome: resolvedChromosome)
                    let effectiveSamples = chromosomeScopedSamples.isEmpty ? db.sampleNames() : chromosomeScopedSamples
                    let effectiveSampleSet = Set(effectiveSamples)
                    for name in effectiveSamples where sampleNameSet.insert(name).inserted {
                        sampleNames.append(name)
                    }
                    for entry in db.allSampleMetadata() where effectiveSampleSet.contains(entry.name) {
                        var merged = sampleMetadata[entry.name] ?? [:]
                        merged.merge(entry.metadata) { current, _ in current }
                        sampleMetadata[entry.name] = merged
                    }

                    for (variant, genotypes) in regionData {
                        var gtMap: [String: GenotypeDisplayCall] = [:]
                        var afMap: [String: Double] = [:]
                        for gt in genotypes {
                            let call = classifyGenotype(gt)
                            gtMap[gt.sampleName] = call
                            if let af = alleleFraction(from: gt.alleleDepths) {
                                afMap[gt.sampleName] = af
                            }
                        }
                        allSites.append(VariantSite(
                            position: variant.position,
                            ref: variant.ref,
                            alt: variant.alt,
                            variantType: variant.variantType,
                            genotypes: gtMap,
                            sampleAlleleFractions: afMap,
                            databaseRowId: variant.id,
                            variantID: variant.variantID,
                            sourceTrackId: trackId
                        ))
                    }
                } catch {
                    sequenceViewerLogger.error("fetchGenotypesAsync: Failed for track \(trackId): \(error.localizedDescription)")
                }
            }

            // Enrich variant sites with CSQ impact data (batch query)
            enrichSitesWithCSQImpact(&allSites, variantDatabasesByTrackId: variantDBByTrackId)

            let visibleOrderedSamples = displayState.visibleSamples(from: sampleNames, metadata: sampleMetadata)
            var sampleDisplayNames: [String: String] = [:]

            // Layer 1: DB display_name column
            for (_, db) in variantDBByTrackId {
                for (name, displayName) in db.allDisplayNames() {
                    sampleDisplayNames[name] = displayName
                }
            }

            // Layer 2: displayNameField metadata lookup (overrides DB)
            let displayField = displayState.displayNameField?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let field = displayField, !field.isEmpty {
                for sampleName in visibleOrderedSamples {
                    if let label = sampleMetadata[sampleName]?[field]?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !label.isEmpty {
                        sampleDisplayNames[sampleName] = label
                    }
                }
            }

            // Layer 3: Explicit per-sample overrides (highest priority)
            for (name, override) in displayState.sampleDisplayNameOverrides {
                sampleDisplayNames[name] = override
            }

            let displayData = GenotypeDisplayData(
                sampleNames: visibleOrderedSamples,
                sites: allSites,
                region: expandedRegion
            )
            let siteCount = allSites.count
            let sampleCount = visibleOrderedSamples.count

            Self.enqueueMainRunLoop { [weak self] in
                guard let viewer = self else { return }
                guard thisGeneration == viewer.genotypeFetchGeneration else {
                    sequenceViewerLogger.info("fetchGenotypesAsync: Discarding stale result gen=\(thisGeneration)")
                    return
                }
                let elapsed = Date().timeIntervalSince(fetchStart)
                viewer.cachedGenotypeData = displayData
                viewer.cachedGenotypeSampleDisplayNames = sampleDisplayNames
                viewer.cachedGenotypeRegion = expandedRegion
                viewer.invalidateGutterWidth()
                // Eagerly repopulate frame.leadingInset so draw() uses the correct value
                if let frame = viewer.viewController?.referenceFrame {
                    frame.leadingInset = viewer.variantDataStartX
                }
                viewer.clampGenotypeScrollOffset()
                viewer.isFetchingGenotypes = false
                viewer.invalidateAnnotationTile()
                sequenceViewerLogger.info("fetchGenotypesAsync: Cached \(siteCount) sites × \(sampleCount) samples in \(elapsed, format: .fixed(precision: 3))s")
                viewer.setNeedsDisplay(viewer.bounds)
            }
        }
    }

    /// Fetches sequence data asynchronously from bgzip-compressed FASTA.
    /// Runs decompression on a background thread to avoid blocking the UI.
    /// Only called when zoomed in enough to display sequence (<500 bp/pixel).
    /// Dedicated queue for sequence I/O to avoid being starved by annotation scanning
    /// on the global concurrent queue.
    static let sequenceFetchQueue = DispatchQueue(label: "com.lungfish.sequenceFetch", qos: .userInteractive)

    func fetchSequenceAsync(bundle: ReferenceBundle, region: GenomicRegion) {
        sequenceFetchGeneration += 1
        let thisGeneration = sequenceFetchGeneration
        isFetchingBundleData = true
        sequenceFetchStartTime = Date()
        bundleFetchError = nil

        let chromLength = bundle.chromosomeLength(named: region.chromosome) ?? Int64(region.end + 1000)

        // Limit fetch to a reasonable size to avoid loading hundreds of MB.
        // Always fetch at least 100 Kb to provide buffer for panning.
        let maxFetchSize = AppSettings.shared.sequenceFetchCapKb * 1_000
        let center = (region.start + region.end) / 2
        let visibleSpan = region.end - region.start
        let halfFetch = min(maxFetchSize / 2, max(50_000, visibleSpan / 2 + visibleSpan))
        let expandedStart = max(0, center - halfFetch)
        let expandedEnd = min(Int(chromLength), center + halfFetch)
        let expandedRegion = GenomicRegion(chromosome: region.chromosome, start: expandedStart, end: expandedEnd)

        sequenceViewerLogger.info("fetchSequenceAsync: gen=\(thisGeneration), Fetching \(expandedRegion.description) (\(expandedRegion.length) bp)")

        // Use a dedicated serial queue rather than DispatchQueue.global to prevent
        // thread starvation when the annotation search index is doing heavy annotation I/O
        // scanning on the global concurrent queue.
        Self.sequenceFetchQueue.async { [weak self] in
            sequenceViewerLogger.info("fetchSequenceAsync: gen=\(thisGeneration), background block started, self alive: \(self != nil)")
            do {
                let sequence = try bundle.fetchSequenceSync(region: expandedRegion)
                let count = sequence.count
                sequenceViewerLogger.info("fetchSequenceAsync: gen=\(thisGeneration), fetchSequenceSync returned \(count) bp")

                Self.enqueueMainRunLoop { [weak self] in
                    sequenceViewerLogger.info("fetchSequenceAsync[RUNLOOP_V2]: gen=\(thisGeneration), main-runloop callback executing")
                    guard let viewer = self else {
                        sequenceViewerLogger.error("fetchSequenceAsync: CRITICAL - self is nil in main-runloop callback! \(count) bp lost.")
                        return
                    }
                    guard thisGeneration == viewer.sequenceFetchGeneration else {
                        sequenceViewerLogger.info("fetchSequenceAsync: Discarding stale result gen=\(thisGeneration) (current=\(viewer.sequenceFetchGeneration))")
                        return
                    }
                    let elapsed = viewer.sequenceFetchStartTime.map { Date().timeIntervalSince($0) } ?? 0
                    viewer.cachedBundleSequence = sequence
                    viewer.cachedSequenceRegion = expandedRegion
                    viewer.cachedCDSCodingContexts = [:]
                    viewer.isFetchingBundleData = false
                    viewer.sequenceFetchStartTime = nil
                    viewer.bundleFetchError = nil
                    viewer.failedFetchRegion = nil
                    sequenceViewerLogger.info("fetchSequenceAsync: Cached \(count) bp for \(expandedRegion.description) in \(elapsed, format: .fixed(precision: 3))s, triggering redraw")
                    viewer.setNeedsDisplay(viewer.bounds)
                }
            } catch {
                let errorDesc = error.localizedDescription
                sequenceViewerLogger.error("fetchSequenceAsync: gen=\(thisGeneration), FAILED - \(errorDesc, privacy: .public)")

                Self.enqueueMainRunLoop { [weak self] in
                    sequenceViewerLogger.info("fetchSequenceAsync[RUNLOOP_V2]: gen=\(thisGeneration), main-runloop callback (error path) executing")
                    guard let viewer = self else {
                        sequenceViewerLogger.error("fetchSequenceAsync: self is nil in main-runloop callback (error path)")
                        return
                    }
                    guard thisGeneration == viewer.sequenceFetchGeneration else {
                        sequenceViewerLogger.info("fetchSequenceAsync: Discarding stale error gen=\(thisGeneration) (current=\(viewer.sequenceFetchGeneration))")
                        return
                    }
                    sequenceViewerLogger.error("fetchSequenceAsync: Error delivered to main thread - \(errorDesc, privacy: .public)")
                    viewer.failedFetchRegion = expandedRegion
                    viewer.isFetchingBundleData = false
                    viewer.sequenceFetchStartTime = nil
                    viewer.bundleFetchError = errorDesc
                    viewer.setNeedsDisplay(viewer.bounds)
                }
            }
        }
    }
    
    /// Draws sequence data from a bundle.
    func drawBundleSequence(_ sequenceString: String, region: GenomicRegion, frame: ReferenceFrame, context: CGContext) {
        let inset = frame.leadingInset
        let dataRight = bounds.width - frame.trailingInset
        if inset > 0 || frame.trailingInset > 0 {
            context.saveGState()
            defer { context.restoreGState() }
            let clipRect = CGRect(
                x: inset,
                y: trackY,
                width: max(0, dataRight - inset),
                height: trackHeight
            )
            context.clip(to: clipRect)
        }

        let scale = frame.scale  // bp/pixel
        guard let slice = visibleSequenceSlice(
            sequenceString: sequenceString,
            cachedRegion: region,
            frame: frame
        ) else { return }

        let sequenceRect = CGRect(x: inset, y: trackY, width: frame.dataPixelWidth, height: trackHeight)
        
        // Draw based on zoom level
        if scale < showLettersThreshold {
            // High zoom: draw individual bases with letters
            drawBasesWithLetters(
                slice.sequence,
                startPosition: slice.startPosition,
                frame: frame,
                context: context,
                rowRect: sequenceRect,
                font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
            )
        } else if scale < showLineThreshold {
            // Medium zoom: draw colored blocks
            drawColoredBlocks(
                slice.sequence,
                startPosition: slice.startPosition,
                frame: frame,
                context: context,
                rowRect: sequenceRect
            )
        } else {
            // Low zoom: draw simple line
            drawSequenceLine(frame: frame, context: context)
        }
    }
    
    /// Slice of sequence that overlaps the visible viewport.
    struct VisibleSequenceSlice {
        let sequence: String
        let startPosition: Int
    }

    /// Extracts the visible base window from cached sequence data.
    /// Uses the same overlap logic for both reference and consensus rows.
    func visibleSequenceSlice(
        sequenceString: String,
        cachedRegion: GenomicRegion,
        frame: ReferenceFrame
    ) -> VisibleSequenceSlice? {
        let viewport = visibleViewportBaseRange(frame: frame)
        let visibleStart = viewport.lowerBound
        let visibleEnd = viewport.upperBound
        guard visibleEnd > visibleStart else { return nil }

        let overlapStart = max(visibleStart, cachedRegion.start)
        let overlapEnd = min(visibleEnd, cachedRegion.end)
        guard overlapEnd > overlapStart else { return nil }

        let offsetInCache = overlapStart - cachedRegion.start
        guard offsetInCache >= 0, offsetInCache < sequenceString.count else { return nil }

        let span = min(overlapEnd - overlapStart, sequenceString.count - offsetInCache)
        guard span > 0 else { return nil }

        let startIndex = sequenceString.index(sequenceString.startIndex, offsetBy: offsetInCache)
        let endIndex = sequenceString.index(startIndex, offsetBy: span)
        return VisibleSequenceSlice(
            sequence: String(sequenceString[startIndex..<endIndex]),
            startPosition: overlapStart
        )
    }

    /// Visible genomic base range using the same rounding semantics across
    /// sequence rendering, consensus rendering, and viewport selection.
    func visibleViewportBaseRange(frame: ReferenceFrame) -> Range<Int> {
        let lower = max(0, Int(frame.start))
        let upper = max(lower + 1, Int(ceil(frame.end)))
        return lower..<upper
    }

    /// Converts a source consensus string into a fixed target genomic window.
    func normalizedConsensusSequence(
        _ rawSequence: String,
        sourceStart: Int,
        targetStart: Int,
        targetEnd: Int
    ) -> String {
        let targetLength = max(0, targetEnd - targetStart)
        guard targetLength > 0 else { return "" }
        var normalized = Array(repeating: Character("N"), count: targetLength)
        guard !rawSequence.isEmpty else { return String(normalized) }

        let sourceBases = Array(rawSequence)
        let sourceEnd = sourceStart + sourceBases.count
        let overlapStart = max(sourceStart, targetStart)
        let overlapEnd = min(sourceEnd, targetEnd)
        guard overlapEnd > overlapStart else { return String(normalized) }

        let sourceOffset = overlapStart - sourceStart
        let targetOffset = overlapStart - targetStart
        let copyLength = overlapEnd - overlapStart
        for i in 0..<copyLength {
            normalized[targetOffset + i] = sourceBases[sourceOffset + i]
        }
        return String(normalized)
    }

    /// Pixel rect for one genomic base using the frame's exact transform.
    func baseCellRect(position: Int, frame: ReferenceFrame, rowRect: CGRect) -> CGRect {
        let x = frame.screenPosition(for: Double(position))
        let nextX = frame.screenPosition(for: Double(position + 1))
        return CGRect(
            x: x,
            y: rowRect.minY,
            width: max(1, nextX - x),
            height: rowRect.height
        )
    }

    /// Draws bases with individual letters (high zoom level).
    func drawBasesWithLetters(
        _ sequence: String,
        startPosition: Int,
        frame: ReferenceFrame,
        context: CGContext,
        rowRect: CGRect,
        font: NSFont
    ) {
        for (index, base) in sequence.enumerated() {
            let position = startPosition + index
            let cellRect = baseCellRect(position: position, frame: frame, rowRect: rowRect)

            // Draw background
            let color = BaseColors.color(for: base)
            context.setFillColor(color.cgColor)
            context.fill(cellRect)
            
            // Draw letter if space permits
            let baseWidth = cellRect.width
            if baseWidth >= 8 {
                let displayChar = isRNAMode && base.uppercased() == "T" ? "U" : String(base).uppercased()
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: NSColor.white
                ]
                let size = (displayChar as NSString).size(withAttributes: attributes)
                let letterRect = CGRect(
                    x: cellRect.minX + (baseWidth - size.width) / 2,
                    y: rowRect.minY + (rowRect.height - size.height) / 2,
                    width: size.width,
                    height: size.height
                )
                (displayChar as NSString).draw(in: letterRect, withAttributes: attributes)
            }
        }
    }
    
    /// Draws colored blocks for bases (medium zoom level).
    func drawColoredBlocks(
        _ sequence: String,
        startPosition: Int,
        frame: ReferenceFrame,
        context: CGContext,
        rowRect: CGRect
    ) {
        // Group consecutive bases of the same type for efficient drawing
        var currentBase: Character?
        var blockStart = startPosition
        
        for (index, base) in sequence.enumerated() {
            let position = startPosition + index
            
            if base != currentBase {
                // Draw previous block if any
                if let prevBase = currentBase {
                    let x = frame.screenPosition(for: Double(blockStart))
                    let width = frame.screenPosition(for: Double(position)) - x
                    let color = BaseColors.color(for: prevBase)
                    context.setFillColor(color.cgColor)
                    let rect = CGRect(x: x, y: rowRect.minY, width: max(1, width), height: rowRect.height)
                    context.fill(rect)
                }
                
                currentBase = base
                blockStart = position
            }
        }
        
        // Draw final block
        if let prevBase = currentBase {
            let x = frame.screenPosition(for: Double(blockStart))
            let endX = frame.screenPosition(for: Double(startPosition + sequence.count))
            let width = endX - x
            let color = BaseColors.color(for: prevBase)
            context.setFillColor(color.cgColor)
            let rect = CGRect(x: x, y: rowRect.minY, width: max(1, width), height: rowRect.height)
            context.fill(rect)
        }
    }
    
    /// Draws a simple line representing the sequence (low zoom level).
    func drawSequenceLine(frame: ReferenceFrame, context: CGContext) {
        let startX = frame.screenPosition(for: frame.start)
        let endX = frame.screenPosition(for: frame.end)
        let centerY = trackY + trackHeight / 2

        context.setStrokeColor(NSColor.systemGray.cgColor)
        context.setLineWidth(2)
        context.move(to: CGPoint(x: startX, y: centerY))
        context.addLine(to: CGPoint(x: endX, y: centerY))
        context.strokePath()

        // Show "Fetching sequence..." if we're loading data for this zoom level
        if isFetchingBundleData && frame.scale < showLineThreshold {
            let label = "Fetching sequence..." as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            let size = label.size(withAttributes: attributes)
            let labelRect = CGRect(
                x: (bounds.width - size.width) / 2,
                y: trackY + (trackHeight - size.height) / 2,
                width: size.width,
                height: size.height
            )
            label.draw(in: labelRect, withAttributes: attributes)
        }
    }
    
    /// Draws an error message in the sequence track when fetch failed.
    func drawSequenceError(_ error: String, frame: ReferenceFrame, context: CGContext) {
        let startX = frame.screenPosition(for: frame.start)
        let endX = frame.screenPosition(for: frame.end)
        let centerY = trackY + trackHeight / 2

        // Draw a danger-tinted line
        context.setStrokeColor(NSColor.lungfishDanger.withAlphaComponent(0.3).cgColor)
        context.setLineWidth(2)
        context.move(to: CGPoint(x: startX, y: centerY))
        context.addLine(to: CGPoint(x: endX, y: centerY))
        context.strokePath()

        let label = "Sequence error: \(error)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.lungfishDanger
        ]
        let size = label.size(withAttributes: attributes)
        let labelRect = CGRect(
            x: (bounds.width - size.width) / 2,
            y: trackY + (trackHeight - size.height) / 2,
            width: size.width,
            height: size.height
        )
        label.draw(in: labelRect, withAttributes: attributes)
    }

}
