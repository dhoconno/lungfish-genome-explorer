// ImportFastqE2ETests+RecordTruth.swift - A real import's record states what the command ran (CHTC lane L5-RECORDS)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import CryptoKit
import Foundation
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow

/// Each test forks `lungfish-cli import fastq` on the sarscov2 pair and reads what it wrote, so the assertions read the
/// record a user would replay and the output a user would see, never the source that builds them. The tests belong to
/// this class so the full suite gate runs them with the other forked-CLI tests, one at a time and with the managed
/// tools present. `LUNGFISH_REQUIRE_TOOLS=1` turns a missing tool or database into a failure, not a skip.
extension ImportFastqE2ETests {

    // MARK: - Helpers

    /// How a forked CLI ended, with its standard output and standard error in one stream.
    private struct RecordTruthRun {
        let status: Int32
        let output: String
        let timedOut: Bool
    }

    private enum RecordTruthTool {
        case fastp, seqkit, deacon, clumpify
    }

    private var recordTruthCLI: URL? {
        CLITestBinaryResolver.cliBinaryURL(
            buildProductsDirectory: Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        )
    }

    private var recordTruthFixtures: URL? {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/sarscov2")
        return FileManager.default.fileExists(atPath: dir.path) ? dir : nil
    }

    /// Skips, or under `LUNGFISH_REQUIRE_TOOLS=1` fails, unless every named managed tool is installed.
    private func recordTruthRequire(_ tools: RecordTruthTool...) async throws {
        for tool in tools {
            switch tool {
            case .fastp: _ = try await ToolAvailability.require("fastp", environment: "fastp")
            case .seqkit: _ = try await ToolAvailability.require("seqkit", environment: "seqkit")
            case .deacon: _ = try await ToolAvailability.require("deacon", environment: "deacon")
            case .clumpify: _ = try await ToolAvailability.require("clumpify.sh", environment: "bbtools")
            }
        }
    }

    /// Runs the CLI and waits at most `timeout` seconds. On expiry it terminates the child, kills it ten seconds later
    /// if it ignores the signal, and reports the expiry. Output goes to a file, so a chatty child cannot block on a
    /// full pipe while the test waits.
    private func recordTruthRun(
        _ arguments: [String],
        environment: [String: String] = [:],
        scratch: URL,
        timeout: TimeInterval
    ) throws -> RecordTruthRun {
        guard let binary = recordTruthCLI else {
            try ToolAvailability.skipOrFail(
                "Inject LUNGFISH_CLI with the resolved swiftbuild product or build it beside the test bundle"
            )
        }
        let outputURL = scratch.appendingPathComponent("cli-output-\(UUID().uuidString).txt")
        XCTAssertTrue(FileManager.default.createFile(atPath: outputURL.path, contents: nil))
        let handle = try FileHandle(forWritingTo: outputURL)
        defer { try? handle.close() }

        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.standardOutput = handle
        process.standardError = handle
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + 10) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 10)
            }
        }
        let output = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
        return RecordTruthRun(
            status: process.isRunning ? -1 : process.terminationStatus, output: output, timedOut: timedOut
        )
    }

    /// A scratch folder holding `input` (the sarscov2 pair) and an empty `p.lungfish/Imports`.
    private func recordTruthProject() throws -> (root: URL, input: URL, project: URL) {
        guard let fixtures = recordTruthFixtures else { try ToolAvailability.skipOrFail("Fixtures not found") }
        let root = try TestTempDirectory.make(prefix: "record-truth")
        addTeardownBlock { TestTempDirectory.cleanup(root) }
        let input = root.appendingPathComponent("input")
        let project = root.appendingPathComponent("p.lungfish")
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent("Imports"), withIntermediateDirectories: true
        )
        for name in ["test_1.fastq.gz", "test_2.fastq.gz"] {
            try FileManager.default.copyItem(
                at: fixtures.appendingPathComponent(name), to: input.appendingPathComponent(name)
            )
        }
        return (root, input, project)
    }

    /// The bundles an import wrote into the project's `Imports` folder.
    private func recordTruthBundles(in project: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: project.appendingPathComponent("Imports"), includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "lungfishfastq" }
    }

    /// Imports the sarscov2 pair with `arguments` after the inputs and project, and returns the bundle's record and
    /// its sidecar metadata.
    private func recordTruthImport(
        _ arguments: [String]
    ) throws -> (envelope: ProvenanceEnvelope, metadata: PersistedFASTQMetadata?) {
        let (root, input, project) = try recordTruthProject()
        let run = try recordTruthRun(
            ["import", "fastq", input.path, "--project", project.path] + arguments, scratch: root, timeout: 900
        )
        XCTAssertFalse(run.timedOut, "import fastq did not end within 900 s: \(run.output)")
        XCTAssertEqual(run.status, 0, "import fastq failed: \(run.output)")

        let bundle = try XCTUnwrap(try recordTruthBundles(in: project).first, "the import wrote no bundle")
        let envelope = try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self,
            from: Data(contentsOf: bundle.appendingPathComponent(ProvenanceRecorder.provenanceFilename))
        )
        let payload = try FileManager.default.contentsOfDirectory(at: bundle, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasSuffix(".fastq.gz") }
        return (envelope, payload.flatMap { FASTQMetadataStore.load(for: $0) })
    }

    // MARK: - C4-10, the writer and level a storage step records leave provenance verify passing

    /// A real import of the sarscov2 pair, signed with a throwaway key, once through `clumpify.sh` and once through
    /// `reformat.sh` after `--clumping-tool none`. The step that wrote the stored gzip names a bgzip writer with an
    /// executable path and a level, and the forked CLI verifies the bundle's record that holds those keys (ARCH N3
    /// condition 3: `provenance verify` passes on a record with the new fields, a real `writer.tool.path` included).
    func testAnImportRecordThatNamesItsWriterAndLevelPassesProvenanceVerify() async throws {
        try await recordTruthRequire(.clumpify)
        let key = [ProvenanceSigningConfiguration.signingKeyEnvironmentKey: "c4-10-throwaway-signing-key"]
        let routes: [(clumpingTool: String, step: String)] = [("bbtools", "clumpify.sh"), ("none", "reformat.sh")]
        for route in routes {
            let (root, input, project) = try recordTruthProject()
            let imported = try recordTruthRun(
                [
                    "import", "fastq", input.path, "--project", project.path, "--platform", "illumina",
                    "--pairing", "paired", "--clumping-tool", route.clumpingTool, "--quality-binning", "illumina4",
                ],
                environment: key, scratch: root, timeout: 900
            )
            XCTAssertFalse(imported.timedOut, "\(route.step): import fastq did not end within 900 s: \(imported.output)")
            XCTAssertEqual(imported.status, 0, "\(route.step): import fastq failed: \(imported.output)")

            let bundle = try XCTUnwrap(
                try recordTruthBundles(in: project).first, "\(route.step): the import wrote no bundle"
            )
            let record = bundle.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
            // The record keeps a tool path portable (`<tool-root>/envs/bbtools/bin/bgzip`); reading resolves it here.
            let data = PortablePath.resolveJSON(try Data(contentsOf: record), forFileAt: record)
            let envelope = try ProvenanceJSON.decoder.decode(ProvenanceEnvelope.self, from: data)
            let step = try XCTUnwrap(
                envelope.steps.first { $0.toolName == route.step }, "\(envelope.steps.map(\.toolName))"
            )
            guard case .dictionary(let writer)? = step.resolvedOptions["writer"],
                  case .dictionary(let tool)? = writer["tool"], case .string(let path)? = tool["path"] else {
                XCTFail("\(route.step) names no bgzip writer: \(step.resolvedOptions)")
                continue
            }
            XCTAssertEqual(writer["name"], .string("bgzip"), route.step)
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: path), "\(route.step): \(path)")
            XCTAssertNotNil(step.resolvedOptions["effectiveCompressionLevel"], route.step)

            let verified = try recordTruthRun(
                ["provenance", "verify", record.path], environment: key, scratch: root, timeout: 60
            )
            XCTAssertEqual(verified.status, 0, "\(route.step): provenance verify: \(verified.output)")
            XCTAssertNotNil(verified.output.range(of: "Signature valid"), "\(route.step): \(verified.output)")
        }
    }

    // MARK: - M1, true recorded defaults

    /// A recipe whose file declares `fiveStep` binning (BIO-BIN), run with neither `--quality-binning` nor `--threads`,
    /// runs the recipe's binning on every core (lane C2-BINNING). The record names the recipe as the binning's source, the
    /// command's own Illumina default as `fiveStep` and the thread default as this host's core count, not 4.
    func testRecordedDefaultsAreTheValuesTheCommandRanWithout() async throws {
        try await recordTruthRequire(.fastp, .clumpify)
        let (envelope, metadata) = try recordTruthImport([
            "--platform", "illumina",
            "--recipe", "illumina-amplicon-merge",
            "--no-optimize-storage",
            "--compression", "fast",
        ])
        let cores = ProcessInfo.processInfo.activeProcessorCount

        XCTAssertEqual(metadata?.ingestion?.qualityBinning, QualityBinningScheme.fiveStep.rawValue,
                       "the import ran the binning the recipe declares")
        XCTAssertEqual(envelope.options.explicit["qualityBinning"], .string(QualityBinningScheme.fiveStep.rawValue))
        XCTAssertEqual(envelope.options.resolvedDefaults["qualityBinningSource"], .string("recipe"))
        XCTAssertEqual(envelope.options.defaults["qualityBinning"], .string(QualityBinningScheme.fiveStep.rawValue),
                       "the recorded default must be the binning the command runs when the option is absent")
        XCTAssertEqual(envelope.options.explicit["threads"], .integer(cores))
        XCTAssertEqual(envelope.options.defaults["threads"], .integer(cores),
                       "the recorded default must be the thread count the command runs when the option is absent")
    }

    /// With no `--quality-binning` and no recipe, an Illumina import bins with `fiveStep` (BIO-BIN) and its record says
    /// the value came from the default. The recorded command names the value, so a replay runs it whatever the default
    /// becomes.
    func testQualityBinningDefaultIsFiveStepForIlluminaAndTheRecordSaysSo() async throws {
        try await recordTruthRequire(.clumpify)
        let (envelope, metadata) = try recordTruthImport([
            "--platform", "illumina", "--no-optimize-storage", "--compression", "fast",
        ])

        XCTAssertEqual(metadata?.ingestion?.qualityBinning, QualityBinningScheme.fiveStep.rawValue,
                       "an import with no binning flag bins with fiveStep")
        XCTAssertEqual(envelope.options.explicit["qualityBinning"], .string(QualityBinningScheme.fiveStep.rawValue))
        XCTAssertEqual(envelope.options.defaults["qualityBinning"], .string(QualityBinningScheme.fiveStep.rawValue))
        XCTAssertEqual(envelope.options.resolvedDefaults["qualityBinningSource"], .string("default"))
        XCTAssertTrue(recordTruthNames(envelope.argv, "--quality-binning", "fiveStep"), "\(envelope.argv)")
    }

    /// `--quality-binning none` turns binning off, and the record says the value came from the option.
    func testQualityBinningDefaultGivesWayToAnExplicitNone() async throws {
        try await recordTruthRequire(.clumpify)
        let (envelope, metadata) = try recordTruthImport([
            "--platform", "illumina", "--no-optimize-storage", "--compression", "fast", "--quality-binning", "none",
        ])

        XCTAssertEqual(metadata?.ingestion?.qualityBinning, QualityBinningScheme.none.rawValue)
        XCTAssertEqual(envelope.options.explicit["qualityBinning"], .string(QualityBinningScheme.none.rawValue))
        XCTAssertEqual(envelope.options.resolvedDefaults["qualityBinningSource"], .string("option"))
        XCTAssertTrue(recordTruthNames(envelope.argv, "--quality-binning", "none"), "\(envelope.argv)")
    }

    /// BIO-BIN (Phase 3.0 lane BIN, S1). An Illumina import that names no binning stores Q20 and Q30 shares equal to
    /// the ones counted from the file as sequenced. The fixture (`Fixtures/quality-binning/q18-q19-q20-q30.fastq`)
    /// holds Q17 to Q21, Q28 to Q31 and Q37 bases, so a scheme that moves Q18 and Q19 up to Q22, as `illumina4` did,
    /// shows 85 percent at Q20 where the reads hold 45.
    func testIlluminaDefaultKeepsQ20() async throws {
        try await recordTruthRequire(.seqkit, .clumpify)
        guard let fixtures = recordTruthFixtures else { try ToolAvailability.skipOrFail("Fixtures not found") }
        let sequenced = fixtures.deletingLastPathComponent()
            .appendingPathComponent("quality-binning/q18-q19-q20-q30.fastq")
        let root = try TestTempDirectory.make(prefix: "record-truth-q20")
        addTeardownBlock { TestTempDirectory.cleanup(root) }
        let input = root.appendingPathComponent("input")
        let project = root.appendingPathComponent("p.lungfish")
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: project.appendingPathComponent("Imports"), withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: sequenced, to: input.appendingPathComponent("thresholds.fastq"))

        let run = try recordTruthRun(
            ["import", "fastq", input.path, "--project", project.path, "--platform", "illumina",
             "--no-optimize-storage", "--compression", "fast"],
            scratch: root, timeout: 900
        )
        XCTAssertFalse(run.timedOut, "import fastq did not end within 900 s: \(run.output)")
        XCTAssertEqual(run.status, 0, "import fastq failed: \(run.output)")
        let bundle = try XCTUnwrap(try recordTruthBundles(in: project).first, "the import wrote no bundle")
        let payload = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(at: bundle, includingPropertiesForKeys: nil)
                .first { $0.lastPathComponent.hasSuffix(".fastq.gz") }
        )
        let stored = try XCTUnwrap(FASTQMetadataStore.load(for: payload)?.computedStatistics)
        let counted = try await FASTQQualityFractions.scan(sequenced)

        XCTAssertEqual(counted.q20Percentage, 45, accuracy: 1e-9, "the fixture holds 36 of 80 bases at Q20 or above")
        XCTAssertEqual(stored.q20Percentage, counted.q20Percentage, accuracy: 1e-9,
                       "the stored Q20 share is the sequenced one")
        XCTAssertEqual(stored.q30Percentage, counted.q30Percentage, accuracy: 1e-9,
                       "the stored Q30 share is the sequenced one")
    }

    /// Whether `argv` holds `flag` followed by `value`.
    private func recordTruthNames(_ argv: [String], _ flag: String, _ value: String) -> Bool {
        zip(argv, argv.dropFirst()).contains { $0 == flag && $1 == value }
    }

    /// An import that names neither platform nor pairing, as the Import FASTQ sheet launches one it leaves untouched,
    /// records `auto` for both in `argv`, what was asked, and in its durable command the platform it detected and
    /// `paired` for the R1/R2 pair, so a replay runs what this run ran whatever detection does then (lane C2-SHEETFIX).
    func testAnUntouchedImportRecordsAutoAndReplaysThePlatformAndPairingThatRan() async throws {
        try await recordTruthRequire(.clumpify)
        let (envelope, metadata) = try recordTruthImport([
            "--no-optimize-storage", "--compression", "fast", "--quality-binning", "none",
        ])
        let durable = try XCTUnwrap(envelope.durableReplayArgv, "the record holds no durable command")
        let durablePlatform = zip(durable, durable.dropFirst()).first { $0.0 == "--platform" }?.1

        XCTAssertEqual(metadata?.ingestion?.pairingMode, .interleaved, "the pair was imported paired")
        XCTAssertTrue(recordTruthNames(envelope.argv, "--platform", "auto"), "\(envelope.argv)")
        XCTAssertTrue(recordTruthNames(envelope.argv, "--pairing", "auto"), "\(envelope.argv)")
        XCTAssertNotNil(durablePlatform, "\(durable)")
        XCTAssertNotEqual(durablePlatform, "auto", "the durable command names the detected platform: \(durable)")
        XCTAssertTrue(recordTruthNames(durable, "--pairing", "paired"), "\(durable)")
    }

    // MARK: - M2, recipe identity

    /// The record names the recipe file that ran by the SHA-256 of its bytes and its format version, beside the id
    /// and name, so a plan built elsewhere can prove it ran the same file.
    func testRecordNamesTheRecipeFileThatRanByItsDigest() async throws {
        try await recordTruthRequire(.fastp)
        let (envelope, metadata) = try recordTruthImport([
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
    private func recordTruthDatabaseEvidence(
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
    /// ribokmers index is the lock's hosted download on a fresh install, so `lockPinned` is true and the source file
    /// and Deacon version come from the lock. An index that an earlier install built on its own host has another
    /// digest, so `lockPinned` is false and those two come from its install record.
    func testRecordNamesEachDatabaseARecipeStepReadByItsDigest() async throws {
        try await recordTruthRequire(.fastp, .seqkit, .deacon)
        let registry = DatabaseRegistry.shared
        let panhuman = try await ToolAvailability.requireDatabase(
            { await registry.effectiveDatabasePath(for: "deacon-panhuman") }, name: "deacon-panhuman"
        )
        let ribokmers = try await ToolAvailability.requireDatabase(
            { await registry.effectiveDatabasePath(for: "deacon-ribokmers") }, name: "deacon-ribokmers"
        )
        let (envelope, _) = try recordTruthImport([
            "--platform", "illumina",
            "--recipe", "wastewater-metagenomics",
            "--no-optimize-storage",
            "--compression", "fast",
        ])

        let scrub = try recordTruthDatabaseEvidence(in: envelope, fileName: panhuman.lastPathComponent)
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

        let ribo = try recordTruthDatabaseEvidence(in: envelope, fileName: ribokmers.lastPathComponent)
        let size = try XCTUnwrap(
            try FileManager.default.attributesOfItem(atPath: ribokmers.path)[.size] as? NSNumber
        )
        let riboPin = try XCTUnwrap(ManagedToolLock.bundled.databases.first { $0.id == "deacon-ribokmers" })
        let riboPinnedSHA256 = try XCTUnwrap(riboPin.sha256, "the lock must pin the ribokmers index's SHA-256").lowercased()
        let riboDigest: String? = ribo.entry["sha256"].flatMap {
            if case .string(let digest) = $0 { return digest } else { return nil }
        }
        XCTAssertNotNil(riboDigest, "the record names the ribokmers index's SHA-256")
        XCTAssertEqual(ribo.entry["id"], .string("deacon-ribokmers"))
        XCTAssertEqual(
            ribo.entry["lockPinned"], .boolean(riboDigest == riboPinnedSHA256),
            "lockPinned is true when the recorded digest is the lock's pin, as for a fresh install, "
                + "and false for an index that an earlier install built on its own host"
        )
        XCTAssertEqual(ribo.entry["sizeBytes"], .integer(size.intValue))
        XCTAssertEqual(ribo.entry["indexFormat"], .integer(3))
        XCTAssertEqual(ribo.entry["kmerLength"], .integer(31))
        XCTAssertEqual(ribo.entry["windowSize"], .integer(15))
        XCTAssertNotNil(ribo.entry["buildToolVersion"], "the record names the Deacon that built the index")
        XCTAssertNotNil(ribo.entry["buildSourceSHA256"], "the record names the source the index was built from")
        XCTAssertEqual(ribo.input?.checksumSHA256, riboDigest)
    }

    // MARK: - M3, host choices

    /// The `-Xmx` value of the record step whose argv sets the Java heap, in GB.
    private func recordTruthHeapInArgv(of envelope: ProvenanceEnvelope) -> Int? {
        envelope.steps.lazy.flatMap(\.argv).first { $0.hasPrefix("-Xmx") && $0.hasSuffix("g") }
            .flatMap { Int($0.dropFirst(4).dropLast()) }
    }

    /// Run with neither `--threads` nor `--clumpify-heap-gb`, the record says the threads, the clumpify heap and the
    /// automatic clumping choice came from the host, and names the heap clumpify's argv ran with.
    func testRecordNamesTheHostAsTheSourceOfEachChoiceItMade() async throws {
        try await recordTruthRequire(.clumpify)
        let (envelope, _) = try recordTruthImport(["--platform", "illumina", "--compression", "fast"])
        let resolved = envelope.options.resolvedDefaults
        let ranHeap = try XCTUnwrap(recordTruthHeapInArgv(of: envelope), "clumpify ran and its argv sets the heap")

        XCTAssertEqual(resolved["threadsSource"], .string("host"))
        XCTAssertEqual(resolved["clumpifyHeapGB"], .integer(ranHeap), "the record names the heap that ran")
        XCTAssertEqual(resolved["clumpingHeapBytes"], .integer(ranHeap * 1_073_741_824))
        XCTAssertEqual(resolved["clumpifyHeapSource"], .string("host"))
        XCTAssertEqual(resolved["resolvedClumpingTool"], .string("bbtools"))
        // C5 D5: the tool's source is the rule's (`default` for auto), the heap keeps the host as its source.
        XCTAssertEqual(resolved["resolvedClumpingToolSource"], .string("default"))
        XCTAssertEqual(resolved["clumpingEstimatedInputBytes"], .null)
        XCTAssertEqual(resolved["clumpingThresholdBytes"], .null)
    }

    /// `--threads`, `--clumping-tool` and `--clumpify-heap-gb` pin each choice. The record names each as the
    /// option's, clumpify runs with the pinned heap, and the replay command pins it again.
    func testOptionsPinEachHostChoiceAndTheRecordSaysSo() async throws {
        try await recordTruthRequire(.clumpify)
        let (envelope, _) = try recordTruthImport([
            "--platform", "illumina", "--compression", "fast",
            "--threads", "2", "--clumping-tool", "bbtools", "--clumpify-heap-gb", "2",
        ])
        let resolved = envelope.options.resolvedDefaults

        XCTAssertEqual(recordTruthHeapInArgv(of: envelope), 2, "clumpify must run with the pinned heap")
        XCTAssertEqual(resolved["threadsSource"], .string("option"))
        XCTAssertEqual(resolved["threads"], .integer(2))
        XCTAssertEqual(resolved["clumpifyHeapGB"], .integer(2))
        XCTAssertEqual(resolved["clumpingHeapBytes"], .integer(2 * 1_073_741_824))
        XCTAssertEqual(resolved["clumpifyHeapSource"], .string("option"))
        XCTAssertEqual(resolved["resolvedClumpingToolSource"], .string("option"))
        XCTAssertEqual(envelope.options.explicit["clumpifyHeapGB"], .integer(2))
        XCTAssertNotNil(envelope.reproducibleCommand.range(of: "--clumpify-heap-gb 2"),
                      "the replay command must pin the heap: \(envelope.reproducibleCommand)")
    }

    // MARK: - Refusals the user sees

    /// A heap no host holds is refused with the input error exit code, and the message names this host's limit.
    func testAClumpifyHeapBeyondTheHostIsRefusedAndTheMessageNamesTheLimit() throws {
        let (root, input, project) = try recordTruthProject()
        let hostGB = ProcessInfo.processInfo.physicalMemory / 1_073_741_824

        let run = try recordTruthRun(
            ["import", "fastq", input.path, "--project", project.path, "--clumpify-heap-gb", "100000", "--dry-run"],
            scratch: root, timeout: 120
        )

        XCTAssertFalse(run.timedOut, run.output)
        XCTAssertEqual(run.status, 3, "the refusal must end with the input error exit code: \(run.output)")
        XCTAssertNotNil(run.output.range(of: "--clumpify-heap-gb must be between 1 and \(hostGB)"),
                      "the message must name the limit: \(run.output)")
    }

    /// An installed panhuman index that is not the file the bundled lock pins refuses the import: a non-zero exit,
    /// a message that says the index does not match the lock, and no bundle in the project's `Imports` folder.
    func testAPanhumanIndexThatIsNotTheLockedFileRefusesTheImport() async throws {
        try await recordTruthRequire(.fastp, .seqkit, .deacon)
        let (root, input, project) = try recordTruthProject()
        let storage = root.appendingPathComponent("storage")
        let installDirectory = storage.appendingPathComponent("databases/deacon-panhuman")
        try FileManager.default.createDirectory(at: installDirectory, withIntermediateDirectories: true)
        // Format 3, k 31, w 15 and no minimizers: it looks like an index, and it is not the pinned file.
        try Data([3, 31, 15, 0, 0, 0, 0, 0, 0, 0, 0])
            .write(to: installDirectory.appendingPathComponent("panhuman-1.k31w15.idx"))

        let run = try recordTruthRun(
            ["import", "fastq", input.path, "--project", project.path, "--recipe", "vsp2",
             "--platform", "illumina", "--no-optimize-storage", "--compression", "fast"],
            environment: [
                "LUNGFISH_STORAGE_ROOT": storage.path,
                "LUNGFISH_CONDA_ROOT": CondaManager.shared.rootPrefix.path,
            ],
            scratch: root, timeout: 180
        )

        XCTAssertFalse(run.timedOut, "the import must stop at the refusal: \(run.output)")
        XCTAssertNotEqual(run.status, 0, "an index that is not the pinned file must fail the import: \(run.output)")
        XCTAssertNotNil(run.output.range(of: "does not match the bundled lock"), "the refusal must say why: \(run.output)")
        XCTAssertEqual(try recordTruthBundles(in: project).count, 0, "a refused import must write no bundle")
    }
}
