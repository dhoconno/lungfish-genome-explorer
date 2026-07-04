import XCTest
@testable import LungfishCLI
@testable import LungfishCore
@testable import LungfishWorkflow

final class FetchNCBIProvenanceTests: XCTestCase {
    func testGenomeFetchBundleWritesFinalCLIProvenance() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fetch-genome-bundle-provenance-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bundleURL = tempDir.appendingPathComponent("Genome.lungfishref", isDirectory: true)
        let genomeDir = bundleURL.appendingPathComponent("genome", isDirectory: true)
        let provenanceDir = bundleURL.appendingPathComponent(
            ProvenanceWriter.bundleProvenanceDirectoryName,
            isDirectory: true
        )
        let downloadsDir = tempDir.appendingPathComponent("downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: genomeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: provenanceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)

        let manifestURL = bundleURL.appendingPathComponent("manifest.json")
        let finalFastaURL = genomeDir.appendingPathComponent("sequence.fa")
        try "{}".write(to: manifestURL, atomically: true, encoding: .utf8)
        try ">chr1\nACGT\n".write(to: finalFastaURL, atomically: true, encoding: .utf8)
        try "{}".write(
            to: bundleURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename),
            atomically: true,
            encoding: .utf8
        )
        try "{}".write(
            to: provenanceDir.appendingPathComponent(ProvenanceWriter.bundleRollupFilename),
            atomically: true,
            encoding: .utf8
        )
        try "{}".write(
            to: finalFastaURL.appendingPathExtension("lungfish-provenance.json"),
            atomically: true,
            encoding: .utf8
        )

        let downloadedFastaURL = downloadsDir.appendingPathComponent("remote.fna.gz")
        let downloadedGFFURL = downloadsDir.appendingPathComponent("remote.gff.gz")
        try Data("downloaded-fasta".utf8).write(to: downloadedFastaURL)
        try Data("downloaded-gff".utf8).write(to: downloadedGFFURL)
        let fastaSourceURL = try XCTUnwrap(URL(string: "https://example.org/remote.fna.gz"))
        let gffSourceURL = try XCTUnwrap(URL(string: "https://example.org/remote.gff.gz"))

        let envelope = try await GenomeFetchProvenanceWriter().writeBundle(
            .init(
                bundleURL: bundleURL,
                accession: "GCF_000001405.40",
                assemblyAccession: "GCF_000001405.40",
                organism: "Homo sapiens",
                outputDirectory: tempDir,
                bundleName: "Human",
                fastaOnly: false,
                noBundle: false,
                apiKeySource: .explicit,
                outputFormat: .json,
                quiet: true,
                fastaSourceURL: fastaSourceURL,
                downloadedFastaURL: downloadedFastaURL,
                gffSourceURL: gffSourceURL,
                downloadedGFFURL: downloadedGFFURL,
                startedAt: Date(timeIntervalSinceNow: -1)
            )
        )
        let storedEnvelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: bundleURL))

        XCTAssertEqual(envelope.workflowName, "lungfish fetch genome")
        XCTAssertEqual(storedEnvelope.workflowName, "lungfish fetch genome")
        XCTAssertEqual(storedEnvelope.toolName, "lungfish fetch genome")
        XCTAssertEqual(storedEnvelope.argv, [
            "lungfish", "fetch", "genome", "GCF_000001405.40",
            "--output-dir", tempDir.path,
            "--name", "Human",
            "--api-key", "<redacted>",
            "--format", "json",
            "--quiet"
        ])
        XCTAssertFalse(storedEnvelope.argv.contains("SECRET"))
        XCTAssertEqual(storedEnvelope.options.explicit["apiKeyProvided"], .boolean(true))
        XCTAssertEqual(storedEnvelope.options.explicit["apiKeySource"], .string("explicit"))

        let fastaInput = try XCTUnwrap(storedEnvelope.files.first { $0.path == fastaSourceURL.absoluteString })
        XCTAssertEqual(fastaInput.checksumSHA256, ProvenanceRecorder.sha256(of: downloadedFastaURL))
        XCTAssertEqual(fastaInput.fileSize, try ProvenanceFileHasher.fileSize(of: downloadedFastaURL))
        XCTAssertEqual(fastaInput.role, .reference)
        let gffInput = try XCTUnwrap(storedEnvelope.files.first { $0.path == gffSourceURL.absoluteString })
        XCTAssertEqual(gffInput.checksumSHA256, ProvenanceRecorder.sha256(of: downloadedGFFURL))
        XCTAssertEqual(gffInput.fileSize, try ProvenanceFileHasher.fileSize(of: downloadedGFFURL))
        XCTAssertEqual(gffInput.role, .input)

        let outputPaths = Set(storedEnvelope.outputs.map(\.path))
        XCTAssertEqual(outputPaths, [manifestURL.standardizedFileURL.path, finalFastaURL.standardizedFileURL.path])
        XCTAssertFalse(storedEnvelope.files.contains { $0.path == downloadedFastaURL.path })
        XCTAssertFalse(storedEnvelope.files.contains { $0.path.contains("/\(ProvenanceWriter.bundleProvenanceDirectoryName)/") })
        XCTAssertFalse(storedEnvelope.outputs.contains { $0.path.hasSuffix(".lungfish-provenance.json") })
    }

    func testGenomeFetchDirectOutputsWriteProvenance() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fetch-genome-direct-provenance-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let downloadsDir = tempDir.appendingPathComponent("downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)

        let downloadedFastaURL = downloadsDir.appendingPathComponent("remote.fna.gz")
        let downloadedGFFURL = downloadsDir.appendingPathComponent("remote.gff.gz")
        let finalFastaURL = tempDir.appendingPathComponent("Human.fna.gz")
        let finalGFFURL = tempDir.appendingPathComponent("Human.gff.gz")
        try Data("downloaded-fasta".utf8).write(to: downloadedFastaURL)
        try Data("downloaded-gff".utf8).write(to: downloadedGFFURL)
        try Data("final-fasta".utf8).write(to: finalFastaURL)
        try Data("final-gff".utf8).write(to: finalGFFURL)
        let fastaSourceURL = try XCTUnwrap(URL(string: "https://example.org/remote.fna.gz"))
        let gffSourceURL = try XCTUnwrap(URL(string: "https://example.org/remote.gff.gz"))

        try await GenomeFetchProvenanceWriter().writeDirectOutputs(
            .init(
                accession: "GCF_000001405.40",
                assemblyAccession: "GCF_000001405.40",
                organism: "Homo sapiens",
                outputDirectory: tempDir,
                bundleName: "Human",
                fastaOnly: false,
                noBundle: true,
                apiKeySource: .environment,
                outputFormat: .text,
                quiet: false,
                fastaSourceURL: fastaSourceURL,
                downloadedFastaURL: downloadedFastaURL,
                gffSourceURL: gffSourceURL,
                downloadedGFFURL: downloadedGFFURL,
                finalFastaURL: finalFastaURL,
                finalGFFURL: finalGFFURL,
                startedAt: Date(timeIntervalSinceNow: -1)
            )
        )

        let directoryEnvelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: tempDir))
        XCTAssertEqual(directoryEnvelope.workflowName, "lungfish fetch genome")
        XCTAssertEqual(directoryEnvelope.options.explicit["apiKeyProvided"], .boolean(true))
        XCTAssertEqual(directoryEnvelope.options.explicit["apiKeySource"], .string("environment"))
        XCTAssertFalse(directoryEnvelope.argv.contains("--api-key"))
        XCTAssertEqual(
            directoryEnvelope.outputs.map(\.path),
            [finalFastaURL.standardizedFileURL.path, finalGFFURL.standardizedFileURL.path]
        )
        let remoteInput = try XCTUnwrap(directoryEnvelope.files.first { $0.path == fastaSourceURL.absoluteString })
        XCTAssertEqual(remoteInput.checksumSHA256, ProvenanceRecorder.sha256(of: downloadedFastaURL))
        XCTAssertEqual(remoteInput.fileSize, try ProvenanceFileHasher.fileSize(of: downloadedFastaURL))
        XCTAssertEqual(try loadFileSidecarEnvelope(for: finalFastaURL).output?.path, finalFastaURL.path)
        XCTAssertEqual(try loadFileSidecarEnvelope(for: finalGFFURL).output?.path, finalGFFURL.path)
    }

    func testSaveToWritesOutputAndFileSpecificWorkflowProvenance() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FetchNCBIProvenanceOutputTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let outputURL = tempDir.appendingPathComponent("MN908947.3.fasta")
        let command = try NCBISubcommand.parse([
            "MN908947.3",
            "--fetch-format", "fasta",
            "--save-to", outputURL.path,
            "--format", "json"
        ])

        try command.writeNCBIFetchOutputWithProvenance(
            content: ">MN908947.3\nACGT\n",
            outputURL: outputURL,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            completedAt: Date(timeIntervalSince1970: 1_700_000_002)
        )

        XCTAssertEqual(try String(contentsOf: outputURL, encoding: .utf8), ">MN908947.3\nACGT\n")
        let provenanceURL = NCBISubcommand.provenanceSidecarURL(for: outputURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: provenanceURL.path))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let run = try decoder.decode(WorkflowRun.self, from: try Data(contentsOf: provenanceURL))
        XCTAssertEqual(run.steps.first?.outputs.first?.path, outputURL.path)
        XCTAssertNotNil(run.steps.first?.outputs.first?.sha256)
        XCTAssertEqual(run.steps.first?.outputs.first?.sizeBytes, 17)
    }

    func testSaveToWritesFileSpecificWorkflowProvenance() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FetchNCBIProvenanceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let outputURL = tempDir.appendingPathComponent("MN908947.3.fasta")
        try ">MN908947.3\nACGT\n".write(to: outputURL, atomically: true, encoding: .utf8)
        let command = try NCBISubcommand.parse([
            "MN908947.3",
            "--fetch-format", "fasta",
            "--save-to", outputURL.path,
            "--format", "json"
        ])

        try command.writeNCBIFetchProvenance(
            outputURL: outputURL,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            completedAt: Date(timeIntervalSince1970: 1_700_000_002)
        )

        let provenanceURL = NCBISubcommand.provenanceSidecarURL(for: outputURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: provenanceURL.path))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let run = try decoder.decode(WorkflowRun.self, from: try Data(contentsOf: provenanceURL))

        XCTAssertEqual(run.name, "ncbi-sequence-fetch")
        XCTAssertEqual(run.status, .completed)
        XCTAssertEqual(run.parameters["database"]?.stringValue, "nucleotide")
        XCTAssertEqual(run.parameters["fetchFormat"]?.stringValue, "fasta")
        XCTAssertEqual(run.parameters["saveTo"]?.stringValue, outputURL.path)
        XCTAssertEqual(run.parameters["endpoint"]?.stringValue, "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi")
        XCTAssertEqual(run.steps.count, 1)

        let step = try XCTUnwrap(run.steps.first)
        XCTAssertEqual(step.toolName, "ncbi-efetch")
        XCTAssertEqual(step.exitCode, 0)
        XCTAssertEqual(step.wallTime, 2)
        XCTAssertTrue(step.command.contains("--save-to"))
        XCTAssertTrue(step.command.contains(outputURL.path))
        XCTAssertEqual(step.inputs.first?.path, "ncbi://nucleotide/MN908947.3?rettype=fasta")
        XCTAssertEqual(step.outputs.first?.path, outputURL.path)
        XCTAssertEqual(step.outputs.first?.format, .fasta)
        XCTAssertNotNil(step.outputs.first?.sha256)
        XCTAssertEqual(step.outputs.first?.sizeBytes, 17)
    }

    func testProvenanceRecordsEnvironmentAPIKeyPresenceWithoutSecret() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FetchNCBIEnvAPIKeyProvenanceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let outputURL = tempDir.appendingPathComponent("MN908947.3.fasta")
        try ">MN908947.3\nACGT\n".write(to: outputURL, atomically: true, encoding: .utf8)
        let command = try NCBISubcommand.parse([
            "MN908947.3",
            "--fetch-format", "fasta",
            "--save-to", outputURL.path,
            "--format", "json"
        ])

        try command.writeNCBIFetchProvenance(
            outputURL: outputURL,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            completedAt: Date(timeIntervalSince1970: 1_700_000_002),
            environment: ["NCBI_API_KEY": "secret-from-env"]
        )

        let provenanceURL = NCBISubcommand.provenanceSidecarURL(for: outputURL)
        let rawProvenance = try String(contentsOf: provenanceURL, encoding: .utf8)
        XCTAssertFalse(rawProvenance.contains("secret-from-env"))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let run = try decoder.decode(WorkflowRun.self, from: Data(rawProvenance.utf8))

        XCTAssertEqual(run.parameters["apiKeyProvided"]?.booleanValue, true)
        XCTAssertFalse(try XCTUnwrap(run.steps.first).command.contains("--api-key"))
    }

    func testProvenanceRecordsRetryMetadataAndNoRetryFlag() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FetchNCBIRetryProvenanceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: tempDir)
        }

        let outputURL = tempDir.appendingPathComponent("MN908947.3.fasta")
        try ">MN908947.3\nACGT\n".write(to: outputURL, atomically: true, encoding: .utf8)
        let command = try NCBISubcommand.parse([
            "MN908947.3",
            "--fetch-format", "fasta",
            "--save-to", outputURL.path,
            "--no-retry",
            "--format", "json"
        ])

        try command.writeNCBIFetchProvenance(
            outputURL: outputURL,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            completedAt: Date(timeIntervalSince1970: 1_700_000_002),
            retryEvents: [
                NCBIRetryEvent(attempt: 1, maxRetries: 5, statusCode: 429, delaySeconds: 5),
                NCBIRetryEvent(attempt: 2, maxRetries: 5, statusCode: 429, delaySeconds: 10)
            ]
        )

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let run = try decoder.decode(
            WorkflowRun.self,
            from: try Data(contentsOf: NCBISubcommand.provenanceSidecarURL(for: outputURL))
        )

        XCTAssertEqual(run.parameters["retryEnabled"]?.booleanValue, false)
        XCTAssertEqual(run.parameters["retryCount"]?.integerValue, 2)
        guard case .array(let retryValues) = run.parameters["retryEvents"] else {
            return XCTFail("Expected retryEvents array")
        }
        XCTAssertEqual(retryValues.count, 2)
        guard case .dictionary(let firstRetry) = retryValues.first else {
            return XCTFail("Expected retry event dictionary")
        }
        XCTAssertEqual(firstRetry["attempt"]?.integerValue, 1)
        XCTAssertEqual(firstRetry["statusCode"]?.integerValue, 429)
        XCTAssertEqual(firstRetry["delaySeconds"]?.numberValue, 5)
        XCTAssertTrue(try XCTUnwrap(run.steps.first).command.contains("--no-retry"))
    }

    private func loadFileSidecarEnvelope(for outputURL: URL) throws -> ProvenanceEnvelope {
        let sidecarURL = ProvenanceRecorder.fileSidecarURL(for: outputURL)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: sidecarURL.path),
            "Missing file-specific provenance sidecar at \(sidecarURL.path)"
        )
        return try XCTUnwrap(ProvenanceRecorder.loadEnvelope(fromSidecar: sidecarURL))
    }
}
