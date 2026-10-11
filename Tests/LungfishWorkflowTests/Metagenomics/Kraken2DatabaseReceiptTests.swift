// Kraken2DatabaseReceiptTests.swift - The install receipt check behind --db-digest
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import XCTest
import LungfishTestSupport
@testable import LungfishWorkflow

/// Review A8 fix 5b. `Kraken2DatabaseReceipt.verifiedReference` vouches for a database only
/// through an install receipt that checks out against the files it lists, the check the
/// `lungfish.classify` wrapper made before Phase 2.7 (`testConfiguredFailureRejectsUntrustedDatabaseReceipts`).
final class Kraken2DatabaseReceiptTests: XCTestCase {

    private var database: URL!

    override func setUpWithError() throws {
        database = try TestTempDirectory.make(prefix: "kraken2-receipt").resolvingSymlinksInPath()
            .appendingPathComponent("viral", isDirectory: true)
        try Self.writeDatabaseFiles(in: database)
    }

    override func tearDown() {
        TestTempDirectory.cleanup(database.deletingLastPathComponent())
    }

    func testAReceiptThatChecksOutGivesTheDatabaseAsAReference() throws {
        let receipt = try Self.writeReceipt(in: database)

        let reference = try XCTUnwrap(Kraken2DatabaseReceipt.verifiedReference(databasePath: database, registryDigest: receipt.digest))

        XCTAssertEqual(reference.path, database.standardizedFileURL.path)
        XCTAssertEqual(reference.checksumSHA256, receipt.digest)
        XCTAssertEqual(reference.fileSize, receipt.size)
        XCTAssertEqual(reference.role, .reference)
        XCTAssertEqual(reference.sourceProvenancePath, database.appendingPathComponent(ProvenanceWriter.provenanceFilename).path)
        XCTAssertNotNil(
            Kraken2DatabaseReceipt.verifiedReference(databasePath: database, registryDigest: "sha256:" + receipt.digest.uppercased()),
            "a registry digest with a prefix and upper-case digits names the same payload"
        )
        XCTAssertNotNil(Kraken2DatabaseReceipt.verifiedReference(databasePath: database, registryDigest: nil))
    }

    func testEveryReceiptThatDoesNotCheckOutIsRejected() throws {
        let elsewhere = database.deletingLastPathComponent().appendingPathComponent("other", isDirectory: true).path
        let cases: [(String, Receipt.Change)] = [
            ("another workflow", { $0.workflowName = "metagenomics.database.verify" }),
            ("a failed install", { $0.exitStatus = 1 }),
            ("another final folder", { $0.intendedFinalPath = elsewhere }),
            ("a digest the listed files do not add up to", { $0.aggregate = String(repeating: "0", count: 64) }),
            ("a total size the listed files do not add up to", { $0.totalSize += 1 }),
        ]
        for (name, change) in cases {
            _ = try Self.writeReceipt(in: database, change: change)
            XCTAssertNil(Kraken2DatabaseReceipt.verifiedReference(databasePath: database, registryDigest: nil), name)
        }

        let receipt = try Self.writeReceipt(in: database)
        XCTAssertNil(
            Kraken2DatabaseReceipt.verifiedReference(databasePath: database, registryDigest: String(repeating: "f", count: 64)),
            "a registry digest that disagrees with the receipt"
        )
        XCTAssertNotNil(Kraken2DatabaseReceipt.verifiedReference(databasePath: database, registryDigest: receipt.digest))
        try FileManager.default.removeItem(at: database.appendingPathComponent(ProvenanceWriter.provenanceFilename))
        XCTAssertNil(Kraken2DatabaseReceipt.verifiedReference(databasePath: database, registryDigest: nil), "no receipt")
    }

    // MARK: - Receipts

    /// The facts of an install receipt a test may change before it is written.
    struct Receipt {
        typealias Change = (inout Receipt) -> Void

        var workflowName = "metagenomics.database.install"
        var exitStatus = 0
        var intendedFinalPath: String
        var aggregate: String
        var totalSize: Int
        let digest: String
        let size: UInt64
    }

    /// Three small Kraken2 database files.
    static func writeDatabaseFiles(in database: URL) throws {
        try FileManager.default.createDirectory(at: database, withIntermediateDirectories: true)
        for (name, text) in [("hash.k2d", "hash\n"), ("opts.k2d", "options\n"), ("taxo.k2d", "taxonomy\n")] {
            try text.write(to: database.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
    }

    /// Writes an install receipt over the database's files, as `metagenomics.database.install`
    /// records one, with `change` applied, and returns the digest and size it states.
    @discardableResult
    static func writeReceipt(in database: URL, change: Receipt.Change = { _ in }) throws -> Receipt {
        let root = database.standardizedFileURL
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let outputs = try files.map { try ProvenanceFileDescriptor.file(url: $0, format: .unknown, role: .output) }
        let lines = outputs.map { descriptor in
            "\(URL(fileURLWithPath: descriptor.path).lastPathComponent)\t\(descriptor.checksumSHA256 ?? "")\t\(descriptor.fileSize ?? 0)\n"
        }.joined()
        let digest = SHA256.hash(data: Data(lines.utf8)).map { String(format: "%02x", $0) }.joined()
        let size = outputs.reduce(UInt64(0)) { $0 + ($1.fileSize ?? 0) }
        var receipt = Receipt(intendedFinalPath: root.path, aggregate: digest, totalSize: Int(size), digest: digest, size: size)
        change(&receipt)
        let envelope = ProvenanceEnvelope(
            workflowName: receipt.workflowName,
            workflowVersion: "2026.1",
            toolName: "kraken2-build",
            toolVersion: "2.17.1",
            options: ProvenanceOptions(explicit: [:], defaults: [:], resolvedDefaults: [
                "intendedFinalPath": .string(receipt.intendedFinalPath),
                "payloadAggregateSHA256": .string(receipt.aggregate),
                "payloadTotalSizeBytes": .integer(receipt.totalSize),
            ]),
            output: outputs.first,
            outputs: outputs,
            exitStatus: receipt.exitStatus
        )
        _ = try ProvenanceWriter(signingProvider: nil).write(envelope, to: root)
        return receipt
    }
}
