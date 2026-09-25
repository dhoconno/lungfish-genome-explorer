// DemoCommandTests.swift - Argument parsing and JSON shape for `lungfish-cli demo`
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import XCTest
@testable import LungfishCLI
@testable import LungfishWorkflow

final class DemoCommandTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("demo-command-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    func testDemoIsATopLevelCommandWithThreeSubcommands() throws {
        let names = LungfishCLI.configuration.subcommands.compactMap { $0.configuration.commandName }
        XCTAssertTrue(names.contains("demo"))
        XCTAssertEqual(
            DemoCommand.configuration.subcommands.compactMap { $0.configuration.commandName },
            ["list", "info", "fetch"]
        )
        let help = DemoCommand.helpMessage()
        XCTAssertTrue(help.contains("list"))
        XCTAssertTrue(help.contains("fetch"))
        XCTAssertTrue(help.contains("info"))
    }

    func testParsesListInfoAndFetch() throws {
        let list = try XCTUnwrap(DemoCommand.parseAsRoot(["list", "--format", "json", "--dest", "/tmp/demos"]) as? DemoCommand.ListSubcommand)
        XCTAssertEqual(list.location.destination, "/tmp/demos")
        XCTAssertEqual(list.location.destinationURL().path, "/tmp/demos")

        let info = try XCTUnwrap(DemoCommand.parseAsRoot(["info", "human-reads"]) as? DemoCommand.InfoSubcommand)
        XCTAssertEqual(info.id, "human-reads")

        let fetch = try XCTUnwrap(DemoCommand.parseAsRoot(["fetch", "mhc-genotyping", "--dest", "~/Demos", "--force"]) as? DemoCommand.FetchSubcommand)
        XCTAssertEqual(fetch.id, "mhc-genotyping")
        XCTAssertTrue(fetch.force)
        XCTAssertFalse(fetch.location.destinationURL().path.hasPrefix("~"))

        let plain = try XCTUnwrap(DemoCommand.parseAsRoot(["fetch", "human-reads"]) as? DemoCommand.FetchSubcommand)
        XCTAssertFalse(plain.force)

        XCTAssertThrowsError(try DemoCommand.parseAsRoot(["fetch"]))
        XCTAssertThrowsError(try DemoCommand.parseAsRoot(["list", "--format", "yaml"]))
    }

    func testDefaultDestinationIsDocumentsLGEDemoProjects() throws {
        let list = try XCTUnwrap(DemoCommand.parseAsRoot(["list"]) as? DemoCommand.ListSubcommand)
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        XCTAssertEqual(list.location.destinationURL(homeDirectory: home).path, "/Users/example/Documents/LGE Demo Projects")
    }

    func testListJSONShape() throws {
        let manifest = try DemoCommandTests.placeholderManifest()
        let destination = tempDir.appendingPathComponent("LGE Demo Projects", isDirectory: true)
        // One installed, current copy and one out-of-date copy.
        try install(manifest.project(id: "human-reads")!, version: manifest.project(id: "human-reads")!.version, in: destination)
        try install(manifest.project(id: "mhc-genotyping")!, version: "2026.1.1", in: destination)

        let json = try DemoCommand.encodeJSON(DemoCommand.listReport(for: manifest, in: destination))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["schemaVersion", "destination", "projects"])
        XCTAssertEqual(object["destination"] as? String, destination.path)
        let projects = try XCTUnwrap(object["projects"] as? [[String: Any]])
        XCTAssertEqual(projects.count, 8)
        XCTAssertEqual(
            Set(projects[0].keys),
            ["id", "title", "summary", "version", "minimumAppVersion", "bytes", "size", "published", "status",
             "installed", "installedVersion", "path", "archiveURL", "sha256", "chapters"]
        )
        let byID = Dictionary(uniqueKeysWithValues: projects.map { ($0["id"] as! String, $0) })
        XCTAssertEqual(byID["genes-and-sequences"]?["status"] as? String, "not-downloaded")
        XCTAssertEqual(byID["genes-and-sequences"]?["installed"] as? Bool, false)
        XCTAssertEqual(byID["genes-and-sequences"]?["published"] as? Bool, false)
        XCTAssertEqual(byID["human-reads"]?["status"] as? String, "downloaded")
        XCTAssertEqual(byID["mhc-genotyping"]?["status"] as? String, "update-available")
        XCTAssertEqual(byID["mhc-genotyping"]?["installedVersion"] as? String, "2026.1.1")
        XCTAssertEqual(
            byID["human-reads"]?["path"] as? String,
            destination.appendingPathComponent("Human Reads.lungfish").path
        )
        let chapters = try XCTUnwrap(byID["twelve-s-metabarcoding"]?["chapters"] as? [[String: String]])
        XCTAssertEqual(
            chapters.first?["url"],
            "https://lungfish-genome-explorer.readthedocs.io/en/latest/chapters/06-classification/10-twelve-s-metabarcoding/"
        )

        let table = DemoCommand.textTable(for: DemoCommand.listReport(for: manifest, in: destination))
        XCTAssertTrue(table.contains("Not published"))
        XCTAssertTrue(table.contains("Update available"))
        XCTAssertTrue(table.contains("human-reads"))
    }

    func testFetchOfPlaceholderProjectFailsWithAClearMessage() async throws {
        let manifest = try DemoCommandTests.placeholderManifest()
        let project = try DemoCommand.resolveProject("human-reads", in: manifest)
        do {
            _ = try await DemoProjectInstaller().install(project, into: tempDir, replaceExisting: false)
            XCTFail("expected refusal")
        } catch {
            XCTAssertTrue("\(error)".contains("has not been published yet"), "\(error)")
        }
        XCTAssertThrowsError(try DemoCommand.resolveProject("no-such-demo", in: manifest)) { error in
            XCTAssertTrue(error.localizedDescription.contains("demo list"))
        }
    }

    private func install(_ project: DemoProject, version: String, in destination: URL) throws {
        let folder = DemoProjectInstaller.projectURL(for: project, in: destination)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(DemoProjectInstallRecord(id: project.id, version: version, sha256: "x", installedAt: Date()))
            .write(to: folder.appendingPathComponent(".lgedemo.json"))
    }

    /// The bundled manifest with every archive reset to the unpublished placeholder.
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

}
