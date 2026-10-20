// ProvenanceRecordPinTests.swift - Pins of the exporter's records and of the slash prediction (Phase 2.13 lane 13.13)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishWorkflow

/// Rows 10 and 11 of `BIO-13.12.md` F2 at the base, before they move onto the writer, and the proof that the writer's
/// bytes differ from the plain encoder's in slashes only (item 4 of the ARCH ruling).
final class ProvenanceRecordPinTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("provenance-record-pin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func export(_ envelope: ProvenanceEnvelope, format: ProvenanceExportFormat) throws -> ProvenanceExportBundle {
        try ProvenanceExporter(signingProvider: nil).exportBundle(
            envelope,
            format: format,
            to: root.appendingPathComponent("export-\(format.rawValue)", isDirectory: true),
            sourceSidecarURL: nil,
            allowUnpinned: true
        )
    }

    /// Row 10, `ProvenanceExporter.swift:162`. The export of a record writes its `provenance.json` as the encode of the
    /// record, with slashes as typed.
    func testExportedProvenanceJSONKeepsItsBytes() throws {
        let bundle = try export(ProvenanceRecordFreezeFixtures.preparationEnvelope(), format: .json)
        XCTAssertEqual(bundle.primaryArtifactURL.lastPathComponent, "provenance.json")
        let bytes = try Data(contentsOf: bundle.primaryArtifactURL)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("\\/"))
        try ProvenanceRecordPin.assertBytes(bytes, equalFixture: "exporter-provenance.json")
    }

    /// Row 10 for a record that names a signature. The export keeps the references the source record holds, and the
    /// writer's `package` refuses that same record. This is the finding of the M0 report, which stops the lane.
    func testExportOfASignedRecordAsJSONKeepsItsSignatureReferences() throws {
        var envelope = ProvenanceRecordFreezeFixtures.preparationEnvelope()
        envelope.signatures = [
            ProvenanceSignatureReference(
                provider: "lungfish-local-deterministic-v1",
                provenanceSHA256: ProvenanceRecordFreezeFixtures.digest,
                signaturePath: ".lungfish-provenance.json.signature.json",
                publicKeyPath: nil
            ),
        ]
        let bundle = try export(envelope, format: .json)
        let exported = try ProvenanceEnvelopeReader.decodeCanonical(Data(contentsOf: bundle.primaryArtifactURL))
        XCTAssertEqual(exported.signatures, envelope.signatures)
        XCTAssertThrowsError(try ProvenanceWriter.package(envelope)) { error in
            XCTAssertEqual(error as? ProvenancePackageError, .envelopeCarriesSignatures(count: 1))
        }
    }

    /// Row 10 moves onto `ProvenanceWriter.exportedRecordBytes`. For a record that names no signature it returns the
    /// bytes `package` returns. For a signed source it keeps the references, where `package` throws, so the export of a
    /// signed record writes the bytes it wrote at the base.
    func testExportedRecordBytesEqualPackageWithoutSignaturesAndKeepThemWith() throws {
        let unsigned = ProvenanceRecordFreezeFixtures.preparationEnvelope()
        XCTAssertEqual(try ProvenanceWriter.exportedRecordBytes(unsigned), try ProvenanceWriter.package(unsigned))
        var signed = unsigned
        signed.signatures = [
            ProvenanceSignatureReference(
                provider: "lungfish-local-deterministic-v1",
                provenanceSHA256: ProvenanceRecordFreezeFixtures.digest,
                signaturePath: ".lungfish-provenance.json.signature.json",
                publicKeyPath: ".lungfish-provenance.json.public-key.json"
            ),
        ]
        let bytes = try ProvenanceWriter.exportedRecordBytes(signed)
        XCTAssertEqual(try ProvenanceEnvelopeReader.decodeCanonical(bytes).signatures, signed.signatures)
        XCTAssertEqual(bytes, try ProvenanceJSON.encoder.encode(signed))
        XCTAssertThrowsError(try ProvenanceWriter.package(signed))
    }

    /// Row 11, `ProvenanceExporter.swift:643`. The Nextflow export writes the container manifest of the plan's steps.
    func testContainerManifestKeepsItsBytes() throws {
        let identity = ProvenanceRuntimeIdentity(
            appVersion: "2026.10.21",
            executablePath: "<external>/lungfish-cli",
            operatingSystemVersion: "macOS 26.0",
            architecture: "arm64",
            user: nil,
            containerImage: "quay.io/biocontainers/fastp:0.23.4--h125f33a_5",
            containerDigest: "sha256:" + ProvenanceRecordFreezeFixtures.digest,
            dependencySet: "lungfish-tools-2026.10"
        )
        let input = ProvenanceFileDescriptor(
            path: "/Volumes/Frozen/reads/in.fastq",
            checksumSHA256: ProvenanceRecordFreezeFixtures.digest,
            fileSize: 1_024,
            role: .input
        )
        let output = ProvenanceFileDescriptor(
            path: "/Volumes/Frozen/reads/out.fastq",
            checksumSHA256: ProvenanceRecordFreezeFixtures.otherDigest,
            fileSize: 512,
            format: .fastq,
            role: .output
        )
        let argv = ["fastp", "-i", "/Volumes/Frozen/reads/in.fastq", "-o", "/Volumes/Frozen/reads/out.fastq"]
        let step = ProvenanceStep(
            id: ProvenanceRecordFreezeFixtures.stepID,
            toolName: "fastp",
            toolVersion: "0.23.4",
            argv: argv,
            runtimeIdentity: identity,
            inputs: [input],
            outputs: [output],
            exitStatus: 0,
            wallTimeSeconds: 42,
            startedAt: ProvenanceRecordFreezeFixtures.startedAt,
            completedAt: ProvenanceRecordFreezeFixtures.completedAt
        )
        let envelope = ProvenanceEnvelope(
            id: ProvenanceRecordFreezeFixtures.cleanupID,
            createdAt: ProvenanceRecordFreezeFixtures.completedAt,
            workflowName: "Container manifest pin",
            workflowVersion: "2026.10.21",
            toolName: "fastp",
            toolVersion: "0.23.4",
            argv: argv,
            runtimeIdentity: identity,
            files: [input],
            output: output,
            outputs: [output],
            steps: [step],
            wallTimeSeconds: 42,
            exitStatus: 0
        )
        let bundle = try export(envelope, format: .nextflow)
        let bytes = try Data(contentsOf: bundle.rootURL.appendingPathComponent("containers/manifest.json"))
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertTrue(text.contains("quay.io/biocontainers/fastp:0.23.4--h125f33a_5"), text)
        try ProvenanceRecordPin.assertBytes(bytes, equalFixture: "exporter-container-manifest.json")
    }

    /// Item 4 of the ARCH ruling predicts that a site of A-F5 moved onto the writer changes its bytes by slashes only.
    func testThePlainEncoderAndTheWriterDifferOnlyInSlashes() throws {
        let envelope = ProvenanceRecordFreezeFixtures.preparationEnvelope()
        let plain = String(decoding: try ProvenanceRecordPin.plainEncoderBytes(of: envelope), as: UTF8.self)
        let packaged = String(decoding: try ProvenanceWriter.package(envelope), as: UTF8.self)
        XCTAssertNotEqual(plain, packaged)
        XCTAssertTrue(plain.contains("\\/"))
        XCTAssertFalse(packaged.contains("\\/"))
        XCTAssertEqual(plain.replacingOccurrences(of: "\\/", with: "/"), packaged)
        try ProvenanceRecordPin.assertPlainEncoderBytes(Data(plain.utf8))
        try ProvenanceRecordPin.assertWriterBytes(Data(packaged.utf8))
    }
}
