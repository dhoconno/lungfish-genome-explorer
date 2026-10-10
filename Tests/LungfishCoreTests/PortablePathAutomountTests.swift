// PortablePathAutomountTests.swift - Canonical paths memoized per sanitize call, byte for byte
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import XCTest
@testable import LungfishCore

/// Plan decision S2. A sanitizer canonicalizes every absolute path a record
/// names, one `realpath(3)` per prefix until one resolves, and below `/home`
/// each probe asks autofs, which took tens of seconds for a 35-path record.
/// One sanitize call now memoizes those probes in a local cache in which a
/// missing prefix answers for its descendants. The canonical paths feed
/// recorded digests, so they must stay byte for byte what they were.
final class PortablePathAutomountTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("automount-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("P.lungfish/Analyses/run-1"),
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testCachedCanonicalPathsEqualTheUncachedCodeForEveryGoldenPathValue() throws {
        let golden = Self.fixtures.appendingPathComponent("golden", isDirectory: true)
        let compared = try compareEveryPathValue(in: golden)
        XCTAssertGreaterThan(compared, 300, "every golden record was read")
    }

    func testCachedCanonicalPathsEqualTheUncachedCodeForEveryCorpusPathValue() throws {
        let corpus = Self.fixtures.appendingPathComponent("provenance-compat", isDirectory: true)
        XCTAssertGreaterThan(try compareEveryPathValue(in: corpus), 300)
    }

    func testCachedCanonicalPathsEqualTheUncachedCodeForUnusualSpellings() throws {
        let existing = root.appendingPathComponent("P.lungfish/Analyses").path
        let values = [
            "/", "/tmp", "/var", "/private/tmp/lge-missing/x", "/var/folders/lge-missing/x.json",
            existing, existing + "/run-1", existing + "/run-1/out.bam", existing + "/missing/deeper/out.bam",
            existing + "//run-1//out.bam", existing + "/./run-1/../run-1/out.bam", existing + "/run-1/out.bam/",
            existing + "/caf\u{E9}/\u{FC}ber.json", existing + "/with space/a b.json", existing + "/100%/x%20y",
            "/lge-no-such-root/a/b/c", "/srv/corpus/.lungfish/x", "/Volumes/lge-no-such-drive/P.lungfish/x",
        ]
        var cache = CanonicalFilePath.Cache()
        for value in values + values {
            let uncached = Self.uncachedPath(for: URL(fileURLWithPath: value))
            XCTAssertEqual(
                CanonicalFilePath.path(for: URL(fileURLWithPath: value, isDirectory: false), cache: &cache),
                uncached,
                value
            )
        }
    }

    func testA35PathHomeRecordMakesABoundedNumberOfCanonicalizerCalls() throws {
        // The corpus receipt as it was captured, before `/home/corpus` became
        // `/srv/corpus` (Tests/Fixtures/provenance-compat/README.md).
        let corpus = Self.fixtures.appendingPathComponent(
            "provenance-compat/cases/s1-db-receipt-kraken2-viral/managed-storage/databases/kraken2/viral/.lungfish-provenance.json"
        )
        let text = try String(contentsOf: corpus, encoding: .utf8)
            .replacingOccurrences(of: "\\/srv\\/corpus", with: "\\/home\\/corpus")
        XCTAssertEqual(text.components(separatedBy: "\\/home\\/corpus").count - 1, 35)

        // Paths below /home never reach autofs here: the injected
        // canonicalizer answers them and counts each probe.
        let probes = ProbeLog()
        let canonicalizer: @Sendable (String) -> String? = { path in
            guard path == "/home" || path.hasPrefix("/home/") else { return Self.realPath(path) }
            probes.append(path)
            return path == "/home" ? "/System/Volumes/Data/home" : nil
        }
        let record = root.appendingPathComponent("P.lungfish/Analyses/run-1/.lungfish-provenance.json")
        let context = PortablePath.Context.forFile(
            at: record,
            toolRootURL: root.appendingPathComponent("tool-root", isDirectory: true),
            storageRootURL: root.appendingPathComponent("storage-root", isDirectory: true)
        )
        let sanitized = try CanonicalFilePath.$canonicalizerOverride.withValue(canonicalizer) {
            try PortablePath.sanitizeJSON(Data(text.utf8), context: context)
        }

        // The deepest path has seven prefixes from its own name up to /home.
        // Each is probed once, and the other 34 values cost nothing.
        XCTAssertLessThanOrEqual(probes.paths.count, 7, "\(probes.paths)")
        XCTAssertEqual(Set(probes.paths).count, probes.paths.count, "no prefix is probed twice")
        let uncachedProbes = probesWithoutCache(text: text)
        XCTAssertGreaterThanOrEqual(uncachedProbes, 35 * 6, "without the cache every value walks to /home")

        let strings = try Self.strings(in: sanitized)
        XCTAssertFalse(strings.contains { $0.contains("/home/corpus") }, "no account path is recorded")
        XCTAssertTrue(strings.contains("\(PortablePath.externalPlaceholder)/taxo.k2d"))
    }

    // MARK: - The reference

    /// `CanonicalFilePath.path(for:)` as it stood before the cache (commit
    /// 90d34c550), copied verbatim with its resolver made injectable.
    static func uncachedPath(
        for url: URL,
        resolve: (String) -> String? = { realPath($0) }
    ) -> String {
        let standardized = url.standardizedFileURL.path
        var existing = standardized
        var pending: [String] = []
        while true {
            if let root = resolve(existing) {
                guard !pending.isEmpty else { return root }
                let tail = pending.reversed().joined(separator: "/")
                return root == "/" ? "/" + tail : root + "/" + tail
            }
            let parentURL = URL(fileURLWithPath: existing).deletingLastPathComponent()
            let parent = parentURL.path
            guard parent != existing, !existing.isEmpty else { return standardized }
            pending.append(URL(fileURLWithPath: existing).lastPathComponent)
            existing = parent
        }
    }

    static func realPath(_ path: String) -> String? {
        guard let resolved = path.withCString({ realpath($0, nil) }) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    // MARK: - Helpers

    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)

    final class ProbeLog: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [String] = []

        func append(_ path: String) {
            lock.withLock { recorded.append(path) }
        }

        var paths: [String] {
            lock.withLock { recorded }
        }
    }

    /// Compares the cached canonical path with the uncached reference for
    /// every path value of every JSON record under `folder`, one cache per
    /// record as one sanitize call uses it. Returns how many were compared.
    private func compareEveryPathValue(in folder: URL) throws -> Int {
        let project = root.appendingPathComponent("P.lungfish", isDirectory: true)
        var compared = 0
        for record in try Self.jsonFiles(under: folder) {
            var cache = CanonicalFilePath.Cache()
            for value in try Self.pathValues(in: Data(contentsOf: record), project: project, root: root) {
                let uncached = Self.uncachedPath(for: URL(fileURLWithPath: value))
                let cached = CanonicalFilePath.path(for: URL(fileURLWithPath: value, isDirectory: false), cache: &cache)
                XCTAssertEqual(cached, uncached, "\(record.lastPathComponent): \(value)")
                XCTAssertEqual(CanonicalFilePath.path(for: URL(fileURLWithPath: value)), uncached, value)
                compared += 1
            }
        }
        return compared
    }

    private func probesWithoutCache(text: String) -> Int {
        var count = 0
        for value in (try? Self.pathValues(in: Data(text.utf8), project: root, root: root, keepingHome: true)) ?? []
        where value.hasPrefix("/home/") {
            _ = Self.uncachedPath(for: URL(fileURLWithPath: value, isDirectory: false)) { path in
                count += 1
                return path == "/home" ? "/System/Volumes/Data/home" : nil
            }
        }
        return count
    }

    static func jsonFiles(under folder: URL) throws -> [URL] {
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        return (enumerator?.compactMap { $0 as? URL } ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.path < $1.path }
    }

    static func strings(in data: Data) throws -> [String] {
        var found: [String] = []
        func walk(_ node: Any) {
            if let text = node as? String {
                found.append(text)
            } else if let array = node as? [Any] {
                array.forEach(walk)
            } else if let object = node as? [String: Any] {
                object.values.forEach(walk)
            }
        }
        walk(try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
        return found
    }

    /// Every absolute path a record's strings name, and every placeholder
    /// path placed under a test folder so its prefixes partly exist.
    static func pathValues(in data: Data, project: URL, root: URL, keepingHome: Bool = false) throws -> [String] {
        let placeholders = [
            PortablePath.projectPrefix: project.path + "/",
            "<tool-root>/": root.path + "/tool-root/",
            "<storage-root>/": root.path + "/storage-root/",
            "<workspace>/": root.path + "/workspace/",
            "<bundle>/": root.path + "/bundle.lungfishfastq/",
            "<external>/": root.path + "/external/",
        ]
        var values: [String] = []
        for text in try strings(in: data) where text.contains("/") {
            if text.hasPrefix("/"), text.count > 1, !text.hasPrefix("//") {
                values.append(text)
            }
            let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'=,;()[]"))
            for token in text.components(separatedBy: separators) where token.count > 1 {
                if token.hasPrefix("/"), !token.hasPrefix("//") {
                    values.append(token)
                    values.append(token.trimmingCharacters(in: CharacterSet(charactersIn: ".:")))
                }
                for (placeholder, replacement) in placeholders where token.hasPrefix(placeholder) {
                    values.append(replacement + token.dropFirst(placeholder.count))
                }
            }
        }
        // Real probes below /home ask autofs, so only the injected canonicalizer sees them.
        return values.filter { $0.hasPrefix("/") && $0.count > 1 && (keepingHome || !$0.hasPrefix("/home")) }
    }
}
