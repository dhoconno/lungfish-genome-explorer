import XCTest
import LungfishCore
import LungfishIO
@testable import LungfishWorkflow

@MainActor
final class NativeBundleBuilderProvenanceTests: XCTestCase {
    func testGenBankRecordStoreIsEmbeddedDeclaredAndRecordedAtFinalPath() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("NativeBundleBuilderProvenanceTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let fastaURL = root.appendingPathComponent("source.fa")
        try ">chr1\nACGT\n>chr2\nTGCA\n".write(to: fastaURL, atomically: true, encoding: .utf8)
        let stagedStoreURL = root.appendingPathComponent("temporary/genbank_records.sqlite")
        try GenBankRecordDatabase.create(
            records: [
                GenBankRecord(
                    sequence: try Sequence(name: "chr1", alphabet: .dna, bases: "ACGT"),
                    annotations: [],
                    locus: LocusInfo(name: "chr1", length: 4, moleculeType: .dna, topology: .linear)
                ),
                GenBankRecord(
                    sequence: try Sequence(name: "chr2", alphabet: .dna, bases: "TGCA"),
                    annotations: [],
                    locus: LocusInfo(name: "chr2", length: 4, moleculeType: .dna, topology: .linear)
                ),
            ],
            at: stagedStoreURL
        )
        let home = root.appendingPathComponent("home", isDirectory: true)
        try writeFakeManagedTool(home: home, environment: "samtools", executable: "samtools", script: """
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo "samtools 1.23"; exit 0; fi
        if [ "$1" = "faidx" ]; then printf "chr1\\t4\\t6\\t4\\t5\\nchr2\\t4\\t17\\t4\\t5\\n" > "$2.fai"; exit 0; fi
        exit 2
        """)

        let bundleURL = try await NativeBundleBuilder(
            toolRunner: NativeToolRunner(toolsDirectory: nil, homeDirectory: home)
        ).build(configuration: BuildConfiguration(
            name: "Record Store",
            identifier: "org.lungfish.test.record-store",
            fastaURL: fastaURL,
            outputDirectory: root,
            source: SourceInfo(organism: "Test", assembly: "Test"),
            compressFASTA: false,
            referenceRecordStoreURL: stagedStoreURL
        ))

        let manifest = try BundleManifest.load(from: bundleURL)
        XCTAssertEqual(manifest.recordStore, ReferenceRecordStoreInfo(
            schemaVersion: 1,
            format: "genbank",
            databasePath: "metadata/genbank_records.sqlite",
            recordCount: 2
        ))
        let finalStoreURL = bundleURL.appendingPathComponent("metadata/genbank_records.sqlite")
        XCTAssertEqual(try GenBankRecordDatabase(url: finalStoreURL).recordCount(), 2)

        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: bundleURL))
        let output = try XCTUnwrap(envelope.steps.flatMap(\.outputs).first { $0.path == finalStoreURL.path })
        XCTAssertEqual(output.checksumSHA256, try ProvenanceFileHasher.sha256(of: finalStoreURL))
        XCTAssertEqual(output.fileSize, try ProvenanceFileHasher.fileSize(of: finalStoreURL))
        XCTAssertTrue(envelope.files.contains { $0.path == stagedStoreURL.path && $0.role == .input })
        XCTAssertTrue(envelope.steps.flatMap(\.inputs).contains { $0.path == stagedStoreURL.path })
        XCTAssertFalse(envelope.steps.flatMap(\.outputs).contains { $0.path.contains("temporary/genbank_records.sqlite") })
        XCTAssertTrue(envelope.argv.contains(stagedStoreURL.path))
        XCTAssertTrue(envelope.reproducibleCommand.contains(stagedStoreURL.path))
        XCTAssertEqual(envelope.options.explicit["reference_record_store"], .file(stagedStoreURL))
        XCTAssertEqual(envelope.options.defaults["reference_record_store"], .string("none"))
        XCTAssertEqual(envelope.options.resolvedDefaults["reference_record_store"], .file(stagedStoreURL))
    }

    func testRecordStoreProvenanceUsesDurableSourceOverrideWithoutStagingLeak() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("NativeBundleBuilderProvenanceTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let fastaURL = root.appendingPathComponent("staging/input.fa")
        try fm.createDirectory(at: fastaURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ">record1\nACGT\n".write(to: fastaURL, atomically: true, encoding: .utf8)
        let stagedStoreURL = root.appendingPathComponent("staging/genbank_records.sqlite")
        try GenBankRecordDatabase.create(records: [
            GenBankRecord(
                sequence: try Sequence(name: "record1", alphabet: .dna, bases: "ACGT"),
                annotations: [],
                locus: LocusInfo(name: "record1", length: 4, moleculeType: .dna, topology: .linear)
            ),
        ], at: stagedStoreURL)
        let durableSourceURL = root.appendingPathComponent("original.gb")
        try "durable source".write(to: durableSourceURL, atomically: true, encoding: .utf8)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try writeFakeManagedTool(home: home, environment: "samtools", executable: "samtools", script: """
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo "samtools 1.23"; exit 0; fi
        if [ "$1" = "faidx" ]; then printf "record1\\t4\\t9\\t4\\t5\\n" > "$2.fai"; exit 0; fi
        exit 2
        """)

        let builder = NativeBundleBuilder(
            toolRunner: NativeToolRunner(toolsDirectory: nil, homeDirectory: home)
        )
        do {
            _ = try await builder.build(configuration: BuildConfiguration(
                name: "Missing Replay",
                identifier: "org.lungfish.test.missing-replay",
                fastaURL: fastaURL,
                outputDirectory: root,
                source: SourceInfo(organism: "Test", assembly: "Test"),
                compressFASTA: false,
                provenanceInputFiles: [durableSourceURL],
                referenceRecordStoreURL: stagedStoreURL
            ))
            XCTFail("Expected explicit replay command requirement")
        } catch let error as BundleBuildError {
            guard case .unsupportedProvenanceConfiguration = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let highLevelReplay = [
            "lungfish-cli", "import", "fasta", durableSourceURL.path,
            "--output-dir", root.path,
        ]
        let bundleURL = try await builder.build(configuration: BuildConfiguration(
            name: "Durable Store",
            identifier: "org.lungfish.test.durable-store",
            fastaURL: fastaURL,
            outputDirectory: root,
            source: SourceInfo(organism: "Test", assembly: "Test"),
            compressFASTA: false,
            provenanceWorkflowName: "lungfish import fasta",
            provenanceCommand: highLevelReplay,
            provenanceInputFiles: [durableSourceURL],
            referenceRecordStoreURL: stagedStoreURL
        ))

        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: bundleURL))
        XCTAssertTrue(envelope.files.contains { $0.path == durableSourceURL.path && $0.role == .input })
        XCTAssertFalse(envelope.files.contains { $0.path.contains("/staging/") })
        XCTAssertFalse(envelope.steps.flatMap(\.inputs).contains { $0.path.contains("/staging/") })
        XCTAssertEqual(envelope.argv, highLevelReplay)
        XCTAssertEqual(envelope.durableReplayArgv, highLevelReplay)
        XCTAssertEqual(envelope.workflowName, "lungfish import fasta")
        XCTAssertEqual(envelope.options.explicit["reference_source"], .file(durableSourceURL))
        XCTAssertEqual(envelope.options.resolvedDefaults["reference_source"], .file(durableSourceURL))
        XCTAssertNil(envelope.options.explicit["reference_record_store"])
        XCTAssertNil(envelope.options.resolvedDefaults["reference_record_store"])
        XCTAssertTrue(envelope.steps.first?.inputs.contains {
            $0.path == durableSourceURL.path && $0.role == .input
        } == true)
    }

    func testRecordStoreIdentityMismatchRejectsBuildBeforePublication() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("NativeBundleBuilderProvenanceTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let fastaURL = root.appendingPathComponent("source.fa")
        try ">record1\nACGT\n".write(to: fastaURL, atomically: true, encoding: .utf8)
        let storeURL = root.appendingPathComponent("records.sqlite")
        try GenBankRecordDatabase.create(records: [
            GenBankRecord(
                sequence: try Sequence(name: "different", alphabet: .dna, bases: "ACGT"),
                annotations: [],
                locus: LocusInfo(name: "different", length: 4, moleculeType: .dna, topology: .linear)
            ),
        ], at: storeURL)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try writeFakeManagedTool(home: home, environment: "samtools", executable: "samtools", script: """
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo "samtools 1.23"; exit 0; fi
        if [ "$1" = "faidx" ]; then printf "record1\\t4\\t9\\t4\\t5\\n" > "$2.fai"; exit 0; fi
        exit 2
        """)
        let publishedURL = root.appendingPathComponent("Mismatch.lungfishref")

        do {
            _ = try await NativeBundleBuilder(
                toolRunner: NativeToolRunner(toolsDirectory: nil, homeDirectory: home)
            ).build(configuration: BuildConfiguration(
                name: "Mismatch",
                identifier: "org.lungfish.test.mismatch",
                fastaURL: fastaURL,
                outputDirectory: root,
                source: SourceInfo(organism: "Test", assembly: "Test"),
                compressFASTA: false,
                referenceRecordStoreURL: storeURL
            ))
            XCTFail("Expected identity mismatch")
        } catch let error as BundleBuildError {
            guard case .validationFailed(let errors) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(errors.contains { $0.contains("sequence name") })
        }
        XCTAssertFalse(fm.fileExists(atPath: publishedURL.path))
    }

    func testCompressedReferenceBundleRecordsBgzipAndFaidxSteps() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("NativeBundleBuilderProvenanceTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let fastaURL = root.appendingPathComponent("source.fa")
        try """
        >chr1
        ACGTACGTACGT
        """.write(to: fastaURL, atomically: true, encoding: .utf8)

        let home = root.appendingPathComponent("home", isDirectory: true)
        try writeFakeManagedTool(home: home, environment: "htslib", executable: "bgzip", script: """
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo "bgzip 1.23" >&2; exit 0; fi
        for arg in "$@"; do input="$arg"; done
        cp "$input" "$input.gz"
        rm -f "$input"
        exit 0
        """)
        try writeFakeManagedTool(home: home, environment: "samtools", executable: "samtools", script: """
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo "samtools 1.23"; exit 0; fi
        if [ "$1" = "faidx" ]; then
          printf "chr1\\t12\\t6\\t12\\t13\\n" > "$2.fai"
          case "$2" in
            *.gz) printf "0\\t0\\n" > "$2.gzi" ;;
          esac
          exit 0
        fi
        exit 2
        """)

        let builder = NativeBundleBuilder(
            toolRunner: NativeToolRunner(toolsDirectory: nil, homeDirectory: home)
        )
        let bundleURL = try await builder.build(
            configuration: BuildConfiguration(
                name: "Test Bundle",
                identifier: "org.lungfish.test.native-provenance",
                fastaURL: fastaURL,
                outputDirectory: root,
                source: SourceInfo(organism: "Test organism", assembly: "Test assembly"),
                compressFASTA: true
            )
        )

        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(from: bundleURL))
        let compressedFASTA = bundleURL.appendingPathComponent("genome/sequence.fa.gz").path
        let fastaIndex = bundleURL.appendingPathComponent("genome/sequence.fa.gz.fai").path
        let gzipIndex = bundleURL.appendingPathComponent("genome/sequence.fa.gz.gzi").path

        let bgzipStep = try XCTUnwrap(envelope.steps.first { $0.toolName == "bgzip" })
        XCTAssertTrue(bgzipStep.argv.first?.hasSuffix("/envs/htslib/bin/bgzip") == true)
        XCTAssertEqual(bgzipStep.outputs.map(\.path), [compressedFASTA])
        XCTAssertNotNil(bgzipStep.outputs.first?.checksumSHA256)
        XCTAssertNotNil(bgzipStep.outputs.first?.fileSize)

        let faidxStep = try XCTUnwrap(envelope.steps.first { $0.toolName == "samtools" && $0.argv.contains("faidx") })
        XCTAssertTrue(faidxStep.argv.first?.hasSuffix("/envs/samtools/bin/samtools") == true)
        XCTAssertTrue(faidxStep.inputs.contains { $0.path == compressedFASTA })
        XCTAssertTrue(faidxStep.outputs.contains { $0.path == fastaIndex && $0.checksumSHA256 != nil })
        XCTAssertTrue(faidxStep.outputs.contains { $0.path == gzipIndex && $0.checksumSHA256 != nil })
    }

    private func writeFakeManagedTool(
        home: URL,
        environment: String,
        executable: String,
        script: String
    ) throws {
        let binDir = home
            .appendingPathComponent(".lungfish/conda/envs", isDirectory: true)
            .appendingPathComponent(environment, isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        let toolURL = binDir.appendingPathComponent(executable)
        try script.write(to: toolURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: toolURL.path)
    }
}
