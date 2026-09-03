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
        /// `bbmerge.sh` argv exactly as executed, empty when nothing was run.
        ///
        /// When the run was staged these hold the temporary paths bbmerge was
        /// actually given, not the project paths. Recording the real argv is
        /// what makes a provenance record reproduce the run; `stagingRoot`
        /// tells a reader why the paths look unfamiliar.
        public let arguments: [String]
        /// Temporary directory the run used, nil when it ran in place.
        ///
        /// Present so provenance can explain argv paths that no longer exist:
        /// the directory is deleted as soon as the merge returns.
        public let stagingRoot: URL?
        public let stderr: String

        public var didMerge: Bool { disposition == .merged }
    }

    public enum MergeError: LocalizedError {
        case bbmergeFailed(status: Int32, stderr: String)
        case bbmergeProducedNoReads(stderr: String)
        case stagingRootContainsWhitespace(URL)

        public var errorDescription: String? {
            switch self {
            case .bbmergeFailed(let status, let stderr):
                return "bbmerge failed with status \(status): \(stderr)"
            case .bbmergeProducedNoReads(let stderr):
                return "bbmerge produced no reads to map: \(stderr)"
            case .stagingRootContainsWhitespace(let url):
                return """
                    Cannot run bbmerge for a path containing whitespace: the staging \
                    directory '\(url.path)' contains whitespace too.
                    """
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
                stagingRoot: nil,
                stderr: ""
            )
        }

        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let staging = try MergeStaging.plan(
            fastqURL: fastqURL,
            workingDirectory: workingDirectory,
            stem: stem
        )
        defer { staging.cleanUp() }

        let arguments = [
            "in=\(staging.runInputURL.path)",
            "out=\(staging.runMergedURL.path)",
            "outu=\(staging.runUnmergedURL.path)",
            "interleaved=t",
            "threads=\(max(1, threads))",
        ]

        let (status, stderr) = try await runBBMerge(
            bbmergeURL: bbmergeURL,
            arguments: arguments,
            stderrURL: staging.runStderrURL
        )
        // Move outputs home before checking status, so a failed run still
        // leaves its stderr log next to the other run artifacts for triage.
        try staging.adoptResults()
        guard status == 0 else {
            throw MergeError.bbmergeFailed(status: status, stderr: stderr)
        }

        let mergedURL = staging.finalMergedURL
        let unmergedURL = staging.finalUnmergedURL
        let mergedCount = try await countRecordsIfPresent(at: mergedURL)
        let unmergedCount = try await countRecordsIfPresent(at: unmergedURL)

        // Map merged fragments plus any mates bbmerge could not join, so a
        // library with partial overlap still contributes every usable read.
        // Concatenation is ours, not bbmerge's, so it runs on the real
        // destination path regardless of whitespace.
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
            stagingRoot: staging.temporaryRoot,
            stderr: stderr
        )
    }

    // MARK: - Whitespace staging

    /// True when `url`'s path holds any character the shell would split on.
    ///
    /// Exposed for the staging tests; the merge itself asks `MergeStaging`.
    /// The input's extension as bbmerge understands it, defaulting to plain
    /// FASTQ when the name carries nothing useful.
    static func readableExtension(of url: URL) -> String {
        let name = url.lastPathComponent.lowercased()
        for candidate in ["fastq.gz", "fq.gz", "fastq", "fq"] where name.hasSuffix(".\(candidate)") {
            return candidate
        }
        return "fastq"
    }

    static func pathContainsWhitespace(_ url: URL) -> Bool {
        url.standardizedFileURL.path.rangeOfCharacter(from: .whitespacesAndNewlines) != nil
    }

    /// Where one bbmerge invocation reads and writes, and where its results belong.
    ///
    /// # Why this exists
    ///
    /// bbtools ships wrapper scripts, not binaries, and every one of them ends
    /// the same way:
    ///
    /// ```sh
    /// CMD="java $EA $EOOM $SIMD $XMX $XMS -cp $CP jgi.BBMerge $@"
    /// eval $CMD
    /// ```
    ///
    /// The wrapper interpolates `$@` into a single string and `eval`s it, so
    /// the shell re-splits every argument on whitespace no matter how carefully
    /// the caller passed its argv array. A project at
    /// "…/Analyses/Amplicon genotyping results/…" therefore made bbmerge abort
    /// with "Unknown parameter genotyping" before reading a read, because the
    /// middle word of the directory name arrived as its own argument.
    ///
    /// Lungfish projects are named by the user and routinely contain spaces, so
    /// when the input FASTQ or the working directory does, the run moves to a
    /// system temp directory whose path has none. Only bbmerge's own view
    /// moves: the merged, unmerged, and stderr artifacts are put back into the
    /// caller's working directory before `prepareForMapping` returns, so the
    /// `Outcome` contract is unchanged.
    ///
    /// This mirrors the approach `NFCoreLaunchStaging` takes for QUAST, which
    /// rejects spaced paths outright.
    ///
    /// ``BBToolsArgumentStaging`` now does the same job generically for every
    /// bbtools invocation that goes through `NativeToolRunner`. This type stays
    /// separate because the merge does not: it drives `bbmerge.sh` through its
    /// own `Process` so it can stream stderr to a log file, and its `Outcome`
    /// contract reports the staged argv and staging root for provenance. The
    /// generic helper stages an opaque argv and has no such contract, so
    /// folding this into it would trade a verified-on-real-data merge for a
    /// worse provenance record. Both apply the same two rules: symlink inputs
    /// rather than copy them, and keep the input's real extension so bbtools
    /// still infers format and compression correctly.
    struct MergeStaging {
        /// Temp root created for this run, or nil when the run happened in place.
        let temporaryRoot: URL?
        /// FASTQ handed to bbmerge's `in=`.
        let runInputURL: URL
        let runMergedURL: URL
        let runUnmergedURL: URL
        let runStderrURL: URL
        /// Where the merged reads must end up for the caller.
        let finalMergedURL: URL
        let finalUnmergedURL: URL
        let finalStderrURL: URL

        /// Chooses whitespace-free run paths for one sample.
        ///
        /// `stem` is already sanitized by the caller, so only the directories
        /// and the source FASTQ's own name can introduce whitespace.
        static func plan(fastqURL: URL, workingDirectory: URL, stem: String) throws -> MergeStaging {
            let mergedURL = workingDirectory.appendingPathComponent("\(stem).merged.fastq")
            let unmergedURL = workingDirectory.appendingPathComponent("\(stem).unmerged.fastq")
            let stderrURL = workingDirectory.appendingPathComponent("\(stem).bbmerge.stderr.log")

            let needsStaging = pathContainsWhitespace(fastqURL)
                || pathContainsWhitespace(workingDirectory)
            guard needsStaging else {
                return MergeStaging(
                    temporaryRoot: nil,
                    runInputURL: fastqURL,
                    runMergedURL: mergedURL,
                    runUnmergedURL: unmergedURL,
                    runStderrURL: stderrURL,
                    finalMergedURL: mergedURL,
                    finalUnmergedURL: unmergedURL,
                    finalStderrURL: stderrURL
                )
            }

            let root = try ProjectTempDirectory.create(
                prefix: "bbmerge-",
                contextURL: nil,
                policy: .systemOnly
            ).standardizedFileURL
            // Refuse rather than run a command we know the wrapper will
            // mis-parse: a spaced TMPDIR would reproduce the original failure
            // with a confusing path.
            guard !pathContainsWhitespace(root) else {
                try? FileManager.default.removeItem(at: root)
                throw MergeError.stagingRootContainsWhitespace(root)
            }

            // Link rather than copy: amplicon FASTQs run to gigabytes, and
            // bbmerge only reads the input. The link's own path is what the
            // wrapper interpolates, so it is the path that must stay clean.
            // bbmerge infers compression from the filename, so the staged name
            // must keep the input's real extension. Calling a gzipped FASTQ
            // `.input.fastq` makes it read compressed bytes as text, find zero
            // pairs, and die inside its own parser.
            let stagedInput = root.appendingPathComponent(
                "\(stem).input.\(readableExtension(of: fastqURL))")
            do {
                try FileManager.default.createSymbolicLink(
                    at: stagedInput,
                    withDestinationURL: fastqURL.standardizedFileURL
                )
            } catch {
                try FileManager.default.copyItem(at: fastqURL, to: stagedInput)
            }

            return MergeStaging(
                temporaryRoot: root,
                runInputURL: stagedInput,
                runMergedURL: root.appendingPathComponent("\(stem).merged.fastq"),
                runUnmergedURL: root.appendingPathComponent("\(stem).unmerged.fastq"),
                runStderrURL: root.appendingPathComponent("\(stem).bbmerge.stderr.log"),
                finalMergedURL: mergedURL,
                finalUnmergedURL: unmergedURL,
                finalStderrURL: stderrURL
            )
        }

        /// Moves whatever bbmerge produced back into the caller's directory.
        ///
        /// A missing run-side file is normal: bbmerge writes no `outu` stream
        /// when every pair merged, and no `out` stream when none did.
        func adoptResults() throws {
            guard temporaryRoot != nil else { return }
            let moves = [
                (runMergedURL, finalMergedURL),
                (runUnmergedURL, finalUnmergedURL),
                (runStderrURL, finalStderrURL),
            ]
            for (source, destination) in moves {
                guard FileManager.default.fileExists(atPath: source.path) else { continue }
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: source, to: destination)
            }
        }

        /// Removes the staging root, including on the error path.
        func cleanUp() {
            guard let temporaryRoot else { return }
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
    }

    // MARK: - Support

    private static func runBBMerge(
        bbmergeURL: URL,
        arguments: [String],
        stderrURL: URL
    ) async throws -> (status: Int32, stderr: String) {
        try await runProcess(executableURL: bbmergeURL, arguments: arguments, stderrURL: stderrURL)
    }

    /// Runs `executableURL` to completion with stderr captured to a file.
    ///
    /// The exit is observed through `terminationHandler`, installed before
    /// `run()`, which Foundation guarantees to invoke exactly once. An earlier
    /// version parked a global-queue thread in `waitUntilExit()` instead; on a
    /// 30-sample MiSeq cohort that wait intermittently never returned for a
    /// bbmerge that had already exited in under a second, leaving the CLI
    /// asleep with no child process for the rest of the session.
    ///
    /// Internal so the wait can be exercised directly against fast-exiting
    /// children without a bbmerge install.
    static func runProcess(
        executableURL: URL,
        arguments: [String],
        stderrURL: URL
    ) async throws -> (status: Int32, stderr: String) {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        process.standardError = stderrHandle
        defer { try? stderrHandle.close() }

        let exit = ProcessExitWaiter()
        process.terminationHandler = { terminated in
            exit.finish(terminated.terminationStatus)
        }
        try process.run()
        let status = await exit.wait()
        let stderrText = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
        return (status, stderrText)
    }

    /// Bridges a `Process.terminationHandler` to one awaiting caller.
    ///
    /// Either side may arrive first: a child that exits before the caller
    /// awaits is handed its stored status immediately, and a caller that
    /// awaits first is resumed by the handler.
    private final class ProcessExitWaiter: @unchecked Sendable {
        private let lock = NSLock()
        private var status: Int32?
        private var continuation: CheckedContinuation<Int32, Never>?

        func finish(_ code: Int32) {
            let pending: CheckedContinuation<Int32, Never>?
            lock.lock()
            status = code
            pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: code)
        }

        func wait() async -> Int32 {
            await withCheckedContinuation { continuation in
                let stored: Int32?
                lock.lock()
                stored = status
                if stored == nil {
                    self.continuation = continuation
                }
                lock.unlock()
                if let stored {
                    continuation.resume(returning: stored)
                }
            }
        }
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
