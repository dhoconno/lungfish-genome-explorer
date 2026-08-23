// SequenceViewerView+ReadPacking.swift - Off-main read packing and the visible-read budget
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore

extension SequenceViewerView {

    // MARK: - Budget

    /// Effective read budget for the current window: unlimited once the user
    /// has asked to load all, otherwise the configured budget.
    var effectiveReadBudget: Int {
        loadAllReadsRequested ? ReadViewportPolicy.loadAllReadCeiling : max(1, visibleReadBudgetSetting)
    }

    /// Applies the display budget to a freshly fetched read set, returning the
    /// reads to keep plus the budget bookkeeping for the banner.
    ///
    /// The fetch asks for `budget + 1` reads precisely so that "did this window
    /// overflow?" is answerable without a second query: `reads.count > budget`
    /// is the overflow test. When an exact count is available from the provider
    /// it is preferred over the fetched size, since the fetch itself was capped.
    nonisolated static func applyReadBudget(
        reads: [AlignedRead],
        budget: Int,
        exactTotal: Int?,
        estimatedTotal: Int?,
        loadedAll: Bool
    ) -> (reads: [AlignedRead], state: ReadBudgetState) {
        guard !loadedAll, reads.count > budget else {
            return (
                reads,
                ReadBudgetState(
                    displayedReads: reads.count,
                    totalReads: exactTotal ?? reads.count,
                    isEstimated: false,
                    loadedAll: loadedAll
                )
            )
        }
        let sampled = ReadViewportPolicy.sampleReads(reads, budget: budget)
        let total: Int
        let isEstimated: Bool
        if let exactTotal, exactTotal >= sampled.count {
            total = exactTotal
            isEstimated = false
        } else if let estimatedTotal, estimatedTotal > sampled.count {
            total = estimatedTotal
            isEstimated = true
        } else {
            // The fetch was capped at budget + 1, so all we honestly know is
            // "more than the budget". Say so as an estimate rather than
            // reporting the cap as if it were the truth.
            total = reads.count
            isEstimated = true
        }
        return (
            sampled,
            ReadBudgetState(
                displayedReads: sampled.count,
                totalReads: total,
                isEstimated: isEstimated,
                loadedAll: false
            )
        )
    }

    /// Estimate of the reads in `region`, derived from the cached depth track.
    /// Used only when the provider gave no exact count.
    func estimatedReadCount(in region: GenomicRegion) -> Int? {
        guard let stats = cachedCoverageStats else { return nil }
        let meanReadLength = cachedAlignedReads.isEmpty
            ? 150.0
            : Double(
                cachedAlignedReads.lazy.prefix(2_000)
                    .map { max(1, $0.alignmentEnd - $0.position) }
                    .reduce(0, +)
            ) / Double(min(2_000, cachedAlignedReads.count))
        return ReadBudgetState.estimateReadCount(
            meanDepth: stats.meanDepth,
            windowSpan: max(1, region.end - region.start),
            meanReadLength: meanReadLength
        )
    }

    /// Records budget bookkeeping produced by a fetch.
    func setReadBudgetState(_ state: ReadBudgetState) {
        guard readBudgetState != state else { return }
        readBudgetStateStorage = state
        needsDisplay = true
    }

    /// Clears the per-window "Load all" override when the fetch window moves.
    ///
    /// "Load all" is scoped to the window the user asked about; carrying it into
    /// the next region would silently reintroduce the unbounded fetch this whole
    /// change exists to prevent. The refetch triggered by the button itself
    /// targets the same region, so it is deliberately not treated as a move.
    func resetLoadAllOverrideIfWindowChanged(to region: GenomicRegion) {
        guard loadAllReadsRequested else { return }
        guard loadAllReadsRegion != region else { return }
        loadAllReadsRequested = false
        loadAllReadsRegion = nil
    }

    /// Handles a click on the banner's "Load all" target. Returns true when the
    /// click was consumed.
    @discardableResult
    func handleLoadAllClick(at point: NSPoint) -> Bool {
        guard !loadAllButtonRect.isNull, loadAllButtonRect.contains(point) else { return false }
        guard readBudgetState.isSampled else { return false }
        loadAllReadsRequested = true
        // Scope the override to the window it was asked for, so the next fetch
        // for a different region drops back to the budget.
        loadAllReadsRegion = cachedReadRegion
        // Force a refetch of the current window without the budget by dropping
        // the coverage claim; the draw path refetches when reads are uncovered.
        cachedReadRegion = nil
        needsDisplay = true
        return true
    }

    // MARK: - Cancellation

    /// Cancels any in-flight read fetch and background pack, leaving whatever
    /// coverage tier is already drawn intact.
    ///
    /// Coverage/depth are deliberately untouched: the point of cancelling an
    /// extreme-depth read load is to get back to a usable view, and the
    /// coverage curve is the usable view.
    func cancelReadLoad() {
        let hadWork = isFetchingReads || backgroundPackTask != nil
        detachedReadFetchTask?.cancel()
        detachedReadFetchTask = nil
        backgroundPackTask?.cancel()
        backgroundPackTask = nil
        inFlightPackKey = nil
        // Bump both gates so a result already in flight cannot commit.
        readFetchGeneration += 1
        packRequestGenerationStorage += 1
        _ = readFetchGate.begin(identity: alignmentFetchIdentity(
            bundleURL: nil, trackID: "cancelled", region: GenomicRegion(chromosome: "", start: 0, end: 1)
        ))
        isFetchingReads = false
        readFetchStartTime = nil
        readLoadPhase = nil
        guard hadWork else { return }
        needsDisplay = true
    }

    // MARK: - Background packing

    /// Requests a background pack for `key`, unless that exact pack is already
    /// cached or already running.
    ///
    /// The draw path calls this instead of packing inline. Until the layout
    /// lands, `draw(_:)` paints the loading badge over the coverage tier — the
    /// main thread is never asked to do `O(reads log rows)` work.
    func requestBackgroundPack(
        key: ReadPackCacheKey,
        reads: [AlignedRead],
        frame: ReadPackFrame,
        maxRows: Int?,
        sortMode: ReadSortMode,
        sortPosition: Int?,
        prioritizedRegion: Range<Int>?
    ) {
        if cachedPackKey == key, cachedPackedReadLayout != nil { return }
        if inFlightPackKey == key { return }

        // A newer pack supersedes an older one outright: the old layout can no
        // longer be installed even if it finishes first.
        backgroundPackTask?.cancel()
        packRequestGenerationStorage += 1
        backgroundPackInvocationCount += 1
        let generation = packRequestGeneration
        inFlightPackKey = key
        readLoadPhase = .packing(readCount: reads.count)

        backgroundPackTask = Task.detached(priority: .userInitiated) { [weak self] in
            let result = ReadTrackRenderer.packReads(
                reads,
                frame: frame,
                maxRows: maxRows,
                sortMode: sortMode,
                sortPosition: sortPosition,
                prioritizedRegion: prioritizedRegion,
                shouldCancel: { Task.isCancelled }
            )
            guard !Task.isCancelled else { return }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.commitPackedLayout(
                        generation: generation,
                        key: key,
                        packed: result.packed,
                        overflow: result.overflow
                    )
                }
            }
        }
    }

    // MARK: - Badge and banner

    /// Draws the read-load badge with its current phase and cancel hint.
    ///
    /// Replaces the old unconditional "Loading mapped reads..." string: at
    /// extreme depth the difference between "still fetching" and "packing
    /// 600,000 reads" is the difference between a hang and visible progress.
    func drawReadLoadingBadge(context: CGContext, yOffset: CGFloat) {
        let phase: ReadLoadPhase?
        if let readLoadPhase {
            phase = readLoadPhase
        } else if isFetchingReads {
            phase = .fetching(readsSoFar: nil)
        } else {
            phase = nil
        }
        guard let phase else { return }

        // The 0.15s delay stops the badge flashing on fast local fetches.
        if case .fetching = phase {
            let elapsed = readFetchStartTime.map { Date().timeIntervalSince($0) } ?? 0
            guard elapsed > 0.15 else { return }
        }

        var message = phase.badgeMessage
        if case .fetching = phase, !cachedAlignedReads.isEmpty, readLoadPhase == nil {
            message = "Updating mapped reads\u{2026}"
        }
        drawTrackLoadingBadge(
            context: context,
            message: message + ReadLoadPhase.cancelHint,
            yOffset: yOffset,
            tooltip: "Press Escape to cancel loading and keep the coverage view."
        )
    }

    /// Draws the sampling banner plus its "Load all" hit target.
    ///
    /// The banner is the honesty contract for the read budget: without it a
    /// sampled pileup is indistinguishable from a complete one.
    func drawReadBudgetBanner(context: CGContext, yOffset: CGFloat) {
        guard let message = readBudgetState.bannerMessage else {
            loadAllButtonRect = .null
            return
        }

        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let actionAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.controlAccentColor,
        ]
        let text = message as NSString
        let action = ReadBudgetState.loadAllActionTitle as NSString
        let textSize = text.size(withAttributes: textAttrs)
        let actionSize = action.size(withAttributes: actionAttrs)

        let padding: CGFloat = 8
        let gap: CGFloat = 12
        let height: CGFloat = 18
        // The badge occupies the same corner while a load is in flight, so the
        // banner drops below it rather than overpainting it.
        let bannerY = (readLoadPhase != nil || isFetchingReads) ? yOffset + height + 4 : yOffset
        let width = min(
            textSize.width + gap + actionSize.width + padding * 2,
            max(160, bounds.width - 16)
        )
        let bannerRect = CGRect(x: 8, y: max(0, bannerY), width: width, height: height)

        context.saveGState()
        context.setFillColor(NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor)
        context.setStrokeColor(NSColor.separatorColor.withAlphaComponent(0.7).cgColor)
        context.setLineWidth(0.8)
        context.addPath(CGPath(roundedRect: bannerRect, cornerWidth: 6, cornerHeight: 6, transform: nil))
        context.drawPath(using: .fillStroke)

        let actionRect = CGRect(
            x: bannerRect.maxX - padding - actionSize.width,
            y: bannerRect.midY - actionSize.height / 2,
            width: actionSize.width,
            height: actionSize.height
        )
        let textRect = CGRect(
            x: bannerRect.minX + padding,
            y: bannerRect.midY - textSize.height / 2,
            width: max(0, actionRect.minX - gap - bannerRect.minX - padding),
            height: textSize.height
        )
        text.draw(in: textRect, withAttributes: textAttrs)
        action.draw(in: actionRect, withAttributes: actionAttrs)
        context.restoreGState()

        // Pad the hit target so the click is not pixel-precise.
        loadAllButtonRect = actionRect.insetBy(dx: -4, dy: -4)
        _ = addToolTip(
            loadAllButtonRect,
            owner: "Refetch this window without the display budget." as NSString,
            userData: nil
        )
    }

#if DEBUG
    /// Test seam: runs the pack that `requestBackgroundPack` just queued to
    /// completion synchronously and installs it, so a test can assert on the
    /// resulting layout without racing a detached task.
    ///
    /// It re-derives the pack from the same inputs rather than awaiting the real
    /// task, which keeps the assertion about *what* gets packed rather than
    /// about scheduling.
    func testDrainPendingPack(
        reads: [AlignedRead],
        frame: ReadPackFrame,
        maxRows: Int?,
        sortMode: ReadSortMode = .position,
        sortPosition: Int? = nil,
        prioritizedRegion: Range<Int>? = nil
    ) {
        guard let key = inFlightPackKey else { return }
        backgroundPackTask?.cancel()
        backgroundPackTask = nil
        let result = ReadTrackRenderer.packReads(
            reads,
            frame: frame,
            maxRows: maxRows,
            sortMode: sortMode,
            sortPosition: sortPosition,
            prioritizedRegion: prioritizedRegion,
            shouldCancel: nil
        )
        _ = commitPackedLayout(
            generation: packRequestGeneration,
            key: key,
            packed: result.packed,
            overflow: result.overflow
        )
    }
#endif

    /// Installs a background pack's result, rejecting it when a newer pack has
    /// superseded it.
    @discardableResult
    func commitPackedLayout(
        generation: Int,
        key: ReadPackCacheKey,
        packed: [(row: Int, read: AlignedRead)],
        overflow: Int
    ) -> Bool {
        guard generation == packRequestGeneration else { return false }
        inFlightPackKey = nil
        backgroundPackTask = nil
        readLoadPhase = nil
        installPackedLayout(key: key, packed: packed, overflow: overflow)
        needsDisplay = true
        return true
    }
}
