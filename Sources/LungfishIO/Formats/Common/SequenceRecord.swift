import Foundation
import LungfishCore

// MARK: - SequenceRecord Protocol

/// A protocol abstracting over FASTQ and FASTA records.
/// Types conforming to this protocol can be processed by format-agnostic
/// operations (subset, trim, orient, length filter, etc.).
public protocol SequenceRecord: Sendable {
    /// The record identifier (read ID without format-specific prefix like @ or >).
    var identifier: String { get }

    /// The nucleotide sequence.
    var sequence: String { get }

    /// Optional description text from the record header (after the first space).
    var recordDescription: String? { get }

    /// Sequence length in bases.
    var length: Int { get }
}

extension SequenceRecord {
    public var length: Int { sequence.count }
}

// MARK: - Sequence Format

/// Identifies the format of a sequence file.
public enum SequenceFormat: String, Codable, Sendable {
    case fastq
    case fasta

    /// Infers format from a file extension.
    public static func from(pathExtension ext: String) -> SequenceFormat? {
        let lower = ext.lowercased()
        switch lower {
        case "fastq", "fq":
            return .fastq
        case "fasta", "fa", "fna", "fsa":
            return .fasta
        case "gz":
            return nil  // Need to check the pre-gz extension
        default:
            return nil
        }
    }

    /// Infers format from a URL, stripping .gz if present.
    public static func from(url: URL) -> SequenceFormat? {
        var ext = url.pathExtension.lowercased()
        if ext == "gz" {
            ext = url.deletingPathExtension().pathExtension.lowercased()
        }
        return from(pathExtension: ext)
    }

    /// The canonical file extension for this format.
    public var fileExtension: String {
        switch self {
        case .fastq: return "fastq"
        case .fasta: return "fasta"
        }
    }
}

// MARK: - Simple FASTA Record

/// A simple FASTA record for use in derivative operations.
/// For genomic reference FASTA files, the existing `FASTAReader` and
/// bgzip-indexed system is used instead.
public struct SimpleFASTARecord: SequenceRecord, Equatable, Identifiable {
    public var id: String { identifier }
    public let identifier: String
    public let recordDescription: String?
    public let sequence: String

    public init(identifier: String, description: String? = nil, sequence: String) {
        self.identifier = identifier
        self.recordDescription = description
        self.sequence = sequence
    }
}

// MARK: - LungfishCore.Sequence Conformance

extension LungfishCore.Sequence: SequenceRecord {
    public var identifier: String { name }
    public var recordDescription: String? { description }
    public var sequence: String { asString() }
}

// MARK: - FASTA Line Formatting

extension SimpleFASTARecord {
    /// Formats this record as a FASTA entry with wrapped sequence lines.
    public func formatted(lineWidth: Int = 60) -> String {
        var result = ">\(identifier)"
        if let desc = recordDescription {
            result += " \(desc)"
        }
        result += "\n"
        let seq = sequence
        for i in stride(from: 0, to: seq.count, by: lineWidth) {
            let start = seq.index(seq.startIndex, offsetBy: i)
            let end = seq.index(start, offsetBy: min(lineWidth, seq.count - i))
            result += String(seq[start..<end]) + "\n"
        }
        return result
    }
}
