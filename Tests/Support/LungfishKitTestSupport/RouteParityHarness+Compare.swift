// RouteParityHarness+Compare.swift - How two sides of a route parity case differ
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane Q30. Two sides compare in two ways.
//
// - How each ended, in the words of a row (`RouteParityEnd`).
// - Every file under the two side roots, through `OutputEquivalence.compare` with the harness's
//   kind and the contract's masks. That comparison decides whether a file differs.
//
// A file that differs is then explained from the two texts the comparison read, normalized for the
// kind and masked for the file's role with UUIDs and run IDs numbered across each side's tree, so
// the explanation applies no rule of its own (review fix 4) and a declared difference names one
// value or one line, never a whole file (panel G5). A JSON text gives one difference for each value
// path whose value differs or that one side lacks, and a value at a path that names the caller
// (`CallerIdentityPaths`, R2 of BIO-Q-A2) gives an `identity:` difference in place of `differs:`,
// which `appIdentityDifference` declares. Any other text, a decompressed gzip or BGZF file,
// a database dump and a BAM's header and record hash included, gives one difference for each line
// one side holds more often than the other, and one more, `line order`, when the lines both sides
// hold come in another order. A binary file, or one with more than `explainedLimit` differences,
// stays one whole-file difference, which no entry may declare (RouteParityHarness+Declared.swift).
// A provenance envelope, which holds the argument vectors and the paths of every step of a run,
// is explained up to `provenanceExplainedLimit` values, each with its own difference and so its
// own exact count (lane A45 M1 ruling, section 3).
//
// Ids are stable from run to run. A UUID, run ID or timestamp that no mask hid is masked in an id,
// and the number the comparison gave a UUID or run ID across its tree stays, so a changed link
// changes the id.
//
// Each side also holds a fact of its own. No file its run wrote names another side's root, so no
// side reads or records another side's files, which the root mask reads as `<ROOT>` on both sides.

import CryptoKit
import Foundation
import LungfishTestSupport

extension RouteParityHarness {
    /// The most differences one file is explained as. A file that differs in more is one
    /// whole-file difference.
    static let explainedLimit = 50

    /// The most differences a provenance envelope is explained as. A record of a run lists the
    /// argument vector of its host and of each step, with the paths and digests of their files, so
    /// one record legitimately differs in hundreds of values. It still gives one difference for
    /// each value, with an exact count (panel G5), and a record past this many is a different
    /// record, which stays one whole-file difference.
    static let provenanceExplainedLimit = 1_000

    /// Whether the comparison read the file called `name` as a provenance envelope, a JSON file
    /// whose own name contains `provenance` (`OutputEquivalence.role(ofFileNamed:)`).
    static func isProvenanceEnvelope(_ name: String) -> Bool {
        OutputEquivalence.role(ofFileNamed: (name as NSString).lastPathComponent) == .provenance
    }

    /// Every difference of the case, by scope. Each side's own facts, A against C, and C against
    /// C' or, when side C recorded no command, that fact of side C.
    public func differences(of runs: RouteParityRuns) throws -> [RouteParityScope: [RouteParityDifference]] {
        var found = Dictionary(uniqueKeysWithValues: RouteParityScope.all.map { ($0, [RouteParityDifference]()) })
        for run in runs.all {
            found[.side(run.side)] = Self.rootFacts(of: run, among: runs)
        }
        found[.aAgainstC] = try differences(runs.a, runs.c)
        if runs.c.outcome.recordedCommand == nil {
            found[.side(.c), default: []].append(
                RouteParityDifference(id: "command: side C records no command", detail: runs.c.outcome.detail)
            )
        } else {
            found[.cAgainstCPrime] = try differences(runs.c, runs.cPrime)
        }
        return found
    }

    /// How `candidate` differs from `reference`. How each ended, then every file under the two
    /// side roots.
    public func differences(_ reference: RouteParitySideRun, _ candidate: RouteParitySideRun) throws -> [RouteParityDifference] {
        var found: [RouteParityDifference] = []
        if reference.outcome.end != candidate.outcome.end {
            found.append(RouteParityDifference(
                id: "end: \(reference.side) \(reference.outcome.end), \(candidate.side) \(candidate.outcome.end)",
                detail: "\(reference.side) \(reference.outcome.detail) | \(candidate.side) \(candidate.outcome.detail)"
            ))
        }
        let comparison = try OutputEquivalence.compare(reference.root, candidate.root, kind: kind, masks: masks)
        let files = Dictionary(comparison.differingFiles.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        for line in comparison.differences {
            found += parse(line, reference.side, candidate.side, files: files)
        }
        found += Self.modeDifferences(reference, candidate)
        return found
    }

    // MARK: - File modes (lane 12.23, QA 2)

    /// One difference for each file both side roots hold whose permission bits differ, such as a record one route
    /// wrote 0600 where the other route's read 0644. `OutputEquivalence` compares content only, so no parity class
    /// compared modes before. A file only one side holds is `OutputEquivalence`'s difference and not this one.
    static func modeDifferences(_ reference: RouteParitySideRun, _ candidate: RouteParitySideRun) -> [RouteParityDifference] {
        let referenceModes = fileModes(under: reference.root)
        let candidateModes = fileModes(under: candidate.root)
        return referenceModes.keys.sorted().compactMap { name in
            guard let own = referenceModes[name], let other = candidateModes[name], own != other else { return nil }
            return RouteParityDifference(
                id: "mode: \(maskedID(name))",
                detail: "\(reference.side) \(octal(own)), \(candidate.side) \(octal(other))"
            )
        }
    }

    /// The permission bits of every regular file under `root`, by relative path.
    static func fileModes(under root: URL) -> [String: mode_t] {
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        var modes: [String: mode_t] = [:]
        for name in relativeFiles(under: root) {
            var information = stat()
            if lstat(base.appendingPathComponent(name).path, &information) == 0 {
                modes[name] = information.st_mode & 0o777
            }
        }
        return modes
    }

    private static func octal(_ mode: mode_t) -> String {
        "0" + String(mode, radix: 8)
    }

    /// One `OutputEquivalence` line as differences, with A and B named as the two sides.
    func parse(
        _ line: String,
        _ sideA: RouteParitySide,
        _ sideB: RouteParitySide,
        files: [String: OutputEquivalence.DifferingFile]
    ) -> [RouteParityDifference] {
        var parts = line.components(separatedBy: "\n")
        let head = parts.removeFirst()
        let detail = parts.joined(separator: "\n        ")
        let prefixes: [(prefix: String, words: String, side: RouteParitySide)] = [
            ("only in A: ", "only in", sideA), ("only in B: ", "only in", sideB),
            ("collides in A: ", "collides in", sideA), ("collides in B: ", "collides in", sideB),
        ]
        for item in prefixes where head.hasPrefix(item.prefix) {
            let name = Self.maskedID(String(head.dropFirst(item.prefix.count)))
            return [RouteParityDifference(id: "\(item.words) \(item.side): \(name)", detail: detail)]
        }
        if head.hasPrefix("differs: ") {
            let name = String(head.dropFirst("differs: ".count))
            if let file = files[name], let explained = explained(file, sideA, sideB) {
                return explained
            }
            return [RouteParityDifference(id: "differs: \(Self.maskedID(name))", detail: detail, wholeFile: true)]
        }
        return [RouteParityDifference(id: Self.maskedID(head), detail: detail)]
    }

    // MARK: - Explaining a file that differs

    /// One difference for each value or line of `file` that differs, one whole-file difference
    /// when more than `explainedLimit` do (`provenanceExplainedLimit` for a provenance envelope),
    /// or nil for a binary file.
    func explained(
        _ file: OutputEquivalence.DifferingFile,
        _ sideA: RouteParitySide,
        _ sideB: RouteParitySide
    ) -> [RouteParityDifference]? {
        guard !file.isBinary else { return nil }
        let label = Self.maskedID(file.name)
        var found: [RouteParityDifference] = []
        if let valuesA = Self.jsonValues(file.normalizedA), let valuesB = Self.jsonValues(file.normalizedB) {
            for path in Set(valuesA.keys).union(valuesB.keys).sorted() where valuesA[path] != valuesB[path] {
                // The caller's name differs by design between the app's route and a leaf (R2, MD62). It is its own class
                // of difference, which only `appIdentityDifference` declares, and every other path stays `differs:`.
                let identity = CallerIdentityPaths.isIdentityDifference(path: path, valuesA[path], valuesB[path])
                found.append(RouteParityDifference(
                    id: "\(identity ? "identity" : "differs"): \(label) at \(Self.maskedID(path))",
                    detail: "\(sideA) \(Self.shown(valuesA[path])), \(sideB) \(Self.shown(valuesB[path]))"
                ))
            }
        } else {
            let linesA = file.normalizedA.components(separatedBy: "\n")
            let linesB = file.normalizedB.components(separatedBy: "\n")
            let lines = Self.unmatchedLines(linesA, linesB)
            for (side, sideLines) in [(sideA, lines.onlyA), (sideB, lines.onlyB)] {
                found += sideLines.map { line in
                    RouteParityDifference(id: "differs: \(label): only in \(side): \(Self.maskedID(String(line.prefix(200))))")
                }
            }
            // The lines both sides hold, each in its side's order. A reorder is one more
            // difference, so it cannot hide under a declared line.
            if Self.sharedLines(linesA, over: linesB) != Self.sharedLines(linesB, over: linesA) {
                found.append(RouteParityDifference(id: "differs: \(label): line order"))
            }
        }
        guard !found.isEmpty else { return nil }
        let limit = Self.isProvenanceEnvelope(file.name) ? Self.provenanceExplainedLimit : Self.explainedLimit
        guard found.count <= limit else {
            return [RouteParityDifference(
                id: "differs: \(label)",
                detail: "\(found.count) values or lines differ, the first \(found[0])",
                wholeFile: true
            )]
        }
        return found
    }

    /// The one entry that declares the paths where a record names its caller (R2 of BIO-Q-A2, MD62), such as `toolName` and
    /// `runtime.app`, which `CallerIdentityPaths` lists. `counts` gives the exact number of such differences in each case,
    /// so one more or one fewer fails the case. A difference at any other path stays `differs:` and fails, and C against C'
    /// cannot declare it, since `failures` rejects an entry that is not A against C.
    public static func appIdentityDifference<Case: Hashable & Sendable>(
        _ counts: [Case: Int]
    ) -> RouteParityDeclaredDifference<Case> {
        RouteParityDeclaredDifference(
            counts,
            "identity: <ANY>",
            reason: "A record names its caller. The app's route names the app (Lungfish Genome Explorer, kind gui) where the "
                + "leaf's route names lungfish-cli (kind cli), at the paths CallerIdentityPaths lists and at no other (R2, MD62).",
            closedBy: "13.27 R2, by design"
        )
    }

    /// Every scalar of a JSON object or array under its value path, such as `steps[0].argv[2]`,
    /// or nil when the text is neither.
    static func jsonValues(_ text: String) -> [String: String]? {
        guard let data = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        var values: [String: String] = [:]
        flatten(value, path: "", into: &values)
        return values
    }

    private static func flatten(_ value: Any, path: String, into values: inout [String: String]) {
        if let object = value as? [String: Any] {
            if object.isEmpty { values[path.isEmpty ? "." : path] = "{}" }
            for (key, item) in object {
                flatten(item, path: path.isEmpty ? key : "\(path).\(key)", into: &values)
            }
        } else if let array = value as? [Any] {
            if array.isEmpty { values[path.isEmpty ? "." : path] = "[]" }
            for (index, item) in array.enumerated() {
                flatten(item, path: "\(path)[\(index)]", into: &values)
            }
        } else {
            let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
            values[path.isEmpty ? "." : path] = data.flatMap { String(data: $0, encoding: .utf8) } ?? String(describing: value)
        }
    }

    /// The lines each side holds more often than the other, in the order each side holds them.
    static func unmatchedLines(_ linesA: [String], _ linesB: [String]) -> (onlyA: [String], onlyB: [String]) {
        func counts(_ lines: [String]) -> [String: Int] {
            lines.reduce(into: [:]) { $0[$1, default: 0] += 1 }
        }
        func surplus(_ lines: [String], over other: [String: Int]) -> [String] {
            var seen: [String: Int] = [:]
            return lines.filter { line in
                seen[line, default: 0] += 1
                return seen[line, default: 0] > other[line, default: 0]
            }
        }
        return (surplus(linesA, over: counts(linesB)), surplus(linesB, over: counts(linesA)))
    }

    /// The lines of `lines` that `other` holds as often, in the order `lines` holds them.
    static func sharedLines(_ lines: [String], over other: [String]) -> [String] {
        let counts = other.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        var seen: [String: Int] = [:]
        return lines.filter { line in
            seen[line, default: 0] += 1
            return seen[line, default: 0] <= counts[line, default: 0]
        }
    }

    private static func shown(_ value: String?) -> String {
        guard let value else { return "absent" }
        return value.count > 300 ? String(value.prefix(300)) + "..." : value
    }

    // MARK: - Each side's own facts

    /// The largest file a side's facts and the fixture's digests read.
    static let factFileLimit = 16 * 1024 * 1024

    /// One fact for each file under the root of `run` that names another side's root, plain or
    /// JSON-escaped, leaving out a file the fixture held as it is. The side folder names are
    /// fixed and none starts another, so a spelling found is that side's root.
    static func rootFacts(of run: RouteParitySideRun, among runs: RouteParityRuns) -> [RouteParityDifference] {
        let others = runs.all.filter { $0.side != run.side }.map { other in
            let spellings = rootSpellings(other.root).flatMap { [$0, $0.replacingOccurrences(of: "/", with: "\\/")] }
            return (side: other.side, spellings: spellings.map { Data($0.utf8) })
        }
        var found: [RouteParityDifference] = []
        for name in relativeFiles(under: run.root) {
            guard let data = readForFacts(run.root.appendingPathComponent(name)),
                  runs.fixture[name] != digest(data)
            else { continue }
            for other in others where other.spellings.contains(where: { data.range(of: $0) != nil }) {
                found.append(RouteParityDifference(id: "fact: \(maskedID(name)) names the root of side \(other.side)"))
            }
        }
        return found
    }

    /// The SHA-256 of each file under `root` by its relative name, the fixture as it was built.
    public static func fixtureDigests(under root: URL) -> [String: String] {
        var digests: [String: String] = [:]
        for name in relativeFiles(under: root) {
            if let data = readForFacts(root.appendingPathComponent(name)) { digests[name] = digest(data) }
        }
        return digests
    }

    /// The bytes of a file the facts read, nil above `factFileLimit`.
    private static func readForFacts(_ url: URL) -> Data? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= factFileLimit else { return nil }
        return try? Data(contentsOf: url)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The relative paths of every regular file under `root`, sorted.
    static func relativeFiles(under root: URL) -> [String] {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        var paths: [String] = []
        while let item = enumerator.nextObject() as? URL {
            guard (try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let path = item.resolvingSymlinksInPath().standardizedFileURL.path
            if path.hasPrefix(base + "/") { paths.append(String(path.dropFirst(base.count + 1))) }
        }
        return paths.sorted()
    }

    // MARK: - Ids

    /// `text` with the values that change from run to run masked, so an id names the same
    /// difference in every run. Raw UUIDs, run IDs and timestamps. A UUID or run ID the comparison
    /// numbered across its tree, `<UUID-n>` or `<RUN-ID-n>`, keeps its number, so a link that
    /// changes changes the id.
    public static func maskedID(_ text: String) -> String {
        [
            ("[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}", "<UUID>"),
            ("aln_[0-9A-Fa-f]{8}", "<RUN-ID>"),
            ("[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}[-:][0-9]{2}[-:][0-9]{2}(?:\\.[0-9]+)?Z?", "<TS>"),
        ].reduce(text) { $0.replacingOccurrences(of: $1.0, with: $1.1, options: .regularExpression) }
    }
}
