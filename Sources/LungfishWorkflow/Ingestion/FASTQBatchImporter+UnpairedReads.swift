// FASTQBatchImporter+UnpairedReads.swift - A run's reads without a mate import beside its pairs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

/// ENA's mirror and the SRA Toolkit name a run's files `<run>_1`, `<run>_2`
/// and `<run>`, and the third file holds the spots whose mate is missing.
/// `import fastq` imports the three as one sample, the pairs as pairs and
/// the third file's reads as unpaired reads, in the one-file mixed form a
/// merge recipe writes (row L3 of docs/contracts/READ-PAIRING.md). The
/// window imports an SRA run through this command, so both keep every read.
/// The file names propose the join, and the first reads of the three files
/// decide it (``checkingUnpairedReads(_:)``).
extension FASTQBatchImporter {

    // MARK: - Detection

    /// A file's folder and a name, which detection pairs mates and joins a
    /// run's third file by. A mate pairs only with a file of its own folder,
    /// as `import fastq <folder> --recursive` groups them, so a list of two
    /// folders' files that share names, the Import Center's flattened scan
    /// or explicit files, never pairs one folder's R1 with the other's R2
    /// (review B-S1).
    struct FolderName: Hashable {
        let folder: String
        let name: String

        init(of file: URL, _ name: String) {
            folder = file.deletingLastPathComponent().standardizedFileURL.path
            self.name = name
        }
    }

    /// Joins each run's file of reads without a mate to the pair detected
    /// from `<run>_1` and `<run>_2` of the same folder, by file name.
    ///
    /// That file used to import as a second sample of the same name, which
    /// found the pair's bundle and was skipped, so the bundle held part of
    /// the run. A bare file beside an `_R1` and `_R2` pair, a BAM, and a name
    /// two bare files share keep their own samples. A name proves nothing
    /// about the reads, so ``checkingUnpairedReads(_:)`` keeps a join only
    /// when the first reads bear it out.
    static func joiningUnpairedReads(_ samples: [SamplePair]) -> [SamplePair] {
        let singles = Dictionary(
            grouping: samples.filter { $0.r2 == nil && !SequencingReadImportSource.isBAM($0.r1) },
            by: { FolderName(of: $0.r1, $0.sampleName) }
        )
        var joinedFiles: Set<URL> = []
        let joined = samples.map { sample -> SamplePair in
            guard let r2 = sample.r2, sample.unpaired == nil,
                  !SequencingReadImportSource.isBAM(sample.r1),
                  fastqStem(sample.r1) == "\(sample.sampleName)_1",
                  fastqStem(r2) == "\(sample.sampleName)_2",
                  let matches = singles[FolderName(of: sample.r1, sample.sampleName)], matches.count == 1 else {
                return sample
            }
            joinedFiles.insert(matches[0].r1)
            return SamplePair(
                sampleName: sample.sampleName,
                r1: sample.r1,
                r2: r2,
                unpaired: matches[0].r1,
                relativePath: sample.relativePath,
                metadata: sample.metadata,
                sampleSheetURL: sample.sampleSheetURL
            )
        }
        return joined.filter { $0.r2 != nil || !joinedFiles.contains($0.r1) }
    }

    // MARK: - Check

    /// What ``checkingUnpairedReads(_:)`` decided for the detected samples.
    public struct UnpairedReadsCheck: Sendable {
        /// The samples to import. A run whose third file passed keeps it.
        /// Any other run is its pair followed by its third file as a sample
        /// of the same name, the two samples detection gave before the join.
        public let samples: [SamplePair]
        /// A `notice` for each third file left out, naming it and saying why.
        public let warnings: [ImportLogEvent]
    }

    /// Keeps a run's third file joined to its pair only when the first
    /// records show that it holds the run's reads without a mate.
    ///
    /// The first reads of `<run>_1` and `<run>_2` must be mates by
    /// ``FASTQReadLayoutClassifier/areMates(_:_:)``, the rule the join checks
    /// every pair with and the storage step finds pairs by. The third file
    /// must start with a whole record whose read is not of that first
    /// fragment, neither a mate of either read nor a read of the same name,
    /// and no two adjacent reads among its first ``thirdFileReadsChecked``
    /// may be mates, in either order. Mates that `fastq-dump --readids`
    /// names `SRR1.1.1` and `SRR1.1.2` fail the first rule, which made the
    /// join fail the whole sample (finding F9-S1). An interleaved copy of the
    /// pair that starts at its first pair fails the second (F9-N1), and a
    /// copy that starts at any other pair (F10-N1) or with half a pair
    /// (F11-N1) fails the third, because a file of reads whose mate is
    /// missing holds one read of each spot. The join stored either copy
    /// beside the pair. The pair's files are read to their first record and
    /// the third file to its 1,000th at most, plain or gzip. The import
    /// checks every adjacent pair of the third file as it copies it, so a
    /// copy whose mates first meet later fails its sample with the file
    /// named, never stores a read twice.
    ///
    /// The warning says what follows. The third file's sample is skipped
    /// whatever the pair does, so the run's name never holds its reads whose
    /// mate is missing alone (F11-S1, review B-S2). When a mate file has no
    /// whole first record the pair fails too, and the warning never promises
    /// that it imports (F10-N2). For any other reason the pair imports
    /// without the third file, by position as a pair of files always does.
    ///
    /// `import fastq` runs this on the detected samples before it lists
    /// them, so a dry run prints the same warnings as an import.
    public static func checkingUnpairedReads(_ samples: [SamplePair]) -> UnpairedReadsCheck {
        var checked: [SamplePair] = []
        var warnings: [ImportLogEvent] = []
        for sample in samples {
            guard let r2 = sample.r2, let unpaired = sample.unpaired,
                  let reason = reasonNotToJoin(r1: sample.r1, r2: r2, unpaired: unpaired)
            else {
                checked.append(sample)
                continue
            }
            checked.append(SamplePair(
                sampleName: sample.sampleName, r1: sample.r1, r2: r2, relativePath: sample.relativePath,
                metadata: sample.metadata, sampleSheetURL: sample.sampleSheetURL
            ))
            checked.append(SamplePair(sampleName: sample.sampleName, r1: unpaired, r2: nil, relativePath: sample.relativePath))
            let file = unpaired.lastPathComponent
            let outcome: String
            switch reason {
            case .pairFile:
                outcome = "\(file) is a separate sample named \(sample.sampleName), which the import skips whether "
                    + "or not the pair imports."
            case .pairImportsAlone:
                outcome = "The pair imports without it, and \(file) is a separate sample named \(sample.sampleName), "
                    + "which the import skips."
            }
            warnings.append(.notice(
                sample: sample.sampleName,
                message: "\(notJoined(unpaired, to: sample.r1, r2, because: reason.text)). \(outcome)"
            ))
        }
        return UnpairedReadsCheck(samples: checked, warnings: warnings)
    }

    /// One of the first records of a FASTQ file, as far as the check reads it.
    enum FirstRecord: Equatable {
        /// A whole record, by its header line without the `@`, the form the
        /// interleaver compares mate names in.
        case read(String)
        /// The file ends before the record.
        case empty
        case incomplete
        case unreadable

        /// Why `file` keeps the third file out, or nil when it starts with a read.
        func problem(of file: String) -> String? {
            switch self {
            case .read: return nil
            case .empty: return "\(file) holds no reads"
            case .incomplete: return "\(file) does not start with a complete FASTQ record"
            case .unreadable: return "\(file) could not be read"
            }
        }
    }

    /// Reads the first `count` records of a plain or gzip FASTQ with the
    /// interleaver's line reader, four lines a record, and checks each
    /// record's shape as the interleaver checks every record. The list
    /// stops at the first entry that is not a whole read.
    static func firstRecords(of url: URL, upTo count: Int) -> [FirstRecord] {
        guard let reader = try? FASTQRawLineReader(url: url) else { return [.unreadable] }
        defer { reader.close() }
        var records: [FirstRecord] = []
        while records.count < count {
            let record = nextRecord(from: reader)
            records.append(record)
            guard case .read = record else { break }
        }
        return records
    }

    private static func nextRecord(from reader: FASTQRawLineReader) -> FirstRecord {
        do {
            guard let header = try reader.nextLine() else { return .empty }
            guard header.first == UInt8(ascii: "@"),
                  let sequence = try reader.nextLine(),
                  let separator = try reader.nextLine(), separator.first == UInt8(ascii: "+"),
                  let quality = try reader.nextLine(), quality.count == sequence.count
            else { return .incomplete }
            return .read(String(decoding: header.dropFirst(), as: UTF8.self))
        } catch {
            return .unreadable
        }
    }

    /// Why a run's third file is not joined, in words for the user, and
    /// what follows for the pair.
    enum ReasonNotToJoin: Equatable {
        /// `<run>_1` or `<run>_2` has no whole first record. The pair fails
        /// as well, and the third file's own sample is skipped all the same.
        case pairFile(String)
        /// The pair's first reads are not named as mates, or the third file
        /// has no whole first record or looks like a copy of the pair. The
        /// pair imports without the third file, by position as a pair of
        /// files always does, and the third file's own sample is skipped.
        case pairImportsAlone(String)

        var text: String {
            switch self {
            case .pairFile(let text), .pairImportsAlone(let text): return text
            }
        }
    }

    /// The reads of a run's third file that the check compares, adjacent
    /// pair by adjacent pair. The import compares the rest as it copies them.
    static let thirdFileReadsChecked = 1_000

    /// Why a run's third file cannot be taken for the run's reads without a
    /// mate, or nil when it can.
    static func reasonNotToJoin(r1: URL, r2: URL, unpaired: URL) -> ReasonNotToJoin? {
        let first1 = firstRecords(of: r1, upTo: 1)[0]
        guard case .read(let name1) = first1 else { return first1.problem(of: r1.lastPathComponent).map { .pairFile($0) } }
        let first2 = firstRecords(of: r2, upTo: 1)[0]
        guard case .read(let name2) = first2 else { return first2.problem(of: r2.lastPathComponent).map { .pairFile($0) } }
        guard FASTQReadLayoutClassifier.areMates(name1, name2) else {
            return .pairImportsAlone("the names of their first reads, \(readID(name1)) and \(readID(name2)), do not "
                + "mark the two as mates")
        }
        let third = firstRecords(of: unpaired, upTo: thirdFileReadsChecked)
        guard case .read(let name3) = third[0] else { return third[0].problem(of: "it").map { .pairImportsAlone($0) } }
        let isOfFirstFragment = [name1, name2].contains { name in
            FASTQReadLayoutClassifier.areMates(name, name3) || FASTQReadLayoutClassifier.areMates(name3, name)
                || fragmentName(name) == fragmentName(name3)
        }
        guard !isOfFirstFragment else {
            return .pairImportsAlone("its first read, \(readID(name3)), belongs to the same fragment as the pair's "
                + "first reads, so the file looks like a copy of the pair")
        }
        // Only whole records are compared. A file damaged after them joins,
        // and the import fails it and names the file.
        let names = third.compactMap { record -> String? in
            guard case .read(let name) = record else { return nil }
            return name
        }
        for position in names.indices.dropLast() {
            if let reason = oneFragment(names[position], names[position + 1], atRead: position + 1) {
                return .pairImportsAlone(reason)
            }
        }
        return nil
    }

    /// Why two adjacent reads of a run's third file, the `read`th and the
    /// next, show that the file is a copy of the pair, or nil when they are
    /// not mates in either order. A file of reads whose mate is missing
    /// holds one read of each spot, so no two of its reads are mates.
    static func oneFragment(_ name: String, _ next: String, atRead read: Int) -> String? {
        guard FASTQReadLayoutClassifier.areMates(name, next) || FASTQReadLayoutClassifier.areMates(next, name) else {
            return nil
        }
        let which = read == 1 ? "its first two reads" : "its reads \(read) and \(read + 1)"
        return "\(which), \(readID(name)) and \(readID(next)), belong to one fragment, so the file looks like a copy "
            + "of the pair"
    }

    /// The read ID of a header line, the text before its first space or tab.
    static func readID(_ header: String) -> Substring {
        header.prefix { $0 != " " && $0 != "\t" }
    }

    /// The read ID without a `/1` or `/2` mate number, which the two reads
    /// of one fragment share, as do two reads with one read ID.
    static func fragmentName(_ header: String) -> Substring {
        let id = readID(header)
        return id.hasSuffix("/1") || id.hasSuffix("/2") ? id.dropLast(2) : id
    }

    private static func notJoined(_ unpaired: URL, to r1: URL, _ r2: URL, because reason: String) -> String {
        "\(unpaired.lastPathComponent) was not joined to \(r1.lastPathComponent) and \(r2.lastPathComponent) "
            + "as reads whose mate is missing, because \(reason)"
    }

    // MARK: - Import

    /// The one file a sample's pairs and its reads without a mate import as.
    struct UnpairedReadsLayout {
        /// Each R1 record followed by its R2 record, then every read without
        /// a mate, as plain FASTQ in the import workspace.
        let file: URL
        /// The pairs and the reads without a mate that the file holds.
        let counts: RecipeMixedLayoutCounts
        /// The provenance step that wrote the file, with its record counts.
        let step: StepExecution
        /// The reads each input file held, by file name.
        let inputReadCounts: [String: ParameterValue]
    }

    /// Writes a sample's pairs, mate names checked record by record, and
    /// then its reads without a mate into one file in `workspace`. Returns
    /// nil for a sample with no file of unpaired reads.
    ///
    /// This is the read-set resolver's interleave by name, so the ingestion
    /// pipeline stores the file as it stores a merge recipe's mixed output,
    /// and the sidecar records how many reads of each kind it holds. The
    /// files must pass ``checkingUnpairedReads(_:)``, which `import fastq`
    /// runs before the import. A caller that skipped it gets an error that
    /// says why, never a copy of the pair stored as unpaired reads.
    static func writePairsThenUnpairedReads(
        of pair: SamplePair,
        in workspace: URL,
        log: (@Sendable (ImportLogEvent) -> Void)?
    ) async throws -> UnpairedReadsLayout? {
        guard let r2 = pair.r2, let unpaired = pair.unpaired else { return nil }
        let r1 = pair.r1
        let output = workspace.appendingPathComponent("\(pair.sampleName)_pairs_then_unpaired.fastq")
        let startedAt = Date()
        // Cancellation reaches the join, which polls it as it copies
        // (F9 re-review N5).
        let counts = try await FASTQIngestionPipeline.detachedWork {
            if let reason = Self.reasonNotToJoin(r1: r1, r2: r2, unpaired: unpaired) {
                throw UnpairedReadsImportError.notJoinable(Self.notJoined(unpaired, to: r1, r2, because: reason.text))
            }
            FileManager.default.createFile(atPath: output.path, contents: nil)
            let handle = try FileHandle(forWritingTo: output)
            defer { try? handle.close() }
            let pairs = try FASTQPairInterleaver.interleave(r1: r1, r2: r2, to: handle, requireMates: true)
            // Every adjacent pair of the third file is compared as it is
            // copied, past the reads the check compared (F11-N1).
            var previous: (name: String, read: Int)?
            let singles = try FASTQPairInterleaver.copyRecords(of: unpaired, to: handle) { name, read in
                if let previous, let reason = Self.oneFragment(previous.name, name, atRead: previous.read) {
                    throw UnpairedReadsImportError.notJoinable(Self.notJoined(unpaired, to: r1, r2, because: reason))
                }
                previous = (name, read)
            }
            return RecipeMixedLayoutCounts(mergedReads: 0, pairs: pairs.r1Records, unpairedReads: singles)
        }
        let step = try ReadSetStep(
            kind: .interleaveByName,
            inputURLs: [r1, r2, unpaired],
            outputURLs: [output],
            pairCount: counts.pairs,
            singleReadCount: counts.unpairedReads,
            startedAt: startedAt,
            endedAt: Date()
        ).stepExecution(toolVersion: WorkflowRun.currentAppVersion)
        log?(.notice(
            sample: pair.sampleName,
            message: "\(unpaired.lastPathComponent) holds \(counts.unpairedReads) reads whose mate is missing. "
                + "They import as unpaired reads beside the \(counts.pairs) pairs."
        ))
        return UnpairedReadsLayout(
            file: output,
            counts: counts,
            step: step,
            inputReadCounts: [
                r1.lastPathComponent: .integer(counts.pairs),
                r2.lastPathComponent: .integer(counts.pairs),
                unpaired.lastPathComponent: .integer(counts.unpairedReads),
            ]
        )
    }

    /// Why an import refused a sample that holds reads without a mate.
    enum UnpairedReadsImportError: Error, LocalizedError {
        /// The first reads do not bear out the join of the third file. Only
        /// a caller that skipped ``checkingUnpairedReads(_:)`` reaches this.
        case notJoinable(String)
        /// Trim Galore was asked to store the sample.
        case trimGaloreLeavesUnpairedReadsOut(sample: String, file: String)

        var errorDescription: String? {
            switch self {
            case .notJoinable(let reason):
                return "\(reason). Import the pair without it."
            case .trimGaloreLeavesUnpairedReadsOut(let sample, let file):
                return "Trim Galore cannot optimize storage for sample '\(sample)', because \(file) holds reads whose "
                    + "mate is missing, and Trim Galore reads only pairs or only single reads. Choose BBTools "
                    + "clumpify or skip storage optimization to keep every read."
            }
        }
    }

    /// The checks that a sample holding reads without a mate is imported
    /// with every read, run before any work.
    static func validateImportKeepsUnpairedReads(pair: SamplePair, config: ImportConfig) throws {
        try validateRecipeKeepsUnpairedReads(pair: pair, config: config)
        try validateStorageKeepsUnpairedReads(pair: pair, config: config)
    }

    /// A recipe reads pairs or single reads, not both, so a sample that also
    /// holds reads without a mate cannot run one without leaving reads out.
    /// The import refuses it and names the file.
    static func validateRecipeKeepsUnpairedReads(pair: SamplePair, config: ImportConfig) throws {
        guard let unpaired = pair.unpaired,
              let recipe = config.newRecipe?.name ?? config.recipe.flatMap({ $0.steps.isEmpty ? nil : $0.name })
        else { return }
        throw BatchImportError.recipeNotApplicable(
            recipe: recipe,
            sample: pair.sampleName,
            reason: "\(unpaired.lastPathComponent) holds reads whose mate is missing, and a recipe reads only "
                + "pairs or only single reads. Import the run with no recipe to keep every read."
        )
    }

    /// Trim Galore reads pairs or single reads, not both, so it would store
    /// such a sample only by leaving reads out. The import refuses it up
    /// front and names the file, as it refuses a recipe, where the pipeline
    /// refused it only after the join with a message that named neither the
    /// run nor the file (finding F9-N2). `auto` never picks Trim Galore.
    static func validateStorageKeepsUnpairedReads(pair: SamplePair, config: ImportConfig) throws {
        guard let unpaired = pair.unpaired, config.clumpingTool == .trimGalore else { return }
        throw UnpairedReadsImportError.trimGaloreLeavesUnpairedReadsOut(
            sample: pair.sampleName,
            file: unpaired.lastPathComponent
        )
    }

    // MARK: - Provenance

    /// The explicit option a sample with reads without a mate records. Any
    /// other sample records none, so its record reads as it did.
    static func unpairedReadsParameters(of pair: SamplePair) -> [String: ParameterValue] {
        pair.unpaired.map { ["unpaired": .file($0)] } ?? [:]
    }

    /// The files of `files` that went into a bundle, the ones its sidecar
    /// names in `originalFilenames`, in their order. A run's third file that
    /// the check leaves out is a sample of its own, which the pair's bundle
    /// keeps out, so a record that names every file a run staged names a
    /// file the bundle holds no read of (f10-report.md, concern 2). A
    /// sidecar that names no file keeps every file.
    public static func inputFilesKept(of files: [URL], by ingestion: IngestionMetadata?) -> [URL] {
        guard let kept = ingestion?.originalFilenames, !kept.isEmpty else { return files }
        return files.filter { kept.contains($0.lastPathComponent) }
    }

    /// The `--log-dir` entry that names a sample's file of reads without a
    /// mate. Any other sample adds nothing, so its log reads as it did.
    static func unpairedReadsLogEntry(of pair: SamplePair) -> [String: Any] {
        pair.unpaired.map { ["unpaired": $0.lastPathComponent] } ?? [:]
    }
}
