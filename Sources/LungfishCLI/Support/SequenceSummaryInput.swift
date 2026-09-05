import Foundation
import LungfishCore
import LungfishIO

/// Streams independent records for CLI summaries; never concatenates the dataset.
enum SequenceSummaryInput {
    static func forEachRecord(
        at url: URL,
        alphabet: SequenceAlphabet? = nil,
        _ consume: (Sequence) throws -> Void
    ) async throws {
        let detectionURL = url.pathExtension.lowercased() == "gz" ? url.deletingPathExtension() : url
        switch detectionURL.pathExtension.lowercased() {
        case "fa", "fasta", "fna", "faa":
            try FASTAReader(url: url).forEachSequenceSync(alphabet: alphabet) { sequence in
                try Task.checkCancellation()
                try consume(sequence)
            }
        case "fastq", "fq":
            for try await record in FASTQReader().records(from: url) {
                try Task.checkCancellation()
                try consume(Sequence(
                    name: record.identifier, description: record.description,
                    alphabet: alphabet ?? .dna, bases: record.sequence
                ))
            }
        case "gb", "gbk", "genbank":
            let reader = try GenBankReader(url: url)
            for try await record in reader.records() {
                try Task.checkCancellation()
                try consume(record.sequence)
            }
        default:
            throw CLIError.formatDetectionFailed(path: url.path)
        }
        try Task.checkCancellation()
    }
}
