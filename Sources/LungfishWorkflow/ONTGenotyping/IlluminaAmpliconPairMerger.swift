import Foundation
import LungfishCore
import LungfishIO

/// Merges overlapping Illumina read pairs before amplicon genotyping.
///
/// # Why this exists
///
/// The genotyping filter (`filter-demux-retained-bam.py`) keeps an alignment
/// only when it spans the reference amplicon end to end with zero mismatches
/// (`reference_span_is_full`). That is the Swift/pysam equivalent of the
/// reference notebook's `bbmap semiperfectmode=t`.
///
/// A single MiSeq mate cannot satisfy that requirement for the longer class II
/// amplicons. In the IPD-MHC Mamu reference the class I amplicons are 156 bp and
/// DQB1/DPA1/DPB1/DQA1 are 154-204 bp, but every **DRB** amplicon is 244 bp.
/// With 2x251 chemistry the sequenced insert is typically ~198 bp, so neither
/// mate alone covers a 244 bp reference from position 0 to 244 exactly. The
/// result is that DRB alleles silently receive **zero** reads while every
/// shorter locus genotypes normally.
///
/// The reference notebook avoids this by running `bbmerge` on R1/R2 first and
/// mapping the merged fragment. This type brings that step into the pipeline so
/// unmerged paired input produces the same DRB calls instead of a silent hole.
///
/// # What it does
///
/// For each Illumina sample input it inspects the FASTQ, and if the records look
/// like interleaved (or split R1/R2) pairs it runs `bbmerge.sh`, then feeds the
/// merged fragments to minimap2. Reads that fail to merge are retained as
/// singles so a partially-overlapping library still contributes the mates it
/// can, exactly as `bbmerge`'s `outu` stream allows.
///
/// Input that is already merged (single-end records, no mate pairing) passes
/// through untouched, so pre-merged bundles behave exactly as before.
public enum IlluminaAmpliconPairMerger {

    /// How a sample's reads were prepared for mapping.
    public enum Disposition: String, Sendable {
        /// Records were already single-end/merged; nothing was run.
        case alreadyMerged = "already-merged"
        /// Pairs were detected and merged with bbmerge.
        case merged = "bbmerge-merged"
    }

    /// Outcome of preparing one sample's reads for mapping.
    public struct Outcome: Sendable {
        /// FASTQ that should be handed to minimap2.
        public let mappingFASTQURL: URL
        public let disposition: Disposition
        /// Pairs presented to bbmerge (0 when nothing was merged).
        public let pairCount: Int
        /// Pairs bbmerge joined into a single fragment.
        public let mergedCount: Int
        /// Unmerged mates carried through as singles.
        public let unmergedReadCount: Int
        /// Number of records in `mappingFASTQURL`.
        public let mappingReadCount: Int
        /// `bbmerge.sh` argv, empty when nothing was run.
        public let arguments: [String]
        public let stderr: String

        public var didMerge: Bool { disposition == .merged }
    }

    public enum MergeError: LocalizedError {
        case bbmergeFailed(status: Int32, stderr: String)
        case bbmergeProducedNoReads(stderr: String)

        public var errorDescription: String? {
            switch self {
            case .bbmergeFailed(let status, let stderr):
                return "bbmerge failed with status \(status): \(stderr)"
            case .bbmergeProducedNoReads(let stderr):
                return "bbmerge produced no reads to map: \(stderr)"
            }
        }
    }

    /// Number of leading records sampled when deciding whether a FASTQ is paired.
    static let pairingProbeRecordCount = 400

    // MARK: - Pair detection

    /// Strips the mate suffix from a FASTQ identifier so the two mates of a
    /// fragment compare equal.
    ///
    /// Handles both Casava 1.8+ (`NAME 1:N:0:index`, mate in the description)
    /// and the older `NAME/1` form.
    static func fragmentKey(identifier: String, description: String?) -> String {
        var name = identifier
        if name.count > 2, name.hasSuffix("/1") || name.hasSuffix("/2") {
            name.removeLast(2)
        }
        _ = description
        return name
    }

    /// Returns the mate number (1 or 2) when the record advertises one.
    static func mateNumber(identifier: String, description: String?) -> Int? {
        if identifier.hasSuffix("/1") { return 1 }
        if identifier.hasSuffix("/2") { return 2 }
        guard let description else { return nil }
        let trimmed = description.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return nil }
        // Casava: "1:N:0:148" / "2:N:0:148"
        guard trimmed.dropFirst().first == ":" else { return nil }
        switch first {
        case "1": return 1
        case "2": return 2
        default: return nil
        }
    }

    /// Decides whether a FASTQ holds interleaved read pairs.
    ///
    /// Reads at most `pairingProbeRecordCount` records: paired input shows the
    /// same fragment name on adjacent records with mate numbers 1 then 2.
    /// Single-end or already-merged input does not.
    public static func fastqIsInterleavedPairs(at url: URL) async throws -> Bool {
        let reader = FASTQReader(validateSequence: false)
        var pending: (key: String, mate: Int?)?
        var inspected = 0
        var pairedFragments = 0
        var fragments = 0

        for try await record in reader.records(from: url) {
            let key = fragmentKey(identifier: record.identifier, description: record.description)
            let mate = mateNumber(identifier: record.identifier, description: record.description)
            if let previous = pending {
                fragments += 1
                if previous.key == key, previous.mate == 1, mate == 2 {
                    pairedFragments += 1
                }
                // Consume both records of the candidate fragment so a run of
                // identical identifiers cannot be counted more than once.
                pending = nil
            } else {
                pending = (key, mate)
            }
            inspected += 1
            if inspected >= pairingProbeRecordCount { break }
        }
        guard fragments > 0 else { return false }
        // Require a clear majority of fragments to look paired, so a stray
        // duplicate identifier in single-end data is not mistaken for pairing.
        return pairedFragments * 2 > fragments
    }

    // MARK: - Merging

    /// Prepares one sample's FASTQ for mapping, merging pairs when present.
    ///
    /// - Parameters:
    ///   - fastqURL: the sample's reads.
    ///   - bbmergeURL: path to `bbmerge.sh`.
    ///   - workingDirectory: scratch directory for bbmerge outputs.
    ///   - stem: filename stem for the produced files.
    ///   - threads: bbmerge thread count.
    public static func prepareForMapping(
        fastqURL: URL,
        bbmergeURL: URL,
        workingDirectory: URL,
        stem: String,
        threads: Int
    ) async throws -> Outcome {
        guard try await fastqIsInterleavedPairs(at: fastqURL) else {
            let count = try await countRecords(at: fastqURL)
            return Outcome(
                mappingFASTQURL: fastqURL,
                disposition: .alreadyMerged,
                pairCount: 0,
                mergedCount: 0,
                unmergedReadCount: 0,
                mappingReadCount: count,
                arguments: [],
                stderr: ""
            )
        }

        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let mergedURL = workingDirectory.appendingPathComponent("\(stem).merged.fastq")
        let unmergedURL = workingDirectory.appendingPathComponent("\(stem).unmerged.fastq")
        let stderrURL = workingDirectory.appendingPathComponent("\(stem).bbmerge.stderr.log")

        let arguments = [
            "in=\(fastqURL.path)",
            "out=\(mergedURL.path)",
            "outu=\(unmergedURL.path)",
            "interleaved=t",
            "threads=\(max(1, threads))",
        ]

        let (status, stderr) = try await runBBMerge(
            bbmergeURL: bbmergeURL,
            arguments: arguments,
            stderrURL: stderrURL
        )
        guard status == 0 else {
            throw MergeError.bbmergeFailed(status: status, stderr: stderr)
        }

        let mergedCount = try await countRecordsIfPresent(at: mergedURL)
        let unmergedCount = try await countRecordsIfPresent(at: unmergedURL)

        // Map merged fragments plus any mates bbmerge could not join, so a
        // library with partial overlap still contributes every usable read.
        let mappingURL = workingDirectory.appendingPathComponent("\(stem).for-mapping.fastq")
        let mappingCount = try concatenate(
            sources: [mergedURL, unmergedURL],
            into: mappingURL
        )
        guard mappingCount > 0 else {
            throw MergeError.bbmergeProducedNoReads(stderr: stderr)
        }

        return Outcome(
            mappingFASTQURL: mappingURL,
            disposition: .merged,
            pairCount: mergedCount + (unmergedCount / 2),
            mergedCount: mergedCount,
            unmergedReadCount: unmergedCount,
            mappingReadCount: mappingCount,
            arguments: arguments,
            stderr: stderr
        )
    }

    // MARK: - Support

    private static func runBBMerge(
        bbmergeURL: URL,
        arguments: [String],
        stderrURL: URL
    ) async throws -> (status: Int32, stderr: String) {
        let process = Process()
        process.executableURL = bbmergeURL
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        process.standardError = stderrHandle
        defer { try? stderrHandle.close() }

        try process.run()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                process.waitUntilExit()
                continuation.resume()
            }
        }
        let stderrText = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
        return (process.terminationStatus, stderrText)
    }

    private static func countRecords(at url: URL) async throws -> Int {
        let reader = FASTQReader(validateSequence: false)
        var count = 0
        for try await _ in reader.records(from: url) { count += 1 }
        return count
    }

    private static func countRecordsIfPresent(at url: URL) async throws -> Int {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        return try await countRecords(at: url)
    }

    /// Appends every existing source into `destination`, returning the record count.
    private static func concatenate(sources: [URL], into destination: URL) throws -> Int {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var lineCount = 0
        for source in sources {
            guard FileManager.default.fileExists(atPath: source.path),
                  let input = try? FileHandle(forReadingFrom: source) else { continue }
            defer { try? input.close() }
            while let chunk = try input.read(upToCount: 4 * 1_024 * 1_024), !chunk.isEmpty {
                try handle.write(contentsOf: chunk)
                lineCount += chunk.reduce(0) { $1 == UInt8(ascii: "\n") ? $0 + 1 : $0 }
            }
        }
        return lineCount / 4
    }
}
