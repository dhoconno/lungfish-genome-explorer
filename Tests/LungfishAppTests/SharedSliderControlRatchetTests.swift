// SharedSliderControlRatchetTests.swift - every slider goes through the shared control
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest

/// Owner decision D10: every slider in LGE uses one shared control
/// (`NumericSliderField` / `InlineNumericSliderField` in LungfishKit) so each
/// has the same look and a numeric field for direct entry. This ratchet fails
/// when a raw SwiftUI `Slider(` or an AppKit `NSSlider(` appears anywhere else
/// in `Sources/`.
final class SharedSliderControlRatchetTests: XCTestCase {
    /// The only file allowed to construct a raw SwiftUI `Slider`.
    private static let sharedControlPath = "Sources/LungfishKit/NumericSliderField.swift"

    /// Files still pending migration. Keep this list shrinking, never growing.
    private static let allowlist: Set<String> = [
        // Another lane is editing this file concurrently. The orchestrator
        // migrates its two sliders afterwards and removes this entry.
        "Sources/LungfishApp/Views/Inspector/Sections/ReadStyleSection.swift",
    ]

    func testRawSwiftUISlidersOnlyAppearInSharedControl() throws {
        let violations = try scan(for: "Slider(") { line in
            // `NSSlider(` and identifiers such as `NumericSliderField(` are
            // handled elsewhere or are the shared control itself.
            Self.containsBareToken("Slider(", in: line)
        }
        XCTAssertTrue(
            violations.isEmpty,
            "Use NumericSliderField or InlineNumericSliderField (LungfishKit) instead of a raw Slider:\n"
                + violations.joined(separator: "\n")
        )
    }

    func testNoAppKitSliderConstruction() throws {
        let violations = try scan(for: "NSSlider(") { line in
            line.contains("NSSlider(")
        }
        XCTAssertTrue(
            violations.isEmpty,
            "Use the shared SwiftUI NumericSliderField instead of constructing an NSSlider:\n"
                + violations.joined(separator: "\n")
        )
    }

    func testAllowlistEntriesStillNeedTheirExemption() throws {
        // A stale entry would silently let a regression back into that file.
        let root = repositoryRoot()
        for path in Self.allowlist {
            let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            let stillHasSlider = source.components(separatedBy: .newlines).contains { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !isCommentLine(trimmed) && Self.containsBareToken("Slider(", in: trimmed)
            }
            XCTAssertTrue(stillHasSlider, "\(path) no longer needs its allowlist entry; remove it.")
        }
    }

    func testBareTokenMatcherIgnoresPrefixedIdentifiers() {
        XCTAssertTrue(Self.containsBareToken("Slider(", in: "Slider(value: $x, in: 0...1)"))
        XCTAssertTrue(Self.containsBareToken("Slider(", in: "let s = Slider(value: $x)"))
        XCTAssertFalse(Self.containsBareToken("Slider(", in: "NumericSliderField(\"Height\","))
        XCTAssertFalse(Self.containsBareToken("Slider(", in: "InlineNumericSliderField("))
        XCTAssertFalse(Self.containsBareToken("Slider(", in: "let s = NSSlider(value: 1)"))
    }

    // MARK: - Helpers

    /// True when `token` occurs in `line` without an identifier character
    /// directly before it, so `Slider(` matches but `NumericSliderField(`,
    /// `NSSlider(` and `mySlider(` do not.
    static func containsBareToken(_ token: String, in line: String) -> Bool {
        var searchRange = line.startIndex..<line.endIndex
        while let range = line.range(of: token, range: searchRange) {
            if range.lowerBound == line.startIndex {
                return true
            }
            let previous = line[line.index(before: range.lowerBound)]
            if !(previous.isLetter || previous.isNumber || previous == "_") {
                return true
            }
            searchRange = range.upperBound..<line.endIndex
        }
        return false
    }

    private func scan(for needle: String, matches: (String) -> Bool) throws -> [String] {
        let root = repositoryRoot()
        let files = try swiftSourceFiles(under: root.appendingPathComponent("Sources", isDirectory: true))
        var violations: [String] = []
        for file in files {
            let path = relativePath(file, root: root)
            if path == Self.sharedControlPath || Self.allowlist.contains(path) {
                continue
            }
            let source = try String(contentsOf: file, encoding: .utf8)
            guard source.contains(needle) else { continue }
            for (index, line) in source.components(separatedBy: .newlines).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !isCommentLine(trimmed), matches(trimmed) {
                    violations.append("\(path):\(index + 1)")
                }
            }
        }
        return violations
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func swiftSourceFiles(under root: URL) throws -> [URL] {
        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var files: [URL] = []
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            if try file.resourceValues(forKeys: resourceKeys).isRegularFile == true {
                files.append(file)
            }
        }
        return files
    }

    private func relativePath(_ url: URL, root: URL) -> String {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return url.path.hasPrefix(rootPath) ? String(url.path.dropFirst(rootPath.count)) : url.path
    }

    private func isCommentLine(_ trimmedLine: String) -> Bool {
        trimmedLine.hasPrefix("//") || trimmedLine.hasPrefix("/*") || trimmedLine.hasPrefix("*")
    }
}
