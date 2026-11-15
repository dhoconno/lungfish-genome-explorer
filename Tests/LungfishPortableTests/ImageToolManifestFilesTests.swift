// ImageToolManifestFilesTests.swift - The manifest's data files and the policy of a record output (Phase 5.3 lane EX-TOOL)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import Foundation
import LungfishPortable

final class ImageToolManifestFilesTests: XCTestCase {
    private static let digest = String(repeating: "d", count: 64)
    private static let tool = ImageTool(id: "salmon", version: "2.11.0", build: "t0", path: "/opt/conda/bin/salmon", condaPackage: "salmon")

    func testManifestWithNoFilesEncodesToTodaysBytes() throws {
        let manifest = ImageToolManifest(platform: .linux64, tools: [Self.tool])
        let text = String(decoding: try manifest.encoded(), as: UTF8.self)
        XCTAssertEqual(text, "{\"platform\":\"linux-64\",\"schemaVersion\":1,\"tools\":[{\"build\":\"t0\",\"condaPackage\":\"salmon\",\"id\":\"salmon\",\"path\":\"/opt/conda/bin/salmon\",\"version\":\"2.11.0\"}]}\n")
        XCTAssertNil(try ImageToolManifest.decode(manifest.encoded()).files)
    }

    func testFilesAreSortedByPathAndFoundByRoleAndDigest() throws {
        let later = ImageDataFile(path: "/opt/lungfish/barcodes/b.txt", role: "barcodeList", sha256: Self.digest, size: 4)
        let earlier = ImageDataFile(path: "/opt/lungfish/barcodes/a.txt", role: "barcodeList", sha256: Self.digest, size: 4)
        let manifest = ImageToolManifest(platform: .linux64, tools: [Self.tool], files: [later, earlier])
        let decoded = try ImageToolManifest.decode(manifest.encoded())
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.files, [earlier, later])
        XCTAssertEqual(decoded.file(role: .barcodeList, sha256: Self.digest), earlier)
        XCTAssertNil(decoded.file(role: .barcodeList, sha256: String(repeating: "e", count: 64)))
        XCTAssertNil(decoded.file(role: .database, sha256: Self.digest))
    }

    func testFileChecksRefuseARelativePathABadDigestAndAToolPath() {
        let cases: [(ImageDataFile, String)] = [
            (ImageDataFile(path: "barcodes/a.txt", role: "barcodeList", sha256: Self.digest, size: 4), "files[0].path"),
            (ImageDataFile(path: "/opt/a.txt", role: "barcodeList", sha256: "ABC", size: 4), "files[0].sha256"),
            (ImageDataFile(path: "/opt/a.txt", role: "", sha256: Self.digest, size: 4), "files[0].role"),
            (ImageDataFile(path: Self.tool.path, role: "barcodeList", sha256: Self.digest, size: 4), "files[0]"),
        ]
        for (file, field) in cases {
            XCTAssertThrowsError(try ImageToolManifest(platform: .linux64, tools: [Self.tool], files: [file]).validate()) { error in
                XCTAssertEqual((error as? ImageToolManifestError)?.field, field)
            }
        }
    }

    func testRecordOutputStatesItsPolicyOnlyWhenTheStepHasOne() throws {
        let plain = try JSONEncoder().encode(ExecutorStepRecord.Output(path: "out/a", bytes: 1, sha256: Self.digest))
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("policy"))
        let home = ExecutorStepRecord.Output(path: "out/a", bytes: 1, sha256: Self.digest, policy: .home)
        let data = try JSONEncoder().encode(home)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"policy\":\"home\""))
        XCTAssertEqual(try JSONDecoder().decode(ExecutorStepRecord.Output.self, from: data), home)
    }
}
