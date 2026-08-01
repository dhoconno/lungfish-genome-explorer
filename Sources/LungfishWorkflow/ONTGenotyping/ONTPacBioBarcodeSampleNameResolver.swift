import Foundation
import LungfishIO

public struct ONTPacBioBarcodeSheetAssignment: Sendable, Equatable {
    public let sourceRow: Int
    public let assignment: FASTQSampleBarcodeAssignment

    public init(sourceRow: Int, assignment: FASTQSampleBarcodeAssignment) {
        self.sourceRow = sourceRow
        self.assignment = assignment
    }
}

public struct ONTPacBioResolvedBarcodeAssignment: Sendable, Equatable {
    public let sourceRow: Int
    public let originalSampleID: String
    public let resolvedSampleID: String
    public let assignment: FASTQSampleBarcodeAssignment

    public init(
        sourceRow: Int,
        originalSampleID: String,
        resolvedSampleID: String,
        assignment: FASTQSampleBarcodeAssignment
    ) {
        self.sourceRow = sourceRow
        self.originalSampleID = originalSampleID
        self.resolvedSampleID = resolvedSampleID
        self.assignment = assignment
    }

    var manifestItem: [String: Any] {
        [
            "sourceRow": sourceRow,
            "originalSampleID": originalSampleID,
            "resolvedSampleID": resolvedSampleID,
            "barcode_1": assignment.forwardBarcodeID as Any,
            "barcode_2": assignment.reverseBarcodeID as Any,
        ]
    }
}

public enum ONTPacBioBarcodeSampleNameResolverError: LocalizedError, Sendable, Equatable {
    case outputNameCollision(name: String, firstRow: Int, secondRow: Int)

    public var errorDescription: String? {
        switch self {
        case .outputNameCollision(let name, let firstRow, let secondRow):
            return "Resolved output sample name '\(name)' would be used by rows \(firstRow) and \(secondRow). Rename one of those samples in the barcode sheet."
        }
    }
}

public enum ONTPacBioBarcodeSampleNameResolver {
    public static func resolve(
        _ rows: [ONTPacBioBarcodeSheetAssignment]
    ) throws -> [ONTPacBioResolvedBarcodeAssignment] {
        let normalizedNames = rows.map { sanitizedSampleIdentifier($0.assignment.sampleID) }
        let groupCounts = Dictionary(grouping: normalizedNames, by: comparisonKey)
            .mapValues(\.count)
        var groupOrdinals: [String: Int] = [:]

        let resolved = zip(rows, normalizedNames).map { row, normalizedName in
            let key = comparisonKey(normalizedName)
            let outputName: String
            if groupCounts[key, default: 0] > 1 {
                let ordinal = groupOrdinals[key, default: 0] + 1
                groupOrdinals[key] = ordinal
                outputName = "\(normalizedName)_\(ordinal)"
            } else {
                outputName = normalizedName
            }
            return ONTPacBioResolvedBarcodeAssignment(
                sourceRow: row.sourceRow,
                originalSampleID: row.assignment.sampleID,
                resolvedSampleID: outputName,
                assignment: row.assignment
            )
        }

        var firstAssignmentByOutputName: [String: ONTPacBioResolvedBarcodeAssignment] = [:]
        for assignment in resolved {
            let key = comparisonKey(assignment.resolvedSampleID)
            if let first = firstAssignmentByOutputName[key] {
                throw ONTPacBioBarcodeSampleNameResolverError.outputNameCollision(
                    name: assignment.resolvedSampleID,
                    firstRow: first.sourceRow,
                    secondRow: assignment.sourceRow
                )
            }
            firstAssignmentByOutputName[key] = assignment
        }
        return resolved
    }

    public static func sanitizedSampleIdentifier(_ sampleID: String) -> String {
        let trimmed = sampleID.trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitized = trimmed
            .replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
        return sanitized.isEmpty ? "sample" : sanitized
    }

    private static func comparisonKey(_ name: String) -> String {
        name.lowercased()
    }
}
