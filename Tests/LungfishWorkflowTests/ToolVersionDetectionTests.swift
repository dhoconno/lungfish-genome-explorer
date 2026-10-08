// ToolVersionDetectionTests.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

/// EsViritu provenance recorded `3.14` as EsViritu's version. `EsViritu
/// --version` prints its site-packages path before its own version, and the
/// version regex matched Python's `3.14` inside that path.
final class ToolVersionDetectionTests: XCTestCase {

    /// The exact output of `EsViritu --version` for bioconda esviritu 1.3.3.
    private let esVirituVersionOutput = """
    /opt/lungfish/conda/envs/esviritu/lib/python3.14/site-packages/EsViritu
    1.3.3
    """

    func testParseSkipsVersionsInsideFilePaths() {
        XCTAssertEqual(parseToolVersion(from: esVirituVersionOutput), "1.3.3")
        XCTAssertEqual(
            parseToolVersion(from: "/Volumes/Data 2.0/envs/bowtie2/bin/bowtie2-align-s version 2.5.5\n64-bit"),
            "2.5.5"
        )
    }

    func testParseKeepsExistingVersionShapes() {
        XCTAssertEqual(parseToolVersion(from: "Kraken version 2.17.1\nCopyright 2013-2023"), "2.17.1")
        XCTAssertEqual(parseToolVersion(from: "2.31-r1302\n"), "2.31")
        XCTAssertEqual(parseToolVersion(from: "v7.526 (2024/Apr/26)"), "7.526")
        XCTAssertEqual(parseToolVersion(from: "SKESA 2.5.1\n"), "2.5.1")
        XCTAssertEqual(parseToolVersion(from: "no digits here\nsecond line"), "no digits here")
        XCTAssertNil(parseToolVersion(from: " \n"))
    }

    /// With `condaPackage`, the version comes from conda-meta and the probe,
    /// which here would print the misleading path, never decides it.
    func testCondaPackageVersionWinsOverProbeOutput() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tool-version-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        let metaDir = root.appendingPathComponent("envs/esviritu/conda-meta", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: metaDir, withIntermediateDirectories: true)
        try #"{"name":"python","version":"3.14.0","build":"h1_0"}"#
            .write(to: metaDir.appendingPathComponent("python-3.14.0-h1_0.json"), atomically: true, encoding: .utf8)
        try #"{"name":"esviritu","version":"1.3.3","build":"pyhdfd78af_0"}"#
            .write(to: metaDir.appendingPathComponent("esviritu-1.3.3-pyhdfd78af_0.json"), atomically: true, encoding: .utf8)

        let envBinDir = root.appendingPathComponent("envs/esviritu/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: envBinDir, withIntermediateDirectories: true)
        let scripts = [
            binDir.appendingPathComponent("micromamba"): "#!/bin/sh\necho 1.5.0\n",
            envBinDir.appendingPathComponent("EsViritu"): """
            #!/bin/sh
            echo "\(root.path)/envs/esviritu/lib/python3.14/site-packages/EsViritu"
            echo "1.3.3"
            """,
        ]
        for (url, body) in scripts {
            try body.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        let condaManager = CondaManager(rootPrefix: root)

        let fromMeta = try await detectToolVersion(
            toolName: "EsViritu",
            environment: "esviritu",
            condaManager: condaManager,
            condaPackage: "esviritu"
        )
        XCTAssertEqual(fromMeta, "1.3.3")

        // A package with no conda-meta record falls back to the probe, which
        // now skips the path and still reads 1.3.3 rather than 3.14.
        let fromProbe = try await detectToolVersion(
            toolName: "EsViritu",
            environment: "esviritu",
            condaManager: condaManager,
            condaPackage: "not-installed"
        )
        XCTAssertEqual(fromProbe, "1.3.3")
    }
}
