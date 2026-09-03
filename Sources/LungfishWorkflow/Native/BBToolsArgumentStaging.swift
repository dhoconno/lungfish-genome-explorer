import Foundation
import LungfishCore
import LungfishIO

/// Rewrites bbtools arguments onto whitespace-free paths, and puts the results back.
///
/// # Why this exists
///
/// bbtools ships wrapper scripts, not binaries, and every one of the eight we
/// invoke (bbduk, bbmerge, bbmap, clumpify, mapPacBio, reformat, repair,
/// tadpole) ends the same way:
///
/// ```sh
/// CMD="java $EA $EOOM $SIMD $XMX $XMS -cp $CP jgi.BBMerge $@"
/// eval $CMD
/// ```
///
/// The wrapper interpolates `$@` into a single string and `eval`s it, so the
/// shell re-splits every argument on whitespace no matter how carefully the
/// caller built its argv array. A project at
/// "…/Analyses/Amplicon genotyping results/…" made bbmerge abort with
/// "Unknown parameter genotyping" before reading a read, because the middle
/// word of the directory name arrived as its own argument.
///
/// Lungfish projects are named by the user and routinely contain spaces, so
/// this cannot be fixed at individual call sites: it applies to every bbtools
/// invocation in the app. `NativeToolRunner` applies it once for all of them.
///
/// # What it does
///
/// bbtools arguments are `key=value`. Only the values that name a path matter,
/// and they come in two flavours that must be handled differently:
///
/// - **Inputs** are read, so they are symlinked into the staging root. A link
///   rather than a copy because these FASTQs run to gigabytes and the tool only
///   reads them.
/// - **Outputs** are written, so nothing is linked. The tool is given a fresh
///   path inside the staging root, and whatever it produced is *moved back* to
///   the caller's path once it exits. Getting this wrong loses results
///   silently, which is why outputs are enumerated explicitly rather than
///   guessed.
///
/// Everything else is passed through untouched. When no argument carries
/// whitespace nothing is staged, no directory is created, and the argv is
/// returned byte-identical to what the caller supplied.
enum BBToolsArgumentStaging {

    enum StagingError: LocalizedError {
        case stagingRootContainsWhitespace(URL)

        var errorDescription: String? {
            switch self {
            case .stagingRootContainsWhitespace(let url):
                return """
                    Cannot run a BBTools script for a path containing whitespace: the \
                    staging directory '\(url.path)' contains whitespace too.
                    """
            }
        }
    }

    /// bbtools parameters whose value is a path the tool **reads**.
    ///
    /// Drawn from the eight wrappers Lungfish invokes. `in`/`in1`/`in2` and
    /// their `input` spellings cover reads; `ref` covers adapter and reference
    /// FASTAs (bbduk, bbmap); `extra` and `qfin` cover the less common streams.
    static let inputParameters: Set<String> = [
        "in", "in1", "in2", "input", "input1", "input2",
        "ref", "reference", "extra", "qfin", "qfin1", "qfin2",
        "primerfile", "fastawrap", "sam", "bam", "scafstats", "covstats",
    ]

    /// bbtools parameters whose value is a path the tool **writes**.
    ///
    /// A staged output that is missing when the tool exits is normal, not an
    /// error: bbmerge writes no `outu` stream when every pair merged, bbduk no
    /// `outm` when nothing matched. Adoption skips what was never created.
    static let outputParameters: Set<String> = [
        "out", "out1", "out2", "outu", "outu1", "outu2",
        "outm", "outm1", "outm2", "outs", "outsingle",
        "output", "outputfile", "outb", "outd",
        "stats", "statsfile", "refstats", "rpkm", "bhist", "qhist",
        "aqhist", "lhist", "gchist", "ihist", "ehist", "indelhist",
        "mhist", "idhist", "outputhist", "dump", "khist", "outgc",
    ]

    /// A staged run: the argv to launch with, and where the results belong.
    struct Plan {
        /// Argv the process must actually be given.
        let arguments: [String]
        /// Temp root created for this run, nil when nothing needed staging.
        let temporaryRoot: URL?
        /// Staged output path -> the caller's real path, applied after the run.
        private let outputMoves: [(staged: URL, final: URL)]

        init(
            arguments: [String],
            temporaryRoot: URL?,
            outputMoves: [(staged: URL, final: URL)]
        ) {
            self.arguments = arguments
            self.temporaryRoot = temporaryRoot
            self.outputMoves = outputMoves
        }

        /// True when the run was rewritten onto staged paths.
        var didStage: Bool { temporaryRoot != nil }

        /// Moves whatever the tool produced back to the caller's paths.
        ///
        /// Call this even when the tool failed: a partial or diagnostic output
        /// is more useful next to the caller's other artifacts than inside a
        /// temp directory that is about to be deleted.
        func adoptResults() {
            guard temporaryRoot != nil else { return }
            let fm = FileManager.default
            for move in outputMoves {
                guard fm.fileExists(atPath: move.staged.path) else { continue }
                // The destination directory may not exist when the caller
                // pointed an output at a directory the tool would have created.
                let parent = move.final.deletingLastPathComponent()
                try? fm.createDirectory(at: parent, withIntermediateDirectories: true)
                try? fm.removeItem(at: move.final)
                do {
                    try fm.moveItem(at: move.staged, to: move.final)
                } catch {
                    // A cross-device rename fails; a copy still delivers the
                    // result, which is the part the caller cannot do without.
                    try? fm.copyItem(at: move.staged, to: move.final)
                }
            }
        }

        /// Removes the staging root, including on the error path.
        func cleanUp() {
            guard let temporaryRoot else { return }
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
    }

    /// True when `path` holds any character the shell would split on.
    static func containsWhitespace(_ path: String) -> Bool {
        path.rangeOfCharacter(from: .whitespacesAndNewlines) != nil
    }

    /// Splits a bbtools `key=value` argument, lowercasing the key for matching.
    ///
    /// bbtools parameter names are case-insensitive, and values legitimately
    /// contain `=` (a path could), so only the first `=` separates.
    static func split(argument: String) -> (key: String, value: String)? {
        guard let index = argument.firstIndex(of: "=") else { return nil }
        let key = String(argument[argument.startIndex..<index]).lowercased()
        let value = String(argument[argument.index(after: index)...])
        guard !key.isEmpty, !value.isEmpty else { return nil }
        return (key, value)
    }

    /// The suffix bbtools reads format and compression from.
    ///
    /// bbtools infers both the format and the codec from the filename, so a
    /// staged name must keep the whole meaningful suffix. `URL.pathExtension`
    /// is not enough: it reduces `sample.fastq.gz` to `gz`, which tells the
    /// tool the bytes are gzipped but not that they are FASTQ. Naming a
    /// gzipped FASTQ `.fastq` is worse still, as it makes bbmerge read
    /// compressed bytes as text, report zero pairs, and die inside its own
    /// parser.
    static func readableSuffix(of name: String) -> String {
        let lowercased = name.lowercased()
        let bases = ["fastq", "fq", "fasta", "fa", "fna", "sam", "bam", "txt", "tsv", "csv"]
        let codecs = ["gz", "bz2", "zip", "xz"]
        for base in bases {
            for codec in codecs where lowercased.hasSuffix(".\(base).\(codec)") {
                return "\(base).\(codec)"
            }
            if lowercased.hasSuffix(".\(base)") { return base }
        }
        // Unknown suffix: keep the last component so a tool that only checks
        // for a codec still sees one, and accept the tool's own default format.
        let ext = (name as NSString).pathExtension.lowercased()
        return ext.isEmpty ? "" : ext
    }

    /// Builds the argv a bbtools script can actually be launched with.
    ///
    /// Returns a plan whose `arguments` are identical to `arguments` and whose
    /// `temporaryRoot` is nil when nothing contains whitespace, so a project on
    /// a clean path behaves exactly as it did before staging existed.
    ///
    /// - Throws: ``StagingError/stagingRootContainsWhitespace(_:)`` when the
    ///   system temp directory itself contains whitespace. Refusing is
    ///   deliberate: running anyway would reproduce the very mis-parse this
    ///   exists to prevent, but with a path the user cannot recognise.
    static func plan(arguments: [String]) throws -> Plan {
        let needsStaging = arguments.contains { argument in
            guard let (key, value) = split(argument: argument) else { return false }
            guard inputParameters.contains(key) || outputParameters.contains(key) else {
                return false
            }
            return containsWhitespace(value)
        }
        guard needsStaging else {
            return Plan(arguments: arguments, temporaryRoot: nil, outputMoves: [])
        }

        let root = try ProjectTempDirectory.create(
            prefix: "bbtools-",
            contextURL: nil,
            policy: .systemOnly
        ).standardizedFileURL
        guard !containsWhitespace(root.path) else {
            try? FileManager.default.removeItem(at: root)
            throw StagingError.stagingRootContainsWhitespace(root)
        }

        var staged = arguments
        var outputMoves: [(staged: URL, final: URL)] = []
        var usedNames: Set<String> = []

        for (index, argument) in arguments.enumerated() {
            guard let (key, value) = split(argument: argument),
                  containsWhitespace(value) else { continue }

            let original = URL(fileURLWithPath: value)
            let isInput = inputParameters.contains(key)
            let isOutput = outputParameters.contains(key)
            guard isInput || isOutput else { continue }

            let name = uniqueName(
                for: original.lastPathComponent,
                index: index,
                usedNames: &usedNames
            )
            let stagedURL = root.appendingPathComponent(name)

            if isInput {
                // Link rather than copy: these files run to gigabytes and the
                // tool only reads them. The link's own path is what the wrapper
                // interpolates, so it is the path that must stay clean.
                do {
                    try FileManager.default.createSymbolicLink(
                        at: stagedURL,
                        withDestinationURL: original.standardizedFileURL
                    )
                } catch {
                    try FileManager.default.copyItem(at: original, to: stagedURL)
                }
            } else {
                // Outputs are not linked. bbtools deletes and recreates output
                // files, which replaces a symlink with a regular file inside
                // the staging root and leaves the caller's path empty. The tool
                // writes a fresh path here and `adoptResults` moves it home.
                outputMoves.append((staged: stagedURL, final: original))
            }

            // Preserve the original key's spelling and case; only the value moves.
            let originalKey = argument[argument.startIndex..<argument.firstIndex(of: "=")!]
            staged[index] = "\(originalKey)=\(stagedURL.path)"
        }

        return Plan(arguments: staged, temporaryRoot: root, outputMoves: outputMoves)
    }

    /// A whitespace-free, collision-free name that keeps the readable suffix.
    ///
    /// Two arguments can name different files with the same leaf (an `in=` and
    /// an `out=` both called `sample.fastq` in different directories), and both
    /// land in one staging root, so the name is disambiguated by argv position.
    private static func uniqueName(
        for originalName: String,
        index: Int,
        usedNames: inout Set<String>
    ) -> String {
        let suffix = readableSuffix(of: originalName)
        var candidate = suffix.isEmpty ? "arg\(index)" : "arg\(index).\(suffix)"
        var disambiguator = 2
        while usedNames.contains(candidate) {
            candidate = suffix.isEmpty
                ? "arg\(index)_\(disambiguator)"
                : "arg\(index)_\(disambiguator).\(suffix)"
            disambiguator += 1
        }
        usedNames.insert(candidate)
        return candidate
    }
}
