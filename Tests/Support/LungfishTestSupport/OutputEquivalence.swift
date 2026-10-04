// OutputEquivalence.swift - Compares a GUI run's output with a CLI replay's output
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// docs/contracts/CLI-EQUIVALENCE.md says what "the same result" means for
// each kind of operation. A replay test runs the GUI path on root A and the
// recorded command on root B, then calls `OutputEquivalence.assertSame` on
// the two outputs. The masks here are the contract's masks and nothing else.
// Their patterns follow the binding rules of scripts/golden/normalize.py.

import Foundation
import XCTest

public enum OutputEquivalence {
    /// The kinds of result the contract's "Same result" table names.
    public enum Kind: Sendable, CaseIterable {
        /// Files compared byte for byte. Gzip and BGZF are compared on their
        /// decompressed bytes, a BAM on its header without `@PG` lines and a
        /// hash of its records, and a VCF without its date and command header
        /// lines. A `.bai` or `.csi` BAM index is compared on `samtools
        /// idxstats`, a tabix index on `tabix -l`, and either on its presence
        /// when the tool is missing. Two directories must hold the same
        /// relative file names.
        case files
        /// SQLite files compared on a sorted dump of every table.
        case database
        /// Two bundles or analysis folders. The relative inventory is compared
        /// after the name masks, and every payload is compared by its
        /// extension, with SQLite files dumped and JSON compared as values.
        case bundle
        /// Two recorded requests to a remote service. JSON is compared with
        /// sorted keys and a form or query body as a set of parameters.
        case remoteRequest
        /// Two managed tool or database plans, compared as JSON values.
        case managedPlan
    }

    /// What a mask knows about one side of a comparison. Each side's text has
    /// both roots replaced by `<ROOT>`. `runIDNumbers` and `uuidNumbers`
    /// number every run ID and every UUID in that side's tree by first
    /// appearance, so the same ID gets the same number in a file name and in
    /// a manifest value, and two IDs never share one.
    /// `contentComparedPaths` holds this side's unmasked relative paths of
    /// the files that exist in both trees and are compared by content rather
    /// than by bytes.
    public struct MaskContext: Sendable {
        public let rootA: URL
        public let rootB: URL
        public let runIDNumbers: [String: Int]
        public let uuidNumbers: [String: Int]
        public let contentComparedPaths: Set<String>

        public init(
            rootA: URL,
            rootB: URL,
            runIDNumbers: [String: Int] = [:],
            uuidNumbers: [String: Int] = [:],
            contentComparedPaths: Set<String> = []
        ) {
            self.rootA = rootA
            self.rootB = rootB
            self.runIDNumbers = runIDNumbers
            self.uuidNumbers = uuidNumbers
            self.contentComparedPaths = contentComparedPaths
        }
    }

    /// One rewrite applied to text before it is compared.
    public struct Mask: Sendable {
        public let name: String
        let apply: @Sendable (String, MaskContext) -> String

        public init(name: String, apply: @escaping @Sendable (String, MaskContext) -> String) {
            self.name = name
            self.apply = apply
        }

        public func callAsFunction(_ text: String, context: MaskContext) -> String {
            apply(text, context)
        }
    }

    /// Asserts that `a` and `b` are the same result of `kind`, and fails with
    /// every difference it finds.
    public static func assertSame(
        _ a: URL,
        _ b: URL,
        kind: Kind,
        masks: MaskPolicy = .standard,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            let found = try differences(a, b, kind: kind, masks: masks)
            if !found.isEmpty {
                XCTFail(
                    "\(a.path) and \(b.path) differ as \(kind):\n" + found.joined(separator: "\n"),
                    file: file,
                    line: line
                )
            }
        } catch {
            XCTFail("Could not compare \(a.path) and \(b.path): \(error)", file: file, line: line)
        }
    }

    /// Every difference between `a` and `b` as `kind`. An empty list means
    /// the two are the same result.
    public static func differences(
        _ a: URL,
        _ b: URL,
        kind: Kind,
        masks: MaskPolicy = .standard
    ) throws -> [String] {
        let rootA = comparisonRoot(a)
        let rootB = comparisonRoot(b)
        var filesA = try inventory(a)
        var filesB = try inventory(b)
        if kind == .database {
            filesA = filesA.filter { isSQLiteFile($0.value) }
            filesB = filesB.filter { isSQLiteFile($0.value) }
        }
        let rootsOnly = MaskContext(rootA: rootA, rootB: rootB)
        let numbersA = identifierNumbers(in: filesA, context: rootsOnly)
        let numbersB = identifierNumbers(in: filesB, context: rootsOnly)
        let maskPaths = kind == .bundle
        let (keyedA, collisionsA) = keyed(
            filesA, maskPaths: maskPaths, masks: masks.names,
            context: MaskContext(rootA: rootA, rootB: rootB, runIDNumbers: numbersA.runIDs, uuidNumbers: numbersA.uuids)
        )
        let (keyedB, collisionsB) = keyed(
            filesB, maskPaths: maskPaths, masks: masks.names,
            context: MaskContext(rootA: rootA, rootB: rootB, runIDNumbers: numbersB.runIDs, uuidNumbers: numbersB.uuids)
        )
        // Files in both trees that are compared by content. Only a record
        // that names one of them has its stated checksum and size masked.
        let shared = Set(keyedA.keys).intersection(keyedB.keys).filter { name in
            Masks.contentComparedSuffixes.contains { name.lowercased().hasSuffix($0) }
        }
        // The digest mask runs before any other mask, so each side gets the
        // raw relative names of its own copies.
        func rawNames(_ files: [String: URL], _ keyedFiles: [String: URL]) -> Set<String> {
            let nameByPath = Dictionary(files.map { ($0.value.path, $0.key) }, uniquingKeysWith: { first, _ in first })
            return Set(shared.compactMap { keyedFiles[$0].flatMap { nameByPath[$0.path] } })
        }
        let contextA = MaskContext(
            rootA: rootA, rootB: rootB, runIDNumbers: numbersA.runIDs, uuidNumbers: numbersA.uuids,
            contentComparedPaths: rawNames(filesA, keyedA)
        )
        let contextB = MaskContext(
            rootA: rootA, rootB: rootB, runIDNumbers: numbersB.runIDs, uuidNumbers: numbersB.uuids,
            contentComparedPaths: rawNames(filesB, keyedB)
        )

        var found: [String] = []
        for collision in collisionsA {
            found.append("collides in A: \(collision)")
        }
        for collision in collisionsB {
            found.append("collides in B: \(collision)")
        }
        for name in Set(keyedA.keys).subtracting(keyedB.keys).sorted() {
            found.append("only in A: \(name)")
        }
        for name in Set(keyedB.keys).subtracting(keyedA.keys).sorted() {
            found.append("only in B: \(name)")
        }
        for name in Set(keyedA.keys).intersection(keyedB.keys).sorted() {
            guard let fileA = keyedA[name], let fileB = keyedB[name] else { continue }
            let normalA = try normalized(fileA, kind: kind, masks: masks, context: contextA)
            let normalB = try normalized(fileB, kind: kind, masks: masks, context: contextB)
            if normalA != normalB {
                found.append("differs: \(name)\n" + firstDifference(normalA, normalB))
            }
        }
        return found
    }

    // MARK: - Inventory

    /// The comparison root of one side. A directory is its own root, and a
    /// single file's root is its folder.
    static func comparisonRoot(_ url: URL) -> URL {
        isDirectory(url) ? url : url.deletingLastPathComponent()
    }

    static func isDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }

    /// Relative path to file URL for every regular file under `url`, or the
    /// file itself under the name "." when `url` is a file.
    static func inventory(_ url: URL) throws -> [String: URL] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        guard isDirectory(url) else { return [".": url] }
        let base = url.resolvingSymlinksInPath().standardizedFileURL.path
        var files: [String: URL] = [:]
        let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        )
        while let item = enumerator?.nextObject() as? URL {
            let values = try item.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let path = item.resolvingSymlinksInPath().standardizedFileURL.path
            let relative = path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : item.lastPathComponent
            files[relative] = item
        }
        return files
    }

    /// Each file under its masked name. Two files whose names mask to one
    /// name are a collision, which the comparison reports, because one of
    /// them would otherwise go unseen. The first raw name in sorted order
    /// keeps the masked name.
    private static func keyed(
        _ files: [String: URL],
        maskPaths: Bool,
        masks: [Mask],
        context: MaskContext
    ) -> (files: [String: URL], collisions: [String]) {
        guard maskPaths else { return (files, []) }
        var result: [String: URL] = [:]
        var rawNames: [String: [String]] = [:]
        for name in files.keys.sorted() {
            let masked = applying(masks, to: name, context: context)
            rawNames[masked, default: []].append(name)
            if result[masked] == nil { result[masked] = files[name] }
        }
        let collisions = rawNames
            .filter { $0.value.count > 1 }
            .sorted { $0.key < $1.key }
            .map { "\($0.key) names \($0.value.joined(separator: ", "))" }
        return (result, collisions)
    }

    /// Numbers each run ID and each UUID in one tree by first appearance.
    /// File names come first, the names of provenance envelopes and manifests
    /// before the others, then the text of each provenance envelope and
    /// manifest. The files are taken in an order that ignores the IDs
    /// themselves, by name and then by record text with every ID blanked and
    /// both roots masked, so two children named by random UUIDs get the same
    /// numbers in both trees whichever way their UUIDs sort. Only files that
    /// tie on both keys, such as two children whose records are the same
    /// apart from their IDs, fall back to the order of their raw names.
    static func identifierNumbers(
        in files: [String: URL],
        context: MaskContext
    ) -> (runIDs: [String: Int], uuids: [String: Int]) {
        func blanked(_ text: String) -> String {
            let withoutUUIDs = Masks.replace(Masks.uuidPattern, in: Masks.roots(text, context: context)) { _ in "<ID>" }
            return Masks.replace(Masks.runIDPattern, in: withoutUUIDs) { _ in "<ID>" }
        }
        var recordTexts: [String: String] = [:]
        var isRecord: Set<String> = []
        for (name, url) in files where role(ofFileNamed: url.lastPathComponent) != .payload {
            isRecord.insert(name)
            guard let data = try? Data(contentsOf: url),
                  !isGzip(data),
                  let text = String(data: data, encoding: .utf8)
            else { continue }
            recordTexts[name] = text
        }
        let order = files.keys
            .map { name in (name: name, key: [blanked(name), recordTexts[name].map(blanked) ?? ""]) }
            .sorted { $0.key != $1.key ? $0.key.lexicographicallyPrecedes($1.key) : $0.name < $1.name }
            .map(\.name)

        var runIDs: [String: Int] = [:]
        var uuids: [String: Int] = [:]
        func number(_ pattern: NSRegularExpression, in text: String, into numbers: inout [String: Int]) {
            let source = text as NSString
            for match in pattern.matches(in: text, range: NSRange(location: 0, length: source.length)) {
                let value = source.substring(with: match.range).lowercased()
                if numbers[value] == nil { numbers[value] = numbers.count + 1 }
            }
        }
        func record(_ text: String) {
            number(Masks.runIDPattern, in: text, into: &runIDs)
            number(Masks.uuidPattern, in: text, into: &uuids)
        }
        order.filter { isRecord.contains($0) }.forEach(record)
        order.filter { !isRecord.contains($0) }.forEach(record)
        order.compactMap { recordTexts[$0] }.forEach(record)
        return (runIDs, uuids)
    }

    static func isSQLiteFile(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return isSQLite((try? handle.read(upToCount: 16)) ?? Data())
    }

    static func applying(_ masks: [Mask], to text: String, context: MaskContext) -> String {
        masks.reduce(text) { partial, mask in mask(partial, context: context) }
    }

    /// The first differing line of two normalized forms, for a failure message.
    static func firstDifference(_ a: String, _ b: String) -> String {
        let linesA = a.components(separatedBy: "\n")
        let linesB = b.components(separatedBy: "\n")
        for index in 0..<max(linesA.count, linesB.count) {
            let lineA = index < linesA.count ? linesA[index] : "<end>"
            let lineB = index < linesB.count ? linesB[index] : "<end>"
            if lineA != lineB {
                let before = linesA[max(0, index - 3)..<min(index, linesA.count)]
                    .map { "    = \($0.prefix(300))" }
                let after = linesA[min(index + 1, linesA.count)..<min(index + 4, linesA.count)]
                    .map { "    = \($0.prefix(300))" }
                return (["  line \(index + 1)"] + before + ["    A: \(lineA.prefix(300))", "    B: \(lineB.prefix(300))"] + after)
                    .joined(separator: "\n")
            }
        }
        return "  (no line differs)"
    }
}
