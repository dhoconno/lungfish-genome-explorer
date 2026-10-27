import Foundation
import LungfishCore

/// Utilities for bridging between FASTA and synthetic FASTQ when a downstream
/// execution path still requires FASTQ semantics.
public enum SyntheticFASTQBridge {
    private static let placeholderQualityCharacter = "I"

    /// Converts a FASTA file into a synthetic FASTQ file, preserving record IDs
    /// and sequences while assigning placeholder high-quality scores.
    public static func convertFASTAToFASTQ(
        inputURL: URL,
        outputURL: URL
    ) async throws {
        let reader = try FASTAReader(url: inputURL)
        let writer = FASTQWriter(url: outputURL)
        try writer.open()
        defer { try? writer.close() }

        for try await record in reader.sequences() {
            let quality = String(
                repeating: placeholderQualityCharacter,
                count: record.length
            )
            try writer.write(
                FASTQRecord(
                    identifier: record.name,
                    description: record.description,
                    sequence: record.asString(),
                    qualityString: quality
                )
            )
        }
    }

    /// Drops quality scores from FASTQ and writes a FASTA file.
    public static func convertFASTQToFASTA(
        inputURL: URL,
        outputURL: URL
    ) async throws {
        let reader = FASTQReader(validateSequence: false)
        let writer = FASTAWriter(url: outputURL)
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        for try await record in reader.records(from: inputURL) {
            try writer.append(
                Sequence(
                    name: record.identifier,
                    description: record.description,
                    alphabet: .dna,
                    bases: record.sequence
                )
            )
        }
    }

    /// Measures the records of a FASTQ file whose scores are synthetic. Counts, lengths and GC are measured, and
    /// the synthetic scores are dropped, so the score fields are 0 and the score histogram is empty (walk WF-8).
    public static func placeholderStatistics(fromFASTQ inputURL: URL) async throws -> FASTQDatasetStatistics {
        let reader = FASTQReader(validateSequence: false)
        let (stats, _) = try await reader.computeStatistics(from: inputURL, sampleLimit: 0)
        return stats.withoutQualities
    }
}
