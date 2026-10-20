// ViewerGraphicsLayeringTests.swift - The figure renderer imports no UI framework
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane 13.28 (GFX-0, ruling section 2.2 of ARCH-B10-graphics). The renderer must run in
// `lungfish-cli` with no window server, so its folder imports only Foundation, CoreGraphics,
// CoreText, ImageIO, LungfishCore and LungfishIO. This is an import scan, the same form as
// the module-map check. It reads only `import` lines and asserts nothing about behaviour.

import Foundation
import XCTest
import LungfishTestSupport

final class ViewerGraphicsLayeringTests: XCTestCase {
    private static let folder = "Sources/LungfishWorkflow/ViewerExport/Graphics"
    private static let forbidden: Set<String> = ["AppKit", "SwiftUI", "LungfishKit", "Quartz"]
    private static let allowed: Set<String> = [
        "Foundation", "CoreGraphics", "CoreText", "ImageIO", "LungfishCore", "LungfishIO",
    ]
    private static let modifiers: Set<String> = ["public", "package", "internal", "fileprivate", "private"]
    private static let kinds: Set<String> = [
        "struct", "class", "enum", "protocol", "typealias", "func", "var", "let",
    ]

    /// The module named by each import line of `source`, attributes, modifiers and kinds skipped.
    static func importedModules(in source: String) -> [String] {
        source.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line in
            var words = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            while let first = words.first, first.hasPrefix("@") || modifiers.contains(first) {
                words.removeFirst()
            }
            guard words.first == "import", words.count >= 2 else { return nil }
            var path = words[1]
            if kinds.contains(path), words.count >= 3 {
                path = words[2]
            }
            return path.split(separator: ".").first.map(String.init)
        }
    }

    private func repositoryRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while url.pathComponents.count > 1 {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
            url = url.deletingLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "Package.swift above \(#filePath)"])
    }

    /// Every Swift file of the folder, with the modules it imports.
    private func folderImports() throws -> [(file: String, modules: [String])] {
        let folderURL = try repositoryRoot().appendingPathComponent(Self.folder, isDirectory: true)
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: folderURL, includingPropertiesForKeys: nil))
        var result: [(file: String, modules: [String])] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let source = try readRepositorySource(url)
            result.append((url.lastPathComponent, Self.importedModules(in: source)))
        }
        return result.sorted { $0.file < $1.file }
    }

    func testGraphicsFolderImportsNoUIFramework() throws {
        let files = try folderImports()
        XCTAssertGreaterThanOrEqual(files.count, 2, "the scan found no renderer files")
        for (file, modules) in files {
            XCTAssertFalse(modules.isEmpty, "\(file) has no import line")
            let found = Set(modules).intersection(Self.forbidden)
            XCTAssertTrue(found.isEmpty, "\(file) imports \(found.sorted())")
        }
    }

    func testGraphicsFolderImportsOnlyTheRulingsFrameworks() throws {
        for (file, modules) in try folderImports() {
            let extra = Set(modules).subtracting(Self.allowed)
            XCTAssertTrue(extra.isEmpty, "\(file) imports \(extra.sorted())")
        }
    }

    func testScanFindsEveryFormOfAnImport() {
        // Negative controls, so a violation in any of these forms cannot pass unseen.
        let source = """
            // import SwiftUI
            @preconcurrency import AppKit
            @_implementationOnly import LungfishKit
            public import Quartz.PDFKit
            import struct SwiftUI.Color
            \timport CoreText
            let importance = 1
            """
        XCTAssertEqual(Self.importedModules(in: source), ["AppKit", "LungfishKit", "Quartz", "SwiftUI", "CoreText"])
        XCTAssertEqual(
            Set(Self.importedModules(in: source)).intersection(Self.forbidden),
            ["AppKit", "LungfishKit", "Quartz", "SwiftUI"]
        )
    }
}
