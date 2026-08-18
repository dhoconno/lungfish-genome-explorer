// NoLiteralDependencyPinsTests.swift - Guards against duplicated conda-spec pins outside the manifest
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest

final class NoLiteralDependencyPinsTests: XCTestCase {
    /// Files that may legitimately contain conda specs.
    private let allowlist: [String] = [
        "Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json",
        "Sources/LungfishWorkflow/Conda/CondaManager.swift",           // channel names, not pins
        "Sources/LungfishCLI/Commands/CondaCommand.swift",             // help text examples
    ]

    func testNoCondaSpecLiteralsOutsideManifest() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sourcesRoot = root.appendingPathComponent("Sources")
        let pattern = try NSRegularExpression(pattern: #"\b(bioconda|conda-forge)::[a-z0-9_.-]+=[0-9]"#)
        var offenders: [String] = []
        let enumerator = FileManager.default.enumerator(at: sourcesRoot, includingPropertiesForKeys: nil)!
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let rel = url.path.replacingOccurrences(of: root.path + "/", with: "")
            if allowlist.contains(rel) { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            if pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                offenders.append(rel)
            }
        }
        XCTAssertTrue(offenders.isEmpty, "Conda spec literals outside the manifest:\n" + offenders.joined(separator: "\n"))
    }
}
