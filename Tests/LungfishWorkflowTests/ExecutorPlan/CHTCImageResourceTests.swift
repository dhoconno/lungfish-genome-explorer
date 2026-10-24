// CHTCImageResourceTests.swift - The CHTC tool image's committed identity and manifest copy (CHTC lane I, M3)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import LungfishCore
import LungfishPortable
import XCTest
@testable import LungfishWorkflow

/// `Resources/CHTCImage/image-manifest.json` is a byte copy of `/opt/lungfish/image-manifest.json` in the CHTC tool
/// image, and `image.json` beside it states the image's SIF (file name, SHA-256, size) and the manifest's SHA-256 and
/// size. The plan writer takes the plan's `imageManifest` pin from `image.json` and the tool pins from the copy, and the
/// executor refuses a plan whose pin differs from the manifest it reads, so the two files have to agree. The tests read
/// the files the LungfishWorkflow resource bundle holds, as the app and the plan writer do.
final class CHTCImageResourceTests: XCTestCase {
    private struct FilePin: Decodable {
        let sha256: String
        let size: Int
    }

    private struct SIFPin: Decodable {
        let fileName: String
        let sha256: String
        let size: Int
    }

    /// The members of `image.json` that the launcher and the plan writer read. Its optional `build` object is not read.
    private struct ImageIdentity: Decodable {
        let schemaVersion: Int
        let sif: SIFPin
        let imageManifest: FilePin
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func isLowercaseDigest(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) }
    }

    private func bundledBytes(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            RuntimeResourceLocator.path("CHTCImage/\(name)", in: .workflow),
            "CHTCImage/\(name) is not in the LungfishWorkflow resource bundle"
        )
        return try Data(contentsOf: url)
    }

    private func bundledIdentity() throws -> ImageIdentity {
        try JSONDecoder().decode(ImageIdentity.self, from: bundledBytes("image.json"))
    }

    func testCHTCImageManifestCopyMatchesItsPin() throws {
        let pin = try bundledIdentity().imageManifest
        let copy = try bundledBytes("image-manifest.json")
        XCTAssertEqual(sha256(copy), pin.sha256, "image-manifest.json differs from the SHA-256 that image.json pins")
        XCTAssertEqual(copy.count, pin.size, "image-manifest.json differs from the size that image.json pins")
    }

    func testCHTCImageIdentityNamesTheSIFByItsDigest() throws {
        let identity = try bundledIdentity()
        XCTAssertEqual(identity.schemaVersion, 1)
        XCTAssertTrue(isLowercaseDigest(identity.sif.sha256), "sif.sha256 is not 64 lowercase hex digits")
        XCTAssertTrue(isLowercaseDigest(identity.imageManifest.sha256), "imageManifest.sha256 is not 64 lowercase hex digits")
        XCTAssertEqual(identity.sif.fileName, "lge-tools-\(identity.sif.sha256.prefix(12)).sif")
        XCTAssertGreaterThan(identity.sif.size, 0)
        XCTAssertGreaterThan(identity.imageManifest.size, 0)
    }

    func testCHTCImageManifestCopyDecodesAsTheExecutorsManifest() throws {
        let manifest = try ImageToolManifest.decode(bundledBytes("image-manifest.json"))
        XCTAssertFalse(manifest.tools.isEmpty)
        // The tools of the VSP2 cleanup recipe, which the first CHTC plan pins from this manifest.
        for id in ["fastp", "deacon", "seqkit", "pigz", "clumpify.sh"] {
            XCTAssertTrue(manifest.tools.contains { $0.id == id }, "the image manifest lists no tool \(id)")
            XCTAssertNotNil(try? manifest.pin(forToolID: id), "\(id) has no single version and build in the image manifest")
        }
    }
}
