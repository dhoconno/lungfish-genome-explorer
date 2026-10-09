import Foundation
import XCTest
@testable import LungfishWorkflow
import LungfishIO

final class Primer3DesignPipelineTests: XCTestCase {
    private let options = Primer3DesignOptions(
        productSizeMin: 100, productSizeMax: 240, targetStart: 11, targetEnd: 30,
        pairCount: 2, primerMinSize: 18, primerOptSize: 20, primerMaxSize: 24,
        primerMinTm: 57, primerOptTm: 60, primerMaxTm: 63,
        primerMinGC: 30, primerMaxGC: 70, pickInternalOligo: true)

    func testPreparationFailurePrecedesInputReadsAndCannotPublish() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("not-read-yet.fasta")
        let output = root.appendingPathComponent("result.lungfishprimeranalysis")
        let request = Primer3DesignRequest(inputURLs: [input], selections: [.fastaRecord(inputURL: input, recordIndex: 0)],
            destinationURL: output, options: options,
            invocation: .init(argv: ["lungfish"], callerVersion: "test", explicitOptions: [:], runtimeIdentity: .init()),
            expectedInputChecksums: [input: String(repeating: "0", count: 64)])
        let pipeline = Primer3DesignPipeline(runner: { _ in
            XCTFail("Preparation failure must prevent execution")
            throw CancellationError()
        }, runtimePreparer: { _ in
            NativeProcessObservation.onEvent?(.output(stream: .stdout, line: "Preparing runtime"))
            throw PrimerDesignManagedRuntime.Unavailable(message: "Runtime preparation failed")
        })
        let observed = expectation(description: "Native observer survives detached worker")
        do {
            _ = try await NativeProcessObservation.$onEvent.withValue({ event in
                if case .output(_, "Preparing runtime") = event { observed.fulfill() }
            }) { try await pipeline.run(request: request) }
            XCTFail("Expected preparation failure")
        } catch { XCTAssertEqual(error.localizedDescription, "Runtime preparation failed") }
        await fulfillment(of: [observed], timeout: 5)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testDyeQPCRPresetAppliesPublishedDesignRules() {
        let dye = Primer3DesignOptions.preset(.qpcrDye)
        XCTAssertEqual(dye.assayMode, .qpcrDye)
        XCTAssertEqual(dye.productSizeMin, 70); XCTAssertEqual(dye.productSizeMax, 150)
        XCTAssertEqual(dye.primerMinTm, 58); XCTAssertEqual(dye.primerOptTm, 60); XCTAssertEqual(dye.primerMaxTm, 62)
        XCTAssertEqual(dye.pairMaxTmDifference, 1)
        XCTAssertEqual(dye.primerMinGC, 40); XCTAssertEqual(dye.primerMaxGC, 60)
        XCTAssertEqual(dye.primerMinSize, 18); XCTAssertEqual(dye.primerOptSize, 20); XCTAssertEqual(dye.primerMaxSize, 24)
        XCTAssertEqual(dye.primerMaxEndGC, 2)
        XCTAssertEqual(dye.primerGCClamp, 1)
        XCTAssertEqual(dye.primerMaxPolyX, 4)
        XCTAssertEqual(dye.primerMaxSelfAnyTh, 40); XCTAssertEqual(dye.primerMaxSelfEndTh, 30)
        XCTAssertEqual(dye.pairMaxComplAnyTh, 40); XCTAssertEqual(dye.pairMaxComplEndTh, 30)
        XCTAssertFalse(dye.pickInternalOligo)
        XCTAssertEqual(dye.pairCount, 5)

        let pcr = Primer3DesignOptions.preset(.pcr)
        XCTAssertEqual(pcr, Primer3DesignOptions(
            productSizeMin: 100, productSizeMax: 400, targetStart: nil, targetEnd: nil, pairCount: 5,
            primerMinSize: 18, primerOptSize: 20, primerMaxSize: 27, primerMinTm: 57, primerOptTm: 60, primerMaxTm: 63,
            primerMinGC: 20, primerMaxGC: 80, pickInternalOligo: false))
        XCTAssertNil(pcr.pairMaxTmDifference); XCTAssertNil(pcr.primerMaxEndGC); XCTAssertNil(pcr.primerGCClamp)
        XCTAssertNil(pcr.primerMaxPolyX); XCTAssertNil(pcr.primerMaxSelfEndTh); XCTAssertNil(pcr.pairMaxComplEndTh)
        let probe = Primer3DesignOptions.preset(.qpcrProbe)
        XCTAssertTrue(probe.pickInternalOligo)
        // The probe assay is a qPCR assay, so it takes the dye primer rules, not PCR's.
        XCTAssertEqual(probe.productSizeMin, dye.productSizeMin)
        XCTAssertNil(pcr.probe)
        XCTAssertNil(dye.probe)
    }

    /// A hydrolysis probe must melt above the primers to be bound before extension
    /// reaches it. The preset used to fall back to PCR, which sent no PRIMER_INTERNAL_*
    /// rule at all and let Primer3 pick a probe at its own 60 C default.
    func testProbeQPCRPresetSendsPrimerRulesAndAProbeWindowAboveThem() {
        let probe = Primer3DesignOptions.preset(.qpcrProbe)
        let dye = Primer3DesignOptions.preset(.qpcrDye)
        XCTAssertEqual(probe.assayMode, .qpcrProbe)
        XCTAssertTrue(probe.pickInternalOligo)

        // Primer rules identical to the dye preset.
        for (probeValue, dyeValue) in [(probe.productSizeMin, dye.productSizeMin),
                                       (probe.productSizeMax, dye.productSizeMax),
                                       (probe.primerMinSize, dye.primerMinSize),
                                       (probe.primerOptSize, dye.primerOptSize),
                                       (probe.primerMaxSize, dye.primerMaxSize)] {
            XCTAssertEqual(probeValue, dyeValue)
        }
        XCTAssertEqual(probe.primerMinTm, dye.primerMinTm)
        XCTAssertEqual(probe.primerOptTm, dye.primerOptTm)
        XCTAssertEqual(probe.primerMaxTm, dye.primerMaxTm)
        XCTAssertEqual(probe.primerMinGC, dye.primerMinGC)
        XCTAssertEqual(probe.primerMaxGC, dye.primerMaxGC)
        XCTAssertEqual(probe.pairMaxTmDifference, dye.pairMaxTmDifference)
        XCTAssertEqual(probe.primerMaxEndGC, dye.primerMaxEndGC)
        XCTAssertEqual(probe.primerGCClamp, dye.primerGCClamp)
        XCTAssertEqual(probe.primerMaxPolyX, dye.primerMaxPolyX)
        XCTAssertEqual(probe.primerMaxSelfAnyTh, dye.primerMaxSelfAnyTh)
        XCTAssertEqual(probe.primerMaxSelfEndTh, dye.primerMaxSelfEndTh)
        XCTAssertEqual(probe.pairMaxComplAnyTh, dye.pairMaxComplAnyTh)
        XCTAssertEqual(probe.pairMaxComplEndTh, dye.pairMaxComplEndTh)

        guard let window = probe.probe else { return XCTFail("The probe preset must carry probe rules.") }
        XCTAssertEqual(window.probeMinTm, 64)
        XCTAssertEqual(window.probeOptTm, 67)
        XCTAssertEqual(window.probeMaxTm, 70)
        XCTAssertEqual(window.probeMinSize, 20)
        XCTAssertEqual(window.probeOptSize, 25)
        XCTAssertEqual(window.probeMaxSize, 30)
        XCTAssertEqual(window.probeMinGC, 40)
        XCTAssertEqual(window.probeOptGC, 60)
        XCTAssertEqual(window.probeMaxGC, 80)
        // 3, not the primers' 4: a probe is GC-rich by design, so a 4-base cap
        // readily admits GGGG, and a G run quenches the reporter dye.
        XCTAssertEqual(window.probeMaxPolyX, 3)
        XCTAssertEqual(window.probeMustMatchFivePrime, "hnnnn")
        // The whole probe window sits at least 5 and at most 10 C above the primers.
        XCTAssertGreaterThanOrEqual(window.probeOptTm - probe.primerOptTm, 5)
        XCTAssertLessThanOrEqual(window.probeOptTm - probe.primerOptTm, 10)
        XCTAssertGreaterThan(window.probeMinTm, probe.primerMaxTm)
    }

    func testBoulderInputAddsInternalOligoTagsOnlyForTheProbePreset() throws {
        let template = Primer3PreparedTemplate(
            inputID: UUID(), resultID: UUID(), title: "mhc", sequence: String(repeating: "ACGT", count: 80),
            sourceURL: URL(fileURLWithPath: "/tmp/mhc.fa"), sourceIndex: 0, sourceRecordID: "mhc",
            sourceKind: .fasta, bindingSitePolicy: .templateOnly, alignmentToTemplate: nil, excludedRegions: [])
        // PRIMER_PICK_INTERNAL_OLIGO is always present, so check the rule tags only.
        for mode in [Primer3AssayMode.pcr, .qpcrDye] {
            let text = try Primer3BoulderWriter.makeInput(templates: [template], options: .preset(mode))
            for key in ["PRIMER_INTERNAL_MIN_TM", "PRIMER_INTERNAL_OPT_TM", "PRIMER_INTERNAL_MAX_TM",
                        "PRIMER_INTERNAL_MIN_SIZE", "PRIMER_INTERNAL_OPT_SIZE", "PRIMER_INTERNAL_MAX_SIZE",
                        "PRIMER_INTERNAL_MIN_GC", "PRIMER_INTERNAL_OPT_GC_PERCENT", "PRIMER_INTERNAL_MAX_GC",
                        "PRIMER_INTERNAL_MAX_POLY_X", "PRIMER_INTERNAL_MUST_MATCH_FIVE_PRIME"] {
                XCTAssertFalse(text.contains(key), "\(mode.rawValue) \(key)")
            }
            XCTAssertTrue(text.contains("PRIMER_PICK_INTERNAL_OLIGO=0\n"), mode.rawValue)
        }
        let probe = try Primer3BoulderWriter.makeInput(templates: [template], options: .preset(.qpcrProbe))
        for line in ["PRIMER_PICK_INTERNAL_OLIGO=1", "PRIMER_PRODUCT_SIZE_RANGE=70-150",
                     // The configured 64 C minimum is raised to primerMaxTm + 5 = 67 C,
                     // so the probe is bound before extension reaches it.
                     "PRIMER_INTERNAL_MIN_TM=67.0", "PRIMER_INTERNAL_OPT_TM=67.0", "PRIMER_INTERNAL_MAX_TM=70.0",
                     "PRIMER_INTERNAL_MIN_SIZE=20", "PRIMER_INTERNAL_OPT_SIZE=25", "PRIMER_INTERNAL_MAX_SIZE=30",
                     "PRIMER_INTERNAL_MIN_GC=40.0", "PRIMER_INTERNAL_OPT_GC_PERCENT=60.0", "PRIMER_INTERNAL_MAX_GC=80.0",
                     "PRIMER_INTERNAL_MAX_POLY_X=3", "PRIMER_INTERNAL_MUST_MATCH_FIVE_PRIME=hnnnn"] {
            XCTAssertTrue(probe.contains(line + "\n"), line)
        }
        XCTAssertTrue(probe.hasSuffix("PRIMER_EXPLAIN_FLAG=1\n=\n"))
        // The probe rules survive a round trip, so saved analyses reload them.
        let decoded = try JSONDecoder().decode(
            Primer3DesignOptions.self, from: JSONEncoder().encode(Primer3DesignOptions.preset(.qpcrProbe)))
        XCTAssertEqual(decoded, Primer3DesignOptions.preset(.qpcrProbe))
    }

    func testBoulderInputAddsDyeRulesOnlyForTheDyePreset() throws {
        let template = Primer3PreparedTemplate(
            inputID: UUID(), resultID: UUID(), title: "mhc", sequence: String(repeating: "ACGT", count: 80),
            sourceURL: URL(fileURLWithPath: "/tmp/mhc.fa"), sourceIndex: 0, sourceRecordID: "mhc",
            sourceKind: .fasta, bindingSitePolicy: .templateOnly, alignmentToTemplate: nil, excludedRegions: [])
        let pcr = try Primer3BoulderWriter.makeInput(templates: [template], options: .preset(.pcr))
        for key in ["PRIMER_PAIR_MAX_DIFF_TM", "PRIMER_MAX_END_GC", "PRIMER_GC_CLAMP", "PRIMER_MAX_POLY_X",
                    "PRIMER_MAX_SELF_ANY_TH", "PRIMER_MAX_SELF_END_TH", "PRIMER_PAIR_MAX_COMPL_ANY_TH", "PRIMER_PAIR_MAX_COMPL_END_TH"] {
            XCTAssertFalse(pcr.contains(key), key)
        }
        XCTAssertTrue(pcr.contains("PRIMER_PRODUCT_SIZE_RANGE=100-400\n"))
        let dye = try Primer3BoulderWriter.makeInput(templates: [template], options: .preset(.qpcrDye))
        for line in ["PRIMER_PRODUCT_SIZE_RANGE=70-150", "PRIMER_MIN_TM=58.0", "PRIMER_OPT_TM=60.0", "PRIMER_MAX_TM=62.0",
                     "PRIMER_PAIR_MAX_DIFF_TM=1.0", "PRIMER_MIN_GC=40.0", "PRIMER_MAX_GC=60.0",
                     "PRIMER_MIN_SIZE=18", "PRIMER_OPT_SIZE=20", "PRIMER_MAX_SIZE=24",
                     "PRIMER_MAX_END_GC=2", "PRIMER_GC_CLAMP=1", "PRIMER_MAX_POLY_X=4",
                     "PRIMER_MAX_SELF_ANY_TH=40.0", "PRIMER_MAX_SELF_END_TH=30.0",
                     "PRIMER_PAIR_MAX_COMPL_ANY_TH=40.0", "PRIMER_PAIR_MAX_COMPL_END_TH=30.0",
                     "PRIMER_PICK_INTERNAL_OLIGO=0"] {
            XCTAssertTrue(dye.contains(line + "\n"), line)
        }
        XCTAssertTrue(dye.hasSuffix("PRIMER_EXPLAIN_FLAG=1\n=\n"))
    }

    func testAssayModeAndDyeRulesSurviveCodableRoundTripAndOlderRecordsDecodeAsPCR() throws {
        let dye = Primer3DesignOptions.preset(.qpcrDye)
        let decoded = try JSONDecoder().decode(Primer3DesignOptions.self, from: JSONEncoder().encode(dye))
        XCTAssertEqual(decoded, dye)
        let legacy = Data("""
        {"productSizeMin":100,"productSizeMax":400,"pairCount":5,"primerMinSize":18,"primerOptSize":20,"primerMaxSize":27,"primerMinTm":57,"primerOptTm":60,"primerMaxTm":63,"primerMinGC":20,"primerMaxGC":80,"pickInternalOligo":false}
        """.utf8)
        let older = try JSONDecoder().decode(Primer3DesignOptions.self, from: legacy)
        // A record written before the probe Tm offset existed decodes with it
        // absent, so reloading it cannot silently move its probe window.
        XCTAssertNil(older.probeMinTmOffsetOverPrimers)
        XCTAssertEqual(older, .preset(.pcr, probeMinTmOffsetOverPrimers: nil))
    }

    func testBoulderRecordUsesOneBasedInclusiveTargetAndAllResolvedOptions() throws {
        let template = Primer3PreparedTemplate(
            inputID: UUID(), resultID: UUID(), title: "mhc sample", sequence: String(repeating: "ACGT", count: 80),
            sourceURL: URL(fileURLWithPath: "/tmp/mhc.fa"), sourceIndex: 0, sourceRecordID: "mhc sample",
            sourceKind: .fasta, bindingSitePolicy: .templateOnly,
            alignmentToTemplate: nil, excludedRegions: [])
        let text = try Primer3BoulderWriter.makeInput(templates: [template], options: options)
        XCTAssertTrue(text.contains("SEQUENCE_TARGET=10,20\n"))
        XCTAssertTrue(text.contains("PRIMER_PRODUCT_SIZE_RANGE=100-240\n"))
        XCTAssertTrue(text.contains("PRIMER_PICK_INTERNAL_OLIGO=1\n"))
        XCTAssertTrue(text.contains("PRIMER_FIRST_BASE_INDEX=0\n"))
        XCTAssertTrue(text.contains("PRIMER_NUM_RETURN=2\n"))
    }

    func testConservativeExclusionsApplyToPrimersAndInternalOligo() throws {
        let template = Primer3PreparedTemplate(inputID: UUID(), resultID: UUID(), title: "aligned", sequence: String(repeating: "ACGT", count: 80), sourceURL: URL(fileURLWithPath: "/tmp/a.lungfishmsa"), sourceIndex: 1, sourceRecordID: "row-1", sourceKind: .msa, bindingSitePolicy: .excludeVariableAndGappedColumns, alignmentToTemplate: [0], excludedRegions: [2..<5])
        let text = try Primer3BoulderWriter.makeInput(templates: [template], options: options)
        XCTAssertTrue(text.contains("SEQUENCE_TEMPLATE=ACNNNCGT"))
        XCTAssertTrue(text.contains("PRIMER_MAX_NS_ACCEPTED=0\n"))
        XCTAssertTrue(text.contains("PRIMER_INTERNAL_MAX_NS_ACCEPTED=0\n"))
        XCTAssertFalse(text.contains("SEQUENCE_EXCLUDED_REGION="))
        XCTAssertFalse(text.contains("SEQUENCE_INTERNAL_EXCLUDED_REGION="))
    }

    func testConservativeMaskHasNoPrimer3ExcludedRegionElementLimit() throws {
        let sequence = String(repeating: "ACGT", count: 300)
        let exclusions = stride(from: 0, to: sequence.count, by: 2).map { $0..<($0 + 1) }
        let template = Primer3PreparedTemplate(inputID: UUID(), resultID: UUID(), title: "many variable sites", sequence: sequence, sourceURL: URL(fileURLWithPath: "/tmp/a.lungfishmsa"), sourceIndex: 0, sourceRecordID: "row-0", sourceKind: .msa, bindingSitePolicy: .excludeVariableAndGappedColumns, alignmentToTemplate: nil, excludedRegions: exclusions)
        let text = try Primer3BoulderWriter.makeInput(templates: [template], options: options)
        let masked = try XCTUnwrap(text.split(separator: "\n").first { $0.hasPrefix("SEQUENCE_TEMPLATE=") }).dropFirst("SEQUENCE_TEMPLATE=".count)
        XCTAssertEqual(masked.filter { $0 == "N" }.count, exclusions.count)
        XCTAssertFalse(text.contains("SEQUENCE_EXCLUDED_REGION="))
    }

    func testValidationRejectsNonFiniteAndUnpairedTargetBeforeExecution() async throws {
        let runRecorder = Primer3RunRecorder()
        let runner: Primer3DesignRunner = { _ in runRecorder.markRun(); throw CancellationError() }
        let pipeline = Primer3DesignPipeline(runner: runner)
        let bad = Primer3DesignOptions(
            productSizeMin: 100, productSizeMax: 200, targetStart: 2, targetEnd: nil,
            pairCount: 1, primerMinSize: 18, primerOptSize: 20, primerMaxSize: 24,
            primerMinTm: .nan, primerOptTm: 60, primerMaxTm: 63,
            primerMinGC: 20, primerMaxGC: 80, pickInternalOligo: false)
        let request = request(options: bad, selections: [])
        do { _ = try await pipeline.run(request: request) } catch { }
        XCTAssertFalse(runRecorder.didRun)
    }

    /// Every product must span the whole target, so a target longer than the maximum
    /// product size makes Primer3 consider zero pairs while the run still exits cleanly.
    /// Validation has to reject it up front and name both lengths.
    func testValidationRejectsTargetLongerThanTheMaximumProductSize() throws {
        let dye = Primer3AssayDefaults.defaults(for: .qpcrDye)
        let tooLong = Primer3DesignOptions.preset(.qpcrDye, targetStart: 205, targetEnd: 474)
        XCTAssertGreaterThan(474 - 205 + 1, dye.productSizeMax)
        do {
            try Primer3DesignPipeline.validate(tooLong)
            XCTFail("Expected an over-long target to be rejected.")
        } catch let error as Primer3DesignError {
            let message = "\(error)"
            XCTAssertTrue(message.contains("270"), message)
            XCTAssertTrue(message.contains("\(dye.productSizeMax)"), message)
        }

        // A target exactly at the maximum product size still designs.
        XCTAssertNoThrow(try Primer3DesignPipeline.validate(
            Primer3DesignOptions.preset(.qpcrDye, targetStart: 1, targetEnd: dye.productSizeMax)))
        XCTAssertNoThrow(try Primer3DesignPipeline.validate(
            Primer3DesignOptions.preset(.pcr, targetStart: 205, targetEnd: 474)))
    }

    func testParserRejectsMalformedCoordinateAndParsesRightOrientationAndInternalOligo() throws {
        let id = UUID()
        let raw = """
        SEQUENCE_ID=\(id.uuidString)
        PRIMER_PAIR_NUM_RETURNED=1
        PRIMER_LEFT_0=5,20
        PRIMER_LEFT_0_SEQUENCE=ACGTACGTACGTACGTACGT
        PRIMER_LEFT_0_TM=60.1
        PRIMER_LEFT_0_GC_PERCENT=50
        PRIMER_RIGHT_0=99,21
        PRIMER_RIGHT_0_SEQUENCE=TGCATGCATGCATGCATGCAT
        PRIMER_RIGHT_0_TM=60.2
        PRIMER_RIGHT_0_GC_PERCENT=48
        PRIMER_INTERNAL_0=40,18
        PRIMER_INTERNAL_0_SEQUENCE=AAAAAAAAAAAAAAAAAA
        PRIMER_INTERNAL_0_TM=59
        PRIMER_INTERNAL_0_GC_PERCENT=33
        PRIMER_PAIR_0_PRODUCT_SIZE=95
        =
        """
        let parsed = try Primer3BoulderParser.parse(raw, expectedResultIDs: [id])
        XCTAssertEqual(parsed[0].pairs[0].left.start, 5)
        XCTAssertEqual(parsed[0].pairs[0].right.start, 79)
        XCTAssertEqual(parsed[0].pairs[0].right.end, 100)
        XCTAssertEqual(parsed[0].pairs[0].right.orientation, .reverse)
        XCTAssertEqual(parsed[0].pairs[0].internalOligo?.start, 40)
        XCTAssertThrowsError(try Primer3BoulderParser.parse(raw.replacingOccurrences(of: "99,21", with: "bad"), expectedResultIDs: [id]))
    }

    func testNativeArgumentsUsePrimer3OutputOptionAndSinglePositionalInput() {
        let arguments = Primer3NativeRunner.arguments(
            inputURL: URL(fileURLWithPath: "/tmp/in.boulder"),
            outputURL: URL(fileURLWithPath: "/tmp/out.boulder"))
        XCTAssertEqual(arguments, ["--output=/tmp/out.boulder", "/tmp/in.boulder"])
    }

    func testConservativeMSAExcludesAmbiguousVariableAndSelectedRowGapBoundaries() throws {
        let rows = ["ACGTACGT", "ACNT-CGT", "ACGTTCGT"]
        let mapped = try Primer3InputLoader.prepareAlignedRows(rows, selectedRow: 1)
        XCTAssertEqual(mapped.alignmentToTemplate, [0,1,2,3,nil,4,5,6])
        XCTAssertEqual(mapped.excludedRegions, [2..<5])
    }

    func testPipelinePublishesRelocatableRawNormalizedAnnotationAndBothProvenances() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fasta = root.appendingPathComponent("duplicate.fa")
        try Data((">same\n" + String(repeating: "ACGT", count: 80) + "\n>same\n" + String(repeating: "TGCA", count: 80) + "\n").utf8).write(to: fasta)
        let destination = root.appendingPathComponent("design.lungfishprimeranalysis")
        let runner: Primer3DesignRunner = { invocation in
            let input = try String(contentsOf: invocation.inputURL, encoding: .utf8)
            let id = try XCTUnwrap(input.split(separator: "\n").first(where: { $0.hasPrefix("SEQUENCE_ID=") })).dropFirst("SEQUENCE_ID=".count)
            let template = String(try XCTUnwrap(input.split(separator: "\n").first { $0.hasPrefix("SEQUENCE_TEMPLATE=") }).dropFirst("SEQUENCE_TEMPLATE=".count))
            let output = Self.output(resultID: String(id), template: template)
            try Data(output.utf8).write(to: invocation.outputURL)
            return Primer3RunReceipt(argv: ["/managed/primer3_core", "--output=\(invocation.outputURL.path)", invocation.inputURL.path], stdout: "", stderr: "notice", exitStatus: 0, version: "2.6.1", runtimeIdentity: .init(executablePath: "/managed/primer3_core", condaEnvironment: "primer3"), startedAt: Date(), endedAt: Date())
        }
        let request = Primer3DesignRequest(inputURLs: [fasta], selections: [.fastaRecord(inputURL: fasta, recordIndex: 1)], destinationURL: destination, options: options, invocation: PrimerAnalysisWrapperInvocation(argv: ["lungfish", "primer3"], callerVersion: "test", explicitOptions: [:], runtimeIdentity: .init()), expectedInputChecksums: [fasta: try Primer3InputLoader.fingerprint(fasta)])
        let publishedURL = try await Primer3DesignPipeline(runner: runner).run(request: request)
        let bundle = try PrimerAnalysisBundle.load(from: publishedURL)
        XCTAssertEqual(bundle.manifest.inputs.count, 1)
        XCTAssertTrue(bundle.manifest.artifacts.contains { $0.relativePath == "results/primer3-normalized-v1.json" })
        XCTAssertTrue(bundle.manifest.artifacts.contains { $0.role == "toolProvenance" })
        XCTAssertTrue(bundle.manifest.artifacts.contains { $0.relativePath.hasPrefix("annotations/") })
        let normalizedURL = try bundle.artifactURL(forRelativePath: "results/primer3-normalized-v1.json")
        let normalized = try JSONDecoder().decode(Primer3NormalizedResults.self, from: Data(contentsOf: normalizedURL))
        XCTAssertEqual(normalized.results[0].inputID, bundle.manifest.inputs[0].id)
        XCTAssertEqual(normalized.results[0].pairs[0].right.orientation, .reverse)
        try FileManager.default.removeItem(at: fasta)
        XCTAssertNoThrow(try PrimerAnalysisBundle.load(from: publishedURL))
    }

    func testRunnerFailureAndCancellationNeverPublishBundle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fasta = root.appendingPathComponent("mhc.fa")
        try Data((">mhc\n" + String(repeating: "ACGT", count: 80) + "\n").utf8).write(to: fasta)
        let checksum = try Primer3InputLoader.fingerprint(fasta)
        for cancellation in [false, true] {
            let destination = root.appendingPathComponent(UUID().uuidString + ".lungfishprimeranalysis")
            let pipeline = Primer3DesignPipeline(runner: { _ in
                if cancellation { throw CancellationError() }
                throw Primer3DesignError.executionFailed(2, "bad")
            })
            let request = Primer3DesignRequest(inputURLs: [fasta], selections: [.fastaRecord(inputURL: fasta, recordIndex: 0)], destinationURL: destination, options: options, invocation: PrimerAnalysisWrapperInvocation(argv: ["lungfish"], callerVersion: "test", explicitOptions: [:], runtimeIdentity: .init()), expectedInputChecksums: [fasta: checksum])
            do { _ = try await pipeline.run(request: request); XCTFail("expected failure") } catch { }
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    func testNativeMSASelectionPublishesSourceMapsAndConservativeBoulderExclusions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var selected = Array(String(repeating: "ACGT", count: 80)); selected[4] = "-"
        var comparison = Array(String(repeating: "ACGT", count: 80)); comparison[2] = "N"; comparison[4] = "T"
        let msa = root.appendingPathComponent("mhc.lungfishmsa")
        try Self.writeSyntheticMSA(msa, rows: [String(selected), String(comparison)])
        try Data("canonical-upstream-provenance".utf8).write(to: msa.appendingPathComponent(".lungfish-provenance.json"))
        try FileManager.default.createDirectory(at: msa.appendingPathComponent("alignment"), withIntermediateDirectories: true)
        try Data("unaligned-source".utf8).write(to: msa.appendingPathComponent("alignment/input.unaligned.fasta"))
        let destination = root.appendingPathComponent("msa-design.lungfishprimeranalysis")
        let runner: Primer3DesignRunner = { invocation in
            let input = try String(contentsOf: invocation.inputURL, encoding: .utf8)
            let id = String(try XCTUnwrap(input.split(separator: "\n").first { $0.hasPrefix("SEQUENCE_ID=") }).dropFirst("SEQUENCE_ID=".count))
            let template = String(try XCTUnwrap(input.split(separator: "\n").first { $0.hasPrefix("SEQUENCE_TEMPLATE=") }).dropFirst("SEQUENCE_TEMPLATE=".count))
            try Data(Self.output(resultID: id, template: template).utf8).write(to: invocation.outputURL)
            return Primer3RunReceipt(argv: ["/managed/primer3_core", "--output=\(invocation.outputURL.path)", invocation.inputURL.path], stdout: "", stderr: "", exitStatus: 0, version: "2.6.1", runtimeIdentity: .init(executablePath: "/managed/primer3_core", condaEnvironment: "primer3"), startedAt: Date(), endedAt: Date())
        }
        let request = Primer3DesignRequest(inputURLs: [msa], selections: [.msaTemplate(inputURL: msa, rowIndex: 0, bindingSitePolicy: .excludeVariableAndGappedColumns)], destinationURL: destination, options: options, invocation: PrimerAnalysisWrapperInvocation(argv: ["lungfish", "primer3"], callerVersion: "test", explicitOptions: [:], runtimeIdentity: .init()), expectedInputChecksums: [msa: try Primer3InputLoader.fingerprint(msa)])
        let publishedURL = try await Primer3DesignPipeline(runner: runner).run(request: request)
        let bundle = try PrimerAnalysisBundle.load(from: publishedURL)
        XCTAssertTrue(bundle.manifest.artifacts.contains { $0.relativePath.contains("metadata/coordinate-maps.json") })
        XCTAssertTrue(bundle.manifest.artifacts.contains { $0.relativePath.hasSuffix("/.lungfish-provenance.json") })
        XCTAssertTrue(bundle.manifest.artifacts.contains { $0.relativePath.hasSuffix("/alignment/input.unaligned.fasta") })
        let boulder = try String(contentsOf: try bundle.artifactURL(forRelativePath: "native/primer3-input.boulder"), encoding: .utf8)
        XCTAssertTrue(boulder.contains("PRIMER_MAX_NS_ACCEPTED=0"))
        XCTAssertTrue(boulder.contains("PRIMER_INTERNAL_MAX_NS_ACCEPTED=0"))
        XCTAssertFalse(boulder.contains("SEQUENCE_EXCLUDED_REGION="))
        let normalized = try JSONDecoder().decode(Primer3NormalizedResults.self, from: Data(contentsOf: try bundle.artifactURL(forRelativePath: "results/primer3-normalized-v1.json")))
        let result = try XCTUnwrap(normalized.results.first)
        let pair = try XCTUnwrap(result.pairs.first)
        for oligo in [pair.left, pair.right, try XCTUnwrap(pair.internalOligo)] {
            XCTAssertFalse(result.excludedRegions.contains { oligo.start < $0.end && $0.start < oligo.end })
            let start = result.templateSequence.index(result.templateSequence.startIndex, offsetBy: oligo.start)
            let end = result.templateSequence.index(result.templateSequence.startIndex, offsetBy: oligo.end)
            let source = String(result.templateSequence[start..<end])
            let expected = oligo.orientation == .forward ? source : Self.reverseComplement(source)
            XCTAssertEqual(oligo.sequence, expected)
        }
    }

    func testNativeMSARejectsRowMetadataAttachedToDifferentPrimarySequence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let msa = root.appendingPathComponent("contradictory.lungfishmsa")
        try Self.writeSyntheticMSA(msa, rows: ["ACGT", "TGCA"])
        let rowsURL = msa.appendingPathComponent("metadata/rows.json")
        var rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: rowsURL)) as? [[String: Any]])
        rows[0]["checksumSHA256"] = String(repeating: "0", count: 64)
        try JSONSerialization.data(withJSONObject: rows).write(to: rowsURL)
        let bundle = try MultipleSequenceAlignmentBundle.load(from: msa)
        let aligned = try Primer3InputLoader.readAlignedRows(at: msa.appendingPathComponent("alignment/primary.aligned.fasta"))
        XCTAssertThrowsError(try Primer3InputLoader.validateAlignedRows(aligned, bundle: bundle))
    }

    private func request(options: Primer3DesignOptions, selections: [Primer3TemplateSelection]) -> Primer3DesignRequest {
        Primer3DesignRequest(
            inputURLs: [], selections: selections,
            destinationURL: URL(fileURLWithPath: "/tmp/x.lungfishprimeranalysis"), options: options,
            invocation: PrimerAnalysisWrapperInvocation(argv: ["lungfish"], callerVersion: "test", explicitOptions: [:], runtimeIdentity: .init()))
    }

    private static func output(resultID: String, template: String) -> String {
        let left = String(template.dropFirst(5).prefix(20))
        let rightTemplate = String(template.dropFirst(79).prefix(21))
        let right = String(rightTemplate.reversed().map { base in
            switch base { case "A": "T"; case "C": "G"; case "G": "C"; case "T": "A"; default: "N" }
        })
        let internalOligo = String(template.dropFirst(40).prefix(18))
        return """
        SEQUENCE_ID=\(resultID)
        PRIMER_PAIR_NUM_RETURNED=1
        PRIMER_LEFT_0=5,20
        PRIMER_LEFT_0_SEQUENCE=\(left)
        PRIMER_LEFT_0_TM=60.1
        PRIMER_LEFT_0_GC_PERCENT=50
        PRIMER_RIGHT_0=99,21
        PRIMER_RIGHT_0_SEQUENCE=\(right)
        PRIMER_RIGHT_0_TM=60.2
        PRIMER_RIGHT_0_GC_PERCENT=48
        PRIMER_INTERNAL_0=40,18
        PRIMER_INTERNAL_0_SEQUENCE=\(internalOligo)
        PRIMER_INTERNAL_0_TM=59
        PRIMER_INTERNAL_0_GC_PERCENT=33
        PRIMER_PAIR_0_PRODUCT_SIZE=95
        =
        """
    }

    private static func reverseComplement(_ sequence: String) -> String {
        String(sequence.reversed().map { base in
            switch base { case "A": "T"; case "C": "G"; case "G": "C"; case "T": "A"; default: "N" }
        })
    }

    private static func writeSyntheticMSA(_ url: URL, rows sequences: [String]) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url.appendingPathComponent("alignment"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: url.appendingPathComponent("metadata"), withIntermediateDirectories: true)
        let fasta = zip(["row-a", "row-b"], sequences).map { ">\($0.0)\n\($0.1)" }.joined(separator: "\n") + "\n"
        try Data(fasta.utf8).write(to: url.appendingPathComponent("alignment/primary.aligned.fasta"))
        let rowNames = ["row-a", "row-b"]
        let rows: [[String: Any]] = sequences.enumerated().map { index, sequence in
            ["id": "row-\(index)", "sourceName": rowNames[index], "displayName": "duplicate", "order": index,
             "alphabet": "dna", "alignedLength": sequence.count, "ungappedLength": sequence.filter { $0 != "-" }.count,
             "gapCount": sequence.filter { $0 == "-" }.count, "ambiguousCount": sequence.filter { !"ACGT-".contains($0) }.count,
             "checksumSHA256": MultipleSequenceAlignmentBundle.sha256Hex(for: Data(sequence.utf8)), "metadata": [:]]
        }
        try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys]).write(to: url.appendingPathComponent("metadata/rows.json"))
        let maps: [[String: Any]] = sequences.enumerated().map { index, sequence in
            var next = 0; var aligned: [Any] = []; var ungapped: [Int] = []
            for (column, base) in sequence.enumerated() {
                if base == "-" { aligned.append(NSNull()) } else { aligned.append(next); ungapped.append(column); next += 1 }
            }
            return ["rowID": "row-\(index)", "rowName": rowNames[index], "alignedLength": sequence.count,
                    "ungappedLength": next, "alignmentToUngapped": aligned, "ungappedToAlignment": ungapped]
        }
        try JSONSerialization.data(withJSONObject: maps, options: [.sortedKeys]).write(to: url.appendingPathComponent("metadata/coordinate-maps.json"))
        let manifest: [String: Any] = ["schemaVersion": 1, "bundleKind": "multiple-sequence-alignment", "identifier": UUID().uuidString,
            "name": "synthetic MHC alignment", "createdAt": "2026-09-10T00:00:00Z", "sourceFormat": "aligned-fasta",
            "sourceFileName": "synthetic.fasta", "rowCount": 2, "alignedLength": sequences[0].count, "alphabet": "dna",
            "gapAlphabet": ["-", "."], "warnings": [], "capabilities": [], "consensus": sequences[0],
            "variableSiteCount": 2, "parsimonyInformativeSiteCount": 0, "checksums": [:], "fileSizes": [:]]
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: url.appendingPathComponent("manifest.json"))
    }
}

private final class Primer3RunRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func markRun() { lock.lock(); value = true; lock.unlock() }
    var didRun: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
