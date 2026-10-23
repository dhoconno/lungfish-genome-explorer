// ImageToolManifestTests.swift - The tool manifest built from conda-meta records, its checks and its bytes (CHTC lane K4)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import Foundation
import LungfishPortable

final class ImageToolManifestTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("image-tool-manifest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Writes an environment with one conda record per package, creating each listed file, executable unless named in
    /// `plainFiles`.
    private func makePrefix(_ name: String, packages: [(name: String, version: String, build: String, files: [String])], plainFiles: Set<String> = []) throws -> URL {
        let prefix = root.appendingPathComponent(name)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: prefix.appendingPathComponent("conda-meta"), withIntermediateDirectories: true)
        try Data("==> 2026-10-23 <==\n".utf8).write(to: prefix.appendingPathComponent("conda-meta/history"))
        for package in packages {
            let record: [String: Any] = ["name": package.name, "version": package.version, "build": package.build, "files": package.files]
            let data = try JSONSerialization.data(withJSONObject: record)
            try data.write(to: prefix.appendingPathComponent("conda-meta/\(package.name)-\(package.version)-\(package.build).json"))
            for file in package.files {
                let url = prefix.appendingPathComponent(file)
                try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let mode = plainFiles.contains(file) ? 0o644 : 0o755
                XCTAssertTrue(fileManager.createFile(atPath: url.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: mode]))
            }
        }
        return prefix
    }

    func testImageToolManifestBuildsFromCondaMetaRecords() throws {
        let bbtools = try makePrefix("bbtools", packages: [
            ("bbmap", "40.02", "hdfd78af_0", ["bin/clumpify.sh", "bin/reformat.sh", "bin/readme.txt", "opt/bbmap/clumpify.sh"]),
            ("pigz", "2.8", "h421ea60_1", ["bin/pigz", "bin/unpigz"]),
        ], plainFiles: ["bin/readme.txt"])
        let seqkit = try makePrefix("seqkit", packages: [("seqkit", "2.10.0", "h9ee0642_0", ["bin/seqkit"])])

        let manifest = try ImageToolManifest.build(condaPrefixes: [bbtools, seqkit], platform: .linux64)
        XCTAssertEqual(manifest.schemaVersion, ImageToolManifest.currentSchemaVersion)
        XCTAssertEqual(manifest.platform, .linux64)
        XCTAssertEqual(manifest.tools.map(\.id), ["clumpify.sh", "pigz", "reformat.sh", "seqkit", "unpigz"],
                       "only executables directly under bin/ are tools, sorted by id")
        let clumpify = try XCTUnwrap(manifest.tool(matching: PlanToolPin(id: "clumpify.sh", version: "40.02", build: "hdfd78af_0")))
        XCTAssertEqual(clumpify.path, bbtools.path + "/bin/clumpify.sh")
        XCTAssertEqual(clumpify.condaPackage, "bbmap")
        for tool in manifest.tools { XCTAssertNil(ImageToolManifest.refusal(forToolPath: tool.path), tool.path) }
        XCTAssertEqual(try manifest.pin(forToolID: "seqkit"), PlanToolPin(id: "seqkit", version: "2.10.0", build: "h9ee0642_0"))
        XCTAssertNil(manifest.tool(matching: PlanToolPin(id: "seqkit", version: "2.10.0", build: "other_0")))
        XCTAssertEqual(try ImageToolManifest.decode(manifest.encoded()), manifest)

        // A second pigz at another build makes the plan writer's pin for pigz ambiguous, and it refuses to pick one.
        let pigz = try makePrefix("pigz", packages: [("pigz", "2.8", "hb0a5d6d_2", ["bin/pigz"])])
        let both = try ImageToolManifest.build(condaPrefixes: [pigz, bbtools], platform: .osxArm64)
        XCTAssertThrowsError(try both.pin(forToolID: "pigz")) { error in
            XCTAssertEqual((error as? ImageToolManifestError)?.field, "tools")
        }
        XCTAssertEqual(both.tool(matching: PlanToolPin(id: "pigz", version: "2.8", build: "hb0a5d6d_2"))?.path, pigz.path + "/bin/pigz")
        XCTAssertThrowsError(try manifest.pin(forToolID: "bgzip"))

        // A prefix with no conda-meta, a relative prefix and a prefix with a .. component are refused.
        for prefix in [root.appendingPathComponent("empty"), URL(fileURLWithPath: "/opt/conda/../envs/x")] {
            XCTAssertThrowsError(try ImageToolManifest.build(condaPrefixes: [prefix], platform: .linux64)) { error in
                XCTAssertEqual((error as? ImageToolManifestError)?.field, "condaPrefix", "\(prefix.path)")
            }
        }
    }

    func testToolManifestEncodingIsByteStable() throws {
        let tools = [
            ImageTool(id: "seqkit", version: "2.10.0", build: "h9ee0642_0", path: "/opt/conda/envs/seqkit/bin/seqkit", condaPackage: "seqkit"),
            ImageTool(id: "bgzip", version: "1.21", build: "h96c455f_0", path: "/opt/conda/envs/htslib/bin/bgzip", condaPackage: "htslib"),
            ImageTool(id: "pigz", version: "2.8", build: "h421ea60_1", path: "/opt/conda/envs/bbtools/bin/pigz", condaPackage: "pigz"),
        ]
        let forward = try ImageToolManifest(platform: .linux64, tools: tools).encoded()
        let backward = try ImageToolManifest(platform: .linux64, tools: tools.reversed()).encoded()
        XCTAssertEqual(forward, backward)
        let text = String(decoding: forward, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("{\"platform\":\"linux-64\",\"schemaVersion\":1,\"tools\":[{\"build\":\"h96c455f_0\""), text)
        XCTAssertFalse(text.contains("\\/"))
    }

    func testImageToolManifestRefusesRelativeOrDotToolPath() throws {
        let good = ImageTool(id: "seqkit", version: "2.10.0", build: "h9ee0642_0", path: "/opt/conda/bin/seqkit", condaPackage: "seqkit")
        var cases: [(ImageTool, String)] = []
        for path in ["opt/conda/bin/seqkit", "/opt/conda/./bin/seqkit", "/opt/conda/../bin/seqkit", "/opt//conda/bin/seqkit"] {
            var tool = good
            tool.path = path
            cases.append((tool, "tools[0].path"))
        }
        var slashID = good
        slashID.id = "bin/seqkit"
        cases.append((slashID, "tools[0].id"))
        var noBuild = good
        noBuild.build = ""
        cases.append((noBuild, "tools[0]"))
        for (tool, field) in cases {
            let data = try ImageToolManifest(platform: .linux64, tools: [tool]).encoded()
            XCTAssertThrowsError(try ImageToolManifest.decode(data)) { error in
                XCTAssertEqual((error as? ImageToolManifestError)?.field, field, tool.path)
            }
        }
        let duplicate = try ImageToolManifest(platform: .linux64, tools: [good, good]).encoded()
        XCTAssertThrowsError(try ImageToolManifest.decode(duplicate)) { error in
            XCTAssertEqual((error as? ImageToolManifestError)?.field, "tools[1]")
        }
        let oversized = Data(repeating: 0x20, count: ImageToolManifest.maximumSize + 1)
        XCTAssertThrowsError(try ImageToolManifest.decode(oversized)) { error in
            XCTAssertEqual((error as? ImageToolManifestError)?.field, "imageManifest")
        }
        XCTAssertEqual(ImageToolManifest.imagePath, "/opt/lungfish/image-manifest.json")
    }
}
