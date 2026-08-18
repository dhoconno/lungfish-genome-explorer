// BundledDatabaseManifestTests.swift - Bundled database metadata and micromamba version come from the manifest
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

final class BundledDatabaseManifestTests: XCTestCase {
    func testDatabaseRegistryManifestsComeFromDependencyManifest() async throws {
        let manifest = try ManagedToolLock.loadFromBundle()
        for id in DatabaseRegistry.knownIDs {
            let spec = try XCTUnwrap(manifest.database(id: id), "\(id) missing from manifest")
            let resolved = await DatabaseRegistry.shared.manifest(for: id)
            let bundled = try XCTUnwrap(resolved)
            XCTAssertEqual(bundled.version, spec.version)
            XCTAssertEqual(bundled.filename, spec.filename)
            XCTAssertEqual(bundled.tool, spec.tool)
        }
    }

    func testNoLegacyManifestJSONRemains() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for id in DatabaseRegistry.knownIDs {
            let legacy = root.appendingPathComponent("Sources/LungfishWorkflow/Resources/Databases/\(id)/manifest.json")
            XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path), "legacy manifest still present: \(legacy.path)")
        }
    }

    func testMicromambaVersionAgreesAcrossManifestAndToolVersions() throws {
        let manifest = try ManagedToolLock.loadFromBundle()
        let expected = try XCTUnwrap(manifest.bootstrap?.micromamba.version)
        XCTAssertEqual(BundledToolSpec.micromamba().version, expected)
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Sources/LungfishWorkflow/Resources/Tools/tool-versions.json"))
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let tools = json["tools"] as! [[String: Any]]
        let mm = tools.first { ($0["name"] as? String) == "micromamba" }!
        XCTAssertEqual(mm["version"] as? String, expected)
    }
}
