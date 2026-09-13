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
        }, runtimePreparer: { _ in throw PrimerDesignManagedRuntime.Unavailable(message: "Runtime preparation failed") })
        do { _ = try await pipeline.run(request: request); XCTFail("Expected preparation failure") }
        catch { XCTAssertEqual(error.localizedDescription, "Runtime preparation failed") }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
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
