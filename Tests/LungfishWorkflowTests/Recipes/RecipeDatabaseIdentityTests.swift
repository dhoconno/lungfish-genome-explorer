// RecipeDatabaseIdentityTests.swift - A recipe step's database is recorded by its bytes and checked against the lock
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import CryptoKit
import Foundation
import LungfishIO
@testable import LungfishWorkflow

final class RecipeDatabaseIdentityTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("db-identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A Deacon index of format 3, k 31 and window 15 holding `minimizers` 8-byte minimizers.
    private func writeIndex(named name: String, minimizers: UInt64) throws -> (url: URL, sha256: String, size: Int) {
        var bytes: [UInt8] = [3, 31, 15]
        bytes += withUnsafeBytes(of: minimizers.littleEndian, Array.init)
        bytes += [UInt8](repeating: 7, count: Int(minimizers) * 8)
        let data = Data(bytes)
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return (url, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), data.count)
    }

    private func spec(sha256: String?, sizeBytes: Int?) throws -> DatabaseSpec {
        var json: [String: Any] = [
            "id": "deacon-test", "tool": "deacon", "displayName": "Test", "version": "test-1",
            "filename": "test.idx", "indexFormat": 3,
        ]
        json["sha256"] = sha256
        json["sizeBytes"] = sizeBytes
        return try JSONDecoder().decode(DatabaseSpec.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testAPinnedIndexThatMatchesIsRecordedAndHashedOncePerProcess() async throws {
        let index = try writeIndex(named: "test.idx", minimizers: 2)
        let resolver = RecipeDatabaseIdentity()
        let pin = try spec(sha256: index.sha256, sizeBytes: index.size)

        let first = try await resolver.record(databaseID: "deacon-test", spec: pin, at: index.url)
        let second = try await resolver.record(databaseID: "deacon-test", spec: pin, at: index.url)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.sha256, index.sha256)
        XCTAssertEqual(first.sizeBytes, Int64(index.size))
        XCTAssertEqual(first.version, "test-1")
        XCTAssertEqual(first.fileName, "test.idx")
        XCTAssertEqual(first.indexFormat, 3)
        XCTAssertEqual(first.kmerLength, 31)
        XCTAssertEqual(first.windowSize, 15)
        XCTAssertTrue(first.lockPinned)
        XCTAssertNil(first.buildToolVersion, "a pinned index is fetched, not built")
        let hashes = await resolver.hashCount
        XCTAssertEqual(hashes, 1, "a command hashes each database file once")
    }

    func testAPinnedIndexWithOtherBytesIsRefusedBeforeTheStepRuns() async throws {
        let index = try writeIndex(named: "test.idx", minimizers: 2)
        let resolver = RecipeDatabaseIdentity()
        let wrongDigest = String(repeating: "0", count: 64)

        do {
            _ = try await resolver.record(
                databaseID: "deacon-test", spec: try spec(sha256: wrongDigest, sizeBytes: index.size), at: index.url
            )
            XCTFail("an index whose SHA-256 differs from the pin must be refused")
        } catch let error as RecipeDatabaseIdentityError {
            XCTAssertEqual(error, .lockMismatch(
                databaseID: "deacon-test", path: index.url.path, field: "SHA-256",
                expected: wrongDigest, actual: index.sha256
            ))
        }
        do {
            _ = try await resolver.record(
                databaseID: "deacon-test", spec: try spec(sha256: index.sha256, sizeBytes: 1), at: index.url
            )
            XCTFail("an index whose size differs from the pin must be refused")
        } catch let error as RecipeDatabaseIdentityError {
            guard case .lockMismatch(_, _, let field, _, _) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(field, "size")
        }
    }

    /// An index each install builds has no pin. Its record names its own digest and the source file and Deacon
    /// version of the install record step that wrote it, in the run format an older install wrote.
    func testAnUnpinnedIndexNamesTheBuildInputsOfItsInstallRecord() async throws {
        let index = try writeIndex(named: "ribo.idx", minimizers: 1)
        let installRecord: [String: Any] = [
            "name": "Ribosomal RNA Removal Data managed database install",
            "steps": [
                ["toolName": "URLSession", "toolVersion": "Foundation", "inputs": [],
                 "outputs": [["path": directory.appendingPathComponent("ribo.fa.gz").path, "role": "reference"]]],
                ["toolName": "deacon", "toolVersion": "0.15.0",
                 "inputs": [["path": directory.appendingPathComponent("ribo.fa.gz").path, "role": "reference",
                             "sha256": "abc123", "sizeBytes": 9548991]],
                 "outputs": [["path": index.url.path, "role": "index"]]],
            ],
        ]
        try JSONSerialization.data(withJSONObject: installRecord)
            .write(to: directory.appendingPathComponent(ProvenanceRecorder.provenanceFilename))

        let record = try await RecipeDatabaseIdentity().record(
            databaseID: "deacon-test", spec: try spec(sha256: nil, sizeBytes: 10_107_947), at: index.url
        )

        XCTAssertFalse(record.lockPinned, "a size without a SHA-256 is not a pin")
        XCTAssertEqual(record.sha256, index.sha256)
        XCTAssertEqual(record.buildToolVersion, "0.15.0")
        XCTAssertEqual(record.buildSourceSHA256, "abc123")
        XCTAssertEqual(record.buildSourceSizeBytes, 9_548_991)
    }

    /// The panhuman install refuses a fetched index that is not the pinned file, and the ribokmers install, which
    /// has no pin, accepts any index it built.
    func testTheInstallCheckRefusesAStagedIndexThatIsNotThePinnedFile() throws {
        let staged = try writeIndex(named: "staged.idx", minimizers: 1)
        func manifest(_ id: String) -> BundledDatabase {
            BundledDatabase(
                id: id, displayName: id, tool: "deacon", version: "v", filename: "f.idx",
                releaseDate: "", description: "", sourceUrl: "", releasesUrl: ""
            )
        }

        XCTAssertThrowsError(
            try DatabaseRegistry.checkStagedIndexAgainstLock(staged.url, manifest: manifest("deacon-panhuman"), progress: nil)
        ) { error in
            guard case HumanScrubberDatabaseError.installationFailed(let id, _, _) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(id, "deacon-panhuman")
        }
        XCTAssertNoThrow(
            try DatabaseRegistry.checkStagedIndexAgainstLock(staged.url, manifest: manifest("deacon-ribokmers"), progress: nil)
        )
    }
}
