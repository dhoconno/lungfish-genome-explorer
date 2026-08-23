// BrackenInvocationForm.swift - Bracken CLI dialect detection and argument construction
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// A `bracken` executable reachable from a Lungfish environment can speak either
// of two mutually incompatible command lines.
//
// * The **real** Bracken CLI (`bracken` 2.x/3.x) is a shell driver that takes
//   `-d <database>` and derives the kmer distribution file itself.
// * A **synthesized launcher** takes the inner `est_abundance.py` CLI: it has no
//   `-d`, takes `-k <kmer_distrib>`, and requires the caller to resolve the
//   distribution file. Passing `-d` to it fails with
//   `est_abundance.py: error: the following arguments are required: -k/--kmer_distr`.
//
// The second case is not upstream packaging. The only arm64-installable bioconda
// build, `bioconda::bracken=1.0.0=1`, ships **no driver at all**: its package
// contents under `bin/` are exactly `est_abundance.py`,
// `generate_kmer_distribution.py`, and `count-kmer-abundances.pl`, with no
// `bracken` entry point. Lungfish itself then synthesizes one --
// `CondaManager.ensureBrackenLauncher` (Sources/LungfishWorkflow/Conda/CondaManager.swift)
// writes a `bin/bracken` passthrough (`exec "$TOOL_BIN/python"
// "$TOOL_BIN/est_abundance.py" "$@"`) whenever `bin/bracken` is absent and
// `est_abundance.py` is present. So the wrapper dialect is Lungfish's own
// compatibility shim, and **no bioconda re-pin can remove it** on arm64: any
// build of this package needs the launcher to be invokable as `bracken` at all.
// Handling the inner CLI correctly is therefore a permanent requirement, not a
// workaround for a defect someone upstream will fix.
//
// This file isolates the decision (which dialect) and the argument construction
// for each, so both are unit-testable without a conda install.

import Foundation

/// Which command-line dialect a resolved `bracken` executable speaks.
public enum BrackenCLIDialect: String, Sendable, Equatable, Codable {
    /// Real Bracken driver: accepts `-d <database>`.
    case database

    /// `bioconda::bracken=1.0.0` passthrough wrapper around `est_abundance.py`:
    /// accepts `-k <kmer_distrib>` and has no `-d`.
    case kmerDistribution
}

/// Errors raised while constructing a Bracken invocation.
public enum BrackenInvocationError: Error, LocalizedError, Equatable {
    /// No `database<N>mers.kmer_distrib` file exists in the database directory,
    /// so the passthrough wrapper cannot be given a `-k` argument.
    case noKmerDistribution(databasePath: String, requestedReadLength: Int)

    public var errorDescription: String? {
        switch self {
        case .noKmerDistribution(let databasePath, let requestedReadLength):
            return """
                This Bracken build requires a Bracken kmer distribution file, but the database at \
                \(databasePath) contains no database<N>mers.kmer_distrib file (looked for read length \
                \(requestedReadLength)). Rebuild the database with bracken-build, or install a database \
                that ships Bracken distributions.
                """
        }
    }
}

/// Detection of, and argument construction for, the two Bracken CLI dialects.
public enum BrackenInvocation {

    // MARK: - Dialect detection

    /// Classifies a `bracken --help` (or `-h`) usage text into a CLI dialect.
    ///
    /// The passthrough wrapper's usage line names the inner script directly
    /// (`usage: est_abundance.py ...`) and never offers `-d`. The real driver
    /// documents `-d`/`--db`. Anything that neither names the inner script nor
    /// offers `-d` is treated as the wrapper too: assuming `-d` when it is not
    /// advertised is the failure mode this detection exists to prevent, and the
    /// wrapper form additionally verifies the distribution file up front.
    ///
    /// - Parameter helpText: Combined stdout and stderr of the help invocation.
    public static func dialect(fromHelpText helpText: String) -> BrackenCLIDialect {
        if helpText.contains("est_abundance.py") {
            return .kmerDistribution
        }
        return advertisesDatabaseFlag(helpText) ? .database : .kmerDistribution
    }

    /// Whether help text advertises a `-d` / `--db` option as a whole token.
    ///
    /// Anchored so that unrelated text such as `-db2` or a `--dbstats` option
    /// does not count as an offer of `-d`.
    private static func advertisesDatabaseFlag(_ text: String) -> Bool {
        let patterns = ["(?<![\\w-])-d(?![\\w-])", "(?<![\\w-])--db(?![\\w-])"]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if regex.firstMatch(in: text, range: range) != nil { return true }
        }
        return false
    }

    // MARK: - Kmer distribution resolution

    /// The outcome of resolving a `database<N>mers.kmer_distrib` file.
    public struct KmerDistributionResolution: Sendable, Equatable {
        /// The distribution file to pass as `-k`.
        public let url: URL

        /// The read length actually used, which may differ from the requested one.
        public let readLength: Int

        /// `true` when no exact match existed and a nearest-N file was substituted.
        public var isSubstituted: Bool { readLength != requestedReadLength }

        /// The read length the caller asked for.
        public let requestedReadLength: Int

        public init(url: URL, readLength: Int, requestedReadLength: Int) {
            self.url = url
            self.readLength = readLength
            self.requestedReadLength = requestedReadLength
        }
    }

    static let distributionPrefix = "database"
    static let distributionSuffix = "mers.kmer_distrib"

    /// The canonical distribution filename for a read length.
    public static func distributionFilename(readLength: Int) -> String {
        "\(distributionPrefix)\(readLength)\(distributionSuffix)"
    }

    /// Parses the read length out of a `database<N>mers.kmer_distrib` filename.
    ///
    /// Returns `nil` for any other filename, and for a non-numeric or negative N.
    public static func readLength(fromDistributionFilename filename: String) -> Int? {
        guard filename.hasPrefix(distributionPrefix), filename.hasSuffix(distributionSuffix) else {
            return nil
        }
        let start = filename.index(filename.startIndex, offsetBy: distributionPrefix.count)
        let end = filename.index(filename.endIndex, offsetBy: -distributionSuffix.count)
        guard start < end else { return nil }
        let digits = filename[start..<end]
        guard digits.allSatisfy(\.isNumber), let value = Int(digits) else { return nil }
        return value
    }

    /// Resolves the kmer distribution file to pass as `-k`.
    ///
    /// Prefers the exact `database<readLength>mers.kmer_distrib`. When that file
    /// is absent, picks the nearest available N in the same directory, breaking
    /// ties toward the larger N so the substitution is never silently coarser
    /// than an equally-distant alternative. Throws when the directory has no
    /// distribution file at all, rather than letting Bracken fail obscurely or
    /// produce a degraded result.
    ///
    /// - Parameters:
    ///   - databasePath: The Kraken2 database directory.
    ///   - readLength: The requested read length.
    ///   - availableFilenames: Directory contents, injected for testability.
    public static func resolveKmerDistribution(
        databasePath: URL,
        readLength: Int,
        availableFilenames: [String]
    ) throws -> KmerDistributionResolution {
        let exactName = distributionFilename(readLength: readLength)
        if availableFilenames.contains(exactName) {
            return KmerDistributionResolution(
                url: databasePath.appendingPathComponent(exactName),
                readLength: readLength,
                requestedReadLength: readLength
            )
        }

        let candidates = availableFilenames
            .compactMap(readLength(fromDistributionFilename:))
            .sorted()
        guard let nearest = candidates.min(by: { lhs, rhs in
            let dl = abs(lhs - readLength), dr = abs(rhs - readLength)
            return dl == dr ? lhs > rhs : dl < dr
        }) else {
            throw BrackenInvocationError.noKmerDistribution(
                databasePath: databasePath.path,
                requestedReadLength: readLength
            )
        }

        return KmerDistributionResolution(
            url: databasePath.appendingPathComponent(distributionFilename(readLength: nearest)),
            readLength: nearest,
            requestedReadLength: readLength
        )
    }

    /// Directory listing convenience over the real filesystem.
    public static func availableDistributionFilenames(inDatabase databasePath: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: databasePath.path))?
            .filter { readLength(fromDistributionFilename: $0) != nil } ?? []
    }

    // MARK: - Level support

    /// Level codes the inner `est_abundance.py` CLI accepts.
    ///
    /// Its argparse `choices` are `K,P,C,O,F,G,S`. Note the absence of `D`: the
    /// real Bracken driver accepts `-l D`, this script does not.
    static let kmerDistributionLevelCodes: Set<String> = ["K", "P", "C", "O", "F", "G", "S"]

    /// Whether `levelCode` can be requested under the given dialect.
    ///
    /// `D` (domain) is the only divergence. It is deliberately **not** rewritten
    /// to `K` (kingdom): the two are distinct levels both in Kraken2 reports and
    /// in `est_abundance.py`'s own `main_lvls` list, and a single report commonly
    /// carries both. On the shared SARS-CoV-2 fixture, for instance, `D` is
    /// `Viruses` (taxid 10239) while `K` is `Orthornavirae` (taxid 2732396), so
    /// substituting `K` for `D` would silently profile a different taxon and
    /// report it as the domain the caller asked for. An unsupported rank must
    /// surface as a degraded outcome instead, which is what the pipeline's
    /// existing `.unsupportedRank` path already does for other ranks.
    public static func supportsLevelCode(_ levelCode: String, dialect: BrackenCLIDialect) -> Bool {
        switch dialect {
        case .database:
            return true
        case .kmerDistribution:
            return kmerDistributionLevelCodes.contains(levelCode)
        }
    }

    /// A diagnostic for a level the given dialect cannot profile, or `nil` when
    /// the level is supported.
    public static func unsupportedLevelDiagnostic(
        levelCode: String,
        rankDisplayName: String,
        dialect: BrackenCLIDialect
    ) -> String? {
        guard !supportsLevelCode(levelCode, dialect: dialect) else { return nil }
        return """
            This Bracken build cannot estimate abundance at rank \(levelCode) (\(rankDisplayName)). \
            The installed package ships no Bracken driver, so Lungfish runs est_abundance.py directly, \
            and that script accepts only \(kmerDistributionLevelCodes.sorted().joined(separator: ", ")). \
            Choose a different rank; note that kingdom (K) is a distinct rank from domain (D), not a \
            substitute for it.
            """
    }

    // MARK: - Known upstream crash signature

    /// Whether `stderr` is the known `bracken=1.0.0` `u_reads` crash.
    ///
    /// `est_abundance.py` assigns `u_reads` only while parsing an unclassified
    /// (`U`) line, then unconditionally prints it in the run summary. A Kraken
    /// report in which every read classified has no `U` line, so the script
    /// raises `UnboundLocalError` and exits non-zero -- but only *after* it has
    /// written and closed the complete abundance table. The signature is matched
    /// narrowly (the error type and the `u_reads` variable together) so that no
    /// other traceback is mistaken for it.
    ///
    /// Remove this once an arm64 build of Bracken 2.x/3.x is installable and the
    /// manifest no longer pins `bracken=1.0.0`.
    public static func isUnclassifiedReadsCrash(stderr: String) -> Bool {
        stderr.contains("UnboundLocalError") && stderr.contains("u_reads")
    }

    // MARK: - Argument construction

    /// Builds the argument vector for a Bracken run in the given dialect.
    ///
    /// - Parameters:
    ///   - dialect: Which CLI the resolved executable speaks.
    ///   - databasePath: The Kraken2 database directory (`-d`, database dialect).
    ///   - distributionURL: The resolved kmer distribution (`-k`, wrapper dialect).
    ///   - reportURL: The Kraken2 report to profile (`-i`).
    ///   - outputURL: The Bracken output to write (`-o`).
    ///   - reportOutputURL: The re-estimated Kraken-style report to write (`-w`).
    ///     Bracken always writes this file; passing `-w` keeps it at a modelled,
    ///     declarable path instead of the auto-named
    ///     `<report>_bracken_<rank>.kreport` beside the input.
    ///   - readLength: The read length (`-r`, database dialect only; the wrapper
    ///     has no `-r` because the choice is already baked into `-k`).
    ///   - levelCode: The taxonomic level code (`-l`).
    ///   - threshold: The minimum-reads threshold (`-t`).
    public static func arguments(
        dialect: BrackenCLIDialect,
        databasePath: URL,
        distributionURL: URL,
        reportURL: URL,
        outputURL: URL,
        reportOutputURL: URL,
        readLength: Int,
        levelCode: String,
        threshold: Int
    ) -> [String] {
        switch dialect {
        case .database:
            return [
                "-d", databasePath.path,
                "-i", reportURL.path,
                "-o", outputURL.path,
                "-w", reportOutputURL.path,
                "-r", String(readLength),
                "-l", levelCode,
                "-t", String(threshold),
            ]
        case .kmerDistribution:
            return [
                "-i", reportURL.path,
                "-k", distributionURL.path,
                "-o", outputURL.path,
                "-w", reportOutputURL.path,
                "-l", levelCode,
                "-t", String(threshold),
            ]
        }
    }
}
