// PrimerSchemeResolver.swift - Resolve a primer scheme bundle against a target reference name
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// Resolves a `PrimerSchemeBundle` against the reference name encountered in a
/// user-supplied BAM header, optionally rewriting the bundle's BED to use an
/// equivalent accession.
///
/// A primer scheme is authored against one canonical reference accession
/// (e.g., `MN908947.3`), but a user's BAM may have been mapped to an
/// *equivalent* accession (e.g., `NC_045512.2`, a different versioning of the
/// same organism). The manifest declares both canonical and equivalent
/// accessions; this resolver picks the right BED for downstream tools:
///
/// - Canonical match: returns the bundle's BED unchanged.
/// - Equivalent match: produces a rewritten BED in the system temporary
///   directory with column 1 replaced and the remaining tab-separated columns
///   preserved verbatim.
/// - No match: throws `ResolveError.unknownAccession` listing known accessions.
public enum PrimerSchemeResolver {
    /// The result of resolving a bundle against a target reference name.
    ///
    /// - `bedURL`: Either the bundle's original BED (when the canonical
    ///   accession matched) or a newly-written temp file (when an equivalent
    ///   accession matched). Callers may feed this URL directly to tools that
    ///   expect a primer BED.
    /// - `isRewritten`: `true` when `bedURL` points to a freshly-written temp
    ///   file. Callers that own temp-file cleanup can use this to decide
    ///   whether to delete the file after use.
    public struct Resolved: Sendable {
        /// URL of the BED to use for downstream primer-aware tools.
        public let bedURL: URL

        /// `true` iff `bedURL` is a rewritten temp copy (not the bundle's own BED).
        public let isRewritten: Bool
    }

    /// Errors thrown by `PrimerSchemeResolver.resolve`.
    public enum ResolveError: Error, LocalizedError {
        /// The target reference name is neither the bundle's canonical
        /// accession nor any of its declared equivalents.
        case unknownAccession(bundle: String, requested: String, known: [String])

        /// Rewriting the BED to a temp file failed (e.g., disk I/O error).
        case ioFailure(underlying: Error)

        public var errorDescription: String? {
            switch self {
            case .unknownAccession(let bundle, let requested, let known):
                return "Primer scheme \(bundle) does not declare \(requested) as a reference (known: \(known.joined(separator: ", ")))."
            case .ioFailure(let underlying):
                return "Failed to rewrite primer BED: \(underlying.localizedDescription)"
            }
        }
    }

    /// Resolves `bundle` against `targetReferenceName`, returning a `Resolved`
    /// whose `bedURL` may be used by primer-aware tools.
    ///
    /// - Parameters:
    ///   - bundle: The loaded primer-scheme bundle.
    ///   - targetReferenceName: The reference name extracted from the target
    ///     BAM's `@SQ` header (or any caller-chosen reference context).
    /// - Returns: A `Resolved` pointing at either the original BED or a
    ///   rewritten temp BED.
    /// - Throws: `ResolveError.unknownAccession` if the name matches neither
    ///   canonical nor equivalent accessions; `ResolveError.ioFailure` if
    ///   writing the rewritten BED fails.
    public static func resolve(
        bundle: PrimerSchemeBundle,
        targetReferenceName: String
    ) throws -> Resolved {
        let canonical = bundle.manifest.canonicalAccession
        let equivalents = bundle.manifest.equivalentAccessions
        let known = [canonical] + equivalents

        if targetReferenceName == canonical {
            return Resolved(bedURL: bundle.bedURL, isRewritten: false)
        }

        if equivalents.contains(targetReferenceName) {
            do {
                let rewritten = try rewriteBED(
                    source: bundle.bedURL,
                    from: canonical,
                    to: targetReferenceName
                )
                return Resolved(bedURL: rewritten, isRewritten: true)
            } catch {
                throw ResolveError.ioFailure(underlying: error)
            }
        }

        throw ResolveError.unknownAccession(
            bundle: bundle.manifest.name,
            requested: targetReferenceName,
            known: known
        )
    }

    /// Rewrites the BED at `source`, replacing any column 1 entry equal to
    /// `from` with `newName`. Column structure, tab separators, and line
    /// endings are preserved verbatim; only the first column is touched.
    ///
    /// Lines whose first column does not match `from` (including empty lines
    /// and lines without a tab) are copied through unchanged.
    private static func rewriteBED(source: URL, from: String, to newName: String) throws -> URL {
        let input = try String(contentsOf: source, encoding: .utf8)
        let rewritten = input
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let tab = line.firstIndex(of: "\t") else { return String(line) }
                let col1 = String(line[..<tab])
                guard col1 == from else { return String(line) }
                return newName + line[tab...]
            }
            .joined(separator: "\n")

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("primers-\(UUID().uuidString).bed")
        try rewritten.write(to: tmp, atomically: true, encoding: .utf8)
        return tmp
    }
}
