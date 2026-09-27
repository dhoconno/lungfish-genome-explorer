import Foundation
import LungfishIO

/// Adds a panel of exclusion sequences onto an existing target alignment with
/// the managed MAFFT, so both roles share one coordinate system.
///
/// `--add` with `--keeplength` is what makes the result usable: the target
/// columns are preserved exactly, so every position the report prints still
/// refers to the same template coordinate the caller started from. Without
/// `--keeplength` MAFFT may insert columns for the added sequences and silently
/// shift every target coordinate.
public enum DiscriminatingSitesExclusionAligner {
    public struct Result: Sendable, Equatable {
        /// The exclusion rows, aligned to the target alignment's width.
        public let rows: [DiscriminatingSitesAnalysis.Row]
        /// The MAFFT command, for provenance.
        public let command: String

        public init(rows: [DiscriminatingSitesAnalysis.Row], command: String) {
            self.rows = rows
            self.command = command
        }
    }

    public enum Failure: Error, LocalizedError, Equatable, Sendable {
        case noExclusionSequences(String)
        case widthChanged(expected: Int, actual: Int)
        case missingRows(expected: Int, actual: Int)
        case executableMissing(String)
        case failed(Int32, String)

        public var errorDescription: String? {
            switch self {
            case .noExclusionSequences(let path):
                "No exclusion sequences were read from \(path)."
            case .widthChanged(let expected, let actual):
                "MAFFT --add changed the alignment width from \(expected) to \(actual) columns, so target coordinates would no longer line up."
            case .missingRows(let expected, let actual):
                "MAFFT --add returned \(actual) rows where \(expected) were expected."
            case .executableMissing(let path):
                "The managed MAFFT executable is missing at \(path)."
            case .failed(let status, let detail):
                "MAFFT --add exited with status \(status): \(detail)"
            }
        }
    }

    /// MAFFT arguments this analysis pins. `--keeplength` is not optional here:
    /// it is what keeps the reported coordinates meaningful.
    public static func arguments(exclusionsPath: String, targetAlignmentPath: String) -> [String] {
        ["--quiet", "--keeplength", "--add", exclusionsPath, targetAlignmentPath]
    }

    /// Splits a combined `--add` result back into its target and exclusion rows
    /// and checks that the target geometry survived.
    ///
    /// MAFFT echoes the target alignment first, in order, then the added rows,
    /// so the split is positional.
    public static func split(
        combined: [DiscriminatingSitesAnalysis.Row],
        targetCount: Int,
        expectedWidth: Int
    ) throws -> [DiscriminatingSitesAnalysis.Row] {
        guard combined.count > targetCount else {
            throw Failure.missingRows(expected: targetCount + 1, actual: combined.count)
        }
        if let width = combined.first?.sequence.count, width != expectedWidth {
            throw Failure.widthChanged(expected: expectedWidth, actual: width)
        }
        return Array(combined.dropFirst(targetCount))
    }
}
