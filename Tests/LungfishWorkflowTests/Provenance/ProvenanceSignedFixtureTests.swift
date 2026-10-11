// ProvenanceSignedFixtureTests.swift - Records signed before the reader changes keep verifying
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishTestSupport
@testable import LungfishWorkflow

/// Pins signatures against reader changes (Phase 2.6 lane P3a, panel decisions S3 to S5).
///
/// Signing canonicalizes only bytes that decode as `ProvenanceEnvelope` and signs any other
/// bytes as they are (`ProvenanceSigningPayload.data`). A decoder that accepts fewer or more
/// files therefore changes what a released signature covers. `Tests/Fixtures/provenance-signed`
/// holds one envelope record and one bundle roll-up, signed with the signing code of
/// `ddfe9b778`, and this suite verifies both. It also pins the payload bytes for every case of
/// the compatibility corpus, so a decoder change that moves a file between the two paths fails.
final class ProvenanceSignedFixtureTests: XCTestCase {
    /// The capture runs only with this variable set to 1, and never overwrites a file.
    static let captureVariable = "LUNGFISH_CAPTURE_SIGNED_PROVENANCE_FIXTURE"
    /// The key of the first case of `ProvenanceSigningTests`.
    static let signingKey = "unit-test-private-key"
    static let bundleLayout = "Signed.lungfish/Reference Sequences/Signed-Fixture.lungfishref"
    static let envelopeLayout = "\(bundleLayout)/.lungfish-provenance.json"
    static let rollupLayout = "\(bundleLayout)/provenance/bundle.lungfish-provenance.json"

    static var root: URL {
        ProvenanceCompatCorpus.repositoryRoot.appendingPathComponent("Tests/Fixtures/provenance-signed", isDirectory: true)
    }

    /// Each signed record with its signature and public key, relative to `root`.
    static var signedLayouts: [String] { [envelopeLayout, rollupLayout] }

    static func artifactLayouts(of layout: String) -> [String] {
        [layout, "\(layout).signature.json", "\(layout).pub"]
    }

    // MARK: Verification

    func testEnvelopeRecordSignedBeforeTheReaderChangesVerifies() throws {
        try assertVerifies(Self.envelopeLayout)
    }

    func testBundleRollupSignedBeforeTheReaderChangesVerifies() throws {
        try assertVerifies(Self.rollupLayout)
    }

    func testSignedRecordsDecodeAsEnvelopesSoTheirSignaturesCoverCanonicalBytes() throws {
        for layout in Self.signedLayouts {
            let bytes = try Data(contentsOf: Self.root.appendingPathComponent(layout))
            XCTAssertNoThrow(try ProvenanceEnvelopeReader.decodeCanonical(bytes), "\(layout) must decode as an envelope")
            XCTAssertNotNil(
                try? ProvenanceJSON.decoder.decode(ProvenanceEnvelope.self, from: bytes),
                "\(layout) is signed through the canonical payload, not its raw bytes"
            )
        }
    }

    func testATamperedCopyOfTheSignedRecordFailsVerification() throws {
        let copy = try copyFixture()
        defer { try? FileManager.default.removeItem(at: copy) }
        let url = copy.appendingPathComponent(Self.envelopeLayout)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["workflowName"] = "tampered"
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: url)
        XCTAssertThrowsError(try ProvenanceSignatureVerifier.verify(provenanceURL: url))
    }

    // MARK: Corpus payload pins

    /// For each corpus case, the SHA-256 of the bytes a signature over it covers and whether its
    /// bytes decode as an envelope, which sends them through the canonical reserialization. No corpus
    /// case carries a signature, so this pins what a signature over each would cover. The receipt's
    /// reserialization happens to equal its own bytes, which is why the decode is pinned on its own.
    /// Captured at `b44a9795b`, whose signing code is that of `ddfe9b778`.
    static let corpusPayloadPins: [String: (sha256: String, canonical: Bool)] = [
        "s1-db-receipt-kraken2-viral": ("3cf1b2a9737d665b987bae3b8ffed519f19332f122662292f38068b457b59be2", true),
        "s1-cancelled-single-step": ("fa981ef33f9fb3d38e2fbdd6bb46890d1952d7e56a136c4c19af79bf90f1bc9f", true),
        "s1-recorder-readsetplan": ("0aa580b3ed21634fb83ccccb7c796b8b616566465d2ce99bfcea8efd39bd269d", true),
        "s1-canonical-envelope-run": ("09a7237735365a5cb84e0684861f4107952af60b28ce862a7d3ab6ca3d12a9e6", true),
        "s2-analysis-kraken2-fixture": ("65d624c80e8e27e9aeba823dbd916ad8b32aa114b5b6331192ac7610da87b055", true),
        "s3-ncbi-fetch-alpha11": ("65b9f512e3c7d3e8dfe26aaac4029145715f9035ca6674b6c41731c0a334724a", false),
        "s3-write-sidecar-bare-run": ("fb942957178271821bdc8bf020a84dbadd188a320e46771ca706c75e4cb0ce8b", false),
        "s3-gatk-container-bare-run": ("2e3cf6b99e261d0ffc78108440728a7d0919e913a47b565a157ebbe5e486b0ff", false),
        "s4-mcm-mhcref-shipped": ("c3fddb4438c4b56a2d322612ef25c2be6eeb6fc322baa6a6ee07391a1e8cea79", false),
        "s4-msa-mafft-2026-05": ("5d10981a3d4dd6ea76a696c808a8470dca4ba70dce3f0d9c559d54d83a74a907", false),
    ]

    func testSigningPayloadOfEveryCorpusRecordIsPinned() throws {
        let cases = try ProvenanceCompatCorpus.cases()
        XCTAssertEqual(Set(cases.map(\.id)), Set(Self.corpusPayloadPins.keys), "every corpus case needs a payload pin")
        for item in cases {
            let materialized = try ProvenanceCompatCorpus.materialize(item.id)
            defer { materialized.cleanup() }
            let bytes = try Data(contentsOf: materialized.sidecar)
            let payload = try ProvenanceSigningPayload.data(
                forProvenanceData: bytes,
                provider: ProvenanceSigningConfiguration.localProviderID,
                signatureURL: ProvenanceSigningConfiguration.signatureURL(for: materialized.sidecar)
            )
            let pin = try XCTUnwrap(Self.corpusPayloadPins[item.id], "no payload pin for \(item.id)")
            let canonical = (try? ProvenanceJSON.decoder.decode(ProvenanceEnvelope.self, from: bytes)) != nil
            XCTAssertEqual(canonical, pin.canonical, "whether \(item.id) is signed through the canonical payload")
            XCTAssertEqual(ProvenanceSigningPayload.sha256Hex(payload), pin.sha256, "signing payload of \(item.id)")
            if !canonical {
                XCTAssertEqual(payload, bytes, "\(item.id) is signed as its own bytes")
            }
        }
    }

    // MARK: Capture

    /// Writes the fixture once, through `ProvenanceWriter` with the local signer, inside a temporary
    /// project, then copies the signed record, the roll-up and their signature artifacts.
    func testCaptureSignedFixture() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment[Self.captureVariable] == "1",
            "Set \(Self.captureVariable)=1 to capture the signed fixture."
        )
        for layout in Self.signedLayouts.flatMap(Self.artifactLayouts(of:)) {
            let destination = Self.root.appendingPathComponent(layout)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "refusing to overwrite \(layout)")
            if FileManager.default.fileExists(atPath: destination.path) { return }
        }

        let temporary = try TestTempDirectory.make(prefix: "provenance-signed-capture")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let bundle = temporary.appendingPathComponent(Self.bundleLayout, isDirectory: true)
        let genome = bundle.appendingPathComponent("genome", isDirectory: true)
        try FileManager.default.createDirectory(at: genome, withIntermediateDirectories: true)
        let sequence = genome.appendingPathComponent("sequence.fa")
        try Data(">signed-fixture\nACGTACGTACGT\n".utf8).write(to: sequence)
        let index = genome.appendingPathComponent("sequence.fa.fai")
        try Data("signed-fixture\t12\t16\t12\t13\n".utf8).write(to: index)
        let input = temporary.appendingPathComponent("Signed.lungfish/Downloads/signed-fixture.fa")
        try FileManager.default.createDirectory(at: input.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(">signed-fixture\nACGTACGTACGT\n".utf8).write(to: input)

        let inputDescriptor = try ProvenanceFileDescriptor.file(url: input, format: .fasta, role: .input)
        let outputs = [
            try ProvenanceFileDescriptor.file(url: sequence, format: .fasta, role: .output),
            try ProvenanceFileDescriptor.file(url: index, format: .fai, role: .output),
        ]
        let startedAt = Date(timeIntervalSince1970: 1_791_000_000)
        let argv = ["lungfish-cli", "import", "fasta", input.path, "--output", bundle.path]
        let step = ProvenanceStep(
            id: UUID(uuidString: "5A1C0B7E-2D3F-4E58-9A6B-7C8D9E0F1A2B")!,
            toolName: "lungfish-cli",
            toolVersion: "2026.10.10",
            argv: argv,
            inputs: [inputDescriptor],
            outputs: outputs,
            exitStatus: 0,
            wallTimeSeconds: 2,
            startedAt: startedAt,
            completedAt: startedAt.addingTimeInterval(2)
        )
        let envelope = ProvenanceEnvelope(
            id: UUID(uuidString: "3E9B5C1D-7A2F-4B6E-8C0D-1F2A3B4C5D6E")!,
            createdAt: startedAt,
            workflowName: "reference-import",
            workflowVersion: "Lungfish 2026.10.10 (signed-fixture)",
            toolName: "lungfish-cli",
            toolVersion: "2026.10.10",
            tool: ProvenanceToolIdentity(name: "lungfish-cli", version: "2026.10.10", kind: "cli"),
            argv: argv,
            options: ProvenanceOptions(explicit: ["format": .string("fasta")]),
            runtimeIdentity: ProvenanceRuntimeIdentity(
                appVersion: "Lungfish 2026.10.10 (signed-fixture)",
                executablePath: "/usr/local/bin/lungfish-cli",
                processIdentifier: 4242,
                operatingSystemVersion: "macOS 26.0.0 (arm64)",
                architecture: "arm64",
                user: nil,
                dependencySet: "2026.2"
            ),
            files: [inputDescriptor] + outputs,
            output: outputs[0],
            outputs: outputs,
            steps: [step],
            wallTimeSeconds: 2,
            exitStatus: 0,
            status: .completed
        )
        let writer = ProvenanceWriter(signingProvider: LocalProvenanceSigningProvider(privateKey: Self.signingKey))
        try writer.write(envelope, to: bundle)

        for layout in Self.signedLayouts.flatMap(Self.artifactLayouts(of:)) {
            let source = temporary.appendingPathComponent(layout)
            let destination = Self.root.appendingPathComponent(layout)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: destination)
        }
    }

    // MARK: Helpers

    private func copyFixture() throws -> URL {
        let temporary = try TestTempDirectory.make(prefix: "provenance-signed")
        let source = Self.root.appendingPathComponent("Signed.lungfish", isDirectory: true)
        try FileManager.default.copyItem(at: source, to: temporary.appendingPathComponent("Signed.lungfish", isDirectory: true))
        return temporary
    }

    private func assertVerifies(_ layout: String, file: StaticString = #filePath, line: UInt = #line) throws {
        for artifact in Self.artifactLayouts(of: layout) {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: Self.root.appendingPathComponent(artifact).path),
                "missing \(artifact)", file: file, line: line
            )
        }
        let copy = try copyFixture()
        defer { try? FileManager.default.removeItem(at: copy) }
        let result = try ProvenanceSignatureVerifier.verify(provenanceURL: copy.appendingPathComponent(layout))
        XCTAssertTrue(result.isValid, file: file, line: line)
        XCTAssertEqual(result.provider, ProvenanceSigningConfiguration.localProviderID, file: file, line: line)
        let signature = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: copy.appendingPathComponent("\(layout).signature.json"))) as? [String: Any]
        )
        XCTAssertEqual(signature["provenanceSHA256"] as? String, result.provenanceSHA256, file: file, line: line)
    }
}
