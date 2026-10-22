// ImportFastqRecordTruthTests.swift - A real import's record states what the command ran (CHTC lane L5-RECORDS)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import CryptoKit
import Foundation
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow

/// Each test runs `lungfish-cli import fastq` on the sarscov2 pair and reads the bundle it writes, so the assertions
/// read the record a user would replay, never the source that builds it.
final class ImportFastqRecordTruthTests: XCTestCase {

    private var cliBinaryPath: URL? {
        CLITestBinaryResolver.cliBinaryURL(
            buildProductsDirectory: Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        )
    }

    private var fixturesDir: URL? {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/sarscov2")
        return FileManager.default.fileExists(atPath: dir.path) ? dir : nil
    }

    /// Imports the sarscov2 pair with `arguments` after the inputs and project, and returns the bundle's record and
    /// its sidecar metadata.
    private func importFixturePair(
        _ arguments: [String]
    ) throws -> (envelope: ProvenanceEnvelope, metadata: PersistedFASTQMetadata?) {
        guard let fixtures = fixturesDir else { throw XCTSkip("Fixtures not found") }
        guard let binary = cliBinaryPath else {
            throw XCTSkip("Inject LUNGFISH_CLI with the resolved swiftbuild product or build it beside the test bundle")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("record-truth-\(UUID().uuidString)")
        let input = root.appendingPathComponent("input")
        let project = root.appendingPathComponent("p.lungfish")
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent("Imports"), withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        for name in ["test_1.fastq.gz", "test_2.fastq.gz"] {
            try FileManager.default.copyItem(
                at: fixtures.appendingPathComponent(name), to: input.appendingPathComponent(name)
            )
        }

        let process = Process()
        process.executableURL = binary
        process.arguments = ["import", "fastq", input.path, "--project", project.path] + arguments
        let stderrPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe
        try process.run()
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "import fastq failed: \(stderr)")

        let bundle = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(
                at: project.appendingPathComponent("Imports"), includingPropertiesForKeys: nil
            ).first { $0.pathExtension == "lungfishfastq" },
            "the import wrote no bundle"
        )
        let envelope = try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self,
            from: Data(contentsOf: bundle.appendingPathComponent(ProvenanceRecorder.provenanceFilename))
        )
        let payload = try FileManager.default.contentsOfDirectory(at: bundle, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasSuffix(".fastq.gz") }
        return (envelope, payload.flatMap { FASTQMetadataStore.load(for: $0) })
    }

    // MARK: - M1, true recorded defaults

    /// A recipe whose file suggests `illumina4` binning, run with neither `--quality-binning` nor `--threads`, runs
    /// `none` on every core. The record names those as the defaults, not the recipe's suggestion and not 4 threads.
    func testRecordedDefaultsAreTheValuesTheCommandRanWithout() throws {
        let (envelope, metadata) = try importFixturePair([
            "--platform", "illumina",
            "--recipe", "illumina-amplicon-merge",
            "--no-optimize-storage",
            "--compression", "fast",
        ])
        let cores = ProcessInfo.processInfo.activeProcessorCount

        XCTAssertEqual(metadata?.ingestion?.qualityBinning, QualityBinningScheme.none.rawValue,
                       "the import ran without binning")
        XCTAssertEqual(envelope.options.explicit["qualityBinning"], .string(QualityBinningScheme.none.rawValue))
        XCTAssertEqual(envelope.options.defaults["qualityBinning"], .string(QualityBinningScheme.none.rawValue),
                       "the recorded default must be the binning the command runs when the option is absent")
        XCTAssertEqual(envelope.options.explicit["threads"], .integer(cores))
        XCTAssertEqual(envelope.options.defaults["threads"], .integer(cores),
                       "the recorded default must be the thread count the command runs when the option is absent")
    }

    // MARK: - M2, recipe identity

    /// The record names the recipe file that ran by the SHA-256 of its bytes and its format version, beside the id
    /// and name, so a plan built elsewhere can prove it ran the same file.
    func testRecordNamesTheRecipeFileThatRanByItsDigest() throws {
        let (envelope, metadata) = try importFixturePair([
            "--platform", "illumina",
            "--recipe", "illumina-amplicon-merge",
            "--no-optimize-storage",
            "--compression", "fast",
        ])
        let recipeFile = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishWorkflow/Resources/Recipes/illumina-amplicon-merge.recipe.json")
        let expected = SHA256.hash(data: try Data(contentsOf: recipeFile)).map { String(format: "%02x", $0) }.joined()

        XCTAssertEqual(metadata?.ingestion?.recipeApplied?.recipeID, "illumina-amplicon-merge")
        XCTAssertEqual(envelope.options.resolvedDefaults["recipeSHA256"], .string(expected),
                       "the record must name the recipe file's bytes")
        XCTAssertEqual(envelope.options.resolvedDefaults["recipeFormatVersion"], .integer(1))
        XCTAssertEqual(metadata?.ingestion?.recipeApplied?.recipeSHA256, expected, "the sidecar must name it too")
        XCTAssertEqual(metadata?.ingestion?.recipeApplied?.recipeFormatVersion, 1)
    }

    // MARK: - M2, database identity

    /// The `databases` entry and the index input of the record's step whose argv names `fileName`.
    private func databaseEvidence(
        in envelope: ProvenanceEnvelope,
        fileName: String
    ) throws -> (entry: [String: ParameterValue], input: ProvenanceFileDescriptor?) {
        let step = try XCTUnwrap(
            envelope.steps.first { $0.toolName == "deacon" && $0.argv.contains { $0.hasSuffix(fileName) } },
            "the record has no deacon step that read \(fileName)"
        )
        guard case .array(let databases)? = step.resolvedOptions["databases"],
              case .dictionary(let entry)? = databases.first else {
            XCTFail("the deacon step that read \(fileName) names no database in its resolved options")
            return ([:], nil)
        }
        return (entry, step.inputs.first { $0.path.hasSuffix(fileName) })
    }

    /// A wastewater import names each Deacon index it read by id, version, file name, index format, SHA-256 and
    /// size, and lists it as a step input with that digest. The panhuman index is the file the lock pins. The
    /// ribokmers index, which each install builds, names the source file and Deacon version its install record
    /// gives.
    func testRecordNamesEachDatabaseARecipeStepReadByItsDigest() async throws {
        let registry = DatabaseRegistry.shared
        guard let panhuman = try? await registry.requiredDatabasePath(for: "deacon-panhuman"),
              let ribokmers = try? await registry.requiredDatabasePath(for: "deacon-ribokmers") else {
            throw XCTSkip("deacon-panhuman and deacon-ribokmers must be installed")
        }
        let (envelope, _) = try importFixturePair([
            "--platform", "illumina",
            "--recipe", "wastewater-metagenomics",
            "--no-optimize-storage",
            "--compression", "fast",
        ])

        let scrub = try databaseEvidence(in: envelope, fileName: panhuman.lastPathComponent)
        let pin = try XCTUnwrap(ManagedToolLock.bundled.databases.first { $0.id == "deacon-panhuman" })
        XCTAssertEqual(scrub.entry["id"], .string("deacon-panhuman"))
        XCTAssertEqual(scrub.entry["version"], .string(pin.version))
        XCTAssertEqual(scrub.entry["fileName"], .string("panhuman-1.k31w15.idx"))
        XCTAssertEqual(scrub.entry["indexFormat"], .integer(3))
        XCTAssertEqual(scrub.entry["lockPinned"], .boolean(true), "the lock must pin the panhuman index")
        let pinnedSHA256 = try XCTUnwrap(pin.sha256, "the lock must pin the panhuman index's SHA-256")
        XCTAssertEqual(scrub.entry["sha256"], .string(pinnedSHA256))
        XCTAssertEqual(scrub.entry["sizeBytes"], pin.sizeBytes.map { .integer(Int($0)) })
        XCTAssertEqual(scrub.input?.checksumSHA256, pinnedSHA256, "the index is a step input with its digest")

        let ribo = try databaseEvidence(in: envelope, fileName: ribokmers.lastPathComponent)
        let size = try XCTUnwrap(
            try FileManager.default.attributesOfItem(atPath: ribokmers.path)[.size] as? NSNumber
        )
        XCTAssertEqual(ribo.entry["id"], .string("deacon-ribokmers"))
        XCTAssertEqual(ribo.entry["lockPinned"], .boolean(false), "each install builds the ribokmers index")
        XCTAssertEqual(ribo.entry["sizeBytes"], .integer(size.intValue))
        XCTAssertEqual(ribo.entry["indexFormat"], .integer(3))
        XCTAssertEqual(ribo.entry["kmerLength"], .integer(31))
        XCTAssertEqual(ribo.entry["windowSize"], .integer(15))
        XCTAssertNotNil(ribo.entry["buildToolVersion"], "the record names the Deacon that built the index")
        XCTAssertNotNil(ribo.entry["buildSourceSHA256"], "the record names the source the index was built from")
        XCTAssertEqual(ribo.input?.checksumSHA256, ribo.entry["sha256"].flatMap {
            if case .string(let digest) = $0 { return digest } else { return nil }
        })
    }

    // MARK: - M3, host choices

    /// The `-Xmx` value of the record step whose argv sets the Java heap, in GB.
    private func heapInArgv(of envelope: ProvenanceEnvelope) -> Int? {
        envelope.steps.lazy.flatMap(\.argv).first { $0.hasPrefix("-Xmx") && $0.hasSuffix("g") }
            .flatMap { Int($0.dropFirst(4).dropLast()) }
    }

    /// Run with neither `--threads` nor `--clumpify-heap-gb`, the record says the threads, the clumpify heap and the
    /// automatic clumping choice came from the host, and names the heap clumpify's argv ran with.
    func testRecordNamesTheHostAsTheSourceOfEachChoiceItMade() throws {
        let (envelope, _) = try importFixturePair(["--platform", "illumina", "--compression", "fast"])
        let resolved = envelope.options.resolvedDefaults
        let ranHeap = try XCTUnwrap(heapInArgv(of: envelope), "clumpify ran and its argv sets the heap")

        XCTAssertEqual(resolved["threadsSource"], .string("host"))
        XCTAssertEqual(resolved["clumpifyHeapGB"], .integer(ranHeap), "the record names the heap that ran")
        XCTAssertEqual(resolved["clumpingHeapBytes"], .integer(ranHeap * 1_073_741_824))
        XCTAssertEqual(resolved["clumpifyHeapSource"], .string("host"))
        XCTAssertEqual(resolved["resolvedClumpingTool"], .string("bbtools"))
        XCTAssertEqual(resolved["resolvedClumpingToolSource"], .string("host"))
    }

    /// `--threads`, `--clumping-tool` and `--clumpify-heap-gb` pin each choice. The record names each as the
    /// option's, clumpify runs with the pinned heap, and the replay command pins it again.
    func testOptionsPinEachHostChoiceAndTheRecordSaysSo() throws {
        let (envelope, _) = try importFixturePair([
            "--platform", "illumina", "--compression", "fast",
            "--threads", "2", "--clumping-tool", "bbtools", "--clumpify-heap-gb", "2",
        ])
        let resolved = envelope.options.resolvedDefaults

        XCTAssertEqual(heapInArgv(of: envelope), 2, "clumpify must run with the pinned heap")
        XCTAssertEqual(resolved["threadsSource"], .string("option"))
        XCTAssertEqual(resolved["threads"], .integer(2))
        XCTAssertEqual(resolved["clumpifyHeapGB"], .integer(2))
        XCTAssertEqual(resolved["clumpingHeapBytes"], .integer(2 * 1_073_741_824))
        XCTAssertEqual(resolved["clumpifyHeapSource"], .string("option"))
        XCTAssertEqual(resolved["resolvedClumpingToolSource"], .string("option"))
        XCTAssertEqual(envelope.options.explicit["clumpifyHeapGB"], .integer(2))
        XCTAssertTrue(envelope.reproducibleCommand.contains("--clumpify-heap-gb 2"),
                      "the replay command must pin the heap: \(envelope.reproducibleCommand)")
    }
}
