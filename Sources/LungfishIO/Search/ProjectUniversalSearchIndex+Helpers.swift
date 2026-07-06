// ProjectUniversalSearchIndex+Helpers.swift - SQLite-backed project-scoped universal search catalog
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import SQLite3
import os.log

extension ProjectUniversalSearchIndex {

    // MARK: - Types

    struct EntityRow {
        let id: String
        let kind: String
        let title: String
        let subtitle: String?
        let format: String?
        let relPath: String
        let url: URL
        let mtime: Double?
        let sizeBytes: Int64?
    }

    struct ClassificationTaxonSeed {
        let source: String
        let name: String
        let taxID: Int
        let rank: String
        let readCount: Int
        let fraction: Double?
    }

    struct TaxTriageOrganismSeed {
        let name: String
        let sampleName: String?
        let taxID: Int?
        let rank: String?
        let readCount: Int
        let uniqueReads: Int?
        let tassScore: Double?
        let confidence: String?
        let coverageBreadth: Double?
        let coverageDepth: Double?
        let abundance: Double?
        let source: String
    }

    // MARK: - Organism Helpers

    func insertOrganismAttributes(
        entityID: String,
        keys: [String],
        name: String,
        includeOriginal: Bool,
        attributeCount: inout Int
    ) throws {
        var values: [String] = includeOriginal ? [name] : []
        values.append(contentsOf: organismAliases(for: name))

        var seen = Set<String>()
        for value in values {
            let normalized = value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }
            for key in keys {
                try insertAttribute(entityID: entityID, key: key, value: value)
                attributeCount += 1
            }
        }
    }

    func organismAliases(for rawName: String) -> [String] {
        let cleaned = OrganismNameNormalizer.clean(rawName)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return [] }

        let normalized = OrganismNameNormalizer.normalizedKey(cleaned)
        guard !normalized.isEmpty else { return [] }

        var aliases = Set<String>()

        if normalized.contains("severe acute respiratory syndrome coronavirus 2")
            || normalized == "sars cov 2"
            || normalized == "sarscov2" {
            aliases.formUnion([
                "SARS-CoV-2",
                "SARS CoV 2",
                "sarscov2",
                "COVID-19",
                "covid19",
                "2019-nCoV",
                "2019 ncov",
            ])
        }

        if normalized.hasPrefix("human coronavirus ") {
            let code = normalized.replacingOccurrences(of: "human coronavirus ", with: "")
                .replacingOccurrences(of: " ", with: "")
                .uppercased()
            if !code.isEmpty, code.count <= 16 {
                aliases.insert(code)
                aliases.insert("HCoV-\(code)")
                aliases.insert("HCoV \(code)")
            }
        }

        switch normalized {
        case "human coronavirus hku1", "hcov hku1", "hku1":
            aliases.formUnion(["HKU1", "HCoV-HKU1", "HCoV HKU1", "Human coronavirus HKU1"])
        case "human coronavirus 229e", "hcov 229e", "229e":
            aliases.formUnion(["229E", "HCoV-229E", "HCoV 229E", "Human coronavirus 229E"])
        case "human coronavirus nl63", "hcov nl63", "nl63":
            aliases.formUnion(["NL63", "HCoV-NL63", "HCoV NL63", "Human coronavirus NL63"])
        default:
            break
        }

        return aliases
            .map { OrganismNameNormalizer.clean($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !OrganismNameNormalizer.normalizedKey($0).isEmpty }
            .filter { OrganismNameNormalizer.normalizedKey($0) != normalized }
            .sorted()
    }

    // MARK: - TaxTriage Helpers

    func collectOutputFiles(in directory: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [URL] = []
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                files.append(url)
            }
        }
        return files
    }

    func parseTaxTriageTopReport(url: URL) -> [TaxTriageOrganismSeed] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }

        let lines = content.components(separatedBy: .newlines)
        guard lines.count > 1 else { return [] }

        var organisms: [TaxTriageOrganismSeed] = []
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let cols = trimmed.components(separatedBy: "\t")
            guard cols.count >= 6 else { continue }

            let abundance = Double(cols[0].replacingOccurrences(of: "%", with: ""))
            let cladeReads = Int(Double(cols[1].replacingOccurrences(of: ",", with: "")) ?? 0)
            let rank = cols[3].trimmingCharacters(in: .whitespacesAndNewlines)
            let taxID = Int(cols[4].trimmingCharacters(in: .whitespacesAndNewlines))
            let name = OrganismNameNormalizer.clean(cols[5])

            organisms.append(
                TaxTriageOrganismSeed(
                    name: name,
                    sampleName: nil,
                    taxID: taxID,
                    rank: rank.isEmpty ? nil : rank,
                    readCount: cladeReads,
                    uniqueReads: nil,
                    tassScore: nil,
                    confidence: nil,
                    coverageBreadth: nil,
                    coverageDepth: nil,
                    abundance: abundance,
                    source: "top_report"
                )
            )
        }

        return organisms
    }

    func isLikelyFoundPathogen(
        tassScore: Double?,
        confidence: String?,
        readCount: Int
    ) -> Bool {
        guard readCount > 0 else { return false }
        if let tassScore, tassScore >= 0.8 {
            return true
        }

        guard let confidence else { return false }
        let normalized = confidence
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized == "high"
            || normalized == "high confidence"
            || normalized == "critical"
    }

    func stableIdentifierComponent(_ value: String) -> String {
        let normalized = OrganismNameNormalizer.normalizedKey(value)
            .replacingOccurrences(of: " ", with: "_")
        if normalized.isEmpty {
            return "unknown"
        }
        return String(normalized.prefix(80))
    }

    // MARK: - Attribute Extraction

    func appendFASTQSampleAttributes(_ metadata: FASTQSampleMetadata, to attrs: inout [String: Any]) {
        attrs["sample_name"] = metadata.sampleName
        attrs["sample_type"] = metadata.sampleType
        attrs["collection_date"] = metadata.collectionDate
        attrs["geo_loc_name"] = metadata.geoLocName
        attrs["host"] = metadata.host
        attrs["host_disease"] = metadata.hostDisease
        attrs["purpose_of_sequencing"] = metadata.purposeOfSequencing
        attrs["sequencing_instrument"] = metadata.sequencingInstrument
        attrs["library_strategy"] = metadata.libraryStrategy
        attrs["sample_collected_by"] = metadata.sampleCollectedBy
        attrs["organism"] = metadata.organism
        attrs["sample_role"] = metadata.sampleRole.rawValue
        attrs["patient_id"] = metadata.patientId
        attrs["run_id"] = metadata.runId
        attrs["batch_id"] = metadata.batchId
        attrs["plate_position"] = metadata.platePosition
        attrs["metadata_template"] = metadata.metadataTemplate?.rawValue
        attrs["notes"] = metadata.notes

        for (key, value) in metadata.customFields {
            attrs[normalizeKey(key)] = value
        }
    }

    func flattenJSONFile(at fileURL: URL) -> [String: String]? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }

        var flattened: [String: String] = [:]
        flattenJSONObject(object, prefix: "", depth: 0, into: &flattened)
        return flattened
    }

    private func flattenJSONObject(_ object: Any, prefix: String, depth: Int, into flattened: inout [String: String]) {
        guard depth <= 8, flattened.count < 2000 else { return }

        switch object {
        case let dict as [String: Any]:
            for key in dict.keys.sorted() {
                guard let value = dict[key] else { continue }
                let fullKey = prefix.isEmpty ? normalizeKey(key) : "\(prefix).\(normalizeKey(key))"
                flattenJSONObject(value, prefix: fullKey, depth: depth + 1, into: &flattened)
            }

        case let array as [Any]:
            if array.allSatisfy({ $0 is String || $0 is NSNumber }) {
                let values = array.compactMap { valueAsString($0) }.joined(separator: ", ")
                if !values.isEmpty {
                    flattened[prefix] = values
                }
            } else {
                for (index, value) in array.enumerated() {
                    let fullKey = "\(prefix)[\(index)]"
                    flattenJSONObject(value, prefix: fullKey, depth: depth + 1, into: &flattened)
                }
            }

        case let number as NSNumber:
            flattened[prefix] = number.stringValue

        case let text as String:
            if !text.isEmpty {
                flattened[prefix] = text
            }

        default:
            if let text = valueAsString(object), !text.isEmpty {
                flattened[prefix] = text
            }
        }
    }

    // MARK: - Utility Helpers

    func pathCompare(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.path.localizedCaseInsensitiveCompare(rhs.path) == .orderedAscending
    }

    static func likeContainsPattern(for literal: String) -> String {
        SQLiteLikePattern.contains(literal)
    }

    static func likePrefixPattern(for literal: String) -> String {
        SQLiteLikePattern.prefix(literal)
    }

    func entityRow(
        id: String,
        kind: String,
        title: String,
        subtitle: String?,
        format: String?,
        url: URL
    ) -> EntityRow {
        let values = resourceValues(for: url)
        return EntityRow(
            id: id,
            kind: kind,
            title: title,
            subtitle: subtitle,
            format: format,
            relPath: relativePath(for: url),
            url: url,
            mtime: values.mtime,
            sizeBytes: values.size
        )
    }

    private func resourceValues(for url: URL) -> (mtime: Double?, size: Int64?) {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else {
            return (nil, nil)
        }
        let mtime = values.contentModificationDate?.timeIntervalSince1970
        let size = values.fileSize.map(Int64.init)
        return (mtime, size)
    }

    func relativePath(for url: URL) -> String {
        let projectPath = projectURL.standardizedFileURL.path
        let absolutePath = url.standardizedFileURL.path
        let rootPrefix = projectPath.hasSuffix("/") ? projectPath : projectPath + "/"

        if absolutePath == projectPath {
            return "."
        }

        if absolutePath.hasPrefix(rootPrefix) {
            return String(absolutePath.dropFirst(rootPrefix.count))
        }

        return absolutePath
    }

    func valueAsString(_ value: Any) -> String? {
        switch value {
        case let text as String:
            return text
        case let bool as Bool:
            return bool ? "true" : "false"
        case let number as NSNumber:
            return number.stringValue
        case let int as Int:
            return String(int)
        case let int64 as Int64:
            return String(int64)
        case let double as Double:
            return String(double)
        case let date as Date:
            let formatter = ISO8601DateFormatter()
            return formatter.string(from: date)
        default:
            return nil
        }
    }

    func parseDateEpochSeconds(_ value: Any) -> Int64? {
        if let date = value as? Date {
            return Int64(date.timeIntervalSince1970)
        }

        guard let text = valueAsString(value)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }

        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: text) {
            return Int64(date.timeIntervalSince1970)
        }

        let dateFormats = ["yyyy-MM-dd", "yyyy-MM", "yyyy"]
        for format in dateFormats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: text) {
                return Int64(date.timeIntervalSince1970)
            }
        }

        return nil
    }

    func normalizeKey(_ key: String) -> String {
        key
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
    }
}
