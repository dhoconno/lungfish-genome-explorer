import XCTest
@testable import LungfishCLI
import LungfishIO
import LungfishWorkflow

final class FastqGenotypingCommandTests: XCTestCase {
    func testFastqCommandRegistersPlatformNeutralGenotype() {
        let names = FastqCommand.configuration.subcommands.map { $0.configuration.commandName }
        XCTAssertTrue(names.contains("genotype"))
        XCTAssertTrue(names.contains("genotype-cohort"))
        XCTAssertTrue(names.contains("update-current-workbook"))
        XCTAssertTrue(names.contains("ont-fluidigm-samples"))
        XCTAssertTrue(names.contains("ont-pacbio-barcode-demux"))
        XCTAssertTrue(names.contains("mhc-reference-bundle"))
    }

    func testUpdateCurrentWorkbookParsesBundleCallsAndAnnotations() throws {
        let command = try FastqUpdateCurrentWorkbookSubcommand.parse([
            "/tmp/barcode11-mhc.lungfishgenotype",
            "--calls-json", "/tmp/barcode11-mhc/artifacts/workbooks/updates/calls.json",
            "--annotations", "/tmp/barcode11-mhc.lungfishgenotype/annotations.json",
            "--haplotype-projection-mode", "manual-genotype-only",
            "--annotation-only",
        ])

        XCTAssertEqual(command.bundle, "/tmp/barcode11-mhc.lungfishgenotype")
        XCTAssertEqual(command.callsJSON, "/tmp/barcode11-mhc/artifacts/workbooks/updates/calls.json")
        XCTAssertEqual(command.annotations, "/tmp/barcode11-mhc.lungfishgenotype/annotations.json")
        XCTAssertTrue(command.annotationOnly)
        XCTAssertEqual(
            command.haplotypeProjectionMode,
            .manualGenotypeOnly
        )
        XCTAssertNil(command.inputFingerprint)
        XCTAssertNil(command.inputFingerprintSchema)
        XCTAssertNil(command.syncIntent)
        let arguments = command.cliArguments(
            bundleURL: URL(fileURLWithPath: command.bundle, isDirectory: true),
            callsURL: URL(fileURLWithPath: command.callsJSON),
            annotationURL: command.annotations.map { URL(fileURLWithPath: $0) }
        )
        XCTAssertFalse(arguments.contains("--input-fingerprint"))
        XCTAssertFalse(arguments.contains("--input-fingerprint-schema"))
        XCTAssertFalse(arguments.contains("--sync-intent"))
        XCTAssertTrue(
            zip(arguments, arguments.dropFirst()).contains {
                $0.0 == "--haplotype-projection-mode"
                    && $0.1 == "manual-genotype-only"
            }
        )
    }

    func testUpdateCurrentWorkbookParsesAndValidatesAttestationFlags() throws {
        let digest = String(repeating: "a", count: 64)
        let command = try FastqUpdateCurrentWorkbookSubcommand.parse([
            "/tmp/barcode11-mhc.lungfishgenotype",
            "--calls-json", "/tmp/calls.json",
            "--input-fingerprint", digest,
            "--input-fingerprint-schema",
            String(GenotypeCurrentWorkbookInputFingerprint.schemaVersion),
            "--reviewable-row-catalog-path",
            "artifacts/review/reviewable-row-catalog.json",
            "--reviewable-row-catalog-size", "123",
            "--reviewable-row-catalog-sha256",
            String(repeating: "b", count: 64),
            "--reviewable-row-catalog-schema", "1",
            "--sync-intent", "update-and-view",
        ])

        let attestation = try command.validatedAttestation()

        XCTAssertEqual(attestation.inputFingerprint?.sha256, digest)
        XCTAssertEqual(
            attestation.inputFingerprint?.schemaVersion,
            GenotypeCurrentWorkbookInputFingerprint.schemaVersion
        )
        XCTAssertEqual(
            attestation.inputFingerprint?.reviewableRowCatalogPath,
            "artifacts/review/reviewable-row-catalog.json"
        )
        XCTAssertEqual(
            attestation.inputFingerprint?.reviewableRowCatalogSize,
            123
        )
        XCTAssertEqual(attestation.syncIntent, .updateAndView)
    }

    func testUpdateCurrentWorkbookRejectsIncompleteFingerprintPair() throws {
        XCTAssertThrowsError(
            try FastqUpdateCurrentWorkbookSubcommand.parse([
                "/tmp/barcode11-mhc.lungfishgenotype",
                "--calls-json", "/tmp/calls.json",
                "--input-fingerprint", String(repeating: "a", count: 64),
            ])
        )
        XCTAssertThrowsError(
            try FastqUpdateCurrentWorkbookSubcommand.parse([
                "/tmp/barcode11-mhc.lungfishgenotype",
                "--calls-json", "/tmp/calls.json",
                "--input-fingerprint-schema",
                String(GenotypeCurrentWorkbookInputFingerprint.schemaVersion),
            ])
        )
    }

    func testUpdateCurrentWorkbookRejectsMalformedDigestUnsupportedSchemaAndUnknownIntent() throws {
        XCTAssertThrowsError(
            try FastqUpdateCurrentWorkbookSubcommand.parse([
                "/tmp/barcode11-mhc.lungfishgenotype",
                "--calls-json", "/tmp/calls.json",
                "--input-fingerprint", String(repeating: "A", count: 64),
                "--input-fingerprint-schema", "1",
            ])
        )
        XCTAssertThrowsError(
            try FastqUpdateCurrentWorkbookSubcommand.parse([
                "/tmp/barcode11-mhc.lungfishgenotype",
                "--calls-json", "/tmp/calls.json",
                "--input-fingerprint", String(repeating: "a", count: 64),
                "--input-fingerprint-schema",
                String(GenotypeCurrentWorkbookInputFingerprint.schemaVersion + 1),
            ])
        )
        XCTAssertThrowsError(
            try FastqUpdateCurrentWorkbookSubcommand.parse([
                "/tmp/barcode11-mhc.lungfishgenotype",
                "--calls-json", "/tmp/calls.json",
                "--sync-intent", "background-ish",
            ])
        )
        XCTAssertThrowsError(
            try FastqUpdateCurrentWorkbookSubcommand.parse([
                "/tmp/barcode11-mhc.lungfishgenotype",
                "--calls-json", "/tmp/calls.json",
                "--haplotype-projection-mode", "guessed-from-seven-loci",
            ])
        )
    }

    func testUpdateCurrentWorkbookAttestationFlagsHaveHelpText() {
        let help = FastqUpdateCurrentWorkbookSubcommand.helpMessage()

        XCTAssertTrue(help.contains("--input-fingerprint"))
        XCTAssertTrue(help.contains("--input-fingerprint-schema"))
        XCTAssertTrue(help.contains("--reviewable-row-catalog-path"))
        XCTAssertTrue(help.contains("--reviewable-row-catalog-size"))
        XCTAssertTrue(help.contains("--reviewable-row-catalog-sha256"))
        XCTAssertTrue(help.contains("--reviewable-row-catalog-schema"))
        XCTAssertTrue(help.contains("--sync-intent"))
        XCTAssertTrue(help.contains("--haplotype-projection-mode"))
    }

    func testAnnotationOnlyUsesDisplayedCallsOnlyForSemanticFingerprint() throws {
        let command = try FastqUpdateCurrentWorkbookSubcommand.parse([
            "/tmp/barcode11-mhc.lungfishgenotype",
            "--calls-json", "/tmp/calls.json",
            "--included-locus", "MHC-A",
            "--annotation-only",
        ])
        let displayedCalls = [
            GenotypeWorkbookHaplotypeCall(
                sample: "sample-a",
                locus: "MHC-A",
                haplotype1: "A-H1",
                haplotype2: "A-H2",
                status: "called",
                notes: ""
            ),
        ]

        let inputs = command.workbookCallInputs(displayedCalls: displayedCalls)

        XCTAssertTrue(inputs.mutationCalls.isEmpty)
        XCTAssertEqual(inputs.mutationIncludedLoci, [])
        XCTAssertEqual(inputs.fingerprintInputs?.calls, displayedCalls)
        XCTAssertEqual(inputs.fingerprintInputs?.includedLoci, ["MHC-A"])
    }

    func testUpdateCurrentWorkbookProvenanceDescribesExactImmutableCLIInputPaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "FastqUpdateCurrentWorkbookProvenance-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let callsURL = root.appendingPathComponent("displayed-haplotype-calls.json")
        let annotationURL = root.appendingPathComponent("annotations.json")
        let callsData = Data(#"[{"sample":"s1"}]"#.utf8)
        let annotationData = Data(#"{"generatedAt":"2026-07-24T00:00:00Z"}"#.utf8)
        try callsData.write(to: callsURL)
        try annotationData.write(to: annotationURL)
        let bundleURL = root.appendingPathComponent("result.lungfishgenotype", isDirectory: true)
        let command = try FastqUpdateCurrentWorkbookSubcommand.parse([
            bundleURL.path,
            "--calls-json", callsURL.path,
            "--annotations", annotationURL.path,
        ])
        let argv = [
            "lungfish-cli", "fastq", "update-current-workbook",
            bundleURL.path,
            "--calls-json", callsURL.path,
            "--annotations", annotationURL.path,
        ]

        let context = try command.provenanceContext(
            argv: argv,
            callsURL: callsURL,
            annotationURL: annotationURL,
            attestation: command.validatedAttestation()
        )

        XCTAssertEqual(context.argv, argv)
        XCTAssertEqual(
            context.toolName,
            "lungfish-cli fastq update-current-workbook"
        )
        XCTAssertEqual(context.toolKind, "cli")
        XCTAssertEqual(context.durableReplayArgv, argv)
        XCTAssertEqual(context.cliInputDescriptors.map(\.path), [
            callsURL.standardizedFileURL.path,
            annotationURL.standardizedFileURL.path,
        ])
        for descriptor in context.cliInputDescriptors {
            let expectedData = descriptor.path == callsURL.path ? callsData : annotationData
            XCTAssertEqual(descriptor.role, .input)
            XCTAssertEqual(descriptor.format, .json)
            XCTAssertEqual(descriptor.fileSize, UInt64(expectedData.count))
            XCTAssertEqual(
                descriptor.checksumSHA256,
                try ProvenanceFileHasher.sha256(of: URL(fileURLWithPath: descriptor.path))
            )
        }
    }

    func testUpdateCurrentWorkbookResolvedCommandWritesCanonicalFalseNegativeProvenance() throws {
        guard let pythonURL = openpyxlPythonURL() else {
            throw XCTSkip("The managed test runtime must provide openpyxl")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "FastqUpdateCurrentWorkbookCommand-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let bundleURL = try makeUpdateCurrentWorkbookFixture(
            in: root,
            pythonURL: pythonURL
        )
        let callsURL = root.appendingPathComponent("displayed-calls.json")
        try Data("[]".utf8).write(to: callsURL)
        let annotationURL = bundleURL.appendingPathComponent(
            GenotypeAnnotationSidecar.filename
        )
        var sidecar = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-27T00:00:00Z"
        )
        sidecar.matrixReviews = [
            .init(
                target: .cell(
                    locus: "MHC-A",
                    genotype: "Mamu-A1*001:01",
                    sample: "AR3628"
                ),
                disposition: .falseNegative,
                author: "reviewer",
                timestamp: "2026-07-27T01:00:00Z"
            ),
        ]
        try sidecar.encoded().write(to: annotationURL)
        let command = try FastqUpdateCurrentWorkbookSubcommand.parse([
            bundleURL.path,
            "--calls-json", callsURL.path,
            "--annotations", annotationURL.path,
            "--annotation-only",
        ])

        try command.runResolved(
            pythonExecutableURL: pythonURL,
            workbookAttestationRootURL: root.appendingPathComponent(
                "workbook-attestations",
                isDirectory: true
            )
        )

        let manifest = try ONTGenotypeResultBundle.loadManifest(from: bundleURL)
        let provenancePath = try XCTUnwrap(
            manifest.workbookRevisions?.last?.provenancePath
        )
        let envelope = try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self,
            from: Data(contentsOf: ONTGenotypeResultBundle.resolvedURL(
                for: provenancePath,
                in: bundleURL
            ))
        )
        XCTAssertEqual(
            envelope.toolName,
            "lungfish-cli fastq update-current-workbook"
        )
        XCTAssertTrue(envelope.argv.contains("--annotation-only"))
        let pythonStep = try XCTUnwrap(
            envelope.steps.first {
                $0.toolName == "python openpyxl workbook candidate update"
            }
        )
        let decisions = try XCTUnwrap(
            pythonStep.resolvedOptions["falseNegativeTargetCellDecisions"]?
                .arrayValue
        )
        XCTAssertEqual(decisions.count, 1)
        XCTAssertEqual(
            decisions.first?.dictionaryValue?["presentationPrecedence"],
            .string("false-negative-over-viewport-style")
        )
        XCTAssertEqual(
            decisions.first?.dictionaryValue?["target"]?
                .dictionaryValue?["sample"],
            .string("AR3628")
        )
    }

    func testImmutableCLIInputReadRejectsSameSizeMutationDuringInitialRead() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "FastqUpdateCurrentWorkbookInitialRead-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let callsURL = root.appendingPathComponent("displayed-haplotype-calls.json")
        let admittedData = Data(("\"" + String(repeating: "a", count: 150_000) + "\"").utf8)
        let changedData = Data(("\"" + String(repeating: "b", count: 150_000) + "\"").utf8)
        XCTAssertEqual(admittedData.count, changedData.count)
        try admittedData.write(to: callsURL)
        let bundleURL = root.appendingPathComponent("result.lungfishgenotype", isDirectory: true)
        let command = try FastqUpdateCurrentWorkbookSubcommand.parse([
            bundleURL.path,
            "--calls-json", callsURL.path,
        ])
        let mutation = FastqImmutableInputMutationBox()

        XCTAssertThrowsError(
            try command.provenanceContext(
                argv: [
                    "lungfish-cli", "fastq", "update-current-workbook",
                    bundleURL.path, "--calls-json", callsURL.path,
                ],
                callsURL: callsURL,
                annotationURL: nil,
                attestation: command.validatedAttestation(),
                immutableInputReadObserver: { url, chunkIndex in
                    guard url.standardizedFileURL == callsURL.standardizedFileURL,
                          chunkIndex == 1,
                          mutation.claim() else {
                        return
                    }
                    let handle = try FileHandle(forWritingTo: callsURL)
                    defer { try? handle.close() }
                    try handle.seek(toOffset: 0)
                    try handle.write(contentsOf: changedData)
                    try handle.synchronize()
                }
            )
        ) { error in
            XCTAssertTrue(
                String(describing: error).contains("changed while it was being read"),
                "Unexpected error: \(error)"
            )
        }
        XCTAssertTrue(mutation.wasClaimed)
        XCTAssertEqual(try Data(contentsOf: callsURL), changedData)
    }

    func testONTFluidigmSamplesCommandParsesRequiredInputs() throws {
        let command = try FastqONTFluidigmSamplesSubcommand.parse([
            "/tmp/barcode11.lungfishfastq",
            "--barcodes", "/tmp/ONT09_NB11_samples.csv",
            "--output", "/tmp/ont-fluidigm-samples",
            "--threads", "8",
            "--primer-mismatches", "2",
            "--minimum-insert-length", "40",
            "--no-canonicalize-reverse-complements",
            "--force",
        ])

        XCTAssertEqual(command.input, "/tmp/barcode11.lungfishfastq")
        XCTAssertEqual(command.barcodes, "/tmp/ONT09_NB11_samples.csv")
        XCTAssertEqual(command.output, "/tmp/ont-fluidigm-samples")
        XCTAssertEqual(command.threads, 8)
        XCTAssertEqual(command.primerMismatches, 2)
        XCTAssertEqual(command.minimumInsertLength, 40)
        XCTAssertFalse(command.canonicalizeReverseComplements)
        XCTAssertTrue(command.force)
    }

    func testONTPacBioBarcodeDemuxCommandParsesRequiredInputs() throws {
        let command = try FastqONTPacBioBarcodeDemuxSubcommand.parse([
            "/tmp/fastq_pass/barcode13",
            "--barcodes", "/tmp/NB13_MHC-I_plate1.barcodes.csv",
            "--output", "/tmp/mhc-pacbio-demux",
            "--threads", "4",
            "--chunk-jobs", "6",
            "--max-reads-per-slice", "100000",
            "--max-bytes-per-cutadapt", "536870912",
            "--force",
        ])

        XCTAssertEqual(command.input, "/tmp/fastq_pass/barcode13")
        XCTAssertEqual(command.barcodes, "/tmp/NB13_MHC-I_plate1.barcodes.csv")
        XCTAssertEqual(command.output, "/tmp/mhc-pacbio-demux")
        XCTAssertEqual(command.threads, 4)
        XCTAssertEqual(command.chunkJobs, 6)
        XCTAssertEqual(command.maxReadsPerSlice, 100_000)
        XCTAssertEqual(command.maxBytesPerCutadapt, 536_870_912)
        XCTAssertTrue(command.force)
    }

    func testONTPacBioBarcodeDemuxCommandDefaultsToOneChunkJobPerActiveProcessor() throws {
        let command = try FastqONTPacBioBarcodeDemuxSubcommand.parse([
            "/tmp/fastq_pass/barcode13",
            "--barcodes", "/tmp/NB13_MHC-I_plate1.barcodes.csv",
            "--output", "/tmp/mhc-pacbio-demux",
        ])

        XCTAssertEqual(command.threads, 1)
        XCTAssertEqual(command.chunkJobs, max(1, ProcessInfo.processInfo.activeProcessorCount))
    }

    func testONTPacBioBarcodeDemuxProvenanceOutputsDescribeDirectories() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ont-pacbio-cli-provenance-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let outputDirectory = root.appendingPathComponent("demux", isDirectory: true)
        let bundleURL = outputDirectory.appendingPathComponent("PN358.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let fastqURL = bundleURL.appendingPathComponent("PN358.fastq.gz")
        try Data("payload".utf8).write(to: fastqURL)
        let manifestURL = outputDirectory.appendingPathComponent("ont-pacbio-barcode-demux-manifest.json")
        try Data("{}".utf8).write(to: manifestURL)

        let records = FastqONTPacBioBarcodeDemuxSubcommand.provenanceOutputRecords(
            outputDirectory: outputDirectory,
            manifestURL: manifestURL,
            outputBundleURLs: [bundleURL],
            outputPayloads: [fastqURL]
        )

        let outputDirectoryRecord = try XCTUnwrap(records.first { $0.path == outputDirectory.path })
        let bundleRecord = try XCTUnwrap(records.first { $0.path == bundleURL.path })
        XCTAssertNotNil(outputDirectoryRecord.sha256)
        XCTAssertGreaterThan(outputDirectoryRecord.sizeBytes ?? 0, 0)
        XCTAssertNotNil(bundleRecord.sha256)
        XCTAssertGreaterThan(bundleRecord.sizeBytes ?? 0, 0)
    }

    func testGenotypeCohortParsesONTSampleBundlesWithoutBarcodes() throws {
        let command = try FastqGenotypingCohortSubcommand.parse([
            "/tmp/LF2871.lungfishfastq",
            "/tmp/LF2872.lungfishfastq",
            "--mode", "ont-sample-bundles",
            "--read-type", "ont",
            "--reference", "/tmp/mhc.lungfishref",
            "--output-dir", "/tmp/out",
            "--output-name", "ont-mhc",
            "--project", "/tmp/project.lungfish",
            "--threads", "8",
            "--sort-threads", "2",
            "--min-support", "3",
        ])

        XCTAssertEqual(command.inputs, ["/tmp/LF2871.lungfishfastq", "/tmp/LF2872.lungfishfastq"])
        XCTAssertEqual(command.mode, "ont-sample-bundles")
        XCTAssertEqual(command.readType, "ont")
        XCTAssertNil(command.barcodes)
        XCTAssertEqual(command.reference, "/tmp/mhc.lungfishref")
        XCTAssertEqual(command.outputName, "ont-mhc")
    }

    func testGenotypeCohortParsesIlluminaPairedInputsWithoutBarcodes() throws {
        let command = try FastqGenotypingCohortSubcommand.parse([
            "/tmp/DW001.lungfishfastq",
            "/tmp/DW002.lungfishfastq",
            "/tmp/DW003.lungfishfastq",
            "--mode", "illumina-paired",
            "--read-type", "illumina",
            "--reference", "/tmp/mhc.lungfishref",
            "--output-dir", "/tmp/out",
            "--output-name", "miseq-mhc",
            "--project", "/tmp/project.lungfish",
            "--haplotype-assay", "MHC-exon2-miSeq",
            "--haplotype-definition", "MHC-exon2-miSeq.rhesus-macaques",
            "--threads", "8",
            "--sort-threads", "2",
            "--min-support", "3",
        ])

        XCTAssertEqual(command.inputs, [
            "/tmp/DW001.lungfishfastq",
            "/tmp/DW002.lungfishfastq",
            "/tmp/DW003.lungfishfastq",
        ])
        XCTAssertEqual(command.mode, "illumina-paired")
        XCTAssertEqual(command.readType, "illumina")
        XCTAssertNil(command.barcodes)
        XCTAssertEqual(command.reference, "/tmp/mhc.lungfishref")
        XCTAssertEqual(command.outputName, "miseq-mhc")
        XCTAssertEqual(command.threads, 8)
        XCTAssertEqual(command.sortThreads, 2)
        XCTAssertEqual(command.minSupport, 3)
    }

    func testGenotypeParsesIlluminaPairedInputsWithoutBarcodes() throws {
        let command = try FastqGenotypingSubcommand.parse([
            "/tmp/DW001.lungfishfastq",
            "/tmp/DW002.lungfishfastq",
            "--mode", "illumina-paired",
            "--read-type", "illumina",
            "--reference", "/tmp/mhc.lungfishref",
            "--output-dir", "/tmp/out",
            "--output-name", "miseq-mhc",
            "--project", "/tmp/project.lungfish",
            "--haplotype-assay", "MHC-exon2-miSeq",
            "--haplotype-definition", "MHC-exon2-miSeq.rhesus-macaques",
            "--threads", "8",
            "--sort-threads", "2",
            "--min-support", "3",
        ])

        XCTAssertEqual(command.inputs, ["/tmp/DW001.lungfishfastq", "/tmp/DW002.lungfishfastq"])
        XCTAssertEqual(command.mode, "illumina-paired")
        XCTAssertEqual(command.readType, "illumina")
        XCTAssertNil(command.barcodes)
        XCTAssertEqual(command.reference, "/tmp/mhc.lungfishref")
        XCTAssertEqual(command.outputName, "miseq-mhc")
        XCTAssertEqual(command.threads, 8)
        XCTAssertEqual(command.sortThreads, 2)
        XCTAssertEqual(command.minSupport, 3)
    }

    func testGenotypeParsesLockedMCMMiSeqPresetWithoutReference() throws {
        let command = try FastqGenotypingSubcommand.parse([
            "/tmp/LF2823.lungfishfastq",
            "--preset", "mcm-mhc-miseq",
            "--barcodes", "/tmp/fluidigm.csv",
            "--output-dir", "/tmp/out",
            "--output-name", "mcm-miseq",
        ])

        XCTAssertEqual(command.preset, "mcm-mhc-miseq")
        XCTAssertNil(command.reference)
    }

    func testGenotypePresetRejectsUserReferenceOverride() throws {
        XCTAssertThrowsError(try FastqGenotypingSubcommand.parse([
            "/tmp/LF2823.lungfishfastq",
            "--preset", "mcm-mhc-miseq",
            "--reference", "/tmp/other.fa",
            "--barcodes", "/tmp/fluidigm.csv",
            "--output-dir", "/tmp/out",
        ]))
    }

    func testGenotypeParsesHaplotypeThresholdsAndDefinitionScope() throws {
        let command = try FastqGenotypingSubcommand.parse([
            "/tmp/barcode11.lungfishfastq",
            "--mode", "ont-barcode-demux",
            "--read-type", "ont",
            "--reference", "/tmp/mhc.lungfishmhcref",
            "--output-dir", "/tmp/out",
            "--output-name", "barcode11-mhc-test",
            "--project", "/tmp/project.lungfish",
            "--haplotype-assay", "MHC-exon2-miSeq",
            "--haplotype-species", "MCM",
            "--haplotype-definition-scope", "project",
            "--haplotype-definition", "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            "--haplotype-min-sample-percent", "1",
            "--haplotype-min-locus-percent", "1",
            "--haplotype-min-locus-percent-override", "MHC-DQ=10",
            "--haplotype-min-locus-percent-override", "MHC-DP=10",
            "--barcodes", "/tmp/fluidigm.csv",
            "--threads", "14",
            "--min-support", "10",
        ])

        XCTAssertEqual(command.haplotypeDefinitionScope, "project")
        XCTAssertEqual(command.haplotypeMinSamplePercent, 1)
        XCTAssertEqual(command.haplotypeMinLocusPercent, 1)
        XCTAssertEqual(command.haplotypeMinLocusPercentOverrides, ["MHC-DQ=10", "MHC-DP=10"])
    }

    func testMHCReferenceBundleParsesOptions() throws {
        let command = try FastqMHCReferenceBundleSubcommand.parse([
            "--reference-fasta", "/tmp/MCM_MHC.gb",
            "--haplotype-definition", "/tmp/mcm.json",
            "--haplotype-definition", "/tmp/mamu.json",
            "--default-haplotype-definition", "mcm-mhc",
            "--output", "/tmp/MCM-MHC.lungfishmhcref",
            "--name", "MCM MHC",
            "--source-file", "/tmp/build.log",
            "--force",
        ])

        XCTAssertEqual(command.referenceFASTA, "/tmp/MCM_MHC.gb")
        XCTAssertEqual(command.haplotypeDefinitions, ["/tmp/mcm.json", "/tmp/mamu.json"])
        XCTAssertEqual(command.defaultHaplotypeDefinition, "mcm-mhc")
        XCTAssertEqual(command.output, "/tmp/MCM-MHC.lungfishmhcref")
        XCTAssertEqual(command.name, "MCM MHC")
        XCTAssertEqual(command.sourceFiles, ["/tmp/build.log"])
        XCTAssertTrue(command.force)
        XCTAssertEqual(command.configurationForTesting().defaultHaplotypeDefinitionID, "mcm-mhc")
    }

    func testMHCReferenceBundleFormatsRecoverableAnnotationWarning() {
        let warning = MHCReferenceBundleWarning(
            category: "genbank.annotation.skipped",
            message: "Invalid GenBank location: bad..location",
            recordIdentifier: "MHCREF1",
            featureType: "CDS",
            sourceLocation: "bad..location"
        )

        XCTAssertEqual(
            FastqMHCReferenceBundleSubcommand.warningLine(warning),
            "warning: Invalid GenBank location: bad..location [record MHCREF1, feature CDS, location bad..location]\n"
        )
    }

    private func makeUpdateCurrentWorkbookFixture(
        in root: URL,
        pythonURL: URL
    ) throws -> URL {
        let outputName = "cli-fn"
        let bundleURL = root.appendingPathComponent(
            "\(outputName).lungfishgenotype",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: bundleURL,
            withIntermediateDirectories: true
        )
        let primaryURL = bundleURL.appendingPathComponent("\(outputName).xlsx")
        let currentURL = bundleURL.appendingPathComponent(
            "artifacts/workbooks/current.xlsx"
        )
        try FileManager.default.createDirectory(
            at: currentURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let process = Process()
        process.executableURL = pythonURL
        process.arguments = ["-c", #"""
import sys
from openpyxl import Workbook

path = sys.argv[1]
wb = Workbook()
ws = wb.active
ws.title = "matrix"
ws.append(["Animal ID", None, None, "AR3628"])
ws.append(["GS ID", "Total", "Average", "AR3628"])
ws.append(["Filtered exact-match read count", None, None, 0])
ws.append([])
ws.append(["Comments", "Subtotal", "# Obs.", None])
ws.append(["Genotype", "Total", "# Obs.", "AR3628"])
ws.append(["Mamu-A1*001:01", 0, 0, 0])
wb.save(path)
"""#, primaryURL.path]
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(
                data: stderr.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "openpyxl fixture creation failed"
            throw NSError(
                domain: "FastqGenotypingCommandTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
        try FileManager.default.copyItem(at: primaryURL, to: currentURL)
        let genotypeCSV = bundleURL.appendingPathComponent(
            "\(outputName).retained-demux-genotypes.csv"
        )
        let sampleCSV = bundleURL.appendingPathComponent(
            "\(outputName).retained-demux-samples.csv"
        )
        let statsJSON = bundleURL.appendingPathComponent(
            "\(outputName).retained-demux-stats.json"
        )
        let provenance = bundleURL.appendingPathComponent(
            "retained-demux-genotyping-provenance.json"
        )
        try Data("sample,genotype\nAR3628,Mamu-I*expected\n".utf8)
            .write(to: genotypeCSV)
        try Data("sample\nAR3628\n".utf8).write(to: sampleCSV)
        try Data("{}".utf8).write(to: statsJSON)
        try Data("{}".utf8).write(to: provenance)
        let catalogURL = bundleURL.appendingPathComponent(
            "artifacts/review/reviewable-row-catalog.json"
        )
        try FileManager.default.createDirectory(
            at: catalogURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let catalog = try GenotypeReviewableRowCatalog(
            samples: ["AR3628"],
            rows: [
                .init(
                    kind: .reference,
                    callID: "reference:MHC-A:Mamu-A1*001:01",
                    displayName: "Mamu-A1*001:01",
                    locus: "MHC-A",
                    stableID: nil,
                    section: "reference",
                    sortKey: "MHC-A|Mamu-A1*001:01",
                    supportBySample: ["AR3628": 0]
                ),
            ]
        ).validated()
        try catalog.encoded().write(to: catalogURL)
        let catalogReference = ONTMHCArtifactReference(
            path: "artifacts/review/reviewable-row-catalog.json",
            sha256: try ProvenanceFileHasher.sha256(of: catalogURL),
            sizeBytes: Int64(try ProvenanceFileHasher.fileSize(of: catalogURL))
        )
        let revision = ONTGenotypeWorkbookRevision(
            id: "initial-current-copy",
            role: .initialCurrentCopy,
            path: "artifacts/workbooks/current.xlsx",
            label: "Initial editable workbook",
            sourceFilename: primaryURL.lastPathComponent,
            createdAt: "2026-07-27T00:00:00Z",
            user: "tester",
            predecessorPath: primaryURL.lastPathComponent,
            sha256: try ProvenanceFileHasher.sha256(of: currentURL),
            sizeBytes: Int64(try ProvenanceFileHasher.fileSize(of: currentURL)),
            provenancePath: nil
        )
        let manifest = ONTGenotypeResultBundleManifest(
            outputName: outputName,
            analysisName: outputName,
            primaryWorkbookPath: primaryURL.lastPathComponent,
            currentWorkbookPath: "artifacts/workbooks/current.xlsx",
            workbookRevisions: [revision],
            longSummaryCSVPath: genotypeCSV.lastPathComponent,
            sampleSummaryCSVPath: sampleCSV.lastPathComponent,
            statsJSONPath: statsJSON.lastPathComponent,
            provenancePath: provenance.lastPathComponent,
            reviewableRowCatalog: catalogReference
        )
        try ONTGenotypeResultBundle.writeManifest(manifest, to: bundleURL)
        return bundleURL
    }

    private func openpyxlPythonURL() -> URL? {
        var candidates: [URL] = []
        if let configured = ProcessInfo.processInfo.environment[
            "LUNGFISH_TEST_PYTHON"
        ] {
            candidates.append(URL(fileURLWithPath: configured))
        }
        candidates.append(URL(
            fileURLWithPath:
                "/Users/dho/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3"
        ))
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        which.arguments = ["python3"]
        let stdout = Pipe()
        which.standardOutput = stdout
        which.standardError = FileHandle.nullDevice
        if (try? which.run()) != nil {
            which.waitUntilExit()
            if which.terminationStatus == 0,
               let path = String(
                data: stdout.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
               )?.trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty {
                candidates.append(URL(fileURLWithPath: path))
            }
        }
        candidates += [
            URL(fileURLWithPath: "/opt/homebrew/bin/python3"),
            URL(fileURLWithPath: "/usr/local/bin/python3"),
            URL(fileURLWithPath: "/usr/bin/python3"),
        ]
        var visited = Set<String>()
        for candidate in candidates {
            let resolved = candidate.standardizedFileURL
            guard visited.insert(resolved.path).inserted,
                  FileManager.default.isExecutableFile(atPath: resolved.path)
            else {
                continue
            }
            let probe = Process()
            probe.executableURL = resolved
            probe.arguments = ["-c", "import openpyxl"]
            probe.standardOutput = FileHandle.nullDevice
            probe.standardError = FileHandle.nullDevice
            guard (try? probe.run()) != nil else { continue }
            probe.waitUntilExit()
            if probe.terminationStatus == 0 {
                return resolved
            }
        }
        return nil
    }
}

private final class FastqImmutableInputMutationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    var wasClaimed: Bool {
        lock.withLock { claimed }
    }

    func claim() -> Bool {
        lock.withLock {
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }
}
