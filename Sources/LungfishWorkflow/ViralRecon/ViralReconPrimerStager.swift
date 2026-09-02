import Foundation
import LungfishIO

public enum ViralReconPrimerStager {
    public enum StageError: Error, Sendable, Equatable {
        case emptyReference
        case invalidBEDLine(String)
        case invalidBEDCoordinate(String)
    }

    public static func stage(
        primerBundleURL: URL,
        referenceFASTAURL: URL,
        referenceName: String,
        destinationDirectory: URL
    ) throws -> ViralReconPrimerSelection {
        let bundle = try PrimerSchemeBundle.load(from: primerBundleURL)
        let resolved = try PrimerSchemeResolver.resolve(bundle: bundle, targetReferenceName: referenceName)

        let primersDirectory = destinationDirectory.appendingPathComponent("primers", isDirectory: true)
        try FileManager.default.createDirectory(at: primersDirectory, withIntermediateDirectories: true)

        let stagedBEDURL = primersDirectory.appendingPathComponent("primers.bed")
        try replaceItem(at: stagedBEDURL, withCopyOf: resolved.bedURL)

        let stagedFASTAURL = primersDirectory.appendingPathComponent("primers.fasta")
        let derivedFasta: Bool
        if let bundledFASTAURL = bundle.fastaURL {
            try replaceItem(at: stagedFASTAURL, withCopyOf: bundledFASTAURL)
            derivedFasta = false
        } else {
            try derivePrimerFASTA(
                bedURL: stagedBEDURL,
                referenceFASTAURL: referenceFASTAURL,
                outputURL: stagedFASTAURL
            )
            derivedFasta = true
        }

        let suffixes = inferSuffixes(in: stagedBEDURL)
        return ViralReconPrimerSelection(
            bundleURL: primerBundleURL,
            displayName: bundle.manifest.displayName,
            bedURL: stagedBEDURL,
            fastaURL: stagedFASTAURL,
            leftSuffix: suffixes.left,
            rightSuffix: suffixes.right,
            derivedFasta: derivedFasta
        )
    }

    /// Stages the primer BED without deriving the primer FASTA.
    ///
    /// No bundled SARS-CoV-2 scheme ships `primers.fasta`, so the sequences have
    /// to be cut out of the reference. The wizard has no reference to cut from
    /// until the launch path has acquired one, so it stages the BED here and the
    /// launch path completes the selection with `stage`.
    public static func stageBEDOnly(
        primerBundleURL: URL,
        referenceName: String,
        destinationDirectory: URL
    ) throws -> ViralReconPrimerSelection {
        let bundle = try PrimerSchemeBundle.load(from: primerBundleURL)
        let resolved = try PrimerSchemeResolver.resolve(bundle: bundle, targetReferenceName: referenceName)

        let primersDirectory = destinationDirectory.appendingPathComponent("primers", isDirectory: true)
        try FileManager.default.createDirectory(at: primersDirectory, withIntermediateDirectories: true)

        let stagedBEDURL = primersDirectory.appendingPathComponent("primers.bed")
        try replaceItem(at: stagedBEDURL, withCopyOf: resolved.bedURL)

        // Returns nil rather than a path to a file it did not write: the launch
        // path completes the selection once it has a reference to cut from, and
        // a placeholder path would be indistinguishable from a real one.
        var stagedFASTAURL: URL?
        let derivedFasta: Bool
        if let bundledFASTAURL = bundle.fastaURL {
            let destination = primersDirectory.appendingPathComponent("primers.fasta")
            try replaceItem(at: destination, withCopyOf: bundledFASTAURL)
            stagedFASTAURL = destination
            derivedFasta = false
        } else {
            derivedFasta = true
        }

        let suffixes = inferSuffixes(in: stagedBEDURL)
        return ViralReconPrimerSelection(
            bundleURL: primerBundleURL,
            displayName: bundle.manifest.displayName,
            bedURL: stagedBEDURL,
            fastaURL: stagedFASTAURL,
            leftSuffix: suffixes.left,
            rightSuffix: suffixes.right,
            derivedFasta: derivedFasta
        )
    }

    private static func replaceItem(at destination: URL, withCopyOf source: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private static func derivePrimerFASTA(
        bedURL: URL,
        referenceFASTAURL: URL,
        outputURL: URL
    ) throws {
        let references = try loadReferenceSequences(from: referenceFASTAURL)
        guard !references.isEmpty else { throw StageError.emptyReference }
        let bed = try String(contentsOf: bedURL, encoding: .utf8)
        var records: [String] = []

        for rawLine in bed.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard columns.count >= 4 else { throw StageError.invalidBEDLine(line) }
            guard let reference = references[columns[0]] else {
                throw StageError.invalidBEDCoordinate(line)
            }
            guard let start = Int(columns[1]), let end = Int(columns[2]),
                  start >= 0, end > start, end <= reference.count else {
                throw StageError.invalidBEDCoordinate(line)
            }

            let name = columns[3]
            var sequence = slice(reference, start: start, end: end)
            if columns.count >= 6, columns[5] == "-" {
                sequence = reverseComplement(sequence)
            }
            records.append(">\(name)\n\(sequence)")
        }

        try (records.joined(separator: "\n") + "\n").write(to: outputURL, atomically: true, encoding: .utf8)
    }

    /// Reads a FASTA as text, transparently decompressing gzip/bgzip input.
    ///
    /// Reference FASTAs inside downloaded `.lungfishref` genome bundles are
    /// stored bgzip-compressed (`sequence.fa.gz`). Reading those as UTF-8 text
    /// fails with `NSFileReadCorruptFileError`, so decompress by extension.
    public static func readFASTAText(at url: URL) throws -> String {
        guard isCompressedFASTA(url) else {
            return try String(contentsOf: url, encoding: .utf8)
        }
        return try GzipInputStream(url: url).readAllSync()
    }

    /// Whether `url` names a gzip-compressed FASTA.
    ///
    /// Broader than `URL.isGzipCompressed`, which only recognises `.gz`:
    /// references in the wild also arrive as `.bgz` and `.gzip`.
    public static func isCompressedFASTA(_ url: URL) -> Bool {
        ["gz", "bgz", "gzip"].contains(url.pathExtension.lowercased())
    }

    private static func loadReferenceSequences(from url: URL) throws -> [String: String] {
        let contents = try readFASTAText(at: url)
        var sequences: [String: String] = [:]
        var currentID: String?
        var currentSequence = ""

        func flushCurrentSequence() {
            guard let currentID else { return }
            sequences[currentID] = currentSequence.uppercased()
        }

        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix(">") {
                flushCurrentSequence()
                let header = String(line.dropFirst())
                currentID = header.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? header
                currentSequence = ""
            } else {
                currentSequence += line
            }
        }
        flushCurrentSequence()
        return sequences
    }

    private static func slice(_ sequence: String, start: Int, end: Int) -> String {
        let startIndex = sequence.index(sequence.startIndex, offsetBy: start)
        let endIndex = sequence.index(sequence.startIndex, offsetBy: end)
        return String(sequence[startIndex..<endIndex])
    }

    private static func reverseComplement(_ sequence: String) -> String {
        String(sequence.reversed().map { base in
            switch base {
            case "A": return "T"
            case "C": return "G"
            case "G": return "C"
            case "T": return "A"
            default: return "N"
            }
        })
    }

    private static func inferSuffixes(in bedURL: URL) -> (left: String, right: String) {
        guard let bed = try? String(contentsOf: bedURL, encoding: .utf8) else {
            return ("_LEFT", "_RIGHT")
        }
        let names = bed.split(separator: "\n").compactMap { line -> String? in
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count >= 4 else { return nil }
            return String(columns[3])
        }

        // Ordered most- to least-specific so `_LEFT` is not shadowed by `_L`.
        let orientations: [(left: String, right: String)] = [
            ("LEFT", "RIGHT"),
            ("FORWARD", "REVERSE"),
            ("FWD", "REV"),
            ("F", "R")
        ]
        for separator in ["_", "-"] {
            for orientation in orientations {
                let left = separator + orientation.left
                let right = separator + orientation.right
                if let matchedLeft = suffix(left, in: names),
                   let matchedRight = suffix(right, in: names) {
                    return (matchedLeft, matchedRight)
                }
            }
        }
        return ("_LEFT", "_RIGHT")
    }

    /// Finds the orientation token `candidate` at, or near, the end of a primer name.
    ///
    /// Schemes append an alt-primer index after the orientation token
    /// (ARTIC V5.3.2 uses `SARS-CoV-2_400_1_LEFT_1`), so a trailing
    /// `<separator><digits>` group is tolerated and excluded from the result.
    /// The returned suffix preserves the source casing so it can be passed to
    /// iVar verbatim.
    private static func suffix(_ candidate: String, in names: [String]) -> String? {
        for name in names {
            let trimmed = droppingTrailingIndex(name)
            guard trimmed.uppercased().hasSuffix(candidate.uppercased()) else { continue }
            let start = trimmed.index(trimmed.endIndex, offsetBy: -candidate.count)
            return String(trimmed[start...])
        }
        return nil
    }

    /// Drops a trailing `_<digits>` or `-<digits>` alt-primer index.
    private static func droppingTrailingIndex(_ name: String) -> String {
        guard let separator = name.lastIndex(where: { $0 == "_" || $0 == "-" }),
              separator != name.startIndex else {
            return name
        }
        let tail = name[name.index(after: separator)...]
        guard !tail.isEmpty, tail.allSatisfy(\.isNumber) else { return name }
        return String(name[..<separator])
    }
}
