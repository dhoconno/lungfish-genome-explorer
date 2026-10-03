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
        /// after masks, and every payload is compared by its extension, with
        /// SQLite files dumped and JSON compared after masks.
        case bundle
        /// Two recorded requests to a remote service. JSON is compared with
        /// sorted keys and a form or query body as a set of parameters.
        case remoteRequest
        /// Two managed tool or database plans, compared as JSON values.
        case managedPlan
    }

    /// What a mask knows about one side of a comparison. Each side's text has
    /// both roots replaced by `<ROOT>`. `runIDNumbers` numbers every run ID
    /// in that side's tree by first appearance, file names first and then
    /// file contents in path order, so the same run ID gets the same number
    /// in a file name and in a manifest value.
    public struct MaskContext: Sendable {
        public let rootA: URL
        public let rootB: URL
        public let runIDNumbers: [String: Int]

        public init(rootA: URL, rootB: URL, runIDNumbers: [String: Int] = [:]) {
            self.rootA = rootA
            self.rootB = rootB
            self.runIDNumbers = runIDNumbers
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
        masks: [Mask] = .standard,
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
        masks: [Mask] = .standard
    ) throws -> [String] {
        let rootA = comparisonRoot(a)
        let rootB = comparisonRoot(b)
        var filesA = try inventory(a)
        var filesB = try inventory(b)
        if kind == .database {
            filesA = filesA.filter { isSQLiteFile($0.value) }
            filesB = filesB.filter { isSQLiteFile($0.value) }
        }
        let contextA = MaskContext(rootA: rootA, rootB: rootB, runIDNumbers: runIDNumbers(in: filesA))
        let contextB = MaskContext(rootA: rootA, rootB: rootB, runIDNumbers: runIDNumbers(in: filesB))
        let maskPaths = kind == .bundle
        let keyedA = keyed(filesA, maskPaths: maskPaths, masks: masks, context: contextA)
        let keyedB = keyed(filesB, maskPaths: maskPaths, masks: masks, context: contextB)

        var found: [String] = []
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

    private static func keyed(_ files: [String: URL], maskPaths: Bool, masks: [Mask], context: MaskContext) -> [String: URL] {
        guard maskPaths else { return files }
        var result: [String: URL] = [:]
        for (name, url) in files {
            result[applying(masks, to: name, context: context)] = url
        }
        return result
    }

    /// Numbers each run ID in one tree by first appearance, file names first,
    /// then the contents of each text file in path order.
    static func runIDNumbers(in files: [String: URL]) -> [String: Int] {
        var numbers: [String: Int] = [:]
        func record(_ text: String) {
            let source = text as NSString
            for match in Masks.runIDPattern.matches(in: text, range: NSRange(location: 0, length: source.length)) {
                let value = source.substring(with: match.range).lowercased()
                if numbers[value] == nil { numbers[value] = numbers.count + 1 }
            }
        }
        let names = files.keys.sorted()
        names.forEach(record)
        for name in names {
            guard let url = files[name],
                  let data = try? Data(contentsOf: url),
                  !isGzip(data),
                  let text = String(data: data, encoding: .utf8)
            else { continue }
            record(text)
        }
        return numbers
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
                return "  line \(index + 1)\n    A: \(lineA.prefix(300))\n    B: \(lineB.prefix(300))"
            }
        }
        return "  (no line differs)"
    }
}
