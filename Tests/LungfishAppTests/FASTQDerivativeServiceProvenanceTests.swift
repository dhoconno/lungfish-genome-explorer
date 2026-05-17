import XCTest
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishWorkflow

final class FASTQDerivativeServiceProvenanceTests: XCTestCase {
    func testLengthFilterDerivativeWritesCanonicalProvenanceForFinalPayloads() async throws {
        let fixture = try FASTQDerivativeToolFixture(tools: [.seqkit])
        defer { fixture.cleanup() }

        let source = try fixture.makeBundle(named: "length-source")
        try fixture.writeFASTQ(
            [
                ("keep-1", "ACGTACGT"),
                ("keep-2", "TTTTAAAA"),
            ],
            to: source.fastqURL
        )

        let service = FASTQDerivativeService(runner: fixture.runner)
        let outputBundle = try await service.createDerivative(
            from: source.bundleURL,
            request: .lengthFilter(min: 4, max: nil)
        )

        let envelope = try loadProvenance(from: outputBundle)
        XCTAssertEqual(envelope.workflowName, "lungfish fastq lengthFilter derivative")
        XCTAssertEqual(envelope.workflowVersion, WorkflowRun.currentAppVersion)
        XCTAssertEqual(envelope.toolName, "Lungfish App")
        XCTAssertEqual(envelope.exitStatus, 0)
        XCTAssertNotNil(envelope.wallTimeSeconds)
        XCTAssertEqual(envelope.runtimeIdentity.executablePath, "Lungfish.app")
        XCTAssertEqual(envelope.options.explicit["operation"]?.stringValue, "lengthFilter")
        XCTAssertEqual(envelope.options.explicit["minLength"]?.integerValue, 4)
        XCTAssertTrue(envelope.options.explicit["maxLength"]?.isNull == true)
        XCTAssertTrue(envelope.options.defaults["minLength"]?.isNull == true)
        XCTAssertTrue(envelope.options.defaults["maxLength"]?.isNull == true)
        XCTAssertEqual(envelope.options.resolvedDefaults["minLength"]?.integerValue, 4)
        XCTAssertTrue(envelope.argv.contains(source.bundleURL.path))
        XCTAssertTrue(envelope.argv.contains(outputBundle.path))

        assertNoTemporaryPaths(in: envelope)
        assertInput(source.fastqURL, isRecordedIn: envelope)
        try assertOutput(
            outputBundle.appendingPathComponent("read-ids.txt"),
            isRecordedIn: envelope
        )
        try assertOutput(
            outputBundle.appendingPathComponent("preview.fastq"),
            isRecordedIn: envelope
        )
    }

    func testQualityTrimDerivativeRecordsOptionsDefaultsAndTrimPayloads() async throws {
        let fixture = try FASTQDerivativeToolFixture(tools: [.fastp])
        defer { fixture.cleanup() }

        let source = try fixture.makeBundle(named: "trim-source")
        try fixture.writeFASTQ(
            [
                ("trim-1", "AACCGGTT"),
                ("trim-2", "TTGGCCAA"),
            ],
            to: source.fastqURL
        )

        let service = FASTQDerivativeService(runner: fixture.runner)
        let outputBundle = try await service.createDerivative(
            from: source.bundleURL,
            request: .qualityTrim(threshold: 25, windowSize: 5, mode: .cutBoth)
        )

        let envelope = try loadProvenance(from: outputBundle)
        XCTAssertEqual(envelope.workflowName, "lungfish fastq qualityTrim derivative")
        XCTAssertEqual(envelope.options.explicit["threshold"]?.integerValue, 25)
        XCTAssertEqual(envelope.options.explicit["windowSize"]?.integerValue, 5)
        XCTAssertEqual(envelope.options.explicit["mode"]?.stringValue, FASTQQualityTrimMode.cutBoth.rawValue)
        XCTAssertEqual(envelope.options.defaults["threshold"]?.integerValue, 20)
        XCTAssertEqual(envelope.options.defaults["windowSize"]?.integerValue, 4)
        XCTAssertEqual(envelope.options.defaults["mode"]?.stringValue, FASTQQualityTrimMode.cutRight.rawValue)
        XCTAssertEqual(envelope.options.resolvedDefaults["threshold"]?.integerValue, 25)
        XCTAssertEqual(envelope.options.resolvedDefaults["windowSize"]?.integerValue, 5)
        XCTAssertEqual(envelope.options.resolvedDefaults["mode"]?.stringValue, FASTQQualityTrimMode.cutBoth.rawValue)

        let fastpStep = try XCTUnwrap(envelope.steps.first { $0.toolName == "fastp" })
        XCTAssertTrue(fastpStep.argv.first?.hasSuffix("/fastp") == true)
        XCTAssertTrue(fastpStep.argv.contains("-i"))
        XCTAssertTrue(fastpStep.toolVersion.contains("0.23.4"))
        XCTAssertEqual(fastpStep.exitStatus, 0)
        XCTAssertNotNil(fastpStep.wallTimeSeconds)
        XCTAssertNotNil(fastpStep.completedAt)

        assertNoTemporaryPaths(in: envelope)
        try assertOutput(
            outputBundle.appendingPathComponent(FASTQBundle.trimPositionFilename),
            isRecordedIn: envelope
        )
        try assertOutput(
            outputBundle.appendingPathComponent("preview.fastq"),
            isRecordedIn: envelope
        )
    }

    func testPairedEndMergeDerivativeWritesMixedOutputProvenance() async throws {
        let fixture = try FASTQDerivativeToolFixture(tools: [.bbmerge])
        defer { fixture.cleanup() }

        let source = try fixture.makeBundle(named: "merge-source")
        try fixture.writeFASTQ(
            [
                ("pair-1/1", "ACGTACGT"),
                ("pair-1/2", "ACGTACGT"),
            ],
            to: source.fastqURL
        )
        FASTQMetadataStore.save(
            PersistedFASTQMetadata(ingestion: IngestionMetadata(pairingMode: .interleaved)),
            for: source.fastqURL
        )

        let service = FASTQDerivativeService(runner: fixture.runner)
        let outputBundle = try await service.createDerivative(
            from: source.bundleURL,
            request: .pairedEndMerge(strictness: .strict, minOverlap: 8)
        )

        let envelope = try loadProvenance(from: outputBundle)
        XCTAssertEqual(envelope.workflowName, "lungfish fastq pairedEndMerge derivative")
        XCTAssertEqual(envelope.options.explicit["strictness"]?.stringValue, FASTQMergeStrictness.strict.rawValue)
        XCTAssertEqual(envelope.options.explicit["minOverlap"]?.integerValue, 8)
        XCTAssertEqual(envelope.options.defaults["strictness"]?.stringValue, FASTQMergeStrictness.normal.rawValue)
        XCTAssertEqual(envelope.options.defaults["minOverlap"]?.integerValue, 12)

        assertNoTemporaryPaths(in: envelope)
        try assertOutput(
            outputBundle.appendingPathComponent("merged.fastq"),
            isRecordedIn: envelope
        )
        try assertOutput(
            outputBundle.appendingPathComponent(ReadManifest.filename),
            isRecordedIn: envelope
        )
    }

    func testDemultiplexDerivativeWritesProvenanceForEveryOutputBundle() async throws {
        let fixture = try FASTQDerivativeToolFixture(tools: [])
        defer { fixture.cleanup() }

        let forward = "ACGTACGT"
        let reverse = "TTGGAACC"
        let matchedInsert = String(repeating: "A", count: 2_100)
        let unassignedInsert = String(repeating: "G", count: 2_120)
        let source = try fixture.makeBundle(named: "demux-source")
        try fixture.writeFASTQ(
            [
                ("sample-read", forward + matchedInsert + reverseComplement(reverse)),
                ("unassigned-read", unassignedInsert),
            ],
            to: source.fastqURL
        )

        let kit = BarcodeKitDefinition(
            id: "custom-asymmetric",
            displayName: "Custom Asymmetric",
            vendor: "pacbio",
            isDualIndexed: true,
            pairingMode: .combinatorialDual,
            barcodes: [
                BarcodeEntry(id: "forward", i7Sequence: forward),
                BarcodeEntry(id: "reverse", i7Sequence: reverse),
            ]
        )
        let assignments = [
            FASTQSampleBarcodeAssignment(
                sampleID: "sample_a",
                forwardSequence: forward,
                reverseSequence: reverse
            ),
        ]

        let service = FASTQDerivativeService(runner: fixture.runner)
        _ = try await service.createDerivative(
            from: source.bundleURL,
            request: .demultiplex(
                kitID: kit.id,
                customCSVPath: nil,
                location: "bothEnds",
                symmetryMode: .asymmetric,
                maxDistanceFrom5Prime: 0,
                maxDistanceFrom3Prime: 0,
                errorRate: 0.0,
                trimBarcodes: false,
                sampleAssignments: assignments,
                kitOverride: kit
            )
        )

        let demuxDirectory = source.bundleURL.appendingPathComponent("demux", isDirectory: true)
        let outputBundles = try FileManager.default.contentsOfDirectory(
            at: demuxDirectory,
            includingPropertiesForKeys: nil
        )
            .filter { $0.pathExtension == FASTQBundle.directoryExtension }
        XCTAssertEqual(
            Set(outputBundles.map { $0.deletingPathExtension().lastPathComponent }),
            ["sample_a", "unassigned"]
        )

        for bundleURL in outputBundles {
            let envelope = try loadProvenance(from: bundleURL)
            XCTAssertEqual(envelope.workflowName, "lungfish fastq demultiplex derivative")
            XCTAssertEqual(envelope.options.explicit["kitID"]?.stringValue, kit.id)
            XCTAssertEqual(envelope.options.explicit["location"]?.stringValue, "bothEnds")
            XCTAssertEqual(envelope.options.explicit["symmetryMode"]?.stringValue, BarcodeSymmetryMode.asymmetric.rawValue)
            XCTAssertEqual(envelope.options.explicit["trimBarcodes"]?.booleanValue, false)
            XCTAssertTrue(envelope.argv.contains { pathsReferToSameFile($0, bundleURL.path) })
            assertNoTemporaryPaths(in: envelope)
            try assertOutput(bundleURL.appendingPathComponent("read-ids.txt"), isRecordedIn: envelope)
            try assertOutput(bundleURL.appendingPathComponent("preview.fastq"), isRecordedIn: envelope)
        }
    }

    func testDerivativeFailsAndCleansPartialBundleWhenProvenanceWriteFails() async throws {
        let fixture = try FASTQDerivativeToolFixture(tools: [.seqkit])
        defer { fixture.cleanup() }

        let source = try fixture.makeBundle(named: "cleanup-source")
        try fixture.writeFASTQ([("read-1", "ACGTACGT")], to: source.fastqURL)
        let service = FASTQDerivativeService(
            runner: fixture.runner,
            provenanceWriter: FailingDerivativeProvenanceWriter()
        )

        await XCTAssertThrowsErrorAsync(
            try await service.createDerivative(
                from: source.bundleURL,
                request: .lengthFilter(min: 4, max: nil)
            )
        )

        let derivativesDirectory = source.bundleURL.appendingPathComponent("derivatives", isDirectory: true)
        let derivativeBundles = (try? FileManager.default.contentsOfDirectory(
            at: derivativesDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        XCTAssertTrue(
            derivativeBundles.filter { $0.pathExtension == FASTQBundle.directoryExtension }.isEmpty,
            "A derivative bundle should not remain after provenance writing fails."
        )
    }

    func testBatchDerivativeProvenanceManifestDescriptorMatchesFinalBatchManifest() async throws {
        let fixture = try FASTQDerivativeToolFixture(tools: [.seqkit])
        defer { fixture.cleanup() }

        let source = try fixture.makeBundle(named: "batch-source")
        try fixture.writeFASTQ([("read-1", "ACGTACGT")], to: source.fastqURL)

        let service = FASTQDerivativeService(runner: fixture.runner)
        let result = try await service.createBatchDerivative(
            from: [source.bundleURL],
            request: .lengthFilter(min: 4, max: nil),
            commonParentDirectory: fixture.root
        )

        let outputBundle = try XCTUnwrap(result.outputBundleURLs.first)
        let manifest = try XCTUnwrap(FASTQBundle.loadDerivedManifest(in: outputBundle))
        XCTAssertEqual(manifest.batchOperationID, result.record.id)

        let envelope = try loadProvenance(from: outputBundle)
        try assertOutput(FASTQBundle.derivedManifestURL(in: outputBundle), isRecordedIn: envelope)
    }

    func testSubsampleProvenanceUsesHonestWorkflowReplayAndRecordsSeed() async throws {
        let fixture = try FASTQDerivativeToolFixture(tools: [.seqkit])
        defer { fixture.cleanup() }

        let source = try fixture.makeBundle(named: "subsample-source")
        try fixture.writeFASTQ(
            [
                ("read-1", "ACGTACGT"),
                ("read-2", "TTTTAAAA"),
            ],
            to: source.fastqURL
        )

        let service = FASTQDerivativeService(runner: fixture.runner)
        let outputBundle = try await service.createDerivative(
            from: source.bundleURL,
            request: .subsampleProportion(0.5)
        )

        let envelope = try loadProvenance(from: outputBundle)
        XCTAssertEqual(envelope.argv.first, "lungfish-app-workflow:fastq-derivative")
        XCTAssertFalse(Array(envelope.argv.prefix(3)) == ["Lungfish.app", "fastq", "derive"])

        let seed = try XCTUnwrap(envelope.options.resolvedDefaults["randomSeed"]?.integerValue)
        XCTAssertTrue(envelope.argv.contains("--random-seed"))
        XCTAssertTrue(envelope.argv.contains(String(seed)))
    }

    func testReferenceInputsAreRecordedWithChecksums() async throws {
        let fixture = try FASTQDerivativeToolFixture(tools: [.cutadapt, .seqkit])
        defer { fixture.cleanup() }

        let source = try fixture.makeBundle(named: "reference-source")
        try fixture.writeFASTQ([("read-1", "ACGTACGT")], to: source.fastqURL)

        let referenceURL = fixture.root.appendingPathComponent("adapters.fa")
        try ">adapter\nACGT\n".write(to: referenceURL, atomically: true, encoding: .utf8)

        let service = FASTQDerivativeService(runner: fixture.runner)
        let outputBundle = try await service.createDerivative(
            from: source.bundleURL,
            request: .sequencePresenceFilter(
                sequence: nil,
                fastaPath: referenceURL.path,
                searchEnd: .fivePrime,
                minOverlap: 3,
                errorRate: 0.1,
                keepMatched: true,
                searchReverseComplement: false
            )
        )

        let envelope = try loadProvenance(from: outputBundle)
        assertInput(referenceURL, isRecordedIn: envelope)
        let referenceDescriptor = try XCTUnwrap(
            envelope.files.first { $0.role == .input && pathsReferToSameFile($0.path, referenceURL.path) }
        )
        XCTAssertNotNil(referenceDescriptor.checksumSHA256)
        XCTAssertEqual(referenceDescriptor.fileSize, try ProvenanceFileHasher.fileSize(of: referenceURL))
    }

    func testOrientDerivativeCleansPartialBundlesWhenProvenanceWriteFails() async throws {
        let fixture = try FASTQDerivativeToolFixture(tools: [.seqkit, .vsearch])
        defer { fixture.cleanup() }

        let projectURL = fixture.root.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let source = try fixture.makeBundle(named: "orient-source", in: projectURL)
        try fixture.writeFASTQ(
            [
                ("read-1", "ACGT"),
                ("read-2", "TGCA"),
                ("read-3", "TTTT"),
            ],
            to: source.fastqURL
        )
        let referenceURL = fixture.root.appendingPathComponent("reference.fa")
        try ">ref\nACGT\n".write(to: referenceURL, atomically: true, encoding: .utf8)

        let service = FASTQDerivativeService(
            runner: fixture.runner,
            provenanceWriter: FailingDerivativeProvenanceWriter()
        )

        do {
            _ = try await service.createDerivative(
                from: source.bundleURL,
                request: .orient(
                    referenceURL: referenceURL,
                    wordLength: 11,
                    dbMask: "none",
                    saveUnoriented: true
                )
            )
            XCTFail("Expected orient provenance writing to fail")
        } catch {
            XCTAssertEqual((error as NSError).domain, "FASTQDerivativeServiceProvenanceTests")
        }

        let derivativesDirectory = source.bundleURL.appendingPathComponent("derivatives", isDirectory: true)
        let derivativeBundles = (try? FileManager.default.contentsOfDirectory(
            at: derivativesDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        XCTAssertTrue(
            derivativeBundles.filter { $0.pathExtension == FASTQBundle.directoryExtension }.isEmpty,
            "Orient and unoriented bundles should not remain after provenance writing fails."
        )
    }
}

private struct FailingDerivativeProvenanceWriter: FASTQDerivativeProvenanceWriting {
    func write(_ envelope: ProvenanceEnvelope, to directory: URL) throws -> URL {
        throw NSError(
            domain: "FASTQDerivativeServiceProvenanceTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "forced provenance failure"]
        )
    }
}

private func loadProvenance(from bundleURL: URL) throws -> ProvenanceEnvelope {
    let provenanceURL = bundleURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
    XCTAssertTrue(FileManager.default.fileExists(atPath: provenanceURL.path))
    return try ProvenanceEnvelopeReader.decode(Data(contentsOf: provenanceURL))
}

private func assertInput(
    _ url: URL,
    isRecordedIn envelope: ProvenanceEnvelope,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertTrue(
        envelope.files.contains { $0.role == .input && pathsReferToSameFile($0.path, url.path) },
        "Expected input \(url.path) in provenance files",
        file: file,
        line: line
    )
}

private func assertOutput(
    _ url: URL,
    isRecordedIn envelope: ProvenanceEnvelope,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    let output = try XCTUnwrap(
        envelope.outputs.first { pathsReferToSameFile($0.path, url.path) },
        "Expected output \(url.path) in provenance outputs",
        file: file,
        line: line
    )
    XCTAssertNotNil(output.checksumSHA256, file: file, line: line)
    XCTAssertEqual(output.fileSize, try ProvenanceFileHasher.fileSize(of: url), file: file, line: line)
    XCTAssertTrue(envelope.steps.contains { step in
        step.outputs.contains {
            pathsReferToSameFile($0.path, url.path) && $0.checksumSHA256 != nil && $0.fileSize != nil
        }
    }, file: file, line: line)
}

private func pathsReferToSameFile(_ lhs: String, _ rhs: String) -> Bool {
    URL(fileURLWithPath: lhs).standardizedFileURL.path == URL(fileURLWithPath: rhs).standardizedFileURL.path
}

private func assertNoTemporaryPaths(
    in envelope: ProvenanceEnvelope,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let durableValues = envelope.argv
        + (envelope.durableReplayArgv ?? [])
        + envelope.files.map(\.path)
        + envelope.outputs.map(\.path)
        + envelope.steps.flatMap { step in
            (step.durableReplayArgv ?? [])
                + step.inputs.map(\.path)
                + step.outputs.map(\.path)
        }
    for value in durableValues {
        XCTAssertFalse(value.contains("fastq-derive-"), file: file, line: line)
        XCTAssertFalse(value.contains("transformed.fastq"), file: file, line: line)
        XCTAssertFalse(value.contains("demux-output"), file: file, line: line)
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        // Expected.
    }
}

private final class FASTQDerivativeToolFixture {
    enum Tool {
        case seqkit
        case fastp
        case bbmerge
        case cutadapt
        case vsearch
    }

    let root: URL
    let runner: NativeToolRunner

    init(tools: [Tool]) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQDerivativeServiceProvenanceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let homeDirectory = root.appendingPathComponent("home", isDirectory: true)
        for tool in tools {
            switch tool {
            case .seqkit:
                try Self.install(script: Self.seqkitScript(), tool: "seqkit", environment: "seqkit", homeDirectory: homeDirectory)
            case .fastp:
                try Self.install(script: Self.fastpScript(), tool: "fastp", environment: "fastp", homeDirectory: homeDirectory)
            case .bbmerge:
                try Self.install(script: Self.bbmergeScript(), tool: "bbmerge.sh", environment: "bbtools", homeDirectory: homeDirectory)
            case .cutadapt:
                try Self.install(script: Self.cutadaptScript(), tool: "cutadapt", environment: "cutadapt", homeDirectory: homeDirectory)
            case .vsearch:
                try Self.install(script: Self.vsearchScript(), tool: "vsearch", environment: "vsearch", homeDirectory: homeDirectory)
            }
        }
        runner = NativeToolRunner(toolsDirectory: nil, homeDirectory: homeDirectory)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func makeBundle(named name: String, in directory: URL? = nil) throws -> (bundleURL: URL, fastqURL: URL) {
        let parent = directory ?? root
        let bundleURL = parent.appendingPathComponent("\(name).\(FASTQBundle.directoryExtension)", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        return (bundleURL, bundleURL.appendingPathComponent("reads.fastq"))
    }

    func writeFASTQ(_ records: [(String, String)], to url: URL) throws {
        let text = records.flatMap { id, sequence in
            ["@\(id)", sequence, "+", String(repeating: "I", count: sequence.count)]
        }.joined(separator: "\n") + "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func install(script: String, tool: String, environment: String, homeDirectory: URL) throws {
        let binURL = homeDirectory
            .appendingPathComponent(".lungfish/conda/envs/\(environment)/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)
        let toolURL = binURL.appendingPathComponent(tool)
        try script.write(to: toolURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: toolURL.path)
    }

    private static func seqkitScript() -> String {
        """
        #!/bin/sh
        if [ "$1" = "version" ]; then
          echo "seqkit v2.8.2"
          exit 0
        fi
        command="$1"
        shift
        input=""
        output=""
        names=0
        while [ "$#" -gt 0 ]; do
          case "$1" in
            -o)
              output="$2"
              shift 2
              ;;
            -m|-M|-j|-n|-p|-s)
              shift 2
              ;;
            -2)
              shift
              ;;
            --name|--only-id)
              names=1
              shift
              ;;
            -*)
              shift
              ;;
            *)
              input="$1"
              shift
              ;;
          esac
        done
        if [ "$command" = "seq" ] && [ "$names" = "1" ]; then
          if [ -n "$output" ]; then
            awk 'NR % 4 == 1 { sub(/^@/, ""); split($0, a, " "); print a[1] }' "$input" > "$output"
          else
            awk 'NR % 4 == 1 { sub(/^@/, ""); split($0, a, " "); print a[1] }' "$input"
          fi
          exit 0
        fi
        if [ "$command" = "seq" ] || [ "$command" = "head" ]; then
          if [ -n "$output" ]; then
            cp "$input" "$output"
          else
            cat "$input"
          fi
          exit 0
        fi
        if [ "$command" = "sample" ] || [ "$command" = "sample2" ]; then
          cp "$input" "$output"
          exit 0
        fi
        if [ "$command" = "grep" ]; then
          cp "$input" "$output"
          exit 0
        fi
        if [ "$command" = "stats" ]; then
          file="$input"
          printf 'file\tformat\ttype\tnum_seqs\tsum_len\tmin_len\tavg_len\tmax_len\n'
          printf '%s\tFASTQ\tDNA\t2\t8\t4\t4.0\t4\n' "$file"
          exit 0
        fi
        exit 1
        """
    }

    private static func fastpScript() -> String {
        """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          echo "fastp 0.23.4"
          exit 0
        fi
        input=""
        output=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            -i)
              input="$2"
              shift 2
              ;;
            -o)
              output="$2"
              shift 2
              ;;
            --json|--html|-w|-W|-M|--out2)
              shift 2
              ;;
            *)
              shift
              ;;
          esac
        done
        awk 'NR % 4 == 1 { print; next } NR % 4 == 2 { print substr($0, 2, length($0) - 2); next } NR % 4 == 3 { print; next } NR % 4 == 0 { print substr($0, 2, length($0) - 2); next }' "$input" > "$output"
        exit 0
        """
    }

    private static func bbmergeScript() -> String {
        """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          echo "BBMerge version 39.01"
          exit 0
        fi
        out=""
        for arg in "$@"; do
          case "$arg" in
            out=*)
              out="${arg#out=}"
              ;;
          esac
        done
        printf '@merged-1\\nACGTACGTACGT\\n+\\nIIIIIIIIIIII\\n' > "$out"
        exit 0
        """
    }

    private static func cutadaptScript() -> String {
        """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          echo "4.9"
          exit 0
        fi
        output=""
        input=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            -o)
              output="$2"
              shift 2
              ;;
            -e|--overlap|--action|--cores|-g|-a|-G|--pair-filter)
              shift 2
              ;;
            --discard-untrimmed|--discard-trimmed|--interleaved|--revcomp|--no-indels)
              shift
              ;;
            *)
              input="$1"
              shift
              ;;
          esac
        done
        cp "$input" "$output"
        exit 0
        """
    }

    private static func vsearchScript() -> String {
        """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          echo "vsearch v2.30.5"
          exit 0
        fi
        fastqout=""
        tabbedout=""
        notmatched=""
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --fastqout)
              fastqout="$2"
              shift 2
              ;;
            --tabbedout)
              tabbedout="$2"
              shift 2
              ;;
            --notmatched)
              notmatched="$2"
              shift 2
              ;;
            *)
              shift
              ;;
          esac
        done
        printf '@read-1\\nACGT\\n+\\nIIII\\n@read-2\\nTGCA\\n+\\nIIII\\n' > "$fastqout"
        printf 'read-1\\t+\\tref\\nread-2\\t-\\tref\\nread-3\\t?\\t*\\n' > "$tabbedout"
        if [ -n "$notmatched" ]; then
          printf '@read-3\\nTTTT\\n+\\nIIII\\n' > "$notmatched"
        fi
        printf 'vsearch completed\\n' >&2
        exit 0
        """
    }
}

private func reverseComplement(_ sequence: String) -> String {
    let complement: [Character: Character] = [
        "A": "T",
        "C": "G",
        "G": "C",
        "T": "A",
    ]
    return String(sequence.reversed().map { complement[$0] ?? $0 })
}
