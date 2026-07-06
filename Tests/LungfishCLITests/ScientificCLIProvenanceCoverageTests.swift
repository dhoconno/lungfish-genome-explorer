import XCTest
import LungfishCore
import LungfishIO
@testable import LungfishCLI
@testable import LungfishWorkflow

final class ScientificCLIProvenanceCoverageTests: XCTestCase {
    func testSingleStepHelperPreservesCallerStatusAndPeakMemoryInCompatibilityRun() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("single-step-helper-provenance-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let inputURL = root.appendingPathComponent("reads.fastq")
        let outputURL = root.appendingPathComponent("cancelled.fastq")
        try "@r1\nACGT\n+\nIIII\n".write(to: inputURL, atomically: true, encoding: .utf8)
        try Data().write(to: outputURL)

        let envelope = try await CLIProvenanceSupport.recordSingleStepRun(
            name: "lungfish fastq cancelled-fixture",
            parameters: ["limit": .integer(10)],
            toolName: "lungfish fastq cancelled-fixture",
            toolVersion: "fixture",
            command: [CLICommandIdentity.executableName, "fastq", "cancelled-fixture", inputURL.path],
            inputs: [
                FileRecord(path: inputURL.path, format: .fastq, role: .input),
            ],
            outputs: [
                FileRecord(path: outputURL.path, format: .fastq, role: .output),
            ],
            exitCode: 130,
            wallTime: 0.25,
            peakMemoryBytes: 42_000_000,
            stderr: "cancelled by user",
            status: .cancelled,
            outputDirectory: root,
            writeFileSidecars: false
        )

        let compatibilityRun = envelope.legacyWorkflowRun()
        XCTAssertEqual(compatibilityRun.status, .cancelled)
        XCTAssertEqual(compatibilityRun.steps.first?.peakMemoryBytes, 42_000_000)

        let decoded = try ProvenanceEnvelopeReader.decode(try Data(
            contentsOf: root.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        ))
        XCTAssertEqual(decoded.legacyWorkflowRun().status, .cancelled)
        XCTAssertEqual(decoded.legacyWorkflowRun().steps.first?.peakMemoryBytes, 42_000_000)
    }

    func testScientificTopLevelCommandsHavePolicyEntries() {
        let nonScientificTopLevelCommands: Set<String> = [
            "version",
            "provision-tools",
            "conda",
            "debug"
        ]
        let topLevelCommands = Set(LungfishCLI.configuration.subcommands.compactMap { $0.configuration.commandName })
        let commandsExpectedToHavePolicy = topLevelCommands.subtracting(nonScientificTopLevelCommands)
        let missing = commandsExpectedToHavePolicy
            .filter { ScientificProvenancePolicy.cliCommand($0) == nil }
            .sorted()
        let stale = Set(ScientificProvenancePolicy.canonicalCLICommandNames)
            .subtracting(topLevelCommands)
            .sorted()

        XCTAssertTrue(
            stale.isEmpty,
            "CLI provenance policy references non-top-level commands: \(stale.joined(separator: ", "))"
        )
        XCTAssertTrue(missing.isEmpty, "Top-level commands missing CLI provenance policies: \(missing.joined(separator: ", "))")
    }

    func testTopLevelScientificCommandPolicyRequiresProvenance() throws {
        let policy = try XCTUnwrap(ScientificProvenancePolicy.cliCommand("fastq"))

        XCTAssertTrue(policy.createsOrModifiesScientificData)
        XCTAssertTrue(policy.requiresProvenance)
        XCTAssertEqual(policy.writer, "CLIProvenanceSupport")
    }

    func testGUIRoutedFASTQDerivativeCommandsAreRegisteredForProvenance() {
        let registered = Set(FastqCommand.configuration.subcommands.compactMap { $0.configuration.commandName })

        XCTAssertTrue(registered.contains("reverse-complement"))
        XCTAssertTrue(registered.contains("translate"))
    }

    func testDirectScientificOutputCommandsWriteCanonicalProvenanceSidecars() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scientific-cli-provenance-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let inputURL = root.appendingPathComponent("input.fasta")
        let sequence = try Sequence(name: "seq1", alphabet: .dna, bases: "ATGGAATTCTAA")
        try FASTAWriter(url: inputURL).write([sequence])

        let convertDirectory = root.appendingPathComponent("convert", isDirectory: true)
        let translateDirectory = root.appendingPathComponent("translate", isDirectory: true)
        let searchDirectory = root.appendingPathComponent("search", isDirectory: true)
        let extractDirectory = root.appendingPathComponent("extract", isDirectory: true)
        try [convertDirectory, translateDirectory, searchDirectory, extractDirectory].forEach {
            try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true)
        }

        let convertedURL = convertDirectory.appendingPathComponent("converted.fasta")
        let convert = try ConvertCommand.parse([
            inputURL.path,
            "--to", convertedURL.path,
            "--to-format", "fasta",
            "--force",
            "--quiet"
        ])
        try await convert.run()
        let convertEnvelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: convertDirectory))
        XCTAssertEqual(convertEnvelope.workflowName, "lungfish convert")
        XCTAssertEqual(convertEnvelope.toolName, "lungfish convert")
        XCTAssertEqual(convertEnvelope.output?.path, convertedURL.path)
        XCTAssertNotNil(convertEnvelope.output?.checksumSHA256)
        XCTAssertNil(convertEnvelope.options.explicit["resolvedDefaults"])
        XCTAssertEqual(convertEnvelope.options.defaults["toFormat"]?.stringValue, "fasta")
        XCTAssertEqual(convertEnvelope.options.resolvedDefaults["toFormat"]?.stringValue, "fasta")
        XCTAssertTrue(convertEnvelope.argv.contains("--quiet"))
        let convertFileEnvelope = try loadFileSidecarEnvelope(for: convertedURL)
        XCTAssertEqual(convertFileEnvelope.output?.path, convertedURL.path)
        XCTAssertNotNil(ProvenanceRecorder.findProvenance(forFile: convertedURL))

        let translatedURL = translateDirectory.appendingPathComponent("protein.fasta")
        let translate = try TranslateCommand.parse([
            inputURL.path,
            "--frame", "1",
            "--output", translatedURL.path,
            "--quiet"
        ])
        try await translate.run()
        let translateEnvelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: translateDirectory))
        XCTAssertEqual(translateEnvelope.workflowName, "lungfish translate")
        XCTAssertEqual(translateEnvelope.output?.path, translatedURL.path)
        XCTAssertEqual(translateEnvelope.options.explicit["frame"]?.integerValue, 1)
        XCTAssertEqual(try loadFileSidecarEnvelope(for: translatedURL).output?.path, translatedURL.path)

        let searchURL = searchDirectory.appendingPathComponent("sites.bed")
        let search = try SearchCommand.parse([
            inputURL.path,
            "ATG",
            "--output", searchURL.path,
            "--quiet"
        ])
        try await search.run()
        let searchEnvelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: searchDirectory))
        XCTAssertEqual(searchEnvelope.workflowName, "lungfish search")
        XCTAssertEqual(searchEnvelope.output?.path, searchURL.path)
        XCTAssertEqual(searchEnvelope.options.explicit["pattern"]?.stringValue, "ATG")
        XCTAssertEqual(searchEnvelope.options.defaults["maxMismatches"]?.integerValue, 0)
        XCTAssertEqual(try loadFileSidecarEnvelope(for: searchURL).output?.path, searchURL.path)

        let extractedURL = extractDirectory.appendingPathComponent("region.fasta")
        let extract = try ExtractSequenceSubcommand.parse([
            inputURL.path,
            "seq1:1-3",
            "--output", extractedURL.path,
            "--quiet"
        ])
        try await extract.run()
        let extractEnvelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: extractDirectory))
        XCTAssertEqual(extractEnvelope.workflowName, "lungfish extract sequence")
        XCTAssertEqual(extractEnvelope.output?.path, extractedURL.path)
        XCTAssertEqual(extractEnvelope.options.resolvedDefaults["flank5"]?.integerValue, 0)
        XCTAssertEqual(try loadFileSidecarEnvelope(for: extractedURL).output?.path, extractedURL.path)
    }

    func testExtractReadAndContigCommandsWriteCanonicalProvenanceSidecars() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scientific-extract-provenance-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let readsURL = root.appendingPathComponent("reads.fastq")
        try [
            "@read1",
            "ACGT",
            "+",
            "IIII",
            "@read2",
            "TTTT",
            "+",
            "IIII"
        ].joined(separator: "\n").appending("\n").write(to: readsURL, atomically: true, encoding: .utf8)
        let idsURL = root.appendingPathComponent("ids.txt")
        try "read1\n".write(to: idsURL, atomically: true, encoding: .utf8)
        let extractedReadsURL = root.appendingPathComponent("extracted.fastq")

        let readCommand = try ExtractReadsSubcommand.parse([
            "--by-id",
            "--ids", idsURL.path,
            "--source", readsURL.path,
            "--output", extractedReadsURL.path,
            "--quiet"
        ])
        try await readCommand.run()

        let extractedReadsActualURL = root.appendingPathComponent("extracted.fastq.gz")
        let readsEnvelope = try loadFileSidecarEnvelope(for: extractedReadsActualURL)
        XCTAssertEqual(readsEnvelope.workflowName, "lungfish extract reads")
        XCTAssertEqual(readsEnvelope.output?.path, extractedReadsActualURL.path)
        XCTAssertTrue(readsEnvelope.files.contains { $0.path == idsURL.path && $0.checksumSHA256 != nil })
        XCTAssertTrue(readsEnvelope.files.contains { $0.path == readsURL.path && $0.checksumSHA256 != nil })
        XCTAssertEqual(readsEnvelope.options.defaults["keepReadPairs"]?.booleanValue, true)
        XCTAssertEqual(readsEnvelope.options.defaults["excludeUnmapped"]?.booleanValue, false)
        XCTAssertEqual(readsEnvelope.options.resolvedDefaults["keepReadPairs"]?.booleanValue, true)
        XCTAssertEqual(readsEnvelope.options.resolvedDefaults["excludeUnmapped"]?.booleanValue, false)

        let contigsURL = root.appendingPathComponent("contigs.fa")
        let contigSequence = try Sequence(name: "contig1", alphabet: .dna, bases: "ATGCGT")
        try FASTAWriter(url: contigsURL).write([contigSequence])
        let extractedContigURL = root.appendingPathComponent("contig-subset.fa")
        var contigCommand = try ExtractContigsSubcommand.parse([
            "--contigs", contigsURL.path,
            "--contig", "contig1",
            "--output", extractedContigURL.path,
            "--quiet"
        ])
        contigCommand.rawSelectionArguments = [
            "--contigs", contigsURL.path,
            "--contig", "contig1",
            "--output", extractedContigURL.path,
            "--quiet"
        ]
        try await contigCommand.run()

        let contigEnvelope = try loadFileSidecarEnvelope(for: extractedContigURL)
        XCTAssertEqual(contigEnvelope.workflowName, "lungfish extract contigs")
        XCTAssertEqual(contigEnvelope.output?.path, extractedContigURL.path)
        XCTAssertTrue(contigEnvelope.files.contains { $0.path == contigsURL.path && $0.checksumSHA256 != nil })
        XCTAssertEqual(contigEnvelope.options.defaults["lineWidth"]?.integerValue, 60)
        XCTAssertEqual(contigEnvelope.options.defaults["bundle"]?.booleanValue, false)
        XCTAssertEqual(contigEnvelope.options.resolvedDefaults["lineWidth"]?.integerValue, 60)
        XCTAssertEqual(contigEnvelope.options.resolvedDefaults["bundle"]?.booleanValue, false)
    }

    func testExtractBundleCommandsRecordFinalStoredPayloads() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scientific-extract-bundle-provenance-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let readsURL = root.appendingPathComponent("reads.fastq")
        try [
            "@read1",
            "ACGT",
            "+",
            "IIII"
        ].joined(separator: "\n").appending("\n").write(to: readsURL, atomically: true, encoding: .utf8)
        let idsURL = root.appendingPathComponent("ids.txt")
        try "read1\n".write(to: idsURL, atomically: true, encoding: .utf8)
        let extractedReadsURL = root.appendingPathComponent("bundle-reads.fastq")

        let readCommand = try ExtractReadsSubcommand.parse([
            "--by-id",
            "--ids", idsURL.path,
            "--source", readsURL.path,
            "--output", extractedReadsURL.path,
            "--bundle",
            "--quiet"
        ])
        try await readCommand.run()

        let readBundleURL = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == FASTQBundle.directoryExtension }
        )
        let readPayloadURL = try XCTUnwrap(FASTQBundle.resolvePrimaryFASTQURL(for: readBundleURL))
        let readPayloadPath = readPayloadURL.standardizedFileURL.path
        let readBundleEnvelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: readBundleURL))
        XCTAssertEqual(readBundleEnvelope.workflowName, "lungfish extract reads")
        XCTAssertTrue(readBundleEnvelope.files.contains {
            URL(fileURLWithPath: $0.path).standardizedFileURL.path == readPayloadPath && $0.checksumSHA256 != nil
        })
        XCTAssertEqual(
            try loadFileSidecarEnvelope(for: readPayloadURL).output.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path },
            readPayloadPath
        )

        let contigsURL = root.appendingPathComponent("contigs.fa")
        let contigSequence = try Sequence(name: "contig1", alphabet: .dna, bases: "ATGCGT")
        try FASTAWriter(url: contigsURL).write([contigSequence])
        var contigCommand = try ExtractContigsSubcommand.parse([
            "--contigs", contigsURL.path,
            "--contig", "contig1",
            "--bundle",
            "--bundle-name", "contig-subset",
            "--project-root", root.path,
            "--quiet"
        ])
        contigCommand.rawSelectionArguments = [
            "--contigs", contigsURL.path,
            "--contig", "contig1",
            "--bundle",
            "--bundle-name", "contig-subset",
            "--project-root", root.path,
            "--quiet"
        ]
        try await contigCommand.run()

        let referenceFolderURL = root.appendingPathComponent(ReferenceSequenceFolder.folderName, isDirectory: true)
        let referenceBundleURL = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(at: referenceFolderURL, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "lungfishref" }
        )
        let referenceManifest = try BundleManifest.load(from: referenceBundleURL)
        let referenceGenome = try XCTUnwrap(referenceManifest.genome)
        let referencePayloadURL = referenceBundleURL.appendingPathComponent(referenceGenome.path)
        let referencePayloadPath = referencePayloadURL.standardizedFileURL.path
        let contigBundleEnvelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: referenceBundleURL))
        XCTAssertEqual(contigBundleEnvelope.workflowName, "lungfish extract contigs")
        XCTAssertTrue(contigBundleEnvelope.files.contains {
            URL(fileURLWithPath: $0.path).standardizedFileURL.path == referencePayloadPath && $0.checksumSHA256 != nil
        })
        XCTAssertEqual(
            try loadFileSidecarEnvelope(for: referencePayloadURL).output.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path },
            referencePayloadPath
        )
    }

    func testBundleExtractAnnotationsRecordsDurableSourceInputs() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scientific-annotation-extract-provenance-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let sourceBundleURL = try makeTinyReferenceBundle(in: root, sequence: "ATGAAATAA")
        try addTinyAnnotationTrack(to: sourceBundleURL)
        let outputBundleURL = root.appendingPathComponent("genes-only.lungfishref", isDirectory: true)

        let command = try BundleExtractAnnotationsSubcommand.parse([
            "--bundle", sourceBundleURL.path,
            "--track", "genes",
            "--output-bundle", outputBundleURL.path,
            "--feature-type", "gene",
        ])
        try await command.run()

        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: outputBundleURL))
        XCTAssertEqual(envelope.workflowName, "lungfish bundle extract-annotations")
        XCTAssertTrue(envelope.argv.contains("extract-annotations"))
        XCTAssertTrue(envelope.argv.contains("--feature-type"))

        let inputPaths = Set(envelope.steps.flatMap(\.inputs).map {
            URL(fileURLWithPath: $0.path).standardizedFileURL.path
        })
        let expectedInputs = [
            sourceBundleURL.appendingPathComponent("manifest.json"),
            sourceBundleURL.appendingPathComponent("genome/sequence.fa"),
            sourceBundleURL.appendingPathComponent("genome/sequence.fa.fai"),
            sourceBundleURL.appendingPathComponent("annotations/genes.bed"),
            sourceBundleURL.appendingPathComponent("annotations/genes.db"),
        ].map { $0.standardizedFileURL.path }

        for expectedInput in expectedInputs {
            XCTAssertTrue(inputPaths.contains(expectedInput), "Missing durable provenance input \(expectedInput)")
            let descriptor = envelope.steps.flatMap(\.inputs).first {
                URL(fileURLWithPath: $0.path).standardizedFileURL.path == expectedInput
            }
            XCTAssertNotNil(descriptor?.checksumSHA256, "Missing checksum for \(expectedInput)")
            XCTAssertNotNil(descriptor?.fileSize, "Missing file size for \(expectedInput)")
        }
        XCTAssertFalse(inputPaths.contains { $0.contains("lungfish-cli-annotation-sequences-") })
        XCTAssertFalse(inputPaths.contains { $0.hasSuffix("annotation-sequences.fa") })
        let encodedEnvelope = String(decoding: try JSONEncoder().encode(envelope), as: UTF8.self)
        XCTAssertFalse(encodedEnvelope.contains("lungfish-cli-annotation-sequences-"))
        XCTAssertFalse(encodedEnvelope.contains("annotation-sequences.fa"))
        XCTAssertTrue(envelope.outputs.contains { $0.path.hasPrefix(outputBundleURL.path) && $0.checksumSHA256 != nil })
    }

    func testDirectFileSidecarsProtectMultipleOutputsInSameDirectory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scientific-cli-provenance-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let inputURL = root.appendingPathComponent("input.fasta")
        let sequence = try Sequence(name: "seq1", alphabet: .dna, bases: "ATGGAATTCTAA")
        try FASTAWriter(url: inputURL).write([sequence])

        let firstOutputURL = root.appendingPathComponent("first.fasta")
        let firstConvert = try ConvertCommand.parse([
            inputURL.path,
            "--to", firstOutputURL.path,
            "--to-format", "fasta",
            "--force",
            "--quiet"
        ])
        try await firstConvert.run()

        let secondOutputURL = root.appendingPathComponent("second.fasta")
        let secondConvert = try ConvertCommand.parse([
            inputURL.path,
            "--to", secondOutputURL.path,
            "--to-format", "fasta",
            "--force",
            "--quiet"
        ])
        try await secondConvert.run()

        let directoryEnvelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: root))
        XCTAssertEqual(directoryEnvelope.output?.path, secondOutputURL.path)
        XCTAssertEqual(try loadFileSidecarEnvelope(for: firstOutputURL).output?.path, firstOutputURL.path)
        XCTAssertEqual(try loadFileSidecarEnvelope(for: secondOutputURL).output?.path, secondOutputURL.path)
    }

    func testMultiOutputFileSidecarsUseAdjacentFileAsPrimaryOutput() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scientific-cli-multi-output-provenance-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let inputURL = root.appendingPathComponent("interleaved.fastq")
        let out1URL = root.appendingPathComponent("R1.fastq")
        let out2URL = root.appendingPathComponent("R2.fastq")
        try "@r/1\nACGT\n+\nIIII\n".write(to: inputURL, atomically: true, encoding: .utf8)
        try "@r/1\nACGT\n+\nIIII\n".write(to: out1URL, atomically: true, encoding: .utf8)
        try "@r/2\nTGCA\n+\nIIII\n".write(to: out2URL, atomically: true, encoding: .utf8)

        try await CLIProvenanceSupport.recordSingleStepRun(
            name: "lungfish fastq deinterleave",
            parameters: [
                "input": .file(inputURL),
                "out1": .file(out1URL),
                "out2": .file(out2URL)
            ],
            toolName: "reformat",
            toolVersion: "39.01",
            command: ["lungfish", "fastq", "deinterleave", inputURL.path, "--out1", out1URL.path, "--out2", out2URL.path],
            stepCommand: ["reformat.sh", "in=\(inputURL.path)", "out1=\(out1URL.path)", "out2=\(out2URL.path)"],
            inputs: [ProvenanceRecorder.fileRecord(url: inputURL, format: .fastq, role: .input)],
            outputs: [
                ProvenanceRecorder.fileRecord(url: out1URL, format: .fastq, role: .output),
                ProvenanceRecorder.fileRecord(url: out2URL, format: .fastq, role: .output)
            ],
            exitCode: 0,
            wallTime: 0.25,
            stderr: nil,
            status: .completed,
            outputDirectory: root
        )

        XCTAssertEqual(try loadFileSidecarEnvelope(for: out1URL).output?.path, out1URL.path)
        XCTAssertEqual(try loadFileSidecarEnvelope(for: out1URL).outputs.map(\.path), [out1URL.path])
        XCTAssertEqual(try loadFileSidecarEnvelope(for: out2URL).output?.path, out2URL.path)
        XCTAssertEqual(try loadFileSidecarEnvelope(for: out2URL).outputs.map(\.path), [out2URL.path])
    }

    func testSingleStepRunPreservesCompleteRemoteInputDescriptor() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scientific-cli-remote-input-provenance-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let outputURL = root.appendingPathComponent("reference.fa")
        try ">chr1\nACGT\n".write(to: outputURL, atomically: true, encoding: .utf8)
        let remoteInput = FileRecord(
            path: "https://example.org/reference.fa.gz",
            sha256: String(repeating: "a", count: 64),
            sizeBytes: 128,
            format: .fasta,
            role: .reference
        )

        try await CLIProvenanceSupport.recordSingleStepRun(
            name: "lungfish fetch genome",
            parameters: ["accession": .string("GCF_000001405.40")],
            toolName: "lungfish fetch genome",
            toolVersion: WorkflowRun.currentAppVersion,
            command: ["lungfish", "fetch", "genome", "GCF_000001405.40"],
            inputs: [remoteInput],
            outputs: [ProvenanceRecorder.fileRecord(url: outputURL, format: .fasta, role: .output)],
            exitCode: 0,
            wallTime: 0.25,
            stderr: nil,
            status: .completed,
            outputDirectory: root
        )

        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: root))
        let recordedInput = try XCTUnwrap(envelope.files.first { $0.path == remoteInput.path })
        XCTAssertEqual(recordedInput.checksumSHA256, remoteInput.sha256)
        XCTAssertEqual(recordedInput.fileSize, remoteInput.sizeBytes)
        XCTAssertEqual(recordedInput.role, .reference)
    }

    func testConvertReferenceBundleWritesPayloadInputProvenance() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scientific-convert-ref-provenance-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let bundleURL = try makeTinyReferenceBundle(in: root, sequence: "ATGAAATAA")
        let outputURL = root.appendingPathComponent("export.fa")
        let command = try ConvertCommand.parse([
            bundleURL.path,
            "--to", outputURL.path,
            "--to-format", "fasta",
            "--include-annotations",
            "--force",
            "--quiet",
        ])

        try await command.run()

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        let envelope = try loadFileSidecarEnvelope(for: outputURL)
        let inputPaths = Set(envelope.steps.flatMap(\.inputs).map(\.path))
        let manifestURL = bundleURL.appendingPathComponent("manifest.json")
        let fastaURL = bundleURL.appendingPathComponent("genome/sequence.fa")
        let faiURL = bundleURL.appendingPathComponent("genome/sequence.fa.fai")
        XCTAssertTrue(inputPaths.contains(manifestURL.path))
        XCTAssertTrue(inputPaths.contains(fastaURL.path))
        XCTAssertTrue(inputPaths.contains(faiURL.path))
        XCTAssertFalse(inputPaths.contains(bundleURL.path))
        XCTAssertNotNil(envelope.steps.flatMap(\.inputs).first { $0.path == manifestURL.path }?.checksumSHA256)
        XCTAssertEqual(envelope.output?.path, outputURL.path)
        XCTAssertNotNil(envelope.output?.checksumSHA256)
    }

    func testConvertForceTruncatesExistingGFF3Output() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scientific-convert-force-gff-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let bundleURL = try makeTinyReferenceBundle(in: root, sequence: "ATGAAATAA")
        try addTinyAnnotationTrack(to: bundleURL)
        let outputURL = root.appendingPathComponent("annotations.gff3")
        try [
            "##gff-version 3",
            "chr1\told\tgene\t1\t9\t.\t+\t.\tID=old",
            "STALE_TRAILING_CONTENT_SHOULD_NOT_SURVIVE"
        ].joined(separator: "\n").appending("\n").write(to: outputURL, atomically: true, encoding: .utf8)

        let command = try ConvertCommand.parse([
            bundleURL.path,
            "--to", outputURL.path,
            "--to-format", "gff3",
            "--include-annotations",
            "--force",
            "--quiet",
        ])
        try await command.run()

        let output = try String(contentsOf: outputURL, encoding: .utf8)
        XCTAssertTrue(output.contains("gene1"))
        XCTAssertFalse(output.contains("STALE_TRAILING_CONTENT_SHOULD_NOT_SURVIVE"))
    }

    func testFASTQSearchCommandsWriteNativeToolProvenanceSidecarsWithRealFixture() async throws {
        guard await NativeToolRunner.shared.isToolAvailable(.seqkit) else {
            throw XCTSkip("seqkit is not available in this test environment")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scientific-fastq-provenance-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let inputURL = root.appendingPathComponent("reads.fastq")
        try [
            "@read-match description",
            "ACGTACGT",
            "+",
            "IIIIIIII",
            "@read-other",
            "TTTTGGGG",
            "+",
            "IIIIIIII"
        ].joined(separator: "\n").appending("\n").write(to: inputURL, atomically: true, encoding: .utf8)

        let textOutputURL = root.appendingPathComponent("text.fastq")
        let textCommand = try FastqSearchTextSubcommand.parse([
            inputURL.path,
            "--output", textOutputURL.path,
            "--query", "read-match"
        ])
        try await textCommand.run()

        let textEnvelope = try loadFileSidecarEnvelope(for: textOutputURL)
        XCTAssertEqual(textEnvelope.workflowName, "lungfish fastq search-text")
        XCTAssertEqual(textEnvelope.toolName, "seqkit")
        XCTAssertEqual(textEnvelope.output?.path, textOutputURL.path)
        XCTAssertEqual(textEnvelope.options.defaults["field"]?.stringValue, "id")
        XCTAssertTrue(textEnvelope.argv.contains("search-text"))
        XCTAssertNotNil(ProvenanceRecorder.findProvenance(forFile: textOutputURL))

        let motifOutputURL = root.appendingPathComponent("motif.fastq")
        let motifCommand = try FastqSearchMotifSubcommand.parse([
            inputURL.path,
            "--output", motifOutputURL.path,
            "--pattern", "ACGT"
        ])
        try await motifCommand.run()

        let motifEnvelope = try loadFileSidecarEnvelope(for: motifOutputURL)
        XCTAssertEqual(motifEnvelope.workflowName, "lungfish fastq search-motif")
        XCTAssertEqual(motifEnvelope.toolName, "seqkit")
        XCTAssertEqual(motifEnvelope.output?.path, motifOutputURL.path)
        XCTAssertEqual(motifEnvelope.options.defaults["regex"]?.booleanValue, false)
        XCTAssertTrue(motifEnvelope.argv.contains("search-motif"))
    }

    func testFASTQSwiftCommandsWriteProvenanceSidecarsWithRealFixture() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scientific-fastq-swift-provenance-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let inputURL = root.appendingPathComponent("reads.fastq")
        try [
            "@read1",
            "ATGGCA",
            "+",
            "ABCDEF"
        ].joined(separator: "\n").appending("\n").write(to: inputURL, atomically: true, encoding: .utf8)

        let reverseOutputURL = root.appendingPathComponent("reverse.fastq")
        let reverseCommand = try FastqReverseComplementSubcommand.parse([
            inputURL.path,
            "-o", reverseOutputURL.path
        ])
        try await reverseCommand.run()

        let reverseEnvelope = try loadFileSidecarEnvelope(for: reverseOutputURL)
        XCTAssertEqual(reverseEnvelope.workflowName, "lungfish fastq reverse-complement")
        XCTAssertEqual(reverseEnvelope.toolName, "lungfish fastq reverse-complement")
        XCTAssertEqual(reverseEnvelope.output?.path, reverseOutputURL.path)
        XCTAssertEqual(reverseEnvelope.outputs.first?.format, .fastq)
        XCTAssertTrue(reverseEnvelope.argv.contains("reverse-complement"))
        XCTAssertTrue(try String(contentsOf: reverseOutputURL, encoding: .utf8).contains("TGCCAT"))

        let translateOutputURL = root.appendingPathComponent("translate.fasta")
        let translateCommand = try FastqTranslateSubcommand.parse([
            inputURL.path,
            "--frame", "1",
            "-o", translateOutputURL.path
        ])
        try await translateCommand.run()

        let translateEnvelope = try loadFileSidecarEnvelope(for: translateOutputURL)
        XCTAssertEqual(translateEnvelope.workflowName, "lungfish fastq translate")
        XCTAssertEqual(translateEnvelope.toolName, "lungfish fastq translate")
        XCTAssertEqual(translateEnvelope.output?.path, translateOutputURL.path)
        XCTAssertEqual(translateEnvelope.outputs.first?.format, .fasta)
        XCTAssertEqual(translateEnvelope.options.defaults["table"]?.integerValue, 1)
        XCTAssertTrue(translateEnvelope.argv.contains("translate"))
        XCTAssertTrue(try String(contentsOf: translateOutputURL, encoding: .utf8).contains("MA"))
    }

    private func loadFileSidecarEnvelope(for outputURL: URL) throws -> ProvenanceEnvelope {
        let sidecarURL = ProvenanceRecorder.fileSidecarURL(for: outputURL)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: sidecarURL.path),
            "Missing file-specific provenance sidecar at \(sidecarURL.path)"
        )
        return try XCTUnwrap(ProvenanceRecorder.loadEnvelope(fromSidecar: sidecarURL))
    }

    private func makeTinyReferenceBundle(
        in root: URL,
        chromosomeName: String = "chr1",
        sequence: String
    ) throws -> URL {
        let bundleURL = root.appendingPathComponent("tiny.lungfishref", isDirectory: true)
        let genomeDir = bundleURL.appendingPathComponent("genome", isDirectory: true)
        try FileManager.default.createDirectory(at: genomeDir, withIntermediateDirectories: true)

        let fastaURL = genomeDir.appendingPathComponent("sequence.fa")
        try ">\(chromosomeName)\n\(sequence)\n".write(to: fastaURL, atomically: true, encoding: .utf8)
        let offset = ">\(chromosomeName)\n".utf8.count
        try "\(chromosomeName)\t\(sequence.count)\t\(offset)\t\(sequence.count)\t\(sequence.count + 1)\n"
            .write(
                to: genomeDir.appendingPathComponent("sequence.fa.fai"),
                atomically: true,
                encoding: .utf8
            )

        let manifest = BundleManifest(
            formatVersion: "1.0",
            name: "Tiny Reference",
            identifier: "org.lungfish.tests.scientific-convert-ref",
            source: SourceInfo(organism: "Test organism", assembly: "test"),
            genome: GenomeInfo(
                path: "genome/sequence.fa",
                indexPath: "genome/sequence.fa.fai",
                totalLength: Int64(sequence.count),
                chromosomes: [
                    ChromosomeInfo(
                        name: chromosomeName,
                        length: Int64(sequence.count),
                        offset: Int64(offset),
                        lineBases: sequence.count,
                        lineWidth: sequence.count + 1
                    ),
                ]
            )
        )
        try manifest.save(to: bundleURL)
        return bundleURL
    }

    private func addTinyAnnotationTrack(to bundleURL: URL) throws {
        let annotationsDir = bundleURL.appendingPathComponent("annotations", isDirectory: true)
        try FileManager.default.createDirectory(at: annotationsDir, withIntermediateDirectories: true)
        let bedURL = annotationsDir.appendingPathComponent("genes.bed")
        let dbURL = annotationsDir.appendingPathComponent("genes.db")
        try [
            "chr1", "0", "9", "gene1", "0", "+", "0", "9", "0", "1", "9", "0", "gene", "ID=gene1;gene=gene1"
        ].joined(separator: "\t").appending("\n").write(to: bedURL, atomically: true, encoding: .utf8)
        let featureCount = try AnnotationDatabase.createFromBED(bedURL: bedURL, outputURL: dbURL)
        let manifest = try BundleManifest.load(from: bundleURL)
        let updated = manifest.addingAnnotationTrack(AnnotationTrackInfo(
            id: "genes",
            name: "Genes",
            path: "annotations/genes.bed",
            databasePath: "annotations/genes.db",
            annotationType: .gene,
            featureCount: featureCount
        ))
        try updated.save(to: bundleURL)
    }
}
