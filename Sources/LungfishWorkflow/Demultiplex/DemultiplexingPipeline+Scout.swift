// DemultiplexingPipeline+Scout.swift - Barcode scouting extensions
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import os.log

private let logger = Logger(subsystem: LogSubsystem.workflow, category: "DemultiplexingPipeline")

extension DemultiplexingPipeline {

    // MARK: - Barcode Scouting

    /// Scans a subset of reads to detect which barcodes are present.
    ///
    /// Runs cutadapt against the first `readLimit` reads with all barcodes
    /// in the specified kit. Results include per-barcode hit counts and
    /// automatic disposition thresholds.
    ///
    /// - Parameters:
    ///   - inputURL: Input FASTQ file or bundle URL.
    ///   - kit: Barcode kit to scout against.
    ///   - readLimit: Maximum number of reads to scan (default 10,000).
    ///   - acceptThreshold: Minimum hits to auto-accept a barcode (default 10).
    ///   - rejectThreshold: Maximum hits to auto-reject a barcode (default 3).
    ///   - progress: Progress callback.
    /// - Returns: Scout result with per-barcode detections.
    public func scout(
        inputURL: URL,
        kit: BarcodeKitDefinition,
        adapterContext: (any PlatformAdapterContext)? = nil,
        sourcePlatform: SequencingPlatform? = nil,
        errorRate: Double? = nil,
        minimumOverlap: Int? = nil,
        searchReverseComplement: Bool? = nil,
        useNoIndels: Bool = false,
        readLimit: Int = 10_000,
        acceptThreshold: Int = 10,
        rejectThreshold: Int = 3,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> BarcodeScoutResult {
        let startTime = Date()

        let inputFASTQ = resolveInputFASTQ(inputURL)
        guard FileManager.default.fileExists(atPath: inputFASTQ.path) else {
            throw DemultiplexError.inputFileNotFound(inputFASTQ)
        }

        let fm = FileManager.default
        let workDir = fm.temporaryDirectory
            .appendingPathComponent("lungfish-scout-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        // Step 1: Extract first N reads to a temp file
        progress(0.0, "Extracting first \(readLimit) reads for scouting...")
        let subsetFile = workDir.appendingPathComponent("scout-subset.fastq.gz")
        let headResult = try await runner.run(
            .seqkit,
            arguments: ["head", "-n", String(readLimit), "-o", subsetFile.path, inputFASTQ.path],
            workingDirectory: workDir,
            timeout: 120
        )
        guard headResult.isSuccess else {
            throw DemultiplexError.cutadaptFailed(exitCode: headResult.exitCode, stderr: headResult.stderr)
        }

        // Step 2: Generate adapter FASTA for all barcodes in kit
        progress(0.2, "Preparing barcode adapters...")
        let adapterFASTA = workDir.appendingPathComponent("scout-adapters.fasta")

        let ctx = adapterContext ?? kit.adapterContext
        let useRevcomp = searchReverseComplement ?? kit.platform.readsCanBeReverseComplemented

        // Compute effective parameters (cross-platform aware)
        let scoutParams = ScoutEffectiveParameters.compute(
            kit: kit,
            sourcePlatform: sourcePlatform,
            configuredErrorRate: errorRate,
            configuredMinimumOverlap: minimumOverlap,
            useNoIndels: useNoIndels
        )

        // For combinatorial kits, use a two-phase scout:
        //   Phase 1: Individual barcodes (N entries) to find which barcodes are present
        //   Phase 2: Linked pairs for detected barcodes only (M×M << N×N)
        // This avoids the N×N explosion (96×96 = 9,216 entries) that overwhelms cutadapt.
        if kit.pairingMode == .combinatorialDual {
            return try await scoutCombinatorial(
                kit: kit,
                ctx: ctx,
                subsetFile: subsetFile,
                workDir: workDir,
                effectiveParams: scoutParams,
                useRevcomp: useRevcomp,
                acceptThreshold: acceptThreshold,
                rejectThreshold: rejectThreshold,
                startTime: startTime,
                progress: progress
            )
        }

        var lines: [String] = []
        if kit.pairingMode == .fixedDual {
            // fixedDual: use explicit i7/i5 pairs from each barcode entry.
            // Generate both orientations for long-read platforms.
            for barcode in kit.barcodes {
                guard let i5 = barcode.i5Sequence else { continue }
                let fwdSpec = ctx.fivePrimeSpec(barcodeSequence: barcode.i7Sequence)
                let revSpec = ctx.threePrimeSpec(barcodeSequence: i5)
                lines.append(">\(barcode.id)")
                lines.append("\(fwdSpec)...\(revSpec)")
                // Reverse orientation for long-read platforms
                if barcode.i7Sequence != i5 {
                    let revFwdSpec = ctx.fivePrimeSpec(barcodeSequence: i5)
                    let revRevSpec = ctx.threePrimeSpec(barcodeSequence: barcode.i7Sequence)
                    lines.append(">\(barcode.id)")
                    lines.append("\(revFwdSpec)...\(revRevSpec)")
                }
            }
        } else {
            // Symmetric/single-end kits: use 5'-only specs with --revcomp for orientation.
            for barcode in kit.barcodes {
                let spec = useRevcomp
                    ? ctx.fivePrimeSpec(barcodeSequence: barcode.i7Sequence)
                    : ctx.linkedSpec(barcodeSequence: barcode.i7Sequence)
                lines.append(">\(barcode.id)")
                lines.append(spec)
            }
        }
        let adapterContent = lines.joined(separator: "\n") + "\n"
        try adapterContent.write(to: adapterFASTA, atomically: true, encoding: .utf8)
        try validateAdapterFASTA(at: adapterFASTA, kitName: kit.displayName)

        // Step 3: Run cutadapt (pass 1 — 5' adapter detection)
        progress(0.3, "Running cutadapt scout scan...")
        let isLinkedPairMode = kit.pairingMode == .fixedDual
        let scoutResult = try await runScoutCutadapt(
            adapterFASTA: adapterFASTA,
            subsetFile: subsetFile,
            workDir: workDir,
            kit: kit,
            effectiveParams: scoutParams,
            useRevcomp: useRevcomp && !isLinkedPairMode
        )

        progress(0.7, "Analyzing scout results...")

        var (detections, totalScanned, unassignedCount) = try collectScoutDetections(
            outputDir: scoutResult.outputDir,
            kit: kit,
            acceptThreshold: acceptThreshold,
            rejectThreshold: rejectThreshold
        )

        // Step 4: For symmetric long-read kits, run pass 2 with 3' adapter to count
        // both-end matches. The research pipeline showed 98% 5' detection but only 59%
        // both-end — the scout must report the both-end count for symmetric mode.
        if kit.pairingMode == .symmetric && useRevcomp && !detections.isEmpty {
            progress(0.75, "Validating 3' barcode matches...")
            let pass2Dir = workDir.appendingPathComponent("scout-pass2", isDirectory: true)
            try FileManager.default.createDirectory(at: pass2Dir, withIntermediateDirectories: true)

            var updatedDetections: [BarcodeDetection] = []
            var pass2UnassignedTotal = 0

            for detection in detections {
                guard detection.hitCount > 0,
                      let barcode = kit.barcodes.first(where: { $0.id == detection.barcodeID }) else {
                    updatedDetections.append(detection)
                    continue
                }

                let seq = barcode.i7Sequence
                let barcodeDir = pass2Dir.appendingPathComponent(barcode.id, isDirectory: true)
                try FileManager.default.createDirectory(at: barcodeDir, withIntermediateDirectories: true)

                // Input is the per-barcode output from pass 1
                let pass1Output = scoutResult.outputDir.appendingPathComponent("\(barcode.id).fastq.gz")
                guard FileManager.default.fileExists(atPath: pass1Output.path) else {
                    updatedDetections.append(detection)
                    continue
                }

                // Pass 2a: Trim the 5' adapter with --revcomp to normalize orientation.
                // After this, all reads are in forward orientation with the 5' adapter removed.
                // This prevents pass 2b from falsely matching the RC of the 5' adapter as a 3' hit.
                let fivePrimeFASTA = barcodeDir.appendingPathComponent("5prime.fasta")
                let fiveSpec = ctx.fivePrimeSpec(barcodeSequence: seq)
                try ">\(barcode.id)\n\(fiveSpec)\n".write(to: fivePrimeFASTA, atomically: true, encoding: .utf8)

                let trimmedOutput = barcodeDir.appendingPathComponent("trimmed.fastq.gz")
                var pass2aArgs: [String] = []
                pass2aArgs += ["-g", "file:\(fivePrimeFASTA.path)"]
                pass2aArgs += ["-e", String(scoutParams.errorRate)]
                pass2aArgs += ["--overlap", String(scoutParams.minimumOverlap)]
                if scoutParams.noIndels { pass2aArgs += ["--no-indels"] }
                pass2aArgs += ["--revcomp"]
                pass2aArgs += ["--action", "trim"]
                pass2aArgs += ["--discard-untrimmed"]
                pass2aArgs += ["-o", trimmedOutput.path]
                pass2aArgs += ["--cores", "1"]
                pass2aArgs += [pass1Output.path]

                let pass2aResult = try await runner.run(
                    .cutadapt, arguments: pass2aArgs, workingDirectory: workDir, timeout: 120
                )
                guard pass2aResult.isSuccess,
                      FileManager.default.fileExists(atPath: trimmedOutput.path) else {
                    updatedDetections.append(detection)
                    continue
                }

                // Pass 2b: Check for the 3' adapter on the trimmed reads.
                // Reads are now in forward orientation with 5' adapter removed, so the
                // 3' adapter (if present) is intact at the 3' end.
                let threePrimeFASTA = barcodeDir.appendingPathComponent("3prime.fasta")
                let threeSpec = ctx.threePrimeSpec(barcodeSequence: seq)
                try ">\(barcode.id)\n\(threeSpec)\n".write(to: threePrimeFASTA, atomically: true, encoding: .utf8)

                let bothEndOutput = barcodeDir.appendingPathComponent("both-end.fastq.gz")
                var pass2bArgs: [String] = []
                pass2bArgs += ["-a", "file:\(threePrimeFASTA.path)"]
                pass2bArgs += ["-e", String(scoutParams.errorRate)]
                pass2bArgs += ["--overlap", String(scoutParams.minimumOverlap)]
                if scoutParams.noIndels { pass2bArgs += ["--no-indels"] }
                pass2bArgs += ["--action", "none"]
                pass2bArgs += ["--discard-untrimmed"]
                pass2bArgs += ["-o", bothEndOutput.path]
                pass2bArgs += ["--cores", "1"]
                pass2bArgs += [trimmedOutput.path]

                let pass2bResult = try await runner.run(
                    .cutadapt, arguments: pass2bArgs, workingDirectory: workDir, timeout: 120
                )
                guard pass2bResult.isSuccess else {
                    updatedDetections.append(detection)
                    continue
                }

                // Count reads that matched both ends
                let bothEndCount = countReadsInFASTQ(url: bothEndOutput)
                let singleEndOnly = detection.hitCount - bothEndCount
                pass2UnassignedTotal += singleEndOnly

                let updated = BarcodeDetection(
                    id: detection.id,
                    barcodeID: detection.barcodeID,
                    kitID: detection.kitID,
                    hitCount: bothEndCount,
                    hitPercentage: detection.hitPercentage,
                    matchedEnds: .bothEnds,
                    meanEditDistance: detection.meanEditDistance,
                    disposition: detection.disposition,
                    sampleName: detection.sampleName
                )
                updatedDetections.append(updated)
            }

            // Recalculate percentages and dispositions with both-end counts
            unassignedCount += pass2UnassignedTotal
            detections = updatedDetections
            for i in detections.indices {
                if totalScanned > 0 {
                    detections[i].hitPercentage = Double(detections[i].hitCount) / Double(totalScanned) * 100
                }
                if detections[i].hitCount >= acceptThreshold {
                    detections[i].disposition = .accepted
                } else if detections[i].hitCount <= rejectThreshold {
                    detections[i].disposition = .rejected
                } else {
                    detections[i].disposition = .undecided
                }
            }
            detections.sort { $0.hitCount > $1.hitCount }
        }

        let elapsed = Date().timeIntervalSince(startTime)
        progress(1.0, "Scout complete: \(detections.count) barcodes detected")

        return BarcodeScoutResult(
            readsScanned: totalScanned,
            detections: detections,
            unassignedCount: unassignedCount,
            scoutedKitIDs: [kit.id],
            elapsedSeconds: elapsed
        )
    }

    // MARK: - Combinatorial Scout (Two-Phase)

    /// Two-phase scout for combinatorial kits.
    /// Phase 1: Scout individual barcodes to find which are present (N entries).
    /// Phase 2: Generate linked pairs for detected barcodes only (M×M entries, where M << N).
    private func scoutCombinatorial(
        kit: BarcodeKitDefinition,
        ctx: any PlatformAdapterContext,
        subsetFile: URL,
        workDir: URL,
        effectiveParams: ScoutEffectiveParameters,
        useRevcomp: Bool,
        acceptThreshold: Int,
        rejectThreshold: Int,
        startTime: Date,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> BarcodeScoutResult {
        // Phase 1: Scout individual barcodes with --revcomp (5'-only specs, N entries)
        progress(0.25, "Phase 1: Detecting individual barcodes...")
        let phase1FASTA = workDir.appendingPathComponent("scout-phase1-adapters.fasta")
        var phase1Lines: [String] = []
        for barcode in kit.barcodes {
            let spec = ctx.fivePrimeSpec(barcodeSequence: barcode.i7Sequence)
            phase1Lines.append(">\(barcode.id)")
            phase1Lines.append(spec)
        }
        let phase1Content = phase1Lines.joined(separator: "\n") + "\n"
        try phase1Content.write(to: phase1FASTA, atomically: true, encoding: .utf8)
        try validateAdapterFASTA(at: phase1FASTA, kitName: kit.displayName)

        let phase1Result = try await runScoutCutadapt(
            adapterFASTA: phase1FASTA,
            subsetFile: subsetFile,
            workDir: workDir,
            kit: kit,
            effectiveParams: effectiveParams,
            useRevcomp: useRevcomp && effectiveParams.isLongRead,
            outputSubdir: "scout-phase1-output"
        )

        // Identify which barcodes were detected in phase 1.
        // Do not threshold-prune here: even low-count barcodes must advance so
        // scout can show all valid pair hits on small datasets.
        let (phase1Detections, _, _) = try collectScoutDetections(
            outputDir: phase1Result.outputDir,
            kit: kit,
            acceptThreshold: 1,
            rejectThreshold: 0
        )
        let detectedIDs = Set(phase1Detections.filter { $0.hitCount > 0 }.map(\.barcodeID))
        let detectedBarcodes = kit.barcodes.filter { detectedIDs.contains($0.id) }

        guard !detectedBarcodes.isEmpty else {
            let scanned = countReadsInFASTQ(url: subsetFile)
            let elapsed = Date().timeIntervalSince(startTime)
            progress(1.0, "Scout complete: no barcodes detected")
            return BarcodeScoutResult(
                readsScanned: scanned,
                detections: [],
                unassignedCount: scanned,
                scoutedKitIDs: [kit.id],
                elapsedSeconds: elapsed
            )
        }

        // Phase 2: Generate linked pairs for detected barcodes only (M×M entries)
        let pairCount = detectedBarcodes.count * detectedBarcodes.count
        progress(0.50, "Phase 2: Testing \(detectedBarcodes.count) barcodes (\(pairCount) pairs)...")
        let phase2FASTA = workDir.appendingPathComponent("scout-phase2-adapters.fasta")
        var phase2Lines: [String] = []
        let isLongRead = effectiveParams.isLongRead
        var emittedPairs = Set<String>()
        for fwd in detectedBarcodes {
            for rev in detectedBarcodes {
                let pairName = "\(fwd.id)--\(rev.id)"
                guard emittedPairs.insert(pairName).inserted else { continue }
                // Forward orientation: fwd at 5', rev at 3'
                let fwdSpec = ctx.fivePrimeSpec(barcodeSequence: fwd.i7Sequence)
                let revSpec = ctx.threePrimeSpec(barcodeSequence: rev.i7Sequence)
                phase2Lines.append(">\(pairName)")
                phase2Lines.append("\(fwdSpec)...\(revSpec)")
                // Reverse orientation for long-read platforms: rev at 5', fwd at 3'
                // Must use a distinct header name so cutadapt treats it as a separate adapter
                // that maps to the same ordered pair (counts will be summed by base name prefix)
                if isLongRead && fwd.i7Sequence != rev.i7Sequence {
                    let revFwdSpec = ctx.fivePrimeSpec(barcodeSequence: rev.i7Sequence)
                    let revRevSpec = ctx.threePrimeSpec(barcodeSequence: fwd.i7Sequence)
                    phase2Lines.append(">\(pairName)_rev")
                    phase2Lines.append("\(revFwdSpec)...\(revRevSpec)")
                }
            }
        }
        let phase2Content = phase2Lines.joined(separator: "\n") + "\n"
        try phase2Content.write(to: phase2FASTA, atomically: true, encoding: .utf8)
        try validateAdapterFASTA(at: phase2FASTA, kitName: kit.displayName)

        // Run phase 2 without --revcomp (linked adapters cover both orientations)
        let phase2Result = try await runScoutCutadapt(
            adapterFASTA: phase2FASTA,
            subsetFile: subsetFile,
            workDir: workDir,
            kit: kit,
            effectiveParams: effectiveParams,
            useRevcomp: false,
            outputSubdir: "scout-phase2-output"
        )

        progress(0.85, "Analyzing barcode pair results...")

        let (detections, totalScanned, unassignedCount) = try collectScoutDetections(
            outputDir: phase2Result.outputDir,
            kit: kit,
            acceptThreshold: acceptThreshold,
            rejectThreshold: rejectThreshold
        )

        let elapsed = Date().timeIntervalSince(startTime)
        progress(1.0, "Scout complete: \(detections.count) barcode pairs detected")

        return BarcodeScoutResult(
            readsScanned: totalScanned,
            detections: detections,
            unassignedCount: unassignedCount,
            scoutedKitIDs: [kit.id],
            elapsedSeconds: elapsed
        )
    }

    // MARK: - Scout Helpers

    /// Effective cutadapt parameters for scouting, accounting for cross-platform scenarios.
    private struct ScoutEffectiveParameters: Sendable {
        let errorRate: Double
        let minimumOverlap: Int
        let noIndels: Bool
        let isLongRead: Bool

        static func compute(
            kit: BarcodeKitDefinition,
            sourcePlatform: SequencingPlatform?,
            configuredErrorRate: Double? = nil,
            configuredMinimumOverlap: Int? = nil,
            useNoIndels: Bool = false
        ) -> ScoutEffectiveParameters {
            let platform = sourcePlatform ?? kit.platform
            let baseErrorRate = configuredErrorRate ?? kit.platform.recommendedErrorRate
            let errorRate: Double
            if let sourcePlatform, sourcePlatform != kit.platform {
                errorRate = max(baseErrorRate, sourcePlatform.recommendedErrorRate)
            } else {
                errorRate = baseErrorRate
            }

            let minBarcodeLen = kit.barcodes.reduce(Int.max) { currentMin, barcode in
                let i7Len = barcode.i7Sequence.count
                let i5Len = barcode.i5Sequence?.count ?? i7Len
                return min(currentMin, min(i7Len, i5Len))
            }
            let barcodeLen = minBarcodeLen == Int.max ? 16 : minBarcodeLen
            // For cross-platform scenarios, use the more lenient overlap (smaller value)
            // to handle the higher error rates at adapter junctions
            let baseOverlap: Int
            if let configuredMinimumOverlap {
                baseOverlap = configuredMinimumOverlap
            } else if let sourcePlatform, sourcePlatform != kit.platform {
                baseOverlap = min(kit.platform.recommendedMinimumOverlap, sourcePlatform.recommendedMinimumOverlap)
            } else {
                baseOverlap = kit.platform.recommendedMinimumOverlap
            }
            let overlap = min(baseOverlap, max(3, barcodeLen - 4))
            let isLongRead = platform.readsCanBeReverseComplemented
            return ScoutEffectiveParameters(
                errorRate: errorRate,
                minimumOverlap: overlap,
                noIndels: useNoIndels,
                isLongRead: isLongRead
            )
        }
    }

    private struct ScoutCutadaptResult {
        let outputDir: URL
    }

    /// Runs cutadapt for scouting purposes and returns the output directory.
    private func runScoutCutadapt(
        adapterFASTA: URL,
        subsetFile: URL,
        workDir: URL,
        kit: BarcodeKitDefinition,
        effectiveParams: ScoutEffectiveParameters,
        useRevcomp: Bool,
        outputSubdir: String = "scout-output"
    ) async throws -> ScoutCutadaptResult {
        let fm = FileManager.default
        let demuxOutputDir = workDir.appendingPathComponent(outputSubdir, isDirectory: true)
        try fm.createDirectory(at: demuxOutputDir, withIntermediateDirectories: true)

        let outputPattern = demuxOutputDir.appendingPathComponent("{name}.fastq.gz").path
        let unassignedPath = demuxOutputDir.appendingPathComponent("unassigned.fastq.gz").path
        let jsonReportPath = workDir.appendingPathComponent("\(outputSubdir)-report.json").path

        var args: [String] = []
        args += ["-g", "file:\(adapterFASTA.path)"]
        args += ["-e", String(effectiveParams.errorRate)]
        args += ["--overlap", String(effectiveParams.minimumOverlap)]
        if effectiveParams.noIndels {
            args += ["--no-indels"]
        }
        if useRevcomp {
            args += ["--revcomp"]
        }
        args += ["--action", "none"]
        args += ["-o", outputPattern]
        args += ["--untrimmed-output", unassignedPath]
        args += ["--json", jsonReportPath]
        // Use single core to avoid multiprocessing overhead/issues on scout subset
        args += ["--cores", "1"]
        args += [subsetFile.path]

        let cutadaptResult = try await runner.run(
            .cutadapt,
            arguments: args,
            workingDirectory: workDir,
            timeout: 300
        )

        guard cutadaptResult.isSuccess else {
            throw DemultiplexError.cutadaptFailed(
                exitCode: cutadaptResult.exitCode,
                stderr: cutadaptResult.stderr
            )
        }

        return ScoutCutadaptResult(outputDir: demuxOutputDir)
    }

    /// Collects barcode detections from cutadapt scout output files.
    private func collectScoutDetections(
        outputDir: URL,
        kit: BarcodeKitDefinition,
        acceptThreshold: Int,
        rejectThreshold: Int
    ) throws -> (detections: [BarcodeDetection], totalScanned: Int, unassignedCount: Int) {
        let fm = FileManager.default
        let outputFiles = (try? fm.contentsOfDirectory(
            at: outputDir,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var detections: [BarcodeDetection] = []
        var totalScanned = 0
        var unassignedCount = 0

        // Accumulate counts by canonical barcode name (merge _rev orientation variants)
        var countsByName: [String: Int] = [:]
        for outputFile in outputFiles {
            let baseName = outputFile.deletingPathExtension().deletingPathExtension().lastPathComponent
            let fileBytes = fileSize(outputFile)
            guard fileBytes > 20 else { continue }
            let count = countReadsInFASTQ(url: outputFile)

            // Merge reverse orientation files (e.g., "bc01--bc02_rev") into their canonical name
            let canonicalName = baseName.hasSuffix("_rev") ? String(baseName.dropLast(4)) : baseName

            if canonicalName == "unassigned" {
                unassignedCount += count
            } else {
                countsByName[canonicalName, default: 0] += count
            }
            totalScanned += count
        }
        for (name, count) in countsByName {
            detections.append(BarcodeDetection(
                barcodeID: name,
                kitID: kit.id,
                hitCount: count,
                hitPercentage: 0
            ))
        }

        for i in detections.indices {
            if totalScanned > 0 {
                detections[i].hitPercentage = Double(detections[i].hitCount) / Double(totalScanned) * 100
            }
            if detections[i].hitCount >= acceptThreshold {
                detections[i].disposition = .accepted
            } else if detections[i].hitCount <= rejectThreshold {
                detections[i].disposition = .rejected
            }
        }

        detections.sort { $0.hitCount > $1.hitCount }
        return (detections, totalScanned, unassignedCount)
    }

}
