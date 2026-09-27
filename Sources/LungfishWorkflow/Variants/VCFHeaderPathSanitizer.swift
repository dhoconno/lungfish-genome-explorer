// VCFHeaderPathSanitizer.swift - Strip build-machine paths from VCF meta lines
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

/// Rewrites the `##` meta-information lines a variant caller leaves in a VCF so
/// the track LGE writes into a bundle carries no per-user absolute paths.
///
/// LoFreq's `##source` names the executable by its absolute conda path and the
/// `/var/folders/...` workspace; bcftools adds `##bcftools_<sub>Command` lines
/// naming the workspace as well. Those paths leak into shared projects and
/// published demo archives. The sanitizer keeps the command shape (tool name,
/// subcommand, flags) and replaces each absolute path:
///
/// - a path inside the run workspace becomes `<workspace>/<relative path>`,
/// - an executable (a path whose parent is a `bin` folder) becomes its name,
/// - any other absolute path becomes `<path>/<file name>`.
///
/// When the tool's version is known, `##source=<tool> ...` becomes
/// `##source=<tool> <version> ...`. The full argv, with real paths, stays in
/// LGE's own provenance record, which already stores it.
public enum VCFHeaderPathSanitizer {
    public struct Context: Sendable {
        /// Directories whose contents are rewritten as `<workspace>/...`.
        public var workspaceURLs: [URL]
        /// Tool versions keyed by executable name, for `##source=<tool>`.
        public var toolVersions: [String: String]

        public init(workspaceURLs: [URL], toolVersions: [String: String] = [:]) {
            self.workspaceURLs = workspaceURLs
            self.toolVersions = toolVersions
        }
    }

    public static let workspacePlaceholder = "<workspace>"
    public static let externalPathPlaceholder = "<path>"

    /// Returns `line` with absolute paths rewritten. Non-meta lines (the
    /// `#CHROM` header and data lines) are returned unchanged.
    public static func sanitize(headerLine line: String, context: Context) -> String {
        guard line.hasPrefix("##") else { return line }
        var rewritten = replaceAbsolutePaths(in: line, context: context)
        if rewritten.hasPrefix("##source=") {
            rewritten = insertToolVersion(intoSourceLine: rewritten, context: context)
        }
        return rewritten
    }

    /// Rewrites the meta lines of the plain-text VCF at `url` in place and
    /// returns how many lines changed. Data lines are copied byte for byte.
    @discardableResult
    public static func sanitizeFile(at url: URL, context: Context) throws -> Int {
        let original = try String(contentsOf: url, encoding: .utf8)
        var changed = 0
        var output = ""
        output.reserveCapacity(original.utf8.count)
        var inHeader = true
        for line in original.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            if inHeader, text.hasPrefix("##") {
                let sanitized = sanitize(headerLine: text, context: context)
                if sanitized != text { changed += 1 }
                output += sanitized
            } else {
                inHeader = false
                output += text
            }
            output += "\n"
        }
        // `split` with omittingEmptySubsequences: false yields a trailing empty
        // element for a file that ends in a newline; drop the extra newline.
        if original.hasSuffix("\n") {
            output.removeLast()
        }
        guard changed > 0 else { return 0 }
        try output.write(to: url, atomically: true, encoding: .utf8)
        return changed
    }

    // MARK: - Path rewriting

    /// Characters that end an absolute path token inside a header line.
    private static let pathTerminators: Set<Character> = [
        " ", "\t", "\"", "'", ",", ";", "<", ">", "|", ")", "]",
    ]

    /// Characters that may precede a path token (so `a/b` inside a word is not
    /// mistaken for an absolute path).
    /// `>` is deliberately absent: `<workspace>/x` and `<path>/x` are the
    /// sanitizer's own output, and a second pass must leave them alone.
    private static let pathLeadIns: Set<Character> = [
        " ", "\t", "=", "\"", "'", ",", ";", "<", "|", "(", "[", ":",
    ]

    static func replaceAbsolutePaths(in line: String, context: Context) -> String {
        let characters = Array(line)
        var output = ""
        output.reserveCapacity(line.utf8.count)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            let startsPath = character == "/"
                && (index == 0 || pathLeadIns.contains(characters[index - 1]))
            guard startsPath else {
                output.append(character)
                index += 1
                continue
            }
            var end = index
            while end < characters.count, !pathTerminators.contains(characters[end]) {
                end += 1
            }
            let token = String(characters[index ..< end])
            if token.hasPrefix("//") {
                // `file:///abs/path` carries a path after its slashes; any
                // other `//` (a URL authority) is left alone.
                let slashes = token.prefix(while: { $0 == "/" }).count
                if output.hasSuffix("file:"), slashes >= 3 {
                    output += String(repeating: "/", count: slashes - 1)
                    output += rewrite(absolutePath: "/" + token.dropFirst(slashes), context: context)
                } else {
                    output += token
                }
            } else if token.count > 1 {
                output += rewrite(absolutePath: token, context: context)
            } else {
                output += token
            }
            index = end
        }
        return output
    }

    static func rewrite(absolutePath token: String, context: Context) -> String {
        // Trailing punctuation that is not part of the path (e.g. `.` ending
        // a sentence) is kept outside the rewrite.
        var path = token
        var trailing = ""
        while let last = path.last, last == "." || last == ":" {
            trailing.insert(last, at: trailing.startIndex)
            path.removeLast()
        }
        guard path.count > 1 else { return token }

        for prefix in workspacePrefixes(context) {
            if path == prefix {
                return workspacePlaceholder + trailing
            }
            if path.hasPrefix(prefix + "/") {
                let relative = String(path.dropFirst(prefix.count + 1))
                return workspacePlaceholder + "/" + relative + trailing
            }
        }

        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        if url.deletingLastPathComponent().lastPathComponent == "bin" {
            return name + trailing
        }
        return externalPathPlaceholder + "/" + name + trailing
    }

    private static func workspacePrefixes(_ context: Context) -> [String] {
        var prefixes: [String] = []
        for url in context.workspaceURLs {
            let standardized = url.standardizedFileURL.path
            let canonical = CanonicalFilePath.path(for: url)
            for candidate in [standardized, canonical] {
                let trimmed = candidate.hasSuffix("/") && candidate.count > 1
                    ? String(candidate.dropLast())
                    : candidate
                if !trimmed.isEmpty, !prefixes.contains(trimmed) {
                    prefixes.append(trimmed)
                }
            }
        }
        // Longest prefixes first so a nested workspace wins over its parent.
        return prefixes.sorted { $0.count > $1.count }
    }

    // MARK: - ##source

    private static func insertToolVersion(intoSourceLine line: String, context: Context) -> String {
        let value = String(line.dropFirst("##source=".count))
        guard let firstToken = value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first else {
            return line
        }
        let tool = String(firstToken)
        guard let version = context.toolVersions[tool], !version.isEmpty,
              !value.hasPrefix("\(tool) \(version)") else {
            return line
        }
        let remainder = value.dropFirst(tool.count)
        return "##source=\(tool) \(version)\(remainder)"
    }
}
