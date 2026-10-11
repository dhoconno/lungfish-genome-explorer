// ProvenanceStepParentSupport.swift - What the step parent test classes share
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest

enum StepParentSupport {
    /// The project folder the synthetic records name.
    static let project = "/Users/tester/Demo.lungfish"

    /// The lines of `script` that run something: no comment, no blank line and none of the fixed
    /// preamble every script opens with.
    static func commandLines(of script: String) -> [String] {
        let preamble = ["set ", "PROJECT=", "OUTDIR=", "mkdir ", "INPUT_", "echo "]
        return script.split(separator: "\n", omittingEmptySubsequences: true).map(String.init).filter { line in
            !line.hasPrefix("#") && !preamble.contains { line.hasPrefix($0) }
        }
    }

    /// One stored property of a value, by reflection.
    struct Property {
        let name: String
        let text: String
        let isUnset: Bool
    }

    /// The stored properties of `value` in declaration order, each with its text and whether it is
    /// nil or empty.
    static func properties(of value: Any) -> [Property] {
        Mirror(reflecting: value).children.compactMap { child in
            guard let name = child.label else { return nil }
            let mirror = Mirror(reflecting: child.value)
            let isUnset: Bool
            switch mirror.displayStyle {
            case .optional, .collection, .dictionary, .set: isUnset = mirror.children.isEmpty
            default: isUnset = (child.value as? String)?.isEmpty == true
            }
            return Property(name: name, text: "\(child.value)", isUnset: isUnset)
        }
    }
}

extension XCTestCase {
    /// A fresh temporary folder, removed when the test ends.
    func makeStepParentDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("step-parent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.resolvingSymlinksInPath()
    }

    /// Fails for each stored property of `fixture` that is nil or empty. A fixture that leaves one
    /// unset would pass a carry check even if the code under test dropped that property.
    func assertEveryPropertyIsSet(
        in fixture: Any,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            StepParentSupport.properties(of: fixture).filter(\.isUnset).map(\.name), [],
            "set every property in the fixture, or a rebuild that drops it passes", file: file, line: line
        )
    }

    /// Fails for each stored property of `rebuilt` that the site does not rewrite and that differs
    /// from `original`'s, and when the two do not have the same properties.
    func assertEveryPropertyCarried(
        _ rebuilt: Any,
        from original: Any,
        except rewritten: Set<String>,
        _ site: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let before = Dictionary(uniqueKeysWithValues: StepParentSupport.properties(of: original).map { ($0.name, $0.text) })
        let after = StepParentSupport.properties(of: rebuilt)
        for property in after where !rewritten.contains(property.name) {
            XCTAssertEqual(
                property.text, before[property.name],
                "\(site) changed or dropped \(property.name)", file: file, line: line
            )
        }
        XCTAssertEqual(
            Set(after.map(\.name)), Set(before.keys),
            "\(site) returned a value with other properties", file: file, line: line
        )
    }
}
