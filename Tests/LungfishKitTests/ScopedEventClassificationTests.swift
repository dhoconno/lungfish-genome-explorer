// ScopedEventClassificationTests.swift - Every notification name is window or application (R9)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import LungfishKit
import LungfishTestSupport

/// Keeps `ScopedEventFilter.classifications` equal to the notification names
/// declared under Sources. A new `Notification.Name("...")` fails the first
/// test until it is classified, and a removed or renamed one fails the second
/// until its stale entry goes.
final class ScopedEventClassificationTests: XCTestCase {
    func testEveryDeclaredNotificationNameIsClassified() throws {
        let declared = try Self.declaredNotificationNames()
        let classified = Set(ScopedEventFilter.classifications.keys.map(\.rawValue))
        let unclassified = declared.keys
            .filter { !classified.contains($0) }
            .sorted()
            .map { "\($0) (\(declared[$0] ?? ""))" }

        XCTAssertEqual(
            unclassified,
            [],
            "Add each name to ScopedEventFilter.classifications in Sources/LungfishKit/ScopedEventFilter.swift as .window or .application"
        )
    }

    func testEveryClassifiedNameIsStillDeclared() throws {
        let declared = try Self.declaredNotificationNames()
        let stale = ScopedEventFilter.classifications.keys
            .map(\.rawValue)
            .filter { declared[$0] == nil }
            .sorted()

        XCTAssertEqual(stale, [], "Remove these names from ScopedEventFilter.classifications or restore their declarations")
    }

    func testTheScanFindsNamesFromEveryDeclaringModule() throws {
        let declared = try Self.declaredNotificationNames()

        XCTAssertNotNil(declared["annotationSelected"], "LungfishCore")
        XCTAssertNotNil(declared["com.lungfish.metagenomicsSampleSelectionChanged"], "LungfishKit")
        XCTAssertNotNil(declared["SidebarSelectionChanged"], "LungfishApp")
        XCTAssertNotNil(declared["com.lungfish.dependencyReconciliationDidStart"], "a declaration that wraps its raw value onto the next line")
        XCTAssertNotNil(declared["createAnnotationFromSelection"], "a name built inline at its post site")
        XCTAssertNotNil(declared["com.lungfish.genotypeResultSmartCohortApplied"], "LungfishGenotypeUI")
        XCTAssertNotNil(declared["com.lungfish.assemblyLayoutSwapRequested"], "LungfishAssemblyUI")
    }

    /// Raw value to the first `path:line` that builds a `Notification.Name`
    /// from a string literal, over every Swift file under Sources except the
    /// classification table itself.
    private static func declaredNotificationNames() throws -> [String: String] {
        let root = CLITestBinaryResolver.repositoryRoot(containing: #filePath)
        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        let table = sources.appendingPathComponent("LungfishKit/ScopedEventFilter.swift").standardizedFileURL.path
        let pattern = try NSRegularExpression(
            pattern: #"(?:NS)?Notification\.Name\(\s*(?:rawValue:\s*)?"([^"\\]+)"\s*\)"#
        )
        var declared: [String: String] = [:]
        for url in try repositoryFiles(under: sources) {
            let path = url.standardizedFileURL.path
            guard path != table else { continue }
            let text = try readRepositorySource(url)
            // Blank comment lines but keep the line count, so locations stay right.
            let code = text
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces).hasPrefix("//") ? "" : $0 }
                .joined(separator: "\n")
            let range = NSRange(code.startIndex..., in: code)
            for match in pattern.matches(in: code, range: range) {
                guard let rawRange = Range(match.range(at: 1), in: code),
                      let fullRange = Range(match.range, in: code) else { continue }
                let rawValue = String(code[rawRange])
                guard declared[rawValue] == nil else { continue }
                let line = code[..<fullRange.lowerBound].reduce(into: 1) { count, character in
                    if character == "\n" { count += 1 }
                }
                let relative = String(path.dropFirst(root.standardizedFileURL.path.count + 1))
                declared[rawValue] = "\(relative):\(line)"
            }
        }
        return declared
    }
}
