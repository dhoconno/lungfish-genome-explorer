// DemoProjectManifestTests.swift - Manifest decoding and validation
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

final class DemoProjectManifestTests: XCTestCase {
    private let expectedIDs = [
        "genes-and-sequences",
        "human-reads",
        "human-mapping-and-variants",
        "long-reads-and-assembly",
        "sarscov2-amplicons",
        "pathogen-detection",
        "mhc-genotyping",
        "twelve-s-metabarcoding",
    ]

    func testBundledManifestListsTheEightDemoProjects() throws {
        let manifest = try DemoProjectManifest.loadBundled()
        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.projects.map(\.id), expectedIDs)
        for project in manifest.projects {
            XCTAssertFalse(project.summary.isEmpty, project.id)
            XCTAssertTrue(project.projectFolderName.hasSuffix(".lungfish"), project.id)
            XCTAssertFalse(project.chapters.isEmpty, project.id)
            for chapter in project.chapters {
                let url = try XCTUnwrap(chapter.url)
                XCTAssertTrue(
                    url.absoluteString.hasPrefix("https://lungfish-genome-explorer.readthedocs.io/en/latest/chapters/"),
                    url.absoluteString
                )
            }
        }
    }

    func testBundledManifestPointsAtPublishedArchives() throws {
        let manifest = try DemoProjectManifest.loadBundled()
        XCTAssertEqual(manifest.projects.count, 8)
        for project in manifest.projects {
            XCTAssertFalse(project.archive.isPlaceholder, project.id)
            XCTAssertGreaterThan(project.archive.bytes, 0, project.id)
            XCTAssertEqual(project.archive.sha256.count, 64, project.id)
            XCTAssertTrue(
                project.archive.url.absoluteString.hasPrefix(
                    "https://github.com/dhoconno/lungfish-genome-explorer/releases/download/demo-projects/"
                ),
                project.id
            )
            XCTAssertNoThrow(try project.ensurePublished(), project.id)
        }
    }

    func testPlaceholderArchivesDecodeButRefuseToDownload() throws {
        let manifest = try DemoProjectManifestTests.placeholderManifest()
        let project = try XCTUnwrap(manifest.project(id: "human-reads"))
        XCTAssertTrue(project.archive.isPlaceholder)
        XCTAssertThrowsError(try project.ensurePublished()) { error in
            guard case DemoProjectError.archiveNotPublished(let title) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(title, "Human Reads")
            XCTAssertTrue(error.localizedDescription.contains("has not been published yet"))
        }
    }

    /// The bundled manifest with every archive reset to the unpublished placeholder
    /// (zero checksum, zero bytes), for exercising the refusal path.
    static func placeholderManifest() throws -> DemoProjectManifest {
        let url = try XCTUnwrap(DemoProjectManifest.bundledManifestURL())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var projects = try XCTUnwrap(object["projects"] as? [[String: Any]])
        for index in projects.indices {
            var archive = try XCTUnwrap(projects[index]["archive"] as? [String: Any])
            archive["sha256"] = String(repeating: "0", count: 64)
            archive["bytes"] = 0
            projects[index]["archive"] = archive
        }
        object["projects"] = projects
        return try DemoProjectManifest.decode(from: JSONSerialization.data(withJSONObject: object))
    }

    func testChapterPathsResolveAgainstTheManual() throws {
        let chapter = DemoProject.Chapter(title: "Importing", path: "chapters/02-sequences/01-importing-and-viewing/")
        XCTAssertEqual(
            chapter.url?.absoluteString,
            "https://lungfish-genome-explorer.readthedocs.io/en/latest/chapters/02-sequences/01-importing-and-viewing/"
        )
    }

    func testDecodesMinimalValidManifest() throws {
        let manifest = try DemoProjectManifest.decode(from: Data(manifestJSON().utf8))
        XCTAssertEqual(manifest.projects.first?.archive.bytes, 12345)
        XCTAssertFalse(manifest.projects.first?.archive.isPlaceholder ?? true)
        XCTAssertNoThrow(try manifest.projects.first?.ensurePublished())
    }

    func testRejectsUnsupportedSchemaVersion() {
        assertInvalid(manifestJSON(schemaVersion: 2), contains: "schema version 2")
    }

    func testRejectsDuplicateIDs() {
        let project = projectJSON()
        let json = "{\"schemaVersion\":1,\"projects\":[\(project),\(project)]}"
        assertInvalid(json, contains: "more than once")
    }

    func testRejectsUnsafeFolderNames() {
        assertInvalid(manifestJSON(folder: "../Escape.lungfish"), contains: "project folder name")
        assertInvalid(manifestJSON(folder: "a/b.lungfish"), contains: "project folder name")
        assertInvalid(manifestJSON(folder: "NoExtension"), contains: "project folder name")
        assertInvalid(manifestJSON(folder: ".hidden.lungfish"), contains: "project folder name")
    }

    func testRejectsNonHTTPSArchivesBadHashesAndChapterTraversal() {
        assertInvalid(manifestJSON(url: "http://example.com/a.zip"), contains: "https")
        assertInvalid(manifestJSON(sha: "abc"), contains: "64 hexadecimal")
        assertInvalid(manifestJSON(sha: String(repeating: "z", count: 64)), contains: "64 hexadecimal")
        assertInvalid(manifestJSON(chapterPath: "../../etc/"), contains: "chapter path")
        assertInvalid(manifestJSON(chapterPath: "https://evil.example/"), contains: "chapter path")
        assertInvalid(manifestJSON(id: "Bad ID"), contains: "lowercase")
    }

    func testMalformedJSONIsAClearError() {
        assertInvalid("{not json", contains: "could not be read")
    }

    func testVersionComparisonIsNumeric() {
        XCTAssertEqual(DemoProjectVersion.compare("2026.9.44", "2026.9.8"), .orderedDescending)
        XCTAssertEqual(DemoProjectVersion.compare("2026.9.8", "2026.9.44"), .orderedAscending)
        XCTAssertEqual(DemoProjectVersion.compare("2026.9", "2026.9.0"), .orderedSame)
    }

    func testMinimumAppVersionGate() throws {
        let manifest = try DemoProjectManifest.decode(from: Data(manifestJSON(minimumAppVersion: "2026.9.44").utf8))
        let project = try XCTUnwrap(manifest.projects.first)
        XCTAssertTrue(project.isSupported(byAppVersion: "2026.9.44"))
        XCTAssertTrue(project.isSupported(byAppVersion: "2026.10.1"))
        XCTAssertFalse(project.isSupported(byAppVersion: "2026.9.43"))
    }

    // MARK: - Helpers

    private func assertInvalid(_ json: String, contains fragment: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try DemoProjectManifest.decode(from: Data(json.utf8)), file: file, line: line) { error in
            guard case DemoProjectError.invalidManifest(let message) = error else {
                return XCTFail("unexpected error \(error)", file: file, line: line)
            }
            XCTAssertTrue(message.contains(fragment), "“\(message)” lacks “\(fragment)”", file: file, line: line)
        }
    }

    private func projectJSON(
        id: String = "genes-and-sequences",
        folder: String = "Genes and Sequences.lungfish",
        url: String = "https://github.com/dhoconno/lungfish-genome-explorer/releases/download/demo-projects/lge-demo-genes.zip",
        sha: String = String(repeating: "ab", count: 32),
        chapterPath: String = "chapters/02-sequences/01-importing-and-viewing/",
        minimumAppVersion: String = "2026.9.44"
    ) -> String {
        """
        {"id":"\(id)","title":"Genes and Sequences","summary":"Sequences.",
         "chapters":[{"title":"Importing","path":"\(chapterPath)"}],
         "projectFolderName":"\(folder)",
         "archive":{"url":"\(url)","sha256":"\(sha)","bytes":12345},
         "version":"2026.9.44","minimumAppVersion":"\(minimumAppVersion)"}
        """
    }

    private func manifestJSON(
        schemaVersion: Int = 1,
        id: String = "genes-and-sequences",
        folder: String = "Genes and Sequences.lungfish",
        url: String = "https://github.com/dhoconno/lungfish-genome-explorer/releases/download/demo-projects/lge-demo-genes.zip",
        sha: String = String(repeating: "ab", count: 32),
        chapterPath: String = "chapters/02-sequences/01-importing-and-viewing/",
        minimumAppVersion: String = "2026.9.44"
    ) -> String {
        let project = projectJSON(id: id, folder: folder, url: url, sha: sha, chapterPath: chapterPath, minimumAppVersion: minimumAppVersion)
        return "{\"schemaVersion\":\(schemaVersion),\"projects\":[\(project)]}"
    }
}
