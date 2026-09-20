// VariantFormatOverlay.swift - Immutable FORMAT presentation for variant tracks
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import os.log

private let variantFormatOverlayLogger = Logger(
    subsystem: LogSubsystem.app,
    category: "VariantFormatOverlay"
)

struct VariantFormatKey: Hashable, Sendable {
    let trackID: String
    let chromosome: String
    let position: Int
    let ref: String
    let alt: String
    let sample: String
}

struct VariantFormatSourceIdentity: Hashable, Sendable {
    let trackID: String
    let url: URL
    let fileSize: UInt64?
    let modificationDate: Date?
}

struct VariantFormatOverlaySnapshot: Sendable {
    var fields: [VariantFormatKey: [String: String]] = [:]
    var singleSampleByTrack: [String: String] = [:]
    var projectedKeysByTrack: [String: Set<String>] = [:]
    var sourceIdentities: Set<VariantFormatSourceIdentity> = []

    static let projectableOriginalKeys: Set<String> = [
        "REF_DP", "REF_RV", "REF_QUAL", "ALT_DP", "ALT_RV", "ALT_QUAL",
        "ALT_FREQ", "MERGED_AF", "MERGED_DP",
    ]

    var allProjectedKeys: Set<String> {
        projectedKeysByTrack.values.reduce(into: Set<String>()) { $0.formUnion($1) }
    }

    func projectedInfo(
        trackID: String,
        record: VariantDatabaseRecord,
        existing: [String: String]
    ) -> [String: String] {
        guard let sample = singleSampleByTrack[trackID] else { return existing }
        let sampleValues = sampleFields(trackID: trackID, record: record, sample: sample)
        guard !sampleValues.isEmpty else { return existing }

        var projected = existing
        func insertIfMissing(_ key: String, _ raw: String?) {
            guard projected[key] == nil, let raw, Self.isUsable(raw) else { return }
            projected[key] = raw
        }

        insertIfMissing("DP", sampleValues["DP"])
        for key in Self.projectableOriginalKeys {
            insertIfMissing(key, sampleValues[key])
        }
        if projected["AF"] == nil,
           let raw = sampleValues["ALT_FREQ"],
           let value = Double(raw), value.isFinite, (0...1).contains(value) {
            projected["AF"] = raw
        }
        return projected
    }

    func sampleFields(
        trackID: String,
        record: VariantDatabaseRecord,
        sample: String
    ) -> [String: String] {
        fields[VariantFormatKey(
            trackID: trackID,
            chromosome: record.chromosome,
            position: record.position,
            ref: record.ref,
            alt: record.alt,
            sample: sample
        )] ?? [:]
    }

    func trackNeedsInMemoryEvaluation(trackID: String, infoFilters: [VariantDatabase.InfoFilter], sortKey: String?) -> Bool {
        let keys = projectedKeysByTrack[trackID] ?? []
        if infoFilters.contains(where: { keys.contains($0.key) }) { return true }
        guard let sortKey else { return false }
        let normalized = sortKey.hasPrefix("info_") ? String(sortKey.dropFirst(5)) : sortKey
        return keys.contains(normalized)
    }

    static func matches(_ info: [String: String], filter: VariantDatabase.InfoFilter) -> Bool {
        guard let actual = info[filter.key], isUsable(actual) else {
            return filter.op == .eq && filter.value.isEmpty
        }
        if filter.value.isEmpty {
            return filter.op == .neq
        }
        switch filter.op {
        case .gt, .gte, .lt, .lte:
            guard let lhs = Double(actual), lhs.isFinite,
                  let rhs = Double(filter.value), rhs.isFinite else { return false }
            switch filter.op {
            case .gt: return lhs > rhs
            case .gte: return lhs >= rhs
            case .lt: return lhs < rhs
            case .lte: return lhs <= rhs
            default: return false
            }
        case .eq, .neq:
            let numericKeys: Set<String> = [
                "AF", "ALT_FREQ", "DP", "REF_DP", "REF_RV", "REF_QUAL",
                "ALT_DP", "ALT_RV", "ALT_QUAL",
            ]
            let equal: Bool
            if numericKeys.contains(filter.key),
               let lhs = Double(actual), lhs.isFinite,
               let rhs = Double(filter.value), rhs.isFinite {
                equal = lhs == rhs
            } else {
                equal = actual == filter.value
            }
            return filter.op == .eq ? equal : !equal
        case .like:
            return actual.localizedCaseInsensitiveContains(filter.value)
        }
    }

    func matches(
        _ smartFilter: VariantSmartFilter,
        trackID: String,
        row: AnnotationSearchIndex.SearchResult
    ) -> Bool {
        guard let ref = row.ref, let alt = row.alt,
              let projectedSample = singleSampleByTrack[trackID] else { return false }
        let projectedKey = VariantFormatKey(
            trackID: trackID, chromosome: row.chromosome, position: row.start,
            ref: ref, alt: alt, sample: projectedSample
        )
        guard let projectedFields = fields[projectedKey] else { return false }
        func value(sample: String, field: VariantSampleField) -> String? {
            guard sample == projectedSample else { return nil }
            switch field {
            case .genotype: return projectedFields["GT"]
            case .depth: return projectedFields["DP"]
            case .alleleFrequency:
                if let frequency = projectedFields["ALT_FREQ"] ?? projectedFields["AF"] {
                    return frequency
                }
                guard let depths = projectedFields["AD"] else { return nil }
                let counts = depths.split(separator: ",").compactMap { Double($0) }
                guard counts.count >= 2, counts.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
                let total = counts.reduce(0, +)
                guard total > 0 else { return nil }
                return String(counts.dropFirst().reduce(0, +) / total)
            }
        }
        func compare(_ lhs: String?, _ op: VariantSmartComparisonOp, _ rhs: String?) -> Bool {
            guard let lhs, let rhs else { return false }
            if let left = Double(lhs), left.isFinite, let right = Double(rhs), right.isFinite {
                switch op {
                case .gt: return left > right
                case .gte: return left >= right
                case .lt: return left < right
                case .lte: return left <= right
                case .eq: return left == right
                case .neq: return left != right
                }
            }
            switch op {
            case .eq: return lhs == rhs
            case .neq: return lhs != rhs
            default: return false
            }
        }
        func sampleMatches(_ predicate: VariantSamplePredicate, sample: String) -> Bool {
            compare(value(sample: sample, field: predicate.field), predicate.op, predicate.value)
        }
        return smartFilter.predicates.allSatisfy { predicate in
            switch predicate {
            case .sample(let samplePredicate):
                if let sample = samplePredicate.sampleName {
                    return sampleMatches(samplePredicate, sample: sample)
                }
                return sampleMatches(samplePredicate, sample: projectedSample)
            case .count(let countPredicate):
                let count = sampleMatches(countPredicate.predicate, sample: projectedSample) ? 1 : 0
                return compare(String(count), countPredicate.op, String(countPredicate.count))
            case .sampleFieldComparison(let comparison):
                return compare(
                    value(sample: comparison.lhs.sampleName, field: comparison.lhs.field),
                    comparison.op,
                    value(sample: comparison.rhs.sampleName, field: comparison.rhs.field)
                )
            }
        }
    }

    static func definition(for key: String) -> (type: String, number: String, description: String)? {
        switch key {
        case "AF":
            return ("Float", "1", "Within-sample frequency from iVar FORMAT/ALT_FREQ")
        case "ALT_FREQ":
            return ("Float", "1", "Original within-sample frequency from iVar FORMAT/ALT_FREQ")
        case "DP":
            return ("Integer", "1", "Within-sample depth from iVar FORMAT/DP")
        case "REF_DP", "REF_RV", "REF_QUAL", "ALT_DP", "ALT_RV", "ALT_QUAL":
            return ("Integer", "1", "iVar caller measurement from FORMAT/\(key)")
        case "MERGED_AF", "MERGED_DP":
            return ("String", ".", "Constituent iVar measurements from FORMAT/\(key)")
        default:
            return nil
        }
    }

    fileprivate static func isUsable(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != "."
    }
}

struct VariantFormatOverlaySource: Sendable {
    let trackID: String
    let database: VariantDatabase
    let vcfURL: URL?
    let isIVar: Bool
    let aliasesByExactToken: [String: Set<String>]
    let aliasesByCanonicalToken: [String: Set<String>]
}

enum VariantFormatOverlayLoader {
    static func load(sources: [VariantFormatOverlaySource]) async -> VariantFormatOverlaySnapshot {
        var snapshot = VariantFormatOverlaySnapshot()
        for source in sources {
            if Task.isCancelled { return snapshot }
            await load(source: source, into: &snapshot)
        }
        return snapshot
    }

    private static func load(source: VariantFormatOverlaySource, into snapshot: inout VariantFormatOverlaySnapshot) async {
        let total = max(0, source.database.totalCount())
        let records = source.database.queryForTable(limit: total)
        let recordsByID = Dictionary(uniqueKeysWithValues: records.compactMap { record in
            record.id.map { ($0, record) }
        })
        let genotypeMap = source.database.genotypes(forVariantIds: Array(recordsByID.keys))
        let samples = source.database.sampleNames()
        if samples.count == 1, let sample = samples.first {
            snapshot.singleSampleByTrack[source.trackID] = sample
        }

        for (index, pair) in genotypeMap.enumerated() {
            if index.isMultiple(of: 256), Task.isCancelled { return }
            guard let record = recordsByID[pair.key] else { continue }
            for genotype in pair.value {
                let values = fields(from: genotype)
                let key = formatKey(source.trackID, record, genotype.sampleName)
                snapshot.fields[key] = values
            }
        }

        if source.isIVar {
            if let vcfURL = source.vcfURL {
                await recoverLegacyVCF(source: source, url: vcfURL, into: &snapshot)
            } else {
                variantFormatOverlayLogger.warning(
                    "Missing retained VCF URL for iVar track \(source.trackID, privacy: .public); FORMAT measurements remain unavailable"
                )
            }
        }
        snapshot.projectedKeysByTrack[source.trackID] = projectedKeys(trackID: source.trackID, snapshot: snapshot)
        if snapshot.projectedKeysByTrack[source.trackID]?.isEmpty == true {
            snapshot.projectedKeysByTrack.removeValue(forKey: source.trackID)
        }
    }

    private static func recoverLegacyVCF(
        source: VariantFormatOverlaySource,
        url: URL,
        into snapshot: inout VariantFormatOverlaySnapshot
    ) async {
        if let identity = sourceIdentity(trackID: source.trackID, url: url) {
            snapshot.sourceIdentities.insert(identity)
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            variantFormatOverlayLogger.warning(
                "Retained iVar VCF is unavailable for track \(source.trackID, privacy: .public) at \(url.path, privacy: .public)"
            )
            return
        }

        let available = Set(source.database.allChromosomes())
        var recovered: [VariantFormatKey: [String: String]] = [:]
        var ambiguous = Set<VariantFormatKey>()
        do {
            let reader = VCFReader(validateRecords: false, parseGenotypes: true)
            var rowIndex = 0
            for try await variant in reader.variants(from: url) {
                rowIndex += 1
                if rowIndex.isMultiple(of: 256), Task.isCancelled { return }
                guard let chromosome = resolveChromosome(
                    variant.chromosome,
                    available: available,
                    exactGroups: source.aliasesByExactToken,
                    canonicalGroups: source.aliasesByCanonicalToken
                ) else { continue }
                for (sample, genotype) in variant.genotypes {
                    let key = VariantFormatKey(
                        trackID: source.trackID,
                        chromosome: chromosome,
                        position: variant.position - 1,
                        ref: variant.ref,
                        alt: variant.alt.joined(separator: ","),
                        sample: sample
                    )
                    guard !ambiguous.contains(key) else { continue }
                    let values = genotype.fields.filter { VariantFormatOverlaySnapshot.isUsable($0.value) }
                    if let prior = recovered[key], prior != values {
                        recovered.removeValue(forKey: key)
                        ambiguous.insert(key)
                    } else {
                        recovered[key] = values
                    }
                }
            }
        } catch {
            variantFormatOverlayLogger.warning(
                "Could not hydrate iVar FORMAT fields for track \(source.trackID, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return
        }

        for (key, values) in recovered where !ambiguous.contains(key) {
            var merged = snapshot.fields[key] ?? [:]
            for (field, value) in values where merged[field] == nil {
                merged[field] = value
            }
            snapshot.fields[key] = merged
        }
    }

    private static func fields(from genotype: GenotypeRecord) -> [String: String] {
        var values = AnnotationDatabase.parseAttributes(genotype.rawFields ?? "")
        if let genotype = genotype.genotype, VariantFormatOverlaySnapshot.isUsable(genotype) { values["GT"] = genotype }
        if let depth = genotype.depth { values["DP"] = String(depth) }
        if let quality = genotype.genotypeQuality { values["GQ"] = String(quality) }
        if let depths = genotype.alleleDepths, VariantFormatOverlaySnapshot.isUsable(depths) { values["AD"] = depths }
        return values
    }

    private static func formatKey(
        _ trackID: String,
        _ record: VariantDatabaseRecord,
        _ sample: String
    ) -> VariantFormatKey {
        VariantFormatKey(trackID: trackID, chromosome: record.chromosome, position: record.position,
                         ref: record.ref, alt: record.alt, sample: sample)
    }

    private static func projectedKeys(trackID: String, snapshot: VariantFormatOverlaySnapshot) -> Set<String> {
        guard let sample = snapshot.singleSampleByTrack[trackID] else { return [] }
        var keys = Set<String>()
        for (key, values) in snapshot.fields where key.trackID == trackID && key.sample == sample {
            if let dp = values["DP"], VariantFormatOverlaySnapshot.isUsable(dp) { keys.insert("DP") }
            for field in VariantFormatOverlaySnapshot.projectableOriginalKeys {
                if let value = values[field], VariantFormatOverlaySnapshot.isUsable(value) { keys.insert(field) }
            }
            if let raw = values["ALT_FREQ"], let value = Double(raw), value.isFinite, (0...1).contains(value) {
                keys.insert("AF")
            }
        }
        return keys
    }

    private static func resolveChromosome(
        _ chromosome: String,
        available: Set<String>,
        exactGroups: [String: Set<String>],
        canonicalGroups: [String: Set<String>]
    ) -> String? {
        if available.contains(chromosome) { return chromosome }
        let exact = exactGroups[chromosome.lowercased()] ?? []
        let canonical = canonicalGroups[canonicalVariantChromosomeLookupKey(chromosome)] ?? []
        let matches = available.intersection(exact.union(canonical))
        if matches.count == 1 { return matches.first }
        let canonicalMatches = available.filter {
            canonicalVariantChromosomeLookupKey($0) == canonicalVariantChromosomeLookupKey(chromosome)
        }
        return canonicalMatches.count == 1 ? canonicalMatches.first : nil
    }

    private static func sourceIdentity(trackID: String, url: URL) -> VariantFormatSourceIdentity? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value
        let date = attributes?[.modificationDate] as? Date
        return VariantFormatSourceIdentity(trackID: trackID, url: url.standardizedFileURL,
                                           fileSize: size, modificationDate: date)
    }
}
