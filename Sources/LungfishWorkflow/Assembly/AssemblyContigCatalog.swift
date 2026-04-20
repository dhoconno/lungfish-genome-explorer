// AssemblyContigCatalog.swift - Indexed contig catalog for managed assemblies
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

public struct AssemblyContigRecord: Sendable, Equatable {
    public let rank: Int
    public let name: String
    public let header: String
    public let lengthBP: Int64
    public let gcPercent: Double
    public let shareOfAssemblyPercent: Double
}

public struct AssemblyContigSelectionSummary: Sendable, Equatable {
    public let selectedContigCount: Int
    public let totalSelectedBP: Int64
    public let longestContigBP: Int64
    public let shortestContigBP: Int64
    public let lengthWeightedGCPercent: Double
}

public struct AssemblyContigCatalog: Sendable {
    private struct ContigMetadata: Sendable {
        let order: Int
        let name: String
        let header: String
        let lengthBP: Int64
        let gcBases: Int64
        let gcPercent: Double
        let shareOfAssemblyPercent: Double
    }

    private let reader: IndexedFASTAReader
    private let contigsByName: [String: ContigMetadata]
    private let rankedRecords: [AssemblyContigRecord]

    public init(result: AssemblyResult) async throws {
        self.reader = try IndexedFASTAReader(url: result.contigsPath)
        try Self.validateUniqueSequenceNames(reader.sequenceNames)

        let headersByName = try Self.parseHeaders(from: result.contigsPath)
        var contigs: [ContigMetadata] = []
        contigs.reserveCapacity(reader.sequenceNames.count)

        for (order, name) in reader.sequenceNames.enumerated() {
            guard let entry = reader.index.entry(for: name) else {
                throw AssemblyContigCatalogError.contigNotFound(name)
            }
            guard let header = headersByName[name] else {
                throw AssemblyContigCatalogError.contigNotFound(name)
            }
            let lengthBP = Int64(entry.length)
            let gcBases: Int64
            if lengthBP == 0 {
                gcBases = 0
            } else {
                let sequence = try await reader.fetchSequence(name: name)
                gcBases = Int64(Self.gcBaseCount(in: sequence.asString()))
            }
            contigs.append(
                ContigMetadata(
                    order: order,
                    name: name,
                    header: header,
                    lengthBP: lengthBP,
                    gcBases: gcBases,
                    gcPercent: Self.gcPercent(gcBases: gcBases, totalBases: lengthBP),
                    shareOfAssemblyPercent: Self.shareOfAssemblyPercent(
                        lengthBP: lengthBP,
                        totalAssemblyBP: result.statistics.totalLengthBP
                    )
                )
            )
        }

        var contigsByName: [String: ContigMetadata] = [:]
        contigsByName.reserveCapacity(contigs.count)
        for contig in contigs {
            if contigsByName[contig.name] != nil {
                throw AssemblyContigCatalogError.duplicateContigName(contig.name)
            }
            contigsByName[contig.name] = contig
        }
        self.contigsByName = contigsByName
        let ranked = contigs.sorted {
            if $0.lengthBP != $1.lengthBP {
                return $0.lengthBP > $1.lengthBP
            }
            return $0.order < $1.order
        }
        self.rankedRecords = ranked.enumerated().map { index, contig in
            AssemblyContigRecord(
                rank: index + 1,
                name: contig.name,
                header: contig.header,
                lengthBP: contig.lengthBP,
                gcPercent: contig.gcPercent,
                shareOfAssemblyPercent: contig.shareOfAssemblyPercent
            )
        }
    }

    public func records() async throws -> [AssemblyContigRecord] {
        rankedRecords
    }

    public func sequenceFASTA(for contigName: String, lineWidth: Int = 60) async throws -> String {
        guard let contig = contigsByName[contigName] else {
            throw AssemblyContigCatalogError.contigNotFound(contigName)
        }
        if contig.lengthBP == 0 {
            return Self.formatFASTA(header: contig.header, sequence: "", lineWidth: lineWidth)
        }

        let sequence = try await reader.fetchSequence(name: contig.name)
        return Self.formatFASTA(header: contig.header, sequence: sequence.asString(), lineWidth: lineWidth)
    }

    public func sequenceFASTAs(for contigNames: [String], lineWidth: Int = 60) async throws -> [String] {
        var outputs: [String] = []
        outputs.reserveCapacity(contigNames.count)
        for name in contigNames {
            outputs.append(try await sequenceFASTA(for: name, lineWidth: lineWidth))
        }
        return outputs
    }

    public func selectionSummary(for contigNames: [String]) async throws -> AssemblyContigSelectionSummary {
        guard !contigNames.isEmpty else {
            return AssemblyContigSelectionSummary(
                selectedContigCount: 0,
                totalSelectedBP: 0,
                longestContigBP: 0,
                shortestContigBP: 0,
                lengthWeightedGCPercent: 0
            )
        }

        var totalSelectedBP: Int64 = 0
        var gcBases: Int64 = 0
        var longestContigBP: Int64 = 0
        var shortestContigBP: Int64?

        for name in contigNames {
            guard let contig = contigsByName[name] else {
                throw AssemblyContigCatalogError.contigNotFound(name)
            }

            totalSelectedBP += contig.lengthBP
            gcBases += contig.gcBases
            longestContigBP = max(longestContigBP, contig.lengthBP)
            shortestContigBP = min(shortestContigBP ?? contig.lengthBP, contig.lengthBP)
        }

        let lengthWeightedGCPercent = totalSelectedBP > 0
            ? (Double(gcBases) / Double(totalSelectedBP)) * 100.0
            : 0

        return AssemblyContigSelectionSummary(
            selectedContigCount: contigNames.count,
            totalSelectedBP: totalSelectedBP,
            longestContigBP: longestContigBP,
            shortestContigBP: shortestContigBP ?? 0,
            lengthWeightedGCPercent: lengthWeightedGCPercent
        )
    }

    static func parseHeaders(from fastaURL: URL) throws -> [String: String] {
        let handle = try FileHandle(forReadingFrom: fastaURL)
        defer { try? handle.close() }

        let bufferSize = 256 * 1024
        var bufferedData = Data()
        var headersByName: [String: String] = [:]

        while true {
            guard let chunk = try handle.read(upToCount: bufferSize) else { break }
            if chunk.isEmpty { break }

            bufferedData.append(chunk)
            var lineStartIndex = bufferedData.startIndex

            while let newlineIndex = bufferedData[lineStartIndex...].firstIndex(of: 0x0A) {
                try registerHeaderIfNeeded(
                    from: bufferedData.subdata(in: lineStartIndex..<newlineIndex),
                    headersByName: &headersByName
                )
                lineStartIndex = bufferedData.index(after: newlineIndex)
            }

            if lineStartIndex > bufferedData.startIndex {
                bufferedData.removeSubrange(bufferedData.startIndex..<lineStartIndex)
            }
        }

        if !bufferedData.isEmpty {
            try registerHeaderIfNeeded(from: bufferedData, headersByName: &headersByName)
        }

        return headersByName
    }

    private static func registerHeaderIfNeeded(
        from lineData: Data,
        headersByName: inout [String: String]
    ) throws {
        guard var line = String(data: lineData, encoding: .utf8) else {
            throw AssemblyContigCatalogError.invalidEncoding
        }
        if line.hasSuffix("\r") {
            line.removeLast()
        }

        guard line.hasPrefix(">") else { return }

        let header = String(line.dropFirst())
        let keys = headerLookupKeys(for: header)
        guard let primaryKey = keys.first else {
            throw AssemblyContigCatalogError.invalidHeader(header)
        }

        headersByName[primaryKey] = header
        for aliasKey in keys.dropFirst() where headersByName[aliasKey] == nil {
            headersByName[aliasKey] = header
        }
    }

    private static func headerLookupKeys(for header: String) -> [String] {
        guard let spaceToken = header.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init),
              !spaceToken.isEmpty else {
            return []
        }

        if let tabToken = spaceToken.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init),
           !tabToken.isEmpty,
           tabToken != spaceToken {
            return [spaceToken, tabToken]
        }

        return [spaceToken]
    }

    private static func validateUniqueSequenceNames(_ names: [String]) throws {
        var seen: Set<String> = []
        seen.reserveCapacity(names.count)

        for name in names {
            if !seen.insert(name).inserted {
                throw AssemblyContigCatalogError.duplicateContigName(name)
            }
        }
    }

    private static func gcPercent(gcBases: Int64, totalBases: Int64) -> Double {
        guard totalBases > 0 else { return 0 }
        return (Double(gcBases) / Double(totalBases)) * 100.0
    }

    private static func gcBaseCount(in bases: String) -> Int {
        var gcBases = 0
        for character in bases {
            switch character {
            case "G", "g", "C", "c":
                gcBases += 1
            default:
                break
            }
        }
        return gcBases
    }

    private static func shareOfAssemblyPercent(lengthBP: Int64, totalAssemblyBP: Int64) -> Double {
        guard totalAssemblyBP > 0 else { return 0 }
        return (Double(lengthBP) / Double(totalAssemblyBP)) * 100.0
    }

    private static func formatFASTA(header: String, sequence: String, lineWidth: Int) -> String {
        var output = ">\(header)\n"
        guard !sequence.isEmpty else { return output }
        guard lineWidth > 0 else {
            output += sequence + "\n"
            return output
        }

        var index = sequence.startIndex
        while index < sequence.endIndex {
            let endIndex = sequence.index(index, offsetBy: lineWidth, limitedBy: sequence.endIndex) ?? sequence.endIndex
            output += String(sequence[index..<endIndex]) + "\n"
            index = endIndex
        }
        return output
    }
}

private enum AssemblyContigCatalogError: Error, LocalizedError {
    case contigNotFound(String)
    case duplicateContigName(String)
    case invalidHeader(String)
    case invalidEncoding

    var errorDescription: String? {
        switch self {
        case .contigNotFound(let name):
            return "Contig not found: \(name)"
        case .duplicateContigName(let name):
            return "Duplicate contig name in FASTA index: \(name)"
        case .invalidHeader(let header):
            return "Invalid FASTA header: \(header)"
        case .invalidEncoding:
            return "Assembly contig FASTA has invalid encoding (expected UTF-8)"
        }
    }
}
