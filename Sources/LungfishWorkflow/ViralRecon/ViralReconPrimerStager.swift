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

    private static func loadReferenceSequences(from url: URL) throws -> [String: String] {
        let contents = try String(contentsOf: url, encoding: .utf8)
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

        for pair in [("_LEFT", "_RIGHT"), ("_F", "_R"), ("_FORWARD", "_REVERSE")] {
            if let left = suffix(pair.0, in: names),
               let right = suffix(pair.1, in: names) {
                return (left, right)
            }
        }
        return ("_LEFT", "_RIGHT")
    }

    private static func suffix(_ candidate: String, in names: [String]) -> String? {
        for name in names {
            if name.uppercased().hasSuffix(candidate),
               let range = name.range(of: candidate, options: [.caseInsensitive, .backwards]) {
                return String(name[range.lowerBound...])
            }
        }
        return nil
    }
}
