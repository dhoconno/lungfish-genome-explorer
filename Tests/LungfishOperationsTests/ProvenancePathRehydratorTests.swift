import XCTest
import LungfishWorkflow
@testable import LungfishOperations

final class ProvenancePathRehydratorTests: XCTestCase {
    func testRehydratesCopiedBundleInternalAndAdjacentProvenancePaths() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProvenancePathRehydrator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let sourceBundle = temp.appendingPathComponent("Source.lungfishref", isDirectory: true)
        let destinationBundle = temp.appendingPathComponent("Project/Source copy.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceBundle, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationBundle.deletingLastPathComponent(), withIntermediateDirectories: true)

        let sourcePayload = sourceBundle.appendingPathComponent("reads/SRR.fastq")
        try FileManager.default.createDirectory(at: sourcePayload.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "@r\nACGT\n+\n!!!!\n".write(to: sourcePayload, atomically: true, encoding: .utf8)

        let internalProvenance = sourceBundle.appendingPathComponent(".lungfish-provenance.json")
        try JSONSerialization.data(
            withJSONObject: [
                "bundle": sourceBundle.standardizedFileURL.path,
                "outputs": [
                    ["path": sourcePayload.standardizedFileURL.path]
                ],
                "argv": ["lungfish-cli", "import", "fastq", sourcePayload.standardizedFileURL.path],
                "command": "lungfish-cli import fastq \(sourcePayload.standardizedFileURL.path)",
                "reproducibleCommand": "lungfish-cli import fastq \(sourcePayload.standardizedFileURL.path)",
            ],
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: internalProvenance)

        let adjacentSidecar = URL(fileURLWithPath: sourceBundle.standardizedFileURL.path + ".lungfish-provenance.json")
        try JSONSerialization.data(
            withJSONObject: [
                "outputs": [
                    ["path": sourceBundle.standardizedFileURL.path]
                ]
            ],
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: adjacentSidecar)

        try FileManager.default.copyItem(at: sourceBundle, to: destinationBundle)

        ProvenancePathRehydrator.rehydrate(from: sourceBundle, to: destinationBundle)

        let rewritten = try JSONSerialization.jsonObject(
            with: Data(contentsOf: destinationBundle.appendingPathComponent(".lungfish-provenance.json"))
        ) as? [String: Any]
        let outputs = rewritten?["outputs"] as? [[String: Any]]
        XCTAssertEqual(rewritten?["bundle"] as? String, destinationBundle.standardizedFileURL.path)
        XCTAssertEqual(
            outputs?.first?["path"] as? String,
            destinationBundle.appendingPathComponent("reads/SRR.fastq").standardizedFileURL.path
        )
        XCTAssertEqual(
            rewritten?["command"] as? String,
            "lungfish-cli import fastq \(sourcePayload.standardizedFileURL.path)"
        )
        XCTAssertEqual(
            rewritten?["reproducibleCommand"] as? String,
            "lungfish-cli import fastq \(sourcePayload.standardizedFileURL.path)"
        )
        XCTAssertEqual(
            rewritten?["argv"] as? [String],
            ["lungfish-cli", "import", "fastq", sourcePayload.standardizedFileURL.path]
        )

        let destinationSidecar = URL(fileURLWithPath: destinationBundle.standardizedFileURL.path + ".lungfish-provenance.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationSidecar.path))
    }

    func testWrappedFASTQSidecarIsRehydratedIntoBundleRootProvenance() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProvenancePathRehydrator-FASTQ-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let sourceFASTQ = temp.appendingPathComponent("download.fastq")
        try "@r\nACGT\n+\n!!!!\n".write(to: sourceFASTQ, atomically: true, encoding: .utf8)
        let sourceSidecar = URL(fileURLWithPath: sourceFASTQ.standardizedFileURL.path + ".lungfish-provenance.json")
        try JSONSerialization.data(
            withJSONObject: [
                "outputs": [
                    ["path": sourceFASTQ.standardizedFileURL.path]
                ],
                "command": "lungfish-cli fetch ncbi SRR123 --save-to \(sourceFASTQ.standardizedFileURL.path)",
            ],
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: sourceSidecar)

        let bundleURL = temp.appendingPathComponent("download.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let bundledFASTQ = bundleURL.appendingPathComponent("download.fastq")
        try FileManager.default.copyItem(at: sourceFASTQ, to: bundledFASTQ)

        ProvenancePathRehydrator.rehydrate(from: sourceFASTQ, to: bundledFASTQ)

        let bundleProvenanceURL = bundleURL.appendingPathComponent(".lungfish-provenance.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleProvenanceURL.path))
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: bundleProvenanceURL)) as? [String: Any]
        let outputs = json?["outputs"] as? [[String: Any]]
        XCTAssertEqual(outputs?.first?["path"] as? String, bundledFASTQ.standardizedFileURL.path)
        XCTAssertEqual(
            json?["command"] as? String,
            "lungfish-cli fetch ncbi SRR123 --save-to \(sourceFASTQ.standardizedFileURL.path)"
        )
    }

    func testRehydratesTypedFileParameterValuesWithoutChangingTypedStrings() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProvenancePathRehydrator-Typed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let sourceFASTQ = temp.appendingPathComponent("reads.fastq")
        let destinationFASTQ = temp.appendingPathComponent("Project/Downloads/reads.fastq")
        try FileManager.default.createDirectory(
            at: destinationFASTQ.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "@r\nACGT\n+\n!!!!\n".write(to: sourceFASTQ, atomically: true, encoding: .utf8)
        try FileManager.default.copyItem(at: sourceFASTQ, to: destinationFASTQ)

        let sourceSidecar = URL(fileURLWithPath: sourceFASTQ.standardizedFileURL.path + ".lungfish-provenance.json")
        try JSONSerialization.data(
            withJSONObject: [
                "parameters": [
                    "input": [
                        "type": "file",
                        "value": sourceFASTQ.standardizedFileURL.path,
                    ],
                    "notes": [
                        "type": "string",
                        "value": sourceFASTQ.standardizedFileURL.path,
                    ],
                    "nestedInputs": [
                        "type": "array",
                        "value": [
                            [
                                "type": "file",
                                "value": sourceFASTQ.standardizedFileURL.path,
                            ],
                        ],
                    ],
                ],
                "command": "lungfish-cli import fastq \(sourceFASTQ.standardizedFileURL.path)",
            ],
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: sourceSidecar)

        ProvenancePathRehydrator.rehydrate(from: sourceFASTQ, to: destinationFASTQ)

        let destinationSidecar = URL(fileURLWithPath: destinationFASTQ.standardizedFileURL.path + ".lungfish-provenance.json")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: destinationSidecar)) as? [String: Any]
        let parameters = json?["parameters"] as? [String: Any]
        let input = parameters?["input"] as? [String: Any]
        let notes = parameters?["notes"] as? [String: Any]
        let nestedInputs = parameters?["nestedInputs"] as? [String: Any]
        let nestedValue = nestedInputs?["value"] as? [[String: Any]]

        XCTAssertEqual(input?["value"] as? String, destinationFASTQ.standardizedFileURL.path)
        XCTAssertEqual(notes?["value"] as? String, sourceFASTQ.standardizedFileURL.path)
        XCTAssertEqual(nestedValue?.first?["value"] as? String, destinationFASTQ.standardizedFileURL.path)
        XCTAssertEqual(
            json?["command"] as? String,
            "lungfish-cli import fastq \(sourceFASTQ.standardizedFileURL.path)"
        )
    }

    // MARK: - A rename of a plain folder (Phase 2.11 lane A68, carry-in row SW1)

    /// A pin that passes at the base. A rename of a plain folder rewrites a path value that is the folder itself or
    /// lies under it, keeps argv and command values exact, and leaves an unsigned record unsigned with every other
    /// value as it was.
    func testARenamedFolderRewritesItsOwnPathAndPathsUnderItAndKeepsCommandsExact() throws {
        let temp = try makeTemporaryFolder("Rename")
        let source = temp.appendingPathComponent("kraken2-batch", isDirectory: true)
        let destination = temp.appendingPathComponent("kraken2-batch renamed", isDirectory: true)
        let sourcePath = source.standardizedFileURL.path
        let destinationPath = destination.standardizedFileURL.path
        let record: [String: Any] = [
            "outputPath": sourcePath,
            "outputs": [["path": sourcePath + "/S1/report.tsv"]],
            "argv": ["lungfish-cli", "classify", "--output", sourcePath],
            "command": "lungfish-cli classify --output \(sourcePath)",
            "reproducibleCommand": "lungfish-cli classify --output \(sourcePath)/S1",
            "workflowName": "Metagenomics Classification",
        ]
        try Self.write(record, to: source.appendingPathComponent(".lungfish-provenance.json"))

        try FileManager.default.moveItem(at: source, to: destination)
        ProvenancePathRehydrator.rehydrate(from: source, to: destination)

        let recordURL = destination.appendingPathComponent(".lungfish-provenance.json")
        var expected = record
        expected["outputPath"] = destinationPath
        expected["outputs"] = [["path": destinationPath + "/S1/report.tsv"]]
        XCTAssertEqual(try Self.read(recordURL), expected as NSDictionary)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProvenanceSigningConfiguration.signatureURL(for: recordURL).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProvenanceSigningConfiguration.publicKeyURL(for: recordURL).path))
    }

    /// SW1 (b). A record's signature file is not a record. A rename that changes no signed value of a signed record
    /// leaves its signature file alone, the same file with the same bytes, and the record still verifies. At the base
    /// the enumerator took `<record>.signature.json` for a record and wrote it again.
    func testTheRewriteLeavesASignatureFileAlone() throws {
        let temp = try makeTemporaryFolder("Signature")
        let source = temp.appendingPathComponent("kraken2-batch", isDirectory: true)
        let destination = temp.appendingPathComponent("kraken2-batch renamed", isDirectory: true)
        // The fixture names `input.fastq` and `output.fastq`, nothing under the folder.
        let signer = LocalProvenanceSigningProvider(privateKey: "lane-a68-throwaway-signing-key")
        let written = try ProvenanceWriter(signingProvider: signer).write(.fixture(), to: source)
        try FileManager.default.moveItem(at: source, to: destination)
        let recordURL = destination.appendingPathComponent(written.lastPathComponent)
        let signatureURL = ProvenanceSigningConfiguration.signatureURL(for: recordURL)
        let identity = try Self.fileNumber(of: signatureURL)
        let bytes = try Data(contentsOf: signatureURL)

        ProvenancePathRehydrator.rehydrate(from: source, to: destination)

        XCTAssertEqual(try Self.fileNumber(of: signatureURL), identity, "the signature file is the file it was")
        XCTAssertEqual(try Data(contentsOf: signatureURL), bytes, "the signature file holds the bytes it held")
        XCTAssertNoThrow(try ProvenanceSignatureVerifier.verify(provenanceURL: recordURL))
    }

    /// SW1 (c). A record under a folder that names a file in a sibling folder whose name extends the folder's keeps the
    /// sibling's path after a rename. At the base the rewrite replaced the folder's path inside any value, so
    /// `kraken2-batch-2/S1/report.tsv` came to read `kraken2-batch renamed-2/S1/report.tsv`, a file that never existed.
    func testARenameKeepsThePathOfASiblingWhoseNameExtendsTheFolders() throws {
        let temp = try makeTemporaryFolder("Sibling")
        let source = temp.appendingPathComponent("kraken2-batch", isDirectory: true)
        let destination = temp.appendingPathComponent("kraken2-batch renamed", isDirectory: true)
        let siblingFile = temp.appendingPathComponent("kraken2-batch-2/S1/report.tsv").standardizedFileURL.path
        let ownFile = source.appendingPathComponent("S1/report.tsv").standardizedFileURL.path
        try Self.write(
            ["inputs": [["path": siblingFile]], "outputs": [["path": ownFile]]],
            to: source.appendingPathComponent(".lungfish-provenance.json")
        )

        try FileManager.default.moveItem(at: source, to: destination)
        ProvenancePathRehydrator.rehydrate(from: source, to: destination)

        let record = try Self.read(destination.appendingPathComponent(".lungfish-provenance.json"))
        let input = (record["inputs"] as? [[String: Any]])?.first?["path"] as? String
        let output = (record["outputs"] as? [[String: Any]])?.first?["path"] as? String
        XCTAssertEqual(input, siblingFile, "the sibling's file keeps its path")
        XCTAssertEqual(output, destination.appendingPathComponent("S1/report.tsv").standardizedFileURL.path)
    }

    /// SW1 (c), the other half. A value that holds the folder's path inside a longer string, a `file://` URL or a note
    /// around a path, is neither the folder nor under it, so a rename leaves it as it was (the plan's narrower rule).
    func testAValueThatOnlyHoldsTheFolderPathInsideALongerStringIsLeftAsItWas() throws {
        let temp = try makeTemporaryFolder("Inside")
        let source = temp.appendingPathComponent("kraken2-batch", isDirectory: true)
        let destination = temp.appendingPathComponent("kraken2-batch renamed", isDirectory: true)
        let sourcePath = source.standardizedFileURL.path
        try Self.write(
            [
                "sourceURL": "file://" + sourcePath + "/S1/report.tsv",
                "outputPath": "copied from " + sourcePath + "/S1",
                "inputs": [["path": sourcePath + "/S1/report.tsv"]],
            ],
            to: source.appendingPathComponent(".lungfish-provenance.json")
        )

        try FileManager.default.moveItem(at: source, to: destination)
        ProvenancePathRehydrator.rehydrate(from: source, to: destination)

        let record = try Self.read(destination.appendingPathComponent(".lungfish-provenance.json"))
        for key in ["sourceURL", "outputPath"] {
            let value = try XCTUnwrap(record[key] as? String, key)
            XCTAssertTrue(value.contains("kraken2-batch/S1"), "\(key) keeps the folder name it held")
            XCTAssertFalse(value.contains("kraken2-batch renamed"), "\(key) is not rewritten")
        }
        let input = (record["inputs"] as? [[String: Any]])?.first?["path"] as? String
        XCTAssertEqual(input, destination.appendingPathComponent("S1/report.tsv").standardizedFileURL.path, "a path under the folder is rewritten")
    }

    /// SW1 (a) with the signer passed in. A signed record that the rename changes is signed again with a key and
    /// passes the check of `provenance verify`. With no key it reads unsigned, with no signature file, no public key
    /// and no signature named inside it (plan decision S5).
    func testASignedRecordTheRenameChangesIsSignedAgainWithAKeyAndReadsUnsignedWithNone() throws {
        let signer = LocalProvenanceSigningProvider(privateKey: "lane-a68-throwaway-signing-key")
        for rebindSigner in [signer, nil] as [(any ProvenanceSigningProvider)?] {
            let temp = try makeTemporaryFolder("Signed")
            let source = temp.appendingPathComponent("kraken2-batch", isDirectory: true)
            let destination = temp.appendingPathComponent("kraken2-batch renamed", isDirectory: true)
            let report = source.appendingPathComponent("S1/report.tsv").standardizedFileURL.path
            let written = try ProvenanceWriter(signingProvider: signer).write(.fixture(outputPath: report), to: source)
            try FileManager.default.moveItem(at: source, to: destination)
            let recordURL = destination.appendingPathComponent(written.lastPathComponent)
            let label = rebindSigner == nil ? "with no key" : "with a key"

            ProvenancePathRehydrator.rehydrate(from: source, to: destination, signingProvider: rebindSigner)

            let envelope = try ProvenanceJSON.decoder.decode(ProvenanceEnvelope.self, from: Data(contentsOf: recordURL))
            XCTAssertEqual(
                envelope.output?.path, destination.appendingPathComponent("S1/report.tsv").standardizedFileURL.path, label
            )
            let pair = [
                ProvenanceSigningConfiguration.signatureURL(for: recordURL),
                ProvenanceSigningConfiguration.publicKeyURL(for: recordURL),
            ].map { FileManager.default.fileExists(atPath: $0.path) }
            if rebindSigner == nil {
                XCTAssertEqual(pair, [false, false], "\(label), the record holds no signature file and no public key")
                XCTAssertTrue(envelope.signatures.isEmpty, "\(label), the record names no signature")
            } else {
                XCTAssertNoThrow(try ProvenanceSignatureVerifier.verify(provenanceURL: recordURL), label)
                // The fixture also names a signature of `fixture-provider`, which the writer keeps as it keeps any other provider's.
                XCTAssertEqual(envelope.signatures.filter { $0.provider == signer.providerIdentifier }.count, 1, label)
            }
        }
    }

    /// A record whose signature failed before the rename still fails after it, with a key and with none. The rename
    /// neither signs it again nor drops its signature, so it reads tampered as it did and never verified or unsigned.
    func testARecordWhoseSignatureFailedBeforeTheRenameStillFailsAfterIt() throws {
        let signer = LocalProvenanceSigningProvider(privateKey: "lane-a68-throwaway-signing-key")
        for rebindSigner in [signer, nil] as [(any ProvenanceSigningProvider)?] {
            let label = rebindSigner == nil ? "with no key" : "with a key"
            let temp = try makeTemporaryFolder("Tampered")
            let source = temp.appendingPathComponent("kraken2-batch", isDirectory: true)
            let destination = temp.appendingPathComponent("kraken2-batch renamed", isDirectory: true)
            let report = source.appendingPathComponent("S1/report.tsv").standardizedFileURL.path
            let written = try ProvenanceWriter(signingProvider: signer).write(.fixture(outputPath: report), to: source)
            let tampered = try XCTUnwrap(Self.read(written).mutableCopy() as? NSMutableDictionary)
            tampered["workflowName"] = "edited after signing"
            try JSONSerialization.data(withJSONObject: tampered, options: [.prettyPrinted, .sortedKeys]).write(to: written)
            XCTAssertThrowsError(try ProvenanceSignatureVerifier.verify(provenanceURL: written), "\(label), the edit breaks the signature")
            try FileManager.default.moveItem(at: source, to: destination)
            let recordURL = destination.appendingPathComponent(written.lastPathComponent)

            ProvenancePathRehydrator.rehydrate(from: source, to: destination, signingProvider: rebindSigner)

            XCTAssertTrue(FileManager.default.fileExists(atPath: ProvenanceSigningConfiguration.signatureURL(for: recordURL).path), label)
            XCTAssertTrue(FileManager.default.fileExists(atPath: ProvenanceSigningConfiguration.publicKeyURL(for: recordURL).path), label)
            XCTAssertThrowsError(try ProvenanceSignatureVerifier.verify(provenanceURL: recordURL), "\(label), the record still fails")
            let envelope = try ProvenanceJSON.decoder.decode(ProvenanceEnvelope.self, from: Data(contentsOf: recordURL))
            XCTAssertFalse(envelope.signatures.isEmpty, "\(label), the record still names its signature")
        }
    }

    /// A signed record that is not an envelope cannot be signed again through the writer, so a rename that changes it
    /// drops its signature file and public key, with a key and with none, and never leaves a stale pair.
    func testASignedRecordThatIsNotAnEnvelopeLosesItsPairWhenTheRenameChangesIt() throws {
        let signer = LocalProvenanceSigningProvider(privateKey: "lane-a68-throwaway-signing-key")
        for rebindSigner in [signer, nil] as [(any ProvenanceSigningProvider)?] {
            let label = rebindSigner == nil ? "with no key" : "with a key"
            let temp = try makeTemporaryFolder("BareRun")
            let source = temp.appendingPathComponent("kraken2-batch", isDirectory: true)
            let destination = temp.appendingPathComponent("kraken2-batch renamed", isDirectory: true)
            let recordURL = source.appendingPathComponent(".lungfish-provenance.json")
            try Self.write(["workflowName": "A bare run", "outputPath": source.appendingPathComponent("S1").standardizedFileURL.path], to: recordURL)
            _ = try signer.sign(provenanceURL: recordURL)
            XCTAssertNoThrow(try ProvenanceSignatureVerifier.verify(provenanceURL: recordURL), "\(label), signed before")
            try FileManager.default.moveItem(at: source, to: destination)
            let moved = destination.appendingPathComponent(".lungfish-provenance.json")

            ProvenancePathRehydrator.rehydrate(from: source, to: destination, signingProvider: rebindSigner)

            XCTAssertEqual(try Self.read(moved)["outputPath"] as? String, destination.appendingPathComponent("S1").standardizedFileURL.path, label)
            XCTAssertFalse(FileManager.default.fileExists(atPath: ProvenanceSigningConfiguration.signatureURL(for: moved).path), label)
            XCTAssertFalse(FileManager.default.fileExists(atPath: ProvenanceSigningConfiguration.publicKeyURL(for: moved).path), label)
        }
    }

    // MARK: - Helpers

    private static func fileNumber(of url: URL) throws -> UInt64 {
        let number = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber
        return try XCTUnwrap(number, url.path).uint64Value
    }

    private func makeTemporaryFolder(_ name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProvenancePathRehydrator-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    private static func write(_ record: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]).write(to: url)
    }

    private static func read(_ url: URL) throws -> NSDictionary {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? NSDictionary, url.path)
    }
}
