// DemultiplexingPipeline+VirtualRootFiles.swift - Rebuilding virtual barcode bundles from their root files in one pass
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// Reads one root file's records in file order. The pipeline reads root
/// files through it, so a test can count the records a run reads.
typealias VirtualRootRecordSource = @Sendable (URL) -> AsyncThrowingStream<FASTQRecord, Error>

extension DemultiplexingPipeline {
    /// Reads a root file with the reader the per-barcode rebuild used.
    static let fileRootRecordSource: VirtualRootRecordSource = { url in
        FASTQReader(validateSequence: false).records(from: url)
    }

    /// The root files a virtual barcode bundle's preview and cached
    /// statistics are rebuilt from, in the order a tool reads them.
    ///
    /// A root that holds several files (an ONT chunked import or a merged
    /// bundle) is every member in `source-files.json` order, and any other
    /// root is its one recorded file. This is `FASTQBundle.rootSequenceURLs`,
    /// the resolution `FASTQCLIMaterializer` applies to the barcode bundle,
    /// so the counts describe the reads the bundle materializes to. They were
    /// rebuilt from the recorded file alone, the first chunk of a multi-file
    /// root, while the bundle listed every chunk's reads (R3, final review B1).
    ///
    /// Nil when the run has no root, the recorded file is not a safe member
    /// of the root, or a root file is missing. The caller then reads
    /// cutadapt's output instead, as it did before.
    func virtualRootSequenceURLs(config: DemultiplexConfig) -> [URL]? {
        guard let rootBundleURL = config.rootBundleURL,
              let rootFASTQFilename = config.rootFASTQFilename,
              let urls = try? FASTQBundle.rootSequenceURLs(rootFASTQFilename: rootFASTQFilename, in: rootBundleURL),
              !urls.isEmpty,
              urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            return nil
        }
        return urls
    }

    /// What one virtual barcode bundle needs from the root, its read list,
    /// the trims and orientations the materializer applies, and where its
    /// preview and the FASTQ its cached statistics come from are written.
    struct VirtualBarcodeRebuild: Sendable {
        /// Every read ID the bundle lists, in cutadapt's output order.
        let orderedReadIDs: [String]
        /// The read IDs of the preview, the first 1,000 of `orderedReadIDs`.
        let previewReadIDs: [String]
        let trimEntries: [DemuxTrimEntry]
        let orientMap: [String: String]
        let previewURL: URL
        let statisticsURL: URL
    }

    /// The routing of every virtual barcode bundle's reads for one pass over
    /// the root files.
    ///
    /// A bundle is folded in as soon as its read list is known. For each read
    /// it lists the plan keeps the bundle, whether the read is reverse
    /// complemented, and the last trim listed for mates 0, 1 and 2, which is
    /// what the per-barcode trim table and orientation map answered, so the
    /// bundle's read list and tables can be released.
    struct VirtualRootRebuildPlan: Sendable {
        struct Target: Sendable {
            let previewReadIDs: [String]
            let previewURL: URL
            let statisticsURL: URL
            /// A bundle that lists no read gets no preview and no statistics FASTQ, as before.
            let listsReads: Bool
        }

        fileprivate struct Trim: Sendable {
            let trim5p: Int
            let trim3p: Int
        }

        /// The last trim listed for each mate of one read.
        fileprivate struct MateTrims: Sendable {
            var mate0: Trim?
            var mate1: Trim?
            var mate2: Trim?
        }

        fileprivate struct Route: Sendable {
            let target: Int
            let reversed: Bool
            let trims: MateTrims

            /// The trim of `mate`, else of mate 0, the per-barcode lookup.
            func trim(forMate mate: Int) -> Trim? {
                switch mate {
                case 1: return trims.mate1 ?? trims.mate0
                case 2: return trims.mate2 ?? trims.mate0
                default: return trims.mate0
                }
            }
        }

        private(set) var targets: [Target] = []
        fileprivate var routes: [String: Route] = [:]
        /// The further bundles of a read that more than one bundle lists.
        fileprivate var extraRoutes: [String: [Route]] = [:]

        /// Folds `barcode` in and returns its index among `targets`.
        mutating func add(_ barcode: VirtualBarcodeRebuild) -> Int {
            let target = targets.count
            targets.append(Target(
                previewReadIDs: barcode.previewReadIDs,
                previewURL: barcode.previewURL,
                statisticsURL: barcode.statisticsURL,
                listsReads: !barcode.orderedReadIDs.isEmpty
            ))
            // The last entry for a read and mate wins, as in the per-barcode table.
            var trimsByReadID: [String: MateTrims] = [:]
            for entry in barcode.trimEntries {
                let trim = Trim(trim5p: entry.trim5p, trim3p: entry.trim3p)
                switch entry.mate {
                case 0: trimsByReadID[entry.readID, default: MateTrims()].mate0 = trim
                case 1: trimsByReadID[entry.readID, default: MateTrims()].mate1 = trim
                case 2: trimsByReadID[entry.readID, default: MateTrims()].mate2 = trim
                default: break  // never looked up, a root record's mate is 0, 1 or 2
                }
            }
            var listed = Set<String>()
            for readID in barcode.orderedReadIDs where listed.insert(readID).inserted {
                let route = Route(
                    target: target,
                    reversed: barcode.orientMap[readID] == "-",
                    trims: trimsByReadID[readID] ?? MateTrims()
                )
                if routes[readID] == nil {
                    routes[readID] = route
                } else {
                    extraRoutes[readID, default: []].append(route)
                }
            }
            return target
        }
    }

    /// Writes every planned bundle's preview and the FASTQ its cached
    /// statistics come from, reading the root files once, in manifest order.
    ///
    /// Each root record goes to every bundle that lists its read, trimmed and
    /// reverse complemented as that bundle's tables say. A bundle's statistics
    /// FASTQ holds those records in root order. Its preview holds, in preview
    /// order, the last record seen of each preview read up to the record that
    /// completed the preview. Both are what the per-barcode rebuild wrote,
    /// which read the whole root once per bundle for the statistics and again
    /// for the preview until it was complete (R3).
    ///
    /// - Returns: The number of root records read.
    @discardableResult
    func rebuildVirtualBarcodeFiles(
        fromRootFASTQs rootFASTQs: [URL],
        plan: VirtualRootRebuildPlan
    ) async throws -> Int {
        let targets = plan.targets
        let previewSets = targets.map { Set($0.previewReadIDs) }
        var previews = targets.map { _ in [String: FASTQRecord]() }
        var previewComplete = [Bool](repeating: false, count: targets.count)
        // Up to 256 KB per bundle, at most about 32 MB in all.
        let flushThreshold = max(65_536, min(262_144, 33_554_432 / max(1, targets.count)))
        var sinks = targets.map { StatisticsFASTQSink(url: $0.statisticsURL) }
        for (index, target) in targets.enumerated() where target.listsReads {
            try sinks[index].create()
        }

        // One bundle's copy of a record: its trim, then its orientation, then
        // its statistics FASTQ and, until the preview is complete, its preview.
        func deliver(_ record: FASTQRecord, readID: String, mate: Int, by route: VirtualRootRebuildPlan.Route) throws {
            var outputRecord = record
            if let trim = route.trim(forMate: mate) {
                let trimEnd = max(trim.trim5p, outputRecord.length - trim.trim3p)
                outputRecord = outputRecord.trimmed(from: trim.trim5p, to: trimEnd)
            }
            if route.reversed {
                outputRecord = outputRecord.reverseComplement()
            }
            try sinks[route.target].append(outputRecord, flushThreshold: flushThreshold)
            if !previewComplete[route.target], previewSets[route.target].contains(readID) {
                previews[route.target][readID] = outputRecord
                previewComplete[route.target] = previews[route.target].count == previewSets[route.target].count
            }
        }

        var recordsRead = 0
        for rootFASTQ in rootFASTQs {
            for try await record in rootRecordSource(rootFASTQ) {
                recordsRead += 1
                let rawReadName = record.description.map { "\(record.identifier) \($0)" } ?? record.identifier
                let (readID, mate) = detectMate(rawReadName: rawReadName)
                guard let route = plan.routes[readID] else { continue }
                try deliver(record, readID: readID, mate: mate, by: route)
                for extraRoute in plan.extraRoutes[readID] ?? [] {
                    try deliver(record, readID: readID, mate: mate, by: extraRoute)
                }
            }
        }
        // The reader ends its stream quietly when the task is cancelled.
        try Task.checkCancellation()
        for index in sinks.indices {
            try sinks[index].flush()
        }

        for (index, target) in targets.enumerated() where !target.previewReadIDs.isEmpty {
            let writer = FASTQWriter(url: target.previewURL)
            try writer.open()
            defer { try? writer.close() }
            for readID in target.previewReadIDs {
                if let record = previews[index][readID] {
                    try writer.write(record)
                }
            }
        }
        return recordsRead
    }

    /// The cached statistics of every planned bundle, in `plan.targets`
    /// order, computed from its statistics FASTQ as the per-barcode rebuild
    /// computed them, eight at a time, each file deleted once read.
    func virtualBarcodeStatistics(plan: VirtualRootRebuildPlan) async throws -> [FASTQDatasetStatistics] {
        let urls = plan.targets.map(\.statisticsURL)
        return try await withThrowingTaskGroup(
            of: (Int, FASTQDatasetStatistics).self,
            returning: [FASTQDatasetStatistics].self
        ) { group in
            var statistics = [FASTQDatasetStatistics?](repeating: nil, count: urls.count)
            var nextIndex = 0
            func startNext() {
                let index = nextIndex
                let url = urls[index]
                nextIndex += 1
                group.addTask {
                    defer { try? FileManager.default.removeItem(at: url) }
                    let reader = FASTQReader(validateSequence: false)
                    return (index, try await reader.computeStatistics(from: url, sampleLimit: 0).statistics)
                }
            }
            while nextIndex < min(8, urls.count) {
                startNext()
            }
            while let finished = try await group.next() {
                statistics[finished.0] = finished.1
                if nextIndex < urls.count {
                    startNext()
                }
            }
            return statistics.compactMap { $0 }
        }
    }
}

/// The FASTQ a virtual bundle's cached statistics are computed from,
/// written byte for byte as `FASTQWriter` writes it with its defaults (no
/// line wrapping, a bare `+` separator, Phred+33 qualities). Records are
/// buffered and appended with the file closed again in between, so a pass
/// over the root holds no file open per bundle. A run can have hundreds of
/// barcodes, and an app started by launchd may open 256 files.
private struct StatisticsFASTQSink {
    let url: URL
    private var buffer = Data()

    init(url: URL) {
        self.url = url
    }

    /// Creates the file empty, as `FASTQWriter.open()` does.
    func create() throws {
        let directory = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }

    mutating func append(_ record: FASTQRecord, flushThreshold: Int) throws {
        var output = "@\(record.identifier)"
        if let description = record.description {
            output += " \(description)"
        }
        output += "\n"
        output += record.sequence
        output += "\n+\n"
        output += record.quality.toAscii(encoding: .phred33)
        output += "\n"
        buffer.append(contentsOf: output.utf8)
        if buffer.count >= flushThreshold {
            try flush()
        }
    }

    mutating func flush() throws {
        guard !buffer.isEmpty else { return }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: buffer)
        buffer.removeAll(keepingCapacity: true)
    }
}
