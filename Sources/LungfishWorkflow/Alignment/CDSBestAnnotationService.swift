// CDSBestAnnotationService.swift - Select best CDS-to-genome models as annotations
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

public final class CDSBestAnnotationService: @unchecked Sendable {
    private let samtoolsRunner: any AlignmentSamtoolsRunning
    private let trackIDProvider: @Sendable (String) -> String

    public init(
        samtoolsRunner: any AlignmentSamtoolsRunning = NativeToolSamtoolsRunner.shared
    ) {
        self.samtoolsRunner = samtoolsRunner
        self.trackIDProvider = { _ in "ann_\(String(UUID().uuidString.prefix(8)))" }
    }

    init(
        samtoolsRunner: any AlignmentSamtoolsRunning = NativeToolSamtoolsRunner.shared,
        trackIDProvider: @escaping @Sendable (String) -> String
    ) {
        self.samtoolsRunner = samtoolsRunner
        self.trackIDProvider = trackIDProvider
    }

    public func convertBestCDS(
        request: CDSBestAnnotationRequest,
        progressHandler: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> CDSBestAnnotationResult {
        let sourceBundleURL = request.sourceBundleURL.standardizedFileURL
        let outputBundleURL = request.outputBundleURL.standardizedFileURL
        guard sourceBundleURL.path != outputBundleURL.path else {
            throw CDSBestAnnotationServiceError.sourceAndOutputBundleMatch(outputBundleURL)
        }

        let mappingResult: MappingResult
        do {
            mappingResult = try MappingResult.load(from: request.mappingResultURL.standardizedFileURL)
        } catch MappingResultLoadError.sidecarNotFound {
            throw CDSBestAnnotationServiceError.missingMappingResult(request.mappingResultURL.standardizedFileURL)
        }
        guard FileManager.default.fileExists(atPath: mappingResult.bamURL.path) else {
            throw CDSBestAnnotationServiceError.missingMappingBAM(mappingResult.bamURL)
        }

        progressHandler?(0.1, "Copying source bundle...")
        try prepareOutputBundle(sourceBundleURL: sourceBundleURL, outputBundleURL: outputBundleURL, replace: request.replaceExisting)

        progressHandler?(0.25, "Reading mapped CDS alignments...")
        let samtoolsResult = try await samtoolsRunner.runSamtools(
            arguments: ["view", "-h", mappingResult.bamURL.path],
            timeout: samtoolsTimeout(for: mappingResult.bamURL.path)
        )
        guard samtoolsResult.isSuccess else {
            throw CDSBestAnnotationServiceError.samtoolsFailed(
                samtoolsResult.stderr.isEmpty ? "samtools exited with \(samtoolsResult.exitCode)" : samtoolsResult.stderr
            )
        }

        progressHandler?(0.55, "Selecting best CDS models per locus...")
        let selection = try selectBestModels(
            fromSAM: samtoolsResult.stdout,
            request: request,
            mappingResult: mappingResult
        )

        let outputTrackName = normalizedOutputTrackName(request.outputTrackName)
        let outputTrackID = normalizedTrackID(trackIDProvider(outputTrackName))
        let relativeDatabasePath = "annotations/\(outputTrackID).db"
        let databaseURL = outputBundleURL.appendingPathComponent(relativeDatabasePath)

        var manifest = try BundleManifest.load(from: outputBundleURL)
        let existingTracks = manifest.annotations.filter { $0.id == outputTrackID || $0.name == outputTrackName }
        if !existingTracks.isEmpty && !request.replaceExisting {
            throw CDSBestAnnotationServiceError.outputTrackExists(outputTrackName)
        }
        if request.replaceExisting {
            for track in existingTracks {
                removeAnnotationArtifacts(for: track, bundleURL: outputBundleURL)
                manifest = manifest.removingAnnotationTrack(id: track.id)
            }
        }

        progressHandler?(0.75, "Writing CDS annotation database...")
        let featureCount = try MappedReadsAnnotationDatabaseWriter.write(
            rows: selection.rows,
            to: databaseURL,
            metadata: [
                "source_bundle_path": sourceBundleURL.path,
                "mapping_result_path": request.mappingResultURL.standardizedFileURL.path,
                "source_mapping_bam": mappingResult.bamURL.path,
                "selection": "best_cds_model_by_nm_and_query_coverage",
                "created_by": "cds_best_annotation_service",
            ]
        )

        let trackInfo = AnnotationTrackInfo(
            id: outputTrackID,
            name: outputTrackName,
            description: "Best CDS query models per overlapping genomic interval",
            path: relativeDatabasePath,
            databasePath: relativeDatabasePath,
            annotationType: .custom,
            featureCount: featureCount,
            source: request.mappingResultURL.lastPathComponent,
            version: nil
        )

        progressHandler?(0.9, "Updating output bundle manifest...")
        manifest = manifest.addingAnnotationTrack(trackInfo)
        do {
            try manifest.save(to: outputBundleURL)
        } catch {
            throw CDSBestAnnotationServiceError.manifestWriteFailed(error.localizedDescription)
        }

        progressHandler?(1.0, "CDS annotation track created.")
        return CDSBestAnnotationResult(
            sourceBundleURL: sourceBundleURL,
            mappingResultURL: request.mappingResultURL.standardizedFileURL,
            outputBundleURL: outputBundleURL,
            annotationTrackInfo: trackInfo,
            databasePath: relativeDatabasePath,
            geneCount: selection.geneCount,
            cdsCount: selection.cdsCount,
            candidateRecordCount: selection.candidateRecordCount,
            selectedLocusCount: selection.selectedLocusCount,
            skippedUnmappedCount: selection.skippedUnmappedCount,
            skippedSecondaryCount: selection.skippedSecondaryCount,
            skippedSupplementaryCount: selection.skippedSupplementaryCount
        )
    }

    private struct CDSBlock: Sendable, Equatable {
        let referenceStart0: Int
        let referenceEnd0: Int
        let queryStart0: Int
        let queryEnd0: Int
    }

    private struct CandidateModel: Sendable, Equatable {
        let record: MappedReadsSAMRecord
        let blocks: [CDSBlock]
        let queryCovered: Int
        let queryCoverage: Double
        let mismatchPenalty: Int
        let genomicStart0: Int
        let genomicEnd0: Int
    }

    private struct SelectionSummary {
        let rows: [MappedReadsAnnotationRow]
        let geneCount: Int
        let cdsCount: Int
        let candidateRecordCount: Int
        let selectedLocusCount: Int
        let skippedUnmappedCount: Int
        let skippedSecondaryCount: Int
        let skippedSupplementaryCount: Int
    }

    private struct DisjointSet {
        private var parent: [Int]
        private var rank: [Int]

        init(count: Int) {
            self.parent = Array(0..<count)
            self.rank = Array(repeating: 0, count: count)
        }

        mutating func find(_ value: Int) -> Int {
            if parent[value] != value {
                parent[value] = find(parent[value])
            }
            return parent[value]
        }

        mutating func union(_ lhs: Int, _ rhs: Int) {
            let leftRoot = find(lhs)
            let rightRoot = find(rhs)
            guard leftRoot != rightRoot else { return }
            if rank[leftRoot] < rank[rightRoot] {
                parent[leftRoot] = rightRoot
            } else if rank[leftRoot] > rank[rightRoot] {
                parent[rightRoot] = leftRoot
            } else {
                parent[rightRoot] = leftRoot
                rank[leftRoot] += 1
            }
        }
    }

    private func selectBestModels(
        fromSAM sam: String,
        request: CDSBestAnnotationRequest,
        mappingResult: MappingResult
    ) throws -> SelectionSummary {
        var candidates: [CandidateModel] = []
        var skippedUnmappedCount = 0
        var skippedSecondaryCount = 0
        var skippedSupplementaryCount = 0

        for rawLine in sam.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            guard !line.hasPrefix("@") else { continue }
            if rawSAMFlag(in: line).map({ $0 & 0x4 != 0 }) == true {
                skippedUnmappedCount += 1
                continue
            }
            guard let record = MappedReadsSAMRecord.parse(line) else {
                throw CDSBestAnnotationServiceError.invalidSAMLine(line)
            }
            if record.isSecondary && !request.includeSecondary {
                skippedSecondaryCount += 1
                continue
            }
            if record.isSupplementary && !request.includeSupplementary {
                skippedSupplementaryCount += 1
                continue
            }
            guard let candidate = candidateModel(for: record),
                  candidate.queryCoverage >= request.minimumQueryCoverage else {
                continue
            }
            candidates.append(candidate)
        }

        let selected = dedupeOverlapping(candidates)
        var rows: [MappedReadsAnnotationRow] = []
        var cdsCount = 0
        for (index, candidate) in selected.enumerated() {
            let rowSet = annotationRows(for: candidate, index: index + 1, request: request, mappingResult: mappingResult)
            rows.append(contentsOf: rowSet)
            cdsCount += max(0, rowSet.count - 1)
        }

        return SelectionSummary(
            rows: rows,
            geneCount: selected.count,
            cdsCount: cdsCount,
            candidateRecordCount: candidates.count,
            selectedLocusCount: selected.count,
            skippedUnmappedCount: skippedUnmappedCount,
            skippedSecondaryCount: skippedSecondaryCount,
            skippedSupplementaryCount: skippedSupplementaryCount
        )
    }

    private func candidateModel(for record: MappedReadsSAMRecord) -> CandidateModel? {
        let blocks = cdsBlocks(for: record)
        guard !blocks.isEmpty else { return nil }
        let covered = mergedLength(blocks.map { ($0.queryStart0, $0.queryEnd0) })
        let queryLength = max(1, record.queryLength)
        let queryCoverage = Double(covered) / Double(queryLength)
        let mismatches = record.editDistance ?? Int.max / 4
        let mismatchPenalty = mismatches + max(0, queryLength - covered)
        let genomicStart0 = blocks.map(\.referenceStart0).min() ?? record.start0
        let genomicEnd0 = blocks.map(\.referenceEnd0).max() ?? record.end0
        guard geneSpanIsAllowed(readName: record.readName, span: genomicEnd0 - genomicStart0) else {
            return nil
        }
        return CandidateModel(
            record: record,
            blocks: blocks,
            queryCovered: covered,
            queryCoverage: queryCoverage,
            mismatchPenalty: mismatchPenalty,
            genomicStart0: genomicStart0,
            genomicEnd0: genomicEnd0
        )
    }

    private func geneSpanIsAllowed(readName: String, span: Int) -> Bool {
        guard let limit = mhcSpanLimit(for: readName) else { return true }
        return span <= limit
    }

    private func mhcSpanLimit(for readName: String) -> Int? {
        let geneName = readName.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? readName
        guard geneName.hasPrefix("Mafa-") || geneName.hasPrefix("Mamu-") else { return nil }
        let allelePart = geneName.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).dropFirst().first.map(String.init) ?? ""
        if isMHCClassII(allelePart) {
            return 10_000
        }
        return 4_000
    }

    private func isMHCClassII(_ allelePart: String) -> Bool {
        let prefixes = ["DRA", "DRB", "DQA", "DQB", "DPA", "DPB", "DMA", "DMB", "DOA", "DOB"]
        return prefixes.contains { allelePart.hasPrefix($0) }
    }

    private func cdsBlocks(for record: MappedReadsSAMRecord) -> [CDSBlock] {
        var blocks: [CDSBlock] = []
        var ref = record.start0
        var query = 0
        var blockRefStart: Int?
        var blockQueryStart: Int?
        var blockRefEnd = ref
        var blockQueryEnd = query

        func ensureBlock() {
            if blockRefStart == nil {
                blockRefStart = ref
                blockQueryStart = query
            }
        }
        func flushBlock() {
            guard let refStart = blockRefStart, let queryStart = blockQueryStart, blockRefEnd > refStart else {
                blockRefStart = nil
                blockQueryStart = nil
                return
            }
            blocks.append(CDSBlock(
                referenceStart0: refStart,
                referenceEnd0: blockRefEnd,
                queryStart0: queryStart,
                queryEnd0: max(queryStart, blockQueryEnd)
            ))
            blockRefStart = nil
            blockQueryStart = nil
        }

        for operation in record.cigar {
            switch operation.op {
            case .skip:
                flushBlock()
                ref += operation.length
                blockRefEnd = ref
            case .match, .seqMatch, .seqMismatch:
                ensureBlock()
                ref += operation.length
                query += operation.length
                blockRefEnd = ref
                blockQueryEnd = query
            case .deletion:
                ensureBlock()
                ref += operation.length
                blockRefEnd = ref
            case .insertion:
                ensureBlock()
                query += operation.length
                blockQueryEnd = query
            case .softClip:
                query += operation.length
                if blockRefStart == nil {
                    blockQueryEnd = query
                }
            case .hardClip, .padding:
                continue
            }
        }
        flushBlock()
        return blocks
    }

    private func dedupeOverlapping(_ candidates: [CandidateModel]) -> [CandidateModel] {
        let grouped = Dictionary(grouping: candidates) { "\($0.record.referenceName)\t\($0.record.isReverse ? "-" : "+")" }
        return grouped.values.flatMap { group in
            let sorted = group.sorted {
                ($0.genomicStart0, $0.genomicEnd0, $0.record.readName) < ($1.genomicStart0, $1.genomicEnd0, $1.record.readName)
            }
            var disjointSet = DisjointSet(count: sorted.count)
            var binnedIndices: [Int: [Int]] = [:]
            let binSize = 10_000

            for (index, candidate) in sorted.enumerated() {
                var compared = Set<Int>()
                let startBin = candidate.genomicStart0 / binSize
                let endBin = max(candidate.genomicStart0, candidate.genomicEnd0 - 1) / binSize
                for bin in startBin...endBin {
                    for otherIndex in binnedIndices[bin, default: []] where compared.insert(otherIndex).inserted {
                        guard spansCouldOverlap(candidate, sorted[otherIndex]) else { continue }
                        if modelsOverlap(candidate, sorted[otherIndex]) {
                            disjointSet.union(index, otherIndex)
                        }
                    }
                }
                for bin in startBin...endBin {
                    binnedIndices[bin, default: []].append(index)
                }
            }

            var components: [Int: [CandidateModel]] = [:]
            for (index, candidate) in sorted.enumerated() {
                components[disjointSet.find(index), default: []].append(candidate)
            }
            return components.values.compactMap { $0.sorted(by: bestCandidateSort).first }
        }
        .sorted { ($0.record.referenceName, $0.genomicStart0, $0.genomicEnd0, $0.record.readName) < ($1.record.referenceName, $1.genomicStart0, $1.genomicEnd0, $1.record.readName) }
    }

    private func spansCouldOverlap(_ lhs: CandidateModel, _ rhs: CandidateModel) -> Bool {
        lhs.genomicStart0 < rhs.genomicEnd0 && rhs.genomicStart0 < lhs.genomicEnd0
    }

    private func modelsOverlap(_ lhs: CandidateModel, _ rhs: CandidateModel) -> Bool {
        let lhsIntervals = lhs.blocks.map { ($0.referenceStart0, $0.referenceEnd0) }
        let rhsIntervals = rhs.blocks.map { ($0.referenceStart0, $0.referenceEnd0) }
        let ov = intervalOverlap(lhsIntervals, rhsIntervals)
        let lhsLen = max(1, mergedLength(lhsIntervals))
        let rhsLen = max(1, mergedLength(rhsIntervals))
        return Double(ov) / Double(min(lhsLen, rhsLen)) >= 0.5
            && Double(ov) / Double(max(lhsLen, rhsLen)) >= 0.5
    }

    private func bestCandidateSort(_ lhs: CandidateModel, _ rhs: CandidateModel) -> Bool {
        if lhs.mismatchPenalty != rhs.mismatchPenalty { return lhs.mismatchPenalty < rhs.mismatchPenalty }
        if lhs.queryCoverage != rhs.queryCoverage { return lhs.queryCoverage > rhs.queryCoverage }
        if lhs.queryCovered != rhs.queryCovered { return lhs.queryCovered > rhs.queryCovered }
        if lhs.record.queryLength != rhs.record.queryLength { return lhs.record.queryLength > rhs.record.queryLength }
        if lhs.blocks.count != rhs.blocks.count { return lhs.blocks.count > rhs.blocks.count }
        if lhs.record.mapq != rhs.record.mapq { return lhs.record.mapq > rhs.record.mapq }
        if lhs.genomicStart0 != rhs.genomicStart0 { return lhs.genomicStart0 < rhs.genomicStart0 }
        return lhs.record.readName < rhs.record.readName
    }

    private func annotationRows(
        for candidate: CandidateModel,
        index: Int,
        request: CDSBestAnnotationRequest,
        mappingResult: MappingResult
    ) -> [MappedReadsAnnotationRow] {
        let geneName = candidate.record.readName
        let annotationName = "\(geneName)_cds_model_\(index)"
        let common = commonAttributes(for: candidate, request: request, mappingResult: mappingResult)
        var rows = [
            MappedReadsAnnotationRow(
                name: annotationName,
                type: "gene",
                chromosome: candidate.record.referenceName,
                start: candidate.genomicStart0,
                end: candidate.genomicEnd0,
                strand: candidate.record.isReverse ? "-" : "+",
                attributes: common.merging(["gene": geneName, "feature_role": "gene_span"]) { _, new in new }
            )
        ]
        let orderedBlocks = candidate.blocks.sorted {
            candidate.record.isReverse
                ? $0.referenceStart0 > $1.referenceStart0
                : $0.referenceStart0 < $1.referenceStart0
        }
        for (blockIndex, block) in orderedBlocks.enumerated() {
            rows.append(MappedReadsAnnotationRow(
                name: annotationName,
                type: "CDS",
                chromosome: candidate.record.referenceName,
                start: block.referenceStart0,
                end: block.referenceEnd0,
                strand: candidate.record.isReverse ? "-" : "+",
                attributes: common.merging([
                    "gene": geneName,
                    "Parent": annotationName,
                    "cds_component": String(blockIndex + 1),
                    "query_start": String(block.queryStart0),
                    "query_end": String(block.queryEnd0),
                    "feature_role": "cds_component",
                ]) { _, new in new }
            ))
        }
        return rows
    }

    private func commonAttributes(
        for candidate: CandidateModel,
        request: CDSBestAnnotationRequest,
        mappingResult: MappingResult
    ) -> [String: String] {
        var attributes: [String: String] = [
            "source_alignment_track_name": request.mappingResultURL.lastPathComponent,
            "source_alignment_track_id": "mapping-result",
            "source_query": candidate.record.readName,
            "method": "minimap2_splice_cds_best",
            "cigar": candidate.record.cigarString,
            "mapq": String(candidate.record.mapq),
            "flag": String(candidate.record.flag),
            "query_length": String(candidate.record.queryLength),
            "query_covered": String(candidate.queryCovered),
            "query_cover": String(format: "%.3f", candidate.queryCoverage),
            "nm": String(candidate.record.editDistance ?? -1),
            "mismatch_penalty": String(candidate.mismatchPenalty),
            "cds_component_count": String(candidate.blocks.count),
            "gene_span": String(candidate.genomicEnd0 - candidate.genomicStart0),
            "mapping_result_bam": mappingResult.bamURL.path,
            "source_bundle_path": request.sourceBundleURL.standardizedFileURL.path,
        ]
        for (tag, value) in candidate.record.auxiliaryTags {
            attributes["tag_\(tag)"] = value
        }
        return attributes
    }

    private func mergedLength(_ intervals: [(Int, Int)]) -> Int {
        mergeIntervals(intervals).reduce(0) { $0 + max(0, $1.1 - $1.0) }
    }

    private func intervalOverlap(_ lhs: [(Int, Int)], _ rhs: [(Int, Int)]) -> Int {
        let lhs = mergeIntervals(lhs)
        let rhs = mergeIntervals(rhs)
        var i = 0
        var j = 0
        var total = 0
        while i < lhs.count && j < rhs.count {
            let ov = max(0, min(lhs[i].1, rhs[j].1) - max(lhs[i].0, rhs[j].0))
            total += ov
            if lhs[i].1 < rhs[j].1 {
                i += 1
            } else {
                j += 1
            }
        }
        return total
    }

    private func mergeIntervals(_ intervals: [(Int, Int)]) -> [(Int, Int)] {
        let sorted = intervals.filter { $0.1 > $0.0 }.sorted { ($0.0, $0.1) < ($1.0, $1.1) }
        guard var current = sorted.first else { return [] }
        var merged: [(Int, Int)] = []
        for interval in sorted.dropFirst() {
            if interval.0 <= current.1 {
                current.1 = max(current.1, interval.1)
            } else {
                merged.append(current)
                current = interval
            }
        }
        merged.append(current)
        return merged
    }

    private func prepareOutputBundle(sourceBundleURL: URL, outputBundleURL: URL, replace: Bool) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: outputBundleURL.path) {
            guard replace else {
                throw CDSBestAnnotationServiceError.outputBundleExists(outputBundleURL)
            }
            do {
                try fileManager.removeItem(at: outputBundleURL)
            } catch {
                throw CDSBestAnnotationServiceError.bundleCopyFailed(error.localizedDescription)
            }
        }
        do {
            try fileManager.createDirectory(at: outputBundleURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.copyItem(at: sourceBundleURL, to: outputBundleURL)
        } catch {
            throw CDSBestAnnotationServiceError.bundleCopyFailed(error.localizedDescription)
        }
    }

    private func normalizedOutputTrackName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "CDS Best Matches" : trimmed
    }

    private func normalizedTrackID(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedScalars = trimmed.unicodeScalars.map { scalar -> UnicodeScalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-"
                ? scalar
                : "_"
        }
        let normalized = String(String.UnicodeScalarView(normalizedScalars))
        return normalized.isEmpty ? "ann_\(String(UUID().uuidString.prefix(8)))" : normalized
    }

    private func rawSAMFlag(in line: String) -> UInt16? {
        let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
        guard fields.count >= 2 else { return nil }
        return UInt16(fields[1])
    }

    private func samtoolsTimeout(for path: String) -> TimeInterval {
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
        return max(600.0, Double(fileSize) / 10_000_000.0)
    }

    private func removeAnnotationArtifacts(for track: AnnotationTrackInfo, bundleURL: URL) {
        removeBundleRelativeFile(track.path, bundleURL: bundleURL)
        if let databasePath = track.databasePath, databasePath != track.path {
            removeBundleRelativeFile(databasePath, bundleURL: bundleURL)
        }
    }

    private func removeBundleRelativeFile(_ path: String, bundleURL: URL) {
        let url = URL(fileURLWithPath: path).isFileURL && path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : bundleURL.appendingPathComponent(path)
        try? FileManager.default.removeItem(at: url)
    }
}
