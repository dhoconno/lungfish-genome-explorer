// AnalysisTemplateLibraryTests.swift - App-wide template library
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishTestSupport
import XCTest
@testable import LungfishWorkflow

final class AnalysisTemplateLibraryTests: XCTestCase {

    func testDefaultDirectoryIsBesideUserRecipes() {
        let appSupport = URL(fileURLWithPath: "/tmp/AppSupport")
        let library = AnalysisTemplateLibrary.defaultDirectoryURL(appIdentity: .current, applicationSupportDirectory: appSupport)
        let recipes = RecipeRegistryV2.userRecipesDirectoryURL(appIdentity: .current, applicationSupportDirectory: appSupport)
        XCTAssertEqual(library.deletingLastPathComponent().path, recipes.deletingLastPathComponent().path)
        XCTAssertEqual(library.lastPathComponent, "Workflow Templates")
    }

    func testSaveListResolveAndDelete() throws {
        let root = try TestTempDirectory.make(prefix: "template-library")
        defer { TestTempDirectory.cleanup(root) }
        let library = AnalysisTemplateLibrary(directoryURL: root.appendingPathComponent("Workflow Templates"))
        XCTAssertTrue(library.list().isEmpty)

        var template = try AnalysisTemplateModelTests.sampleTemplate()
        template.name = "Kraken2: viral/screen?"
        let first = try library.save(template)
        XCTAssertEqual(first.lastPathComponent, "Kraken2- viral-screen-.lungfishtemplate")
        let second = try library.save(template)
        XCTAssertEqual(second.lastPathComponent, "Kraken2- viral-screen--2.lungfishtemplate")

        let entries = library.list()
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.map(\.name), ["Kraken2: viral/screen?", "Kraken2: viral/screen?"])
        XCTAssertNil(entries[0].loadError)

        XCTAssertEqual(library.resolve(first.path), first)
        XCTAssertEqual(library.resolve("kraken2: VIRAL/screen?"), first)
        XCTAssertEqual(library.resolve("Kraken2- viral-screen--2"), second)
        XCTAssertEqual(library.resolve("Kraken2- viral-screen--2.lungfishtemplate"), second)
        XCTAssertNil(library.resolve("does not exist"))

        try library.delete(at: first)
        XCTAssertEqual(library.list().map(\.url), [second])
    }

    func testUnreadableTemplateIsListedWithItsError() throws {
        let root = try TestTempDirectory.make(prefix: "template-library")
        defer { TestTempDirectory.cleanup(root) }
        let directory = root.appendingPathComponent("Workflow Templates")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{\"schemaVersion\": 9}".utf8).write(to: directory.appendingPathComponent("Future.lungfishtemplate"))
        try Data("not json".utf8).write(to: directory.appendingPathComponent("Broken.lungfishtemplate"))
        try Data("{}".utf8).write(to: directory.appendingPathComponent("ignored.json"))

        let entries = AnalysisTemplateLibrary(directoryURL: directory).list()
        XCTAssertEqual(entries.map(\.name), ["Broken", "Future"])
        XCTAssertTrue(entries[1].loadError?.contains("newer version of LGE") == true)
        XCTAssertNotNil(entries[0].loadError)
        XCTAssertNil(entries[0].template)
    }
}
