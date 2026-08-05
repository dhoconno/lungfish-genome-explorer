import Foundation
import LungfishIO

public struct SavontClusterSummary: Sendable, Codable, Equatable {
    public let clusterCount: Int
    public let totalSupportingReads: Int

    public init(clusterCount: Int, totalSupportingReads: Int) {
        self.clusterCount = clusterCount
        self.totalSupportingReads = totalSupportingReads
    }
}

public enum SavontClusterFASTAError: Error, LocalizedError, Equatable {
    case sequenceBeforeFirstHeader(line: Int)
    case emptyIdentifier(line: Int)
    case duplicateIdentifier(String)
    case emptySequence(String)
    case missingSupportingReadCount(String)
    case malformedSupportingReadCount(String)
    case multipleSupportingReadCounts(String)
    case supportingReadCountOverflow(String)
    case totalSupportingReadsOverflow

    public var errorDescription: String? {
        switch self {
        case .sequenceBeforeFirstHeader(let line):
            "Sequence data appears before the first FASTA header at line \(line)."
        case .emptyIdentifier(let line):
            "The FASTA header at line \(line) has no identifier."
        case .duplicateIdentifier(let identifier):
            "The Savont FASTA contains duplicate identifier '\(identifier)'."
        case .emptySequence(let identifier):
            "The Savont FASTA record '\(identifier)' has an empty sequence."
        case .missingSupportingReadCount(let identifier):
            "The Savont FASTA record '\(identifier)' has no ReadCount or depth field."
        case .malformedSupportingReadCount(let identifier):
            "The Savont FASTA record '\(identifier)' has a malformed supporting-read count."
        case .multipleSupportingReadCounts(let identifier):
            "The Savont FASTA record '\(identifier)' has multiple supporting-read count fields."
        case .supportingReadCountOverflow(let identifier):
            "The supporting-read count for Savont FASTA record '\(identifier)' exceeds the supported integer range."
        case .totalSupportingReadsOverflow:
            "The total supporting-read count exceeds the supported integer range."
        }
    }
}

public enum SavontClusterFASTA {
    public static func normalize(
        sourceURL: URL,
        destinationURL: URL
    ) throws -> SavontClusterSummary {
        let fileManager = FileManager.default
        let stagingURL = destinationURL.deletingLastPathComponent().appendingPathComponent(
            ".\(destinationURL.lastPathComponent).savont-normalizing-\(UUID().uuidString)"
        )
        var stagingExists = true
        defer {
            if stagingExists {
                try? fileManager.removeItem(at: stagingURL)
            }
        }
        try Data().write(to: stagingURL, options: .atomic)
        let outputHandle = try FileHandle(forWritingTo: stagingURL)
        var outputIsClosed = false
        defer {
            if !outputIsClosed {
                try? outputHandle.close()
            }
        }

        var currentIdentifier: String?
        var currentNormalizedIdentifier: String?
        var currentSupportingReads: Int?
        var currentSequence = ""
        var seenIdentifiers: Set<String> = []
        var clusterCount = 0
        var totalSupportingReads = 0
        var lineNumber = 0

        func finishCurrentRecord() throws {
            guard let identifier = currentIdentifier,
                  let normalizedIdentifier = currentNormalizedIdentifier,
                  let supportingReads = currentSupportingReads else {
                return
            }
            guard !currentSequence.isEmpty else {
                throw SavontClusterFASTAError.emptySequence(identifier)
            }
            let (nextTotal, totalOverflow) = totalSupportingReads.addingReportingOverflow(supportingReads)
            guard !totalOverflow else {
                throw SavontClusterFASTAError.totalSupportingReadsOverflow
            }
            let (nextClusterCount, clusterOverflow) = clusterCount.addingReportingOverflow(1)
            guard !clusterOverflow else {
                throw SavontClusterFASTAError.totalSupportingReadsOverflow
            }

            let record = ">\(normalizedIdentifier)\n\(currentSequence)\n"
            try outputHandle.write(contentsOf: Data(record.utf8))
            clusterCount = nextClusterCount
            totalSupportingReads = nextTotal
        }

        try sourceURL.forEachLineAutoDecompressing { line in
            lineNumber += 1
            if line.hasPrefix(">") {
                try finishCurrentRecord()

                let rawHeader = line.dropFirst()
                guard let identifierSubstring = rawHeader.split(whereSeparator: \.isWhitespace).first else {
                    throw SavontClusterFASTAError.emptyIdentifier(line: lineNumber)
                }
                let identifier = String(identifierSubstring)
                let parsed = try normalizedIdentifierAndCount(for: identifier)
                guard seenIdentifiers.insert(parsed.identifier).inserted else {
                    throw SavontClusterFASTAError.duplicateIdentifier(parsed.identifier)
                }

                currentIdentifier = identifier
                currentNormalizedIdentifier = parsed.identifier
                currentSupportingReads = parsed.count
                currentSequence = ""
            } else if currentIdentifier == nil {
                guard line.isEmpty else {
                    throw SavontClusterFASTAError.sequenceBeforeFirstHeader(line: lineNumber)
                }
            } else {
                currentSequence += line
            }
        }
        try finishCurrentRecord()
        try outputHandle.synchronize()
        try outputHandle.close()
        outputIsClosed = true

        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: stagingURL)
        } else {
            try fileManager.moveItem(at: stagingURL, to: destinationURL)
        }
        stagingExists = false

        return SavontClusterSummary(
            clusterCount: clusterCount,
            totalSupportingReads: totalSupportingReads
        )
    }

    private static func normalizedIdentifierAndCount(
        for identifier: String
    ) throws -> (identifier: String, count: Int) {
        let readCountOccurrences = occurrenceCount(of: "ReadCount", in: identifier)
        if readCountOccurrences > 1 {
            throw SavontClusterFASTAError.multipleSupportingReadCounts(identifier)
        }
        if readCountOccurrences == 1 {
            let count = try parseCount(
                in: identifier,
                marker: "ReadCount-",
                requiresLeadingUnderscore: true
            )
            return (identifier, count)
        }

        let depthOccurrences = occurrenceCount(of: "_depth_", in: identifier)
        guard depthOccurrences > 0 else {
            throw SavontClusterFASTAError.missingSupportingReadCount(identifier)
        }
        guard depthOccurrences == 1 else {
            throw SavontClusterFASTAError.multipleSupportingReadCounts(identifier)
        }
        let count = try parseCount(
            in: identifier,
            marker: "_depth_",
            requiresLeadingUnderscore: false
        )
        return ("\(identifier)_ReadCount-\(count)", count)
    }

    private static func parseCount(
        in identifier: String,
        marker: String,
        requiresLeadingUnderscore: Bool
    ) throws -> Int {
        guard let markerRange = identifier.range(of: marker) else {
            throw SavontClusterFASTAError.malformedSupportingReadCount(identifier)
        }
        if requiresLeadingUnderscore,
           markerRange.lowerBound != identifier.startIndex,
           identifier[identifier.index(before: markerRange.lowerBound)] != "_" {
            throw SavontClusterFASTAError.malformedSupportingReadCount(identifier)
        }

        let suffix = identifier[markerRange.upperBound...]
        let digits = suffix.prefix(while: \.isNumber)
        guard !digits.isEmpty else {
            throw SavontClusterFASTAError.malformedSupportingReadCount(identifier)
        }
        if digits.endIndex != suffix.endIndex, suffix[digits.endIndex] != "_" {
            throw SavontClusterFASTAError.malformedSupportingReadCount(identifier)
        }
        guard let count = Int(digits) else {
            throw SavontClusterFASTAError.supportingReadCountOverflow(identifier)
        }
        return count
    }

    private static func occurrenceCount(of needle: String, in value: String) -> Int {
        var count = 0
        var searchRange = value.startIndex..<value.endIndex
        while let range = value.range(of: needle, range: searchRange) {
            count += 1
            searchRange = range.upperBound..<value.endIndex
        }
        return count
    }
}
