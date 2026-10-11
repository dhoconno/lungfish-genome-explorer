// ProvenanceSigningDurabilityTests.swift - The signature file and the key file publish through DurableReplace
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import XCTest
import LungfishCore
@testable import LungfishWorkflow

/// `LocalProvenanceSigningProvider.sign(provenanceURL:)` is the path the provenance writer takes
/// when nobody observes its publications, and the only path the exporter takes. It publishes the
/// signature file and the public key file through `DurableReplace` in one transaction (Phase 2.7
/// scope row B8, lane S6b). Each file is fsynced before it takes its name, is swapped in whole on
/// ExFAT too, and one full flush covers the pair.
///
/// `ProvenanceSigningArtifactTests` pins the bytes and the mode of both files. These tests pin
/// how they are published. Under `exfat-tests.sh --simulate` every swap takes the ExFAT rotation.
final class ProvenanceSigningDurabilityTests: XCTestCase {
    private var root: URL!
    private var folder: URL!
    private var record: URL!

    private let signer = LocalProvenanceSigningProvider(privateKey: "durable-signing-key")

    private var signatureURL: URL { ProvenanceSigningConfiguration.signatureURL(for: record) }
    private var publicKeyURL: URL { ProvenanceSigningConfiguration.publicKeyURL(for: record) }

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("signing-durability-\(UUID().uuidString)", isDirectory: true)
        folder = root.appendingPathComponent("P.lungfish/Analyses/run-1", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        record = folder.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        try Data(#"{"name":"signed"}"#.utf8).write(to: record)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - One transaction

    func testSigningPublishesBothFilesInOneTransactionWithOneFullFlush() throws {
        let events = Events()
        let artifact = try recording(events) { try signer.sign(provenanceURL: record) }

        XCTAssertEqual(artifact, ProvenanceSignatureArtifact(signatureURL: signatureURL, publicKeyURL: publicKeyURL))
        XCTAssertEqual(events.count("stageSynced"), 2, "the signature and the key are each fsynced before they take their names")
        XCTAssertEqual(events.count("published"), 2)
        XCTAssertEqual(events.count("folderSynced"), 2, "the folder is fsynced after each swap")
        XCTAssertEqual(events.count("fullFlush"), 1, "one full flush covers the pair")
        let all = events.all
        XCTAssertEqual(all.last, "flushed", "the flush ends the transaction")
        let flush = try XCTUnwrap(all.firstIndex(of: "fullFlush"))
        XCTAssertEqual(all[..<flush].filter { $0 == "folderSynced" }.count, 2, "both publications come before the flush")
        XCTAssertEqual(try names(), [record.lastPathComponent, publicKeyURL.lastPathComponent, signatureURL.lastPathComponent])
        XCTAssertTrue(try ProvenanceSignatureVerifier.verify(provenanceURL: record).isValid)
    }

    func testSigningAgainSwapsBothFilesAndUnlinksTheirOldCopies() throws {
        _ = try signer.sign(provenanceURL: record)
        let firstSignature = try Data(contentsOf: signatureURL)
        try Data(#"{"name":"changed"}"#.utf8).write(to: record)

        let events = Events()
        _ = try recording(events) { try signer.sign(provenanceURL: record) }

        XCTAssertEqual(events.count("published"), 2)
        XCTAssertEqual(events.count("retiredRemoved"), 2, "the old signature and the old key are unlinked")
        XCTAssertEqual(events.count("fullFlush"), 1)
        XCTAssertNotEqual(try Data(contentsOf: signatureURL), firstSignature)
        XCTAssertEqual(try names(), [record.lastPathComponent, publicKeyURL.lastPathComponent, signatureURL.lastPathComponent])
        XCTAssertTrue(try ProvenanceSignatureVerifier.verify(provenanceURL: record).isValid)
    }

    func testSigningInsideATransactionJoinsItsOneFlush() throws {
        // The provenance writer wraps a whole write in a transaction, and signs a record three times in it.
        let other = folder.appendingPathComponent("other.lungfish-provenance.json")
        try Data(#"{"name":"other"}"#.utf8).write(to: other)

        let events = Events()
        try recording(events) {
            try DurableReplace.transaction {
                _ = try signer.sign(provenanceURL: record)
                _ = try signer.sign(provenanceURL: other)
            }
        }

        XCTAssertEqual(events.count("published"), 4)
        XCTAssertEqual(events.count("fullFlush"), 1, "the transaction the caller runs owns the flush")
        XCTAssertTrue(try ProvenanceSignatureVerifier.verify(provenanceURL: record).isValid)
        XCTAssertTrue(try ProvenanceSignatureVerifier.verify(provenanceURL: other).isValid)
    }

    // MARK: - Faults

    func testAFaultWhilePublishingTheKeyLeavesAWholeSignatureAndNoStageFile() throws {
        let events = Events()
        XCTAssertThrowsError(
            try recording(events, failingAt: { step, occurrence in step == .staged && occurrence == 2 }) {
                try signer.sign(provenanceURL: record)
            }
        ) { XCTAssertTrue($0 is Refusal, "\($0)") }

        XCTAssertEqual(try names(), [record.lastPathComponent, signatureURL.lastPathComponent],
                       "the signature took its name, the key never did, and no stage file is left")
        let signature = try JSONSerialization.jsonObject(with: Data(contentsOf: signatureURL)) as? [String: Any]
        XCTAssertEqual(signature?["provenancePath"] as? String, record.lastPathComponent, "the signature file is whole")
        XCTAssertEqual(events.count("fullFlush"), 0, "a transaction that throws flushes nothing, because each publication was fsynced")
        XCTAssertThrowsError(try ProvenanceSignatureVerifier.verify(provenanceURL: record)) { error in
            XCTAssertEqual(error as? ProvenanceSignatureVerificationError, .publicKeyMissing(publicKeyURL.path))
        }

        _ = try signer.sign(provenanceURL: record)
        XCTAssertEqual(try names(), [record.lastPathComponent, publicKeyURL.lastPathComponent, signatureURL.lastPathComponent])
        XCTAssertTrue(try ProvenanceSignatureVerifier.verify(provenanceURL: record).isValid, "the next signing repairs the pair")
    }

    func testAFaultAfterTheKeySwapRestoresTheOldKeyAndKeepsTheNewSignature() throws {
        _ = try signer.sign(provenanceURL: record)
        let oldKey = try Data(contentsOf: publicKeyURL)
        try Data(#"{"name":"changed"}"#.utf8).write(to: record)

        let events = Events()
        XCTAssertThrowsError(
            try recording(events, failingAt: { step, occurrence in step == .published && occurrence == 2 }) {
                try signer.sign(provenanceURL: record)
            }
        ) { XCTAssertTrue($0 is Refusal, "\($0)") }

        XCTAssertEqual(try Data(contentsOf: publicKeyURL), oldKey, "the refused swap put the old key back")
        XCTAssertEqual(try names(), [record.lastPathComponent, publicKeyURL.lastPathComponent, signatureURL.lastPathComponent],
                       "no stage file and no retired copy is left")
        XCTAssertTrue(try ProvenanceSignatureVerifier.verify(provenanceURL: record).isValid,
                      "one private key gives one public key, so the new signature verifies against the restored key")
    }

    // MARK: - ExFAT

    func testOnAVolumeWithoutRenameFlagsBothFilesRotateInAndLeaveNoTombstone() throws {
        let events = Events()
        var rename = PortableRename.Operations.unsupportedFlags
        rename.afterReservationCreated = { events.add("reservation") }

        try recording(events, rename: rename) {
            _ = try signer.sign(provenanceURL: record)
            try Data(#"{"name":"changed"}"#.utf8).write(to: record)
            _ = try signer.sign(provenanceURL: record)
        }

        XCTAssertGreaterThanOrEqual(events.count("reservation"), 4, "both signings reserved their names the ExFAT way")
        XCTAssertEqual(events.count("published"), 4)
        XCTAssertEqual(try names(), [record.lastPathComponent, publicKeyURL.lastPathComponent, signatureURL.lastPathComponent],
                       "no tombstone and no stage file is left")
        XCTAssertTrue(try ProvenanceSignatureVerifier.verify(provenanceURL: record).isValid)
    }

    // MARK: - Helpers

    private struct Refusal: Error {}

    /// The steps and system calls one test saw, in order.
    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [String] = []

        func add(_ name: String) {
            lock.withLock { seen.append(name) }
        }

        var all: [String] { lock.withLock { seen } }

        func count(_ name: String) -> Int {
            all.filter { $0 == name }.count
        }
    }

    /// Runs `body` with every `DurableReplace` step and full flush recorded. `fault` sees each step
    /// with the number of times that step has happened and throws when it answers true.
    @discardableResult
    private func recording<Value>(
        _ events: Events,
        failingAt fault: (@Sendable (DurableReplace.Step, Int) -> Bool)? = nil,
        rename: PortableRename.Operations = .current,
        _ body: () throws -> Value
    ) throws -> Value {
        let operations = DurableReplace.Operations(
            rename: rename,
            fullFlush: { descriptor in
                events.add("fullFlush")
                return Darwin.fcntl(descriptor, F_FULLFSYNC)
            },
            checkpoint: { step in
                events.add(step.rawValue)
                if let fault, fault(step, events.count(step.rawValue)) {
                    throw Refusal()
                }
            }
        )
        return try DurableReplace.$overrideOperations.withValue(operations) { try body() }
    }

    private func names() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { !$0.hasPrefix("._") }
            .sorted()
    }
}
