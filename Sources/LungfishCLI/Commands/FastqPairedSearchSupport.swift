// FastqPairedSearchSupport.swift - Pair-aware seqkit grep helpers
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishWorkflow

/// Helpers that turn a record-by-record `seqkit grep` into a whole-pair
/// extraction on interleaved input.
///
/// `seqkit grep` decides per record, so a motif found only in mate 2, or an
/// ID query that matches `NAME/1` but not `NAME/2`, splits pairs. The fix is
/// to search first, collect the fragment keys of whatever matched, and then
/// pull BOTH mates of every matched fragment out of the original file in its
/// original order. seqkit's `--id-regexp` makes the second pass match on the
/// fragment key, so identical names, `/1` `/2` suffixes, and Casava
/// descriptions all behave the same way.
enum FastqPairedSearchSupport {
    /// `--id-regexp` that reduces a header to its fragment key: the first
    /// whitespace-free token with any trailing `/1` or `/2` removed.
    static let fragmentKeyIDRegexp = #"^(\S+?)(?:/[12])?(?:\s.*)?$"#

    /// seqkit arguments that match `-p`/`-f` patterns against fragment keys
    /// instead of raw record IDs.
    static let fragmentKeyIDArguments = ["--id-regexp", fragmentKeyIDRegexp]

    /// Writes the distinct fragment keys of the records in `matchesURL`, in
    /// first-seen order, one per line.
    ///
    /// - Returns: the number of distinct fragments written.
    @discardableResult
    static func writeFragmentKeys(fromMatches matchesURL: URL, to keysURL: URL) async throws -> Int {
        let reader = FASTQReader(validateSequence: false)
        var seen = Set<String>()
        var keys: [String] = []
        for try await record in reader.records(from: matchesURL) {
            let key = IlluminaAmpliconPairMerger.fragmentKey(
                identifier: record.identifier,
                description: record.description
            )
            if seen.insert(key).inserted {
                keys.append(key)
            }
        }
        try (keys.joined(separator: "\n") + (keys.isEmpty ? "" : "\n"))
            .write(to: keysURL, atomically: true, encoding: .utf8)
        return keys.count
    }

    /// seqkit arguments that extract every record whose fragment key is
    /// listed in `keysURL`, preserving the source order (so mates stay
    /// adjacent).
    static func extractFragmentsArguments(keysURL: URL, sourceURL: URL, outputPath: String) -> [String] {
        ["grep", "-f", keysURL.path] + fragmentKeyIDArguments + [sourceURL.path, "-o", outputPath]
    }

    /// Runs `searchArguments` (a `seqkit grep` that selects records), then
    /// re-extracts both mates of every matched fragment into `outputPath`.
    ///
    /// - Returns: the seqkit result and native arguments of the final
    ///   extraction step, for provenance. When nothing matched, the key file
    ///   is empty and seqkit writes an empty output (gzipped when asked).
    static func runPairedSearch(
        searchArguments: [String],
        sourceURL: URL,
        outputPath: String,
        runner: NativeToolRunner
    ) async throws -> (result: NativeToolResult, nativeArguments: [String], matchedFragments: Int) {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-paired-search-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let matchesURL = scratch.appendingPathComponent("matches.fastq")
        let searchArgs = searchArguments + [sourceURL.path, "-o", matchesURL.path]
        let searchResult = try await runner.run(.seqkit, arguments: searchArgs, environment: [:], timeout: 1800)
        guard searchResult.isSuccess else {
            throw CLIError.conversionFailed(reason: "seqkit grep failed: \(searchResult.stderr)")
        }

        let keysURL = scratch.appendingPathComponent("fragment-keys.txt")
        let matchedFragments = try await writeFragmentKeys(fromMatches: matchesURL, to: keysURL)

        let extractArgs = extractFragmentsArguments(keysURL: keysURL, sourceURL: sourceURL, outputPath: outputPath)
        let extractResult = try await runner.run(.seqkit, arguments: extractArgs, environment: [:], timeout: 1800)
        guard extractResult.isSuccess else {
            throw CLIError.conversionFailed(reason: "seqkit grep (pair re-extraction) failed: \(extractResult.stderr)")
        }
        return (extractResult, extractArgs, matchedFragments)
    }
}
