// DemultiplexingPipeline+ExactBare.swift - The Swift-native exact bare-barcode demultiplex engine
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import os.log

private let logger = Logger(subsystem: LogSubsystem.workflow, category: "DemultiplexingPipeline")

extension DemultiplexingPipeline {
    func runExactBareBarcodeDemux(
        config: DemultiplexConfig,
        inputFASTQ: URL,
        runClock: ProvenanceRunClock,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> DemultiplexResult {
        let fm = FileManager.default
        try fm.createDirectory(at: config.outputDirectory, withIntermediateDirectories: true)

        guard let matcher = ExactBareBarcodeMatcher(
            barcodes: config.barcodeKit.barcodes,
            barcodeLocation: config.barcodeLocation,
            maxDistanceFrom5Prime: config.maxDistanceFrom5Prime,
            maxDistanceFrom3Prime: config.maxDistanceFrom3Prime,
            includeReverseComplements: shouldSearchBareBarcodeReverseComplements(config)
        ) else {
            throw DemultiplexError.noBarcodes
        }
        // A derived bundle's own FASTQ is only its preview, so only a physical bundle is listed; a derived one is read as the materialized input.
        let inputURLs: [URL]
        if let bundleURL = config.sourceBundleURL ?? (FASTQBundle.isBundleURL(config.inputURL) ? config.inputURL : nil), !FASTQBundle.isDerivedBundle(bundleURL),
           let allURLs = FASTQBundle.resolveAllFASTQURLs(for: bundleURL), !allURLs.isEmpty {
            inputURLs = allURLs
        } else {
            inputURLs = [inputFASTQ]
        }

        let isVirtualMode = config.rootBundleURL != nil && !config.captureTrimsForChaining
        // Both mates of a fragment follow the fragment's call (A9, D6).
        let placesMates = try demultiplexReadLayout(config: config, inputFASTQ: inputFASTQ).isPaired
        var mateCalls = DemultiplexMateCallCounter()
        let outputCache = ExactBareFASTQOutputCache()
        defer { try? outputCache.closeAll() }

        var bundleURLsByName: [String: URL] = [:]
        var fastqURLsByName: [String: URL] = [:]
        func bundleURL(for name: String) throws -> URL {
            if let existing = bundleURLsByName[name] { return existing }
            let bundleURL = config.outputDirectory
                .appendingPathComponent("\(name).\(FASTQBundle.directoryExtension)", isDirectory: true)
            try fm.createDirectory(at: bundleURL, withIntermediateDirectories: true)
            bundleURLsByName[name] = bundleURL
            return bundleURL
        }
        func fastqURL(for name: String) throws -> URL {
            if let existing = fastqURLsByName[name] { return existing }
            let url = try bundleURL(for: name).appendingPathComponent("\(name).fastq")
            fastqURLsByName[name] = url
            return url
        }

        func trimmedRecord(
            _ record: FASTQRawRecord,
            trim5p: Int,
            trim3p: Int
        ) -> FASTQRawRecord {
            let sequenceLength = record.sequence.count
            let start = max(0, min(trim5p, sequenceLength))
            let end = max(start, min(sequenceLength - max(0, trim3p), sequenceLength))
            guard start > 0 || end < sequenceLength else { return record }
            let sequenceStart = record.sequence.index(record.sequence.startIndex, offsetBy: start)
            let sequenceEnd = record.sequence.index(record.sequence.startIndex, offsetBy: end)
            let qualityStart = record.quality.index(record.quality.startIndex, offsetBy: start)
            let qualityEnd = record.quality.index(record.quality.startIndex, offsetBy: end)
            return FASTQRawRecord(
                header: record.header,
                sequence: String(record.sequence[sequenceStart..<sequenceEnd]),
                separator: record.separator,
                quality: String(record.quality[qualityStart..<qualityEnd])
            )
        }

        func stats(
            for accumulator: ExactBareBarcodeAccumulator
        ) -> FASTQDatasetStatistics {
            ExactBarcodeDemux.computeStatistics(
                readCount: accumulator.readCount,
                baseCount: accumulator.baseCount,
                minReadLength: accumulator.finalizedMinReadLength,
                maxReadLength: accumulator.maxReadLength,
                readLengthHistogram: accumulator.readLengthHistogram
            )
        }

        var barcodeAccumulators = config.barcodeKit.barcodes.map {
            ExactBareBarcodeAccumulator(barcodeID: $0.id)
        }
        var unassigned = ExactBareBarcodeAccumulator(barcodeID: "unassigned")
        var totalReads = 0
        var assignedReads = 0
        let totalInputBytes = inputURLs.reduce(Int64(0)) { $0 + $1.fileSizeBytes }

        func appendFile(_ sourceURL: URL, to destinationURL: URL) throws {
            guard fm.fileExists(atPath: sourceURL.path) else { return }
            try fm.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: destinationURL.path) {
                fm.createFile(atPath: destinationURL.path, contents: nil)
            }
            let input = try FileHandle(forReadingFrom: sourceURL)
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: destinationURL)
            defer { try? output.close() }
            try output.seekToEnd()
            while true {
                let data = input.readData(ofLength: 1_048_576)
                if data.isEmpty { break }
                try output.write(contentsOf: data)
            }
        }

        func shardDirectory(for shardIndex: Int, root: URL) -> URL {
            root.appendingPathComponent(
                String(format: "shard-%05d", shardIndex),
                isDirectory: true
            )
        }

        func processShard(
            inputURL: URL,
            shardIndex: Int,
            shardRoot: URL?
        ) async throws -> ExactBareBarcodeShardResult {
            var shardBarcodeAccumulators = config.barcodeKit.barcodes.map {
                ExactBareBarcodeAccumulator(barcodeID: $0.id)
            }
            var shardUnassigned = ExactBareBarcodeAccumulator(barcodeID: "unassigned")
            var shardTotalReads = 0
            var shardAssignedReads = 0

            let shardOutputDirectory = shardRoot.map { shardDirectory(for: shardIndex, root: $0) }
            let shardOutputCache = ExactBareFASTQOutputCache()
            defer { try? shardOutputCache.closeAll() }

            func shardFASTQURL(for name: String) throws -> URL {
                guard let shardOutputDirectory else {
                    throw DemultiplexError.bundleCreationFailed(
                        barcode: name,
                        underlying: "Exact bare-barcode shard output directory was not configured."
                    )
                }
                try FileManager.default.createDirectory(at: shardOutputDirectory, withIntermediateDirectories: true)
                return shardOutputDirectory.appendingPathComponent("\(name).fastq")
            }

            func place(_ fragment: ExactBareMatePairer.Fragment) throws {
                for record in fragment.records {
                    if let barcodeIndex = fragment.call {
                        shardBarcodeAccumulators[barcodeIndex].add(
                            readID: record.readID,
                            previewRecord: record,
                            outputLength: record.sequence.count,
                            trimEntry: nil
                        )
                        shardAssignedReads += 1

                        if !isVirtualMode {
                            let barcodeID = config.barcodeKit.barcodes[barcodeIndex].id
                            try shardOutputCache.write(record, to: shardFASTQURL(for: barcodeID))
                        }
                    } else {
                        shardUnassigned.add(
                            readID: record.readID,
                            previewRecord: record,
                            outputLength: record.sequence.count,
                            trimEntry: nil
                        )
                        if !isVirtualMode, config.unassignedDisposition == .keep {
                            try shardOutputCache.write(record, to: shardFASTQURL(for: "unassigned"))
                        }
                    }
                }
            }

            let lines = inputURL.linesAutoDecompressing()
            var lineBuffer: [String] = []
            lineBuffer.reserveCapacity(4)
            var pairer = ExactBareMatePairer(placesMates: placesMates)

            for try await line in lines {
                if line.isEmpty && lineBuffer.isEmpty { continue }
                lineBuffer.append(line)
                guard lineBuffer.count == 4 else { continue }

                let record = FASTQRawRecord(
                    header: lineBuffer[0],
                    sequence: lineBuffer[1],
                    separator: lineBuffer[2],
                    quality: lineBuffer[3]
                )
                lineBuffer.removeAll(keepingCapacity: true)
                shardTotalReads += 1

                for fragment in pairer.add(record, call: matcher.assignment(for: record.sequence)?.barcodeIndex) {
                    try place(fragment)
                }
            }
            for fragment in pairer.finish() {
                try place(fragment)
            }

            if !lineBuffer.isEmpty {
                logger.warning("Input FASTQ shard \(shardIndex) had \(lineBuffer.count) trailing lines (incomplete record)")
            }
            try shardOutputCache.closeAll()

            return ExactBareBarcodeShardResult(
                shardIndex: shardIndex,
                barcodeAccumulators: shardBarcodeAccumulators,
                unassigned: shardUnassigned,
                totalReads: shardTotalReads,
                assignedReads: shardAssignedReads,
                mateCalls: pairer.calls
            )
        }

        func mergeShard(_ shard: ExactBareBarcodeShardResult, shardRoot: URL?) throws {
            totalReads += shard.totalReads
            assignedReads += shard.assignedReads
            mateCalls.add(shard.mateCalls)

            for index in barcodeAccumulators.indices {
                let shardAccumulator = shard.barcodeAccumulators[index]
                barcodeAccumulators[index].merge(shardAccumulator)
                if !isVirtualMode, shardAccumulator.readCount > 0, let shardRoot {
                    let barcodeID = config.barcodeKit.barcodes[index].id
                    let shardFASTQ = shardDirectory(for: shard.shardIndex, root: shardRoot)
                        .appendingPathComponent("\(barcodeID).fastq")
                    try appendFile(shardFASTQ, to: fastqURL(for: barcodeID))
                }
            }

            unassigned.merge(shard.unassigned)
            if !isVirtualMode,
               config.unassignedDisposition == .keep,
               shard.unassigned.readCount > 0,
               let shardRoot {
                let shardFASTQ = shardDirectory(for: shard.shardIndex, root: shardRoot)
                    .appendingPathComponent("unassigned.fastq")
                try appendFile(shardFASTQ, to: fastqURL(for: "unassigned"))
            }
        }

        let workerCount = max(1, min(config.threads, inputURLs.count))
        if inputURLs.count > 1 && workerCount > 1 {
            progress(0.0, "Starting exact bare-barcode demultiplexing with \(workerCount) workers...")
            let shardRoot: URL? = isVirtualMode ? nil : config.outputDirectory.appendingPathComponent(
                ".exact-bare-shards-\(UUID().uuidString)",
                isDirectory: true
            )
            if let shardRoot {
                try fm.createDirectory(at: shardRoot, withIntermediateDirectories: true)
            }
            defer {
                if let shardRoot { try? fm.removeItem(at: shardRoot) }
            }

            var nextShardIndex = 0
            var completedChunks = 0
            var completedReads = 0
            var completedAssignedReads = 0
            var pendingShards: [Int: ExactBareBarcodeShardResult] = [:]
            var nextMergeIndex = 0

            try await withThrowingTaskGroup(of: ExactBareBarcodeShardResult.self) { group in
                func submitShard(_ shardIndex: Int) {
                    let inputURL = inputURLs[shardIndex]
                    group.addTask {
                        try await processShard(
                            inputURL: inputURL,
                            shardIndex: shardIndex,
                            shardRoot: shardRoot
                        )
                    }
                }

                while nextShardIndex < min(workerCount, inputURLs.count) {
                    submitShard(nextShardIndex)
                    nextShardIndex += 1
                }

                while let shard = try await group.next() {
                    completedChunks += 1
                    completedReads += shard.totalReads
                    completedAssignedReads += shard.assignedReads
                    pendingShards[shard.shardIndex] = shard

                    while let readyShard = pendingShards.removeValue(forKey: nextMergeIndex) {
                        try mergeShard(readyShard, shardRoot: shardRoot)
                        nextMergeIndex += 1
                    }

                    if nextShardIndex < inputURLs.count {
                        submitShard(nextShardIndex)
                        nextShardIndex += 1
                    }

                    let fraction = min(0.75, 0.75 * Double(completedChunks) / Double(inputURLs.count))
                    progress(
                        fraction,
                        "Processed \(completedChunks) of \(inputURLs.count) chunks, \(completedReads) reads, \(completedAssignedReads) assigned..."
                    )
                }
            }
        } else {
            progress(0.0, "Starting exact bare-barcode demultiplexing...")

            func place(_ fragment: ExactBareMatePairer.Fragment) throws {
                for record in fragment.records {
                    if let barcodeIndex = fragment.call {
                        barcodeAccumulators[barcodeIndex].add(
                            readID: record.readID,
                            previewRecord: record,
                            outputLength: record.sequence.count,
                            trimEntry: nil
                        )
                        assignedReads += 1

                        if !isVirtualMode {
                            let barcodeID = config.barcodeKit.barcodes[barcodeIndex].id
                            try outputCache.write(record, to: fastqURL(for: barcodeID))
                        }
                    } else {
                        unassigned.add(
                            readID: record.readID,
                            previewRecord: record,
                            outputLength: record.sequence.count,
                            trimEntry: nil
                        )
                        if !isVirtualMode, config.unassignedDisposition == .keep {
                            try outputCache.write(record, to: fastqURL(for: "unassigned"))
                        }
                    }
                }
            }

            let lines = URL.multiFileLinesAutoDecompressing(inputURLs)
            var lineBuffer: [String] = []
            lineBuffer.reserveCapacity(4)
            var pairer = ExactBareMatePairer(placesMates: placesMates)

            for try await line in lines {
                if line.isEmpty && lineBuffer.isEmpty { continue }
                lineBuffer.append(line)
                guard lineBuffer.count == 4 else { continue }

                let record = FASTQRawRecord(
                    header: lineBuffer[0],
                    sequence: lineBuffer[1],
                    separator: lineBuffer[2],
                    quality: lineBuffer[3]
                )
                lineBuffer.removeAll(keepingCapacity: true)
                totalReads += 1

                if totalReads % 100_000 == 0 {
                    let estimatedFraction: Double
                    if totalInputBytes > 0 {
                        let avgBytesPerRead = Double(record.baseCount + 50) * 1.1
                        estimatedFraction = min(0.75, (avgBytesPerRead * Double(totalReads)) / Double(totalInputBytes))
                    } else {
                        estimatedFraction = 0.0
                    }
                    progress(estimatedFraction, "Processed \(totalReads) reads, \(assignedReads) assigned...")
                }

                for fragment in pairer.add(record, call: matcher.assignment(for: record.sequence)?.barcodeIndex) {
                    try place(fragment)
                }
            }
            for fragment in pairer.finish() {
                try place(fragment)
            }
            mateCalls.add(pairer.calls)

            if !lineBuffer.isEmpty {
                logger.warning("Input FASTQ had \(lineBuffer.count) trailing lines (incomplete record)")
            }
        }

        try outputCache.closeAll()
        progress(0.80, "Creating exact demultiplex bundles...")

        var barcodeResults: [BarcodeResult] = []
        var outputBundleURLs: [URL] = []
        var unassignedBundleURL: URL?
        let nonEmptyBarcodes = barcodeAccumulators.filter { $0.readCount > 0 }
        let bundleCount = nonEmptyBarcodes.count + (config.unassignedDisposition == .keep && unassigned.readCount > 0 ? 1 : 0)
        let progressPerBundle = 0.15 / max(1.0, Double(bundleCount))
        var completedBundles = 0

        func writeBundleFiles(
            accumulator: ExactBareBarcodeAccumulator,
            bundleURL: URL,
            cachedStatistics: FASTQDatasetStatistics
        ) throws {
            let readIDsURL = bundleURL.appendingPathComponent("read-ids.txt")
            try (accumulator.readIDs.joined(separator: "\n") + "\n")
                .write(to: readIDsURL, atomically: true, encoding: .utf8)

            let previewURL = bundleURL.appendingPathComponent("preview.fastq")
            try accumulator.previewRecords.map(\.fastqString).joined()
                .write(to: previewURL, atomically: true, encoding: .utf8)

            try writeTrimPositions(accumulator.trimEntries, to: bundleURL)

            if let rootBundleURL = config.rootBundleURL,
               let rootFASTQFilename = config.rootFASTQFilename {
                let anchorURL = manifestAnchorURL(for: bundleURL, config: config)
                let rootRelativePath = FASTQBundle.projectRelativePath(for: rootBundleURL, from: anchorURL)
                    ?? relativePath(from: anchorURL, to: rootBundleURL)
                let parentBundleURL = config.sourceBundleURL
                let parentRelativePath = parentBundleURL.flatMap {
                    FASTQBundle.projectRelativePath(for: $0, from: anchorURL)
                        ?? relativePath(from: anchorURL, to: $0)
                } ?? rootRelativePath
                let demuxOp = FASTQDerivativeOperation(
                    kind: .demultiplex,
                    toolUsed: "exact-bare-barcode-demux",
                    toolVersion: nil
                )
                let derivedManifest = FASTQDerivedBundleManifest(
                    name: accumulator.barcodeID,
                    parentBundleRelativePath: parentRelativePath,
                    rootBundleRelativePath: rootRelativePath,
                    rootFASTQFilename: rootFASTQFilename,
                    payload: .demuxedVirtual(
                        barcodeID: accumulator.barcodeID,
                        readIDListFilename: "read-ids.txt",
                        previewFilename: "preview.fastq",
                        trimPositionsFilename: hasTrimPositionsFile(in: bundleURL) ? "trim-positions.tsv" : nil,
                        orientMapFilename: nil
                    ),
                    lineage: [demuxOp],
                    operation: demuxOp,
                    cachedStatistics: cachedStatistics,
                    pairingMode: config.inputPairingMode ?? inferredPairingMode(from: parentBundleURL ?? config.inputURL),
                    sequenceFormat: config.inputSequenceFormat
                )
                try saveRequiredDerivedManifest(
                    derivedManifest,
                    in: bundleURL,
                    barcode: accumulator.barcodeID
                )
            }
        }

        for accumulator in nonEmptyBarcodes {
            let bundleURL = try bundleURL(for: accumulator.barcodeID)
            let cachedStatistics = stats(for: accumulator)
            try writeBundleFiles(
                accumulator: accumulator,
                bundleURL: bundleURL,
                cachedStatistics: cachedStatistics
            )

            let sequenceInfo = barcodeSequenceInfo(
                for: accumulator.barcodeID,
                kit: config.barcodeKit,
                sampleAssignments: config.sampleAssignments
            )
            barcodeResults.append(BarcodeResult(
                barcodeID: accumulator.barcodeID,
                sampleName: sequenceInfo.sampleName,
                forwardSequence: sequenceInfo.forward,
                reverseSequence: sequenceInfo.reverse,
                readCount: accumulator.readCount,
                baseCount: accumulator.baseCount,
                meanReadLength: accumulator.readCount > 0
                    ? Double(accumulator.baseCount) / Double(accumulator.readCount)
                    : nil,
                bundleRelativePath: bundleURL.lastPathComponent
            ))
            outputBundleURLs.append(bundleURL)
            completedBundles += 1
            progress(0.80 + Double(completedBundles) * progressPerBundle, "Created bundle for \(accumulator.barcodeID)")
        }

        if config.unassignedDisposition == .keep && unassigned.readCount > 0 {
            let bundleURL = try bundleURL(for: "unassigned")
            let cachedStatistics = stats(for: unassigned)
            try writeBundleFiles(
                accumulator: unassigned,
                bundleURL: bundleURL,
                cachedStatistics: cachedStatistics
            )
            unassignedBundleURL = bundleURL
            completedBundles += 1
            progress(0.80 + Double(completedBundles) * progressPerBundle, "Created bundle for unassigned")
        }

        barcodeResults.sort { $0.barcodeID.localizedStandardCompare($1.barcodeID) == .orderedAscending }

        let elapsed = runClock.elapsed
        let barcodeType: BarcodeType = {
            switch config.symmetryMode {
            case .symmetric: return .symmetric
            case .asymmetric: return .asymmetric
            case .singleEnd: return .singleEnd
            }
        }()
        let kitForManifest = BarcodeKit(
            name: config.barcodeKit.displayName,
            vendor: config.barcodeKit.vendor,
            barcodeCount: config.barcodeKit.barcodes.count,
            isDualIndexed: false,
            barcodeType: barcodeType
        )
        let commandLine = ([
            "exact-bare-barcode-demux",
            "--search", "whole-read",
            shouldSearchBareBarcodeReverseComplements(config) ? "--search-rc" : nil
        ].compactMap { $0 }
            + (config.threads > 1 ? ["--threads", String(config.threads)] : []))
            .joined(separator: " ")
        let manifest = DemultiplexManifest(
            barcodeKit: kitForManifest,
            parameters: DemultiplexParameters(
                tool: "exact-bare-barcode-demux",
                toolVersion: nil,
                maxMismatches: 0,
                requireBothEnds: false,
                trimBarcodes: false,
                commandLine: commandLine,
                wallClockSeconds: elapsed
            ),
            barcodes: barcodeResults,
            unassigned: UnassignedReadsSummary(
                readCount: unassigned.readCount,
                baseCount: unassigned.baseCount,
                disposition: config.unassignedDisposition,
                bundleRelativePath: unassignedBundleURL?.lastPathComponent
            ),
            outputDirectoryRelativePath: ".",
            inputReadCount: totalReads,
            mateCalls: placesMates ? mateCalls.summary : nil
        )

        try manifest.save(to: config.outputDirectory)
        if FASTQBundle.isBundleURL(config.inputURL) {
            try? manifest.save(to: config.inputURL)
        }

        progress(1.0, "Demultiplexing complete: \(barcodeResults.count) samples, \(String(format: "%.0f%%", manifest.assignmentRate * 100)) assigned")

        logger.info("Exact bare-barcode demux complete: \(barcodeResults.count) samples, \(manifest.assignmentRate * 100)% assigned, \(String(format: "%.1f", elapsed))s")

        return DemultiplexResult(
            manifest: manifest,
            outputBundleURLs: outputBundleURLs,
            unassignedBundleURL: unassignedBundleURL,
            wallClockSeconds: elapsed,
            nativeCommand: nil
        )
    }
}
