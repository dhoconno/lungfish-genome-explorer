import Foundation
import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class PrimerSchemePipelineTests: XCTestCase {
    func testAdapterDirectoryDigestUsesCanonicalPOSIXRelativeRecords() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let licenses = root.appendingPathComponent("LICENSES", isDirectory: true)
        let cache = root.appendingPathComponent("__pycache__", isDirectory: true)
        try FileManager.default.createDirectory(at: licenses, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("license\n".utf8).write(to: licenses.appendingPathComponent("license.txt"))
        try Data("print(1)\n".utf8).write(to: root.appendingPathComponent("run.py"))
        try Data("ignored".utf8).write(to: cache.appendingPathComponent("common.pyc"))

        XCTAssertEqual(
            try PrimerSchemeAdapterResources.directorySHA256(root),
            "dd197bf9b8ca34ae3308bbb4672bf05798e3bfd3f6298d9faf0f82c508e4704a")
    }

    func testWireRequestUsesCanonicalLowercaseUUIDsAndPassesBundledPythonValidation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let input = root.appendingPathComponent("input.fasta")
        try Data(">row\nACGT\n".utf8).write(to: input)
        let output = root.appendingPathComponent("adapter-output")
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let options = PrimerSchemeDesignOptions(
            engine: .varvamp, mode: .single, grouping: .independent,
            nominalAmpliconLength: 400, minimumAmpliconLength: 360,
            maximumAmpliconLength: 440, workers: 1, varvamp: .init())
        let request = PrimerSchemeAdapterRequest(
            engine: .varvamp, engineVersion: "1.3.2",
            analysisID: id, runID: id, resultID: id, mode: .single,
            grouping: .perInput,
            inputs: [.init(id: id, label: "row", path: input.path)],
            outputDirectory: output.path, options: options.adapterOptions)
        let requestURL = root.appendingPathComponent("request.json")
        try JSONEncoder().encode(request).write(to: requestURL)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: requestURL)) as? [String: Any])
        XCTAssertEqual(object["analysisID"] as? String, id.uuidString.lowercased())
        XCTAssertEqual((object["inputs"] as? [[String: Any]])?.first?["id"] as? String,
                       id.uuidString.lowercased())

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import json,sys;sys.path.insert(0,sys.argv[1]);from common import validate_request;validate_request(json.load(open(sys.argv[2])))",
                             try PrimerSchemeAdapterResources.bundledV1URL().path, requestURL.path]
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let diagnostic = String(data: stderr.fileHandleForReading.readDataToEndOfFile(),
                                encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, diagnostic)
    }

    func testRawAlignedFASTAPreservesEveryRowAndSourceBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let input = root.appendingPathComponent("duplicate-names.fasta")
        let bytes = Data(">same\nACGTACGT\n>same\nTGCATGCA\n".utf8)
        try bytes.write(to: input)
        let inputID = UUID()
        let prepared = try PrimerSchemeInputPreparation.prepare(
            inputURLs: [input], inputIDs: [input: inputID],
            expectedInputChecksums: [input: try Primer3InputLoader.fingerprint(input)],
            scratchRoot: root.appendingPathComponent("scratch"))
        XCTAssertEqual(prepared.count, 1)
        XCTAssertEqual(try Data(contentsOf: prepared[0].adapterInputURL), bytes)
        XCTAssertEqual(prepared[0].rows.map(\.title), ["same", "same"])
        XCTAssertEqual(prepared[0].rows.map(\.index), [0, 1])
    }

    func testRawFASTARejectsUnequalRowsInsteadOfUsingFirstRecord() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let input = root.appendingPathComponent("unaligned.fasta")
        try Data(">a\nACGT\n>b\nACGTA\n".utf8).write(to: input)
        XCTAssertThrowsError(try PrimerSchemeInputPreparation.prepare(
            inputURLs: [input], inputIDs: [input: UUID()],
            expectedInputChecksums: [input: try Primer3InputLoader.fingerprint(input)],
            scratchRoot: root.appendingPathComponent("scratch"))) { error in
            XCTAssertTrue(error.localizedDescription.lowercased().contains("equal"),
                          error.localizedDescription)
        }
    }

    func testNativeMSASnapshotsBundleButExecutesExactPrimaryAlignment() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(
                "Fixtures/alignment/sarscov2-mafft-e2e.lungfish/Multiple Sequence Alignments/sars-cov-2-genomes-mafft.lungfishmsa")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let inputID = UUID()
        let prepared = try PrimerSchemeInputPreparation.prepare(
            inputURLs: [source], inputIDs: [source: inputID],
            expectedInputChecksums: [source: try Primer3InputLoader.fingerprint(source)],
            scratchRoot: root)
        XCTAssertEqual(
            try Data(contentsOf: prepared[0].adapterInputURL),
            try Data(contentsOf: source.appendingPathComponent("alignment/primary.aligned.fasta")))
        XCTAssertTrue(prepared[0].sourceArtifactPaths.contains(
            "source-inputs/\(inputID.uuidString)/source.lungfishmsa/manifest.json"))
    }

    func testNativeReferenceRequiresExactlyOneSequence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("multi.lungfishref")
        let fasta = bundle.appendingPathComponent("genome/sequence.fa")
        try FileManager.default.createDirectory(at: fasta.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(">a\nACGT\n>b\nTGCA\n".utf8).write(to: fasta)
        let manifest = BundleManifest(
            name: "Multi", identifier: "org.lungfish.tests.multi",
            source: SourceInfo(organism: "Synthetic", assembly: "test"),
            genome: GenomeInfo(path: "genome/sequence.fa", indexPath: "genome/sequence.fa.fai",
                               totalLength: 8, chromosomes: []))
        try manifest.save(to: bundle)
        XCTAssertThrowsError(try PrimerSchemeInputPreparation.prepare(
            inputURLs: [bundle], inputIDs: [bundle: UUID()],
            expectedInputChecksums: [bundle: try Primer3InputLoader.fingerprint(bundle)],
            scratchRoot: root.appendingPathComponent("scratch")))
    }

    func testSnapshotsCompleteBlastPrefixAndRewritesExecutedOption() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let prefix = root.appendingPathComponent("db/example")
        try FileManager.default.createDirectory(
            at: prefix.deletingLastPathComponent(), withIntermediateDirectories: true)
        for suffix in ["nhr", "nin", "nsq"] {
            try Data("component-\(suffix)".utf8).write(
                to: URL(fileURLWithPath: prefix.path + "." + suffix))
        }
        let options = PrimerSchemeDesignOptions(
            engine: .varvamp, mode: .single, grouping: .independent,
            nominalAmpliconLength: 400, minimumAmpliconLength: 360,
            maximumAmpliconLength: 440, workers: 1,
            varvamp: .init(blastDatabasePath: prefix.path))
        let prepared = try PrimerSchemeInputPreparation.prepareAuxiliaryInputs(
            options: options, scratchRoot: root.appendingPathComponent("scratch"))
        let executedPrefix = try XCTUnwrap(prepared.options.varvamp?.blastDatabasePath)
        XCTAssertNotEqual(executedPrefix, prefix.path)
        XCTAssertTrue(executedPrefix.hasSuffix("/example"))
        XCTAssertEqual(prepared.artifacts.filter { $0.role == "blastDatabase" }.count, 3)
        XCTAssertEqual(prepared.executedToStoredPaths[prefix.path],
                       String(executedPrefix.dropFirst(root.appendingPathComponent("scratch").path.count + 1)))
    }

    func testRejectsIncompleteOrAliasBlastDatabase() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let prefix = root.appendingPathComponent("example")
        try Data("partial".utf8).write(to: URL(fileURLWithPath: prefix.path + ".nin"))
        func options(_ path: String) -> PrimerSchemeDesignOptions {
            .init(engine: .varvamp, mode: .single, grouping: .independent,
                  nominalAmpliconLength: 400, minimumAmpliconLength: 360,
                  maximumAmpliconLength: 440, workers: 1,
                  varvamp: .init(blastDatabasePath: path))
        }
        XCTAssertThrowsError(try PrimerSchemeInputPreparation.prepareAuxiliaryInputs(
            options: options(prefix.path), scratchRoot: root.appendingPathComponent("partial")))
        try Data("alias".utf8).write(to: URL(fileURLWithPath: prefix.path + ".nal"))
        XCTAssertThrowsError(try PrimerSchemeInputPreparation.prepareAuxiliaryInputs(
            options: options(prefix.path), scratchRoot: root.appendingPathComponent("alias"))) { error in
            XCTAssertTrue(error.localizedDescription.lowercased().contains("alias"))
        }
    }

    func testSnapshotsV5MetadataAlongsideNumberedBlastVolumes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let prefix = root.appendingPathComponent("example")
        for suffix in ["ndb", "njs", "nog", "nos", "not", "ntf", "nto",
                       "00.nhr", "00.nin", "00.nsq", "01.nhr", "01.nin", "01.nsq"] {
            try Data(suffix.utf8).write(to: URL(fileURLWithPath: prefix.path + "." + suffix))
        }
        let options = PrimerSchemeDesignOptions(
            engine: .varvamp, mode: .single, grouping: .independent,
            nominalAmpliconLength: 400, minimumAmpliconLength: 360,
            maximumAmpliconLength: 440, workers: 1,
            varvamp: .init(blastDatabasePath: prefix.path))
        let prepared = try PrimerSchemeInputPreparation.prepareAuxiliaryInputs(
            options: options, scratchRoot: root.appendingPathComponent("scratch"))
        XCTAssertEqual(prepared.artifacts.filter { $0.role == "blastDatabase" }.count, 13)
    }

    func testPublishesValidTiledResultWithDurableCanonicalProjection() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let pipeline = fixture.pipeline { command in
            try fixture.writeAdapterSuccess(command: command, mode: .tiled)
            return fixture.execution(for: command)
        }
        let output = try await pipeline.run(request: fixture.request(options: fixture.tiledOptions))
        let bundle = try PrimerAnalysisBundle.load(from: output)
        XCTAssertTrue(bundle.manifest.artifacts.contains {
            $0.relativePath == "results/primer-schemes-v1.json"
        })
        let document = try JSONDecoder().decode(
            PrimerSchemeResultsDocument.self,
            from: Data(contentsOf: output.appendingPathComponent("results/primer-schemes-v1.json")))
        let target = try XCTUnwrap(document.results.first?.targets.first)
        let projection = try JSONDecoder().decode(
            PrimerBindingProjection.self,
            from: Data(contentsOf: output.appendingPathComponent(target.bindingProjectionPath)))
        XCTAssertEqual(projection.sourcePath,
                       "source-inputs/\(fixture.inputID.uuidString)/source.fasta")
        XCTAssertFalse(projection.sourcePath.contains(".primer-scheme-"))

        let relocatedParent = fixture.root.appendingPathComponent("Relocated Bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: relocatedParent, withIntermediateDirectories: true)
        let relocated = relocatedParent.appendingPathComponent(output.lastPathComponent)
        try FileManager.default.moveItem(at: output, to: relocated)
        _ = try PrimerAnalysisBundle.load(from: relocated)
        let relocatedDocument = try JSONDecoder().decode(
            PrimerSchemeResultsDocument.self,
            from: Data(contentsOf: relocated.appendingPathComponent(
                PrimerSchemeResultsDocument.storedRelativePath)))
        let relocatedMapPath = try XCTUnwrap(
            relocatedDocument.results.first?.targets.first?.bindingProjectionPath)
        let relocatedProjection = try JSONDecoder().decode(
            PrimerBindingProjection.self,
            from: Data(contentsOf: relocated.appendingPathComponent(relocatedMapPath)))
        XCTAssertNoThrow(try relocatedDocument.validateStored(
            knownInputIDs: [fixture.inputID],
            projections: [relocatedMapPath: relocatedProjection]))
    }

    func testPublishesProbeBearingAlternativeQPCRResult() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let pipeline = fixture.pipeline { command in
            try fixture.writeAdapterSuccess(command: command, mode: .qpcr,
                                            alternative: true, includeProbe: true)
            return fixture.execution(for: command)
        }
        let output = try await pipeline.run(request: fixture.request(options: fixture.qpcrOptions))
        let document = try JSONDecoder().decode(
            PrimerSchemeResultsDocument.self,
            from: Data(contentsOf: output.appendingPathComponent("results/primer-schemes-v1.json")))
        let target = try XCTUnwrap(document.results.first?.targets.first)
        XCTAssertEqual(target.assays.first?.status, .alternative)
        XCTAssertEqual(target.assays.first?.rank, 2)
        XCTAssertEqual(target.oligos.filter { $0.role == .probe }.count, 1)
    }

    func testRejectsInvalidSpanAtomically() async throws {
        try await assertRejected(mutation: .invalidSpan)
    }

    func testRejectsMalformedBindingMapAtomically() async throws {
        try await assertRejected(mutation: .malformedMap)
    }

    func testRejectsQPCRMissingProbeAtomically() async throws {
        try await assertRejected(options: { $0.qpcrOptions }, mutation: .missingProbe)
    }

    func testRejectsMismatchedInputAndResultUUIDsAtomically() async throws {
        try await assertRejected(mutation: .mismatchedIDs)
    }

    func testRejectsDuplicateOligoNamesAtomically() async throws {
        try await assertRejected(mutation: .duplicateNames)
    }

    func testRejectsCorruptedAdapterArtifactHashAtomically() async throws {
        try await assertRejected(mutation: .corruptedHash)
    }

    func testNonzeroChildRetainsDiagnosticAndDoesNotPublish() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let pipeline = fixture.pipeline { command in
            PrimerSchemeAdapterExecution(
                argv: [command.executableURL.path] + command.arguments,
                stdout: "", stderr: #"{"error":{"code":"no_feasible_design","message":"no pair"}}"#,
                exitStatus: 7, runtime: fixture.runtime,
                startedAt: Date(timeIntervalSince1970: 1),
                endedAt: Date(timeIntervalSince1970: 2))
        }
        do {
            _ = try await pipeline.run(request: fixture.request(options: fixture.tiledOptions))
            XCTFail("Nonzero adapter exit must fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("no pair"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("7"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains(".primer-scheme-failure-\(fixture.runID.uuidString)"),
                          error.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        let diagnostics = fixture.root.appendingPathComponent(
            ".primer-scheme-failure-\(fixture.runID.uuidString)", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: diagnostics.appendingPathComponent("request.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: diagnostics.appendingPathComponent("adapter/run.py").path))
    }

    func testCancellationStopsRunnerAndDoesNotPublish() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let started = expectation(description: "runner started")
        let pipeline = fixture.pipeline { _ in
            started.fulfill()
            try await Task.sleep(nanoseconds: 30_000_000_000)
            throw XCTSkip("unreachable")
        }
        let task = Task { try await pipeline.run(request: fixture.request(options: fixture.tiledOptions)) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled pipeline must throw")
        } catch is CancellationError {
        } catch {
            XCTAssertTrue(error is CancellationError, error.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    func testDestinationCollisionFailsBeforeRunner() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.destination,
                                                withIntermediateDirectories: false)
        let pipeline = fixture.pipeline { _ in
            XCTFail("Runner must not start for a destination collision")
            throw CocoaError(.fileWriteFileExists)
        }
        await XCTAssertThrowsErrorAsync(
            try await pipeline.run(request: fixture.request(options: fixture.tiledOptions)))
    }

    func testPreservesUnrecognizedNativeFilesByteForByte() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let bytes = Data([0, 1, 2, 3, 255, 10, 0])
        let pipeline = fixture.pipeline { command in
            try fixture.writeAdapterSuccess(command: command, mode: .tiled,
                                            unrecognizedBytes: bytes)
            return fixture.execution(for: command)
        }
        let output = try await pipeline.run(request: fixture.request(options: fixture.tiledOptions))
        let stored = output.appendingPathComponent("native/adapter-output/native/unrecognized.bin")
        XCTAssertEqual(try Data(contentsOf: stored), bytes)
        let bundle = try PrimerAnalysisBundle.load(from: output)
        XCTAssertEqual(bundle.manifest.artifacts.first {
            $0.relativePath == "native/adapter-output/native/unrecognized.bin"
        }?.byteSize, UInt64(bytes.count))
    }

    func testInputChecksumMismatchFailsBeforeAdapterExecution() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let pipeline = fixture.pipeline { _ in
            XCTFail("Runner must not execute after input mutation")
            throw CocoaError(.fileReadCorruptFile)
        }
        var request = fixture.request(options: fixture.tiledOptions)
        request = request.replacingExpectedChecksums([fixture.inputURL: String(repeating: "0", count: 64)])
        await XCTAssertThrowsErrorAsync(try await pipeline.run(request: request))
    }

    private func assertRejected(
        options: @escaping @Sendable (Fixture) -> PrimerSchemeDesignOptions = { $0.tiledOptions },
        mutation: Fixture.Mutation
    ) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let pipeline = fixture.pipeline { command in
            try fixture.writeAdapterSuccess(command: command, mode: options(fixture).mode,
                                            mutation: mutation)
            return fixture.execution(for: command)
        }
        do {
            _ = try await pipeline.run(request: fixture.request(options: options(fixture)))
            XCTFail("Invalid native output must be rejected")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains(
                    ".primer-scheme-failure-\(fixture.runID.uuidString)"),
                error.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(
            ".primer-scheme-failure-\(fixture.runID.uuidString)").path))
    }
}

private final class Fixture: @unchecked Sendable {
    enum Mutation { case none, invalidSpan, malformedMap, missingProbe, mismatchedIDs, duplicateNames, corruptedHash }

    let root: URL
    let inputURL: URL
    let destination: URL
    let executableURL: URL
    let adapterSourceURL: URL
    let analysisID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let runID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    let resultID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    let inputID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
    let targetID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
    let assayID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
    let forwardID = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
    let reverseID = UUID(uuidString: "88888888-8888-8888-8888-888888888888")!
    let probeID = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!
    let runtime = ProvenanceRuntimeIdentity(executablePath: "/fixture/python")

    init() throws {
        let systemTemporary = FileManager.default.temporaryDirectory
        let canonicalTemporary = systemTemporary.path.hasPrefix("/var/")
            ? URL(fileURLWithPath: "/private" + systemTemporary.path, isDirectory: true)
            : systemTemporary
        root = canonicalTemporary.appendingPathComponent(UUID().uuidString)
        inputURL = root.appendingPathComponent("input.fasta")
        destination = root.appendingPathComponent("result.lungfishprimeranalysis")
        executableURL = root.appendingPathComponent("environment/bin/python")
        adapterSourceURL = root.appendingPathComponent("adapter-v1", isDirectory: true)
        try FileManager.default.createDirectory(at: adapterSourceURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: executableURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/usr/bin/env python3\n".utf8).write(to: executableURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executableURL.path)
        for name in ["run.py", "common.py", "olivar_adapter.py", "varvamp_adapter.py"] {
            try Data("# lge adapter v1 \(name)\n".utf8).write(
                to: adapterSourceURL.appendingPathComponent(name))
        }
        try Data("{}\n".utf8).write(to: adapterSourceURL.appendingPathComponent("contract.json"))
        try Data((">row-a\n" + String(repeating: "ACGT", count: 25) + "\n").utf8).write(to: inputURL)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    var tiledOptions: PrimerSchemeDesignOptions {
        .init(engine: .varvamp, mode: .tiled, grouping: .independent,
              nominalAmpliconLength: 80, minimumAmpliconLength: 70,
              maximumAmpliconLength: 90, workers: 1, varvamp: .init())
    }

    var qpcrOptions: PrimerSchemeDesignOptions {
        .init(engine: .varvamp, mode: .qpcr, grouping: .independent,
              nominalAmpliconLength: 80, minimumAmpliconLength: 70,
              maximumAmpliconLength: 90, workers: 1,
              varvamp: .init(cumulativeConsensusThreshold: 0.9))
    }

    func pipeline(
        runner: @escaping PrimerSchemeAdapterRunner
    ) -> PrimerSchemeDesignPipeline {
        PrimerSchemeDesignPipeline(
            runner: runner,
            writer: PrimerAnalysisBundleWriter(
                provenanceWriter: ProvenanceWriter(signingProvider: nil)),
            runtimePreparer: nil,
            adapterSourceProvider: { self.adapterSourceURL })
    }

    func request(options: PrimerSchemeDesignOptions) -> PrimerSchemeDesignRequest {
        let checksum = try! Primer3InputLoader.fingerprint(inputURL)
        return .init(
            analysisID: analysisID, runID: runID, resultID: resultID,
            inputURLs: [inputURL], destinationURL: destination, options: options,
            invocation: .init(
                argv: ["lungfish", "primer", "design", options.engine.rawValue],
                callerVersion: "test", explicitOptions: options.provenanceOptions,
                runtimeIdentity: runtime),
            expectedInputChecksums: [inputURL: checksum],
            executableURL: executableURL,
            inputIDs: [inputURL: inputID])
    }

    func execution(for command: PrimerSchemeAdapterCommand) -> PrimerSchemeAdapterExecution {
        .init(argv: [command.executableURL.path] + command.arguments,
              stdout: "adapter ok", stderr: "", exitStatus: 0, runtime: runtime,
              startedAt: Date(timeIntervalSince1970: 1), endedAt: Date(timeIntervalSince1970: 2))
    }

    func writeAdapterSuccess(
        command: PrimerSchemeAdapterCommand, mode: PrimerSchemeMode,
        alternative: Bool = false, includeProbe: Bool = false,
        mutation: Mutation = .none, unrecognizedBytes: Data? = nil
    ) throws {
        let output = command.outputDirectoryURL
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let generated = output.appendingPathComponent("generated/reference.fasta")
        let map = output.appendingPathComponent("maps/target.json")
        let stdout = output.appendingPathComponent("logs/native-stdout.txt")
        let stderr = output.appendingPathComponent("logs/native-stderr.txt")
        let replay = output.appendingPathComponent("replay/request-v1.json")
        for directory in [generated.deletingLastPathComponent(), map.deletingLastPathComponent(),
                          stdout.deletingLastPathComponent(), replay.deletingLastPathComponent(),
                          output.appendingPathComponent("native")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data((">generated-ref\n" + String(repeating: "ACGT", count: 25) + "\n").utf8).write(to: generated)
        try Data("native stdout\n".utf8).write(to: stdout)
        try Data().write(to: stderr)
        try Data("{}\n".utf8).write(to: replay)
        if let unrecognizedBytes {
            try unrecognizedBytes.write(to: output.appendingPathComponent("native/unrecognized.bin"))
        }

        let requestInput = command.request.inputs[0]
        let mapBlocks: [[String: Any]] = mutation == .malformedMap ? [
            ["generatedStart": 0, "generatedEnd": 60, "sourceStart": 0, "sourceEnd": 60, "kind": "mapped"],
            ["generatedStart": 50, "generatedEnd": 100, "sourceStart": 50, "sourceEnd": 100, "kind": "mapped"],
        ] : [
            ["generatedStart": 0, "generatedEnd": 100, "sourceStart": 0, "sourceEnd": 100, "kind": "mapped"],
        ]
        try writeJSON([
            "schemaVersion": 1, "coordinateConvention": "zeroBasedHalfOpen",
            "sourceInputID": requestInput.id.uuidString, "sourcePath": requestInput.path,
            "generatedReferencePath": "generated/reference.fasta",
            "sourceLength": 100, "generatedLength": 100, "blocks": mapBlocks,
        ], to: map)

        var correctArtifacts = try [
            artifact(path: "generated/reference.fasta", kind: "generatedReference", root: output),
            artifact(path: "maps/target.json", kind: "bindingProjection", root: output),
            artifact(path: "logs/native-stdout.txt", kind: "stdout", root: output),
            artifact(path: "logs/native-stderr.txt", kind: "stderr", root: output),
            artifact(path: "replay/request-v1.json", kind: "requestSnapshot", root: output),
        ]
        if unrecognizedBytes != nil {
            correctArtifacts.append(try artifact(
                path: "native/unrecognized.bin", kind: "native", root: output))
        }
        var resultArtifacts = correctArtifacts
        if mutation == .corruptedHash { resultArtifacts[0]["sha256"] = String(repeating: "0", count: 64) }

        var oligos: [[String: Any]] = [
            oligo(id: forwardID, name: "LEFT_1", role: "forward", sequence: "ACGTACGTAC",
                  start: 10, end: 20, strand: "+", mode: mode),
            oligo(id: reverseID, name: mutation == .duplicateNames ? "LEFT_1" : "RIGHT_1",
                  role: "reverse", sequence: "TGCATGCATG", start: 80, end: 90,
                  strand: "-", mode: mode),
        ]
        if includeProbe && mutation != .missingProbe {
            oligos.append(oligo(id: probeID, name: "PROBE_1", role: "probe",
                                sequence: "ACGTRYSWKM", start: 40, end: 50,
                                strand: "-", mode: mode))
        }
        let members = oligos.map { $0["id"] as! String }
        let sourceInputID = mutation == .mismatchedIDs ? UUID().uuidString : requestInput.id.uuidString
        let assayEnd = mutation == .invalidSpan ? 101 : 90
        let target: [String: Any] = [
            "id": targetID.uuidString, "label": "target",
            "referencePath": "generated/reference.fasta", "referenceID": "generated-ref",
            "referenceLength": 100, "sourceInputID": sourceInputID,
            "bindingProjectionPath": "maps/target.json",
            "assays": [[
                "id": assayID.uuidString, "start": 10, "end": assayEnd,
                "memberIDs": members, "pool": mode == .tiled ? "1" : NSNull(),
                "status": alternative ? "alternative" : "selected",
                "rank": alternative ? 2 : NSNull(), "nativeMetadata": [:],
            ]],
            "oligos": oligos,
        ]

        let provenance = output.appendingPathComponent("provenance-v1.json")
        let runPy = command.adapterDirectoryURL.appendingPathComponent("run.py")
        let environmentRoot = command.executableURL.deletingLastPathComponent().deletingLastPathComponent()
        let packageRecord = environmentRoot.appendingPathComponent(
            "conda-meta/\(command.request.engine.rawValue)-\(command.request.engineVersion)-test.json")
        try FileManager.default.createDirectory(
            at: packageRecord.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: packageRecord)
        let inputHash = try ProvenanceFileHasher.sha256(of: URL(fileURLWithPath: requestInput.path))
        let inputSize = try FileManager.default.attributesOfItem(atPath: requestInput.path)[.size] as! NSNumber
        let requestOptions = command.request.options.mapValues(jsonObject)
        var resolvedOptions = requestOptions
        resolvedOptions["adapterResolution"] = ["fixture": true]
        let distribution = command.request.engine == .olivar
            ? "bioconda::olivar=1.3.3=pyhdfd78af_3"
            : "bioconda::varvamp=1.3.2=pyhdfd78af_0"
        try writeJSON([
            "schemaVersion": 1, "adapterVersion": "1.0.0",
            "adapterSHA256": try PrimerSchemeAdapterResources.directorySHA256(
                command.adapterDirectoryURL),
            "engine": command.request.engine.rawValue,
            "engineVersion": command.request.engineVersion,
            "analysisID": command.request.analysisID.uuidString,
            "runID": command.request.runID.uuidString,
            "resultID": command.request.resultID.uuidString,
            "command": [
                "executable": command.executableURL.path,
                "argv": [command.executableURL.path] + command.arguments,
                "replayCommand": "fixture replay", "workingDirectory": command.workingDirectoryURL.path,
                "environment": command.environment,
                "nativeInvocations": command.request.engine == .olivar ? [] : [["fixture-native"]],
                "pathMappings": [["kind": "prefix", "historicalPrefix": command.workingDirectoryURL.path,
                                  "durablePrefix": output.path, "durableBase": "outputDirectory",
                                  "durableRelativePrefix": ".", "excludedHistoricalSubpaths": ["cache"]]],
                "durableReplay": ["kind": "adapterRequestTemplate",
                    "requestSnapshot": try artifact(path: "replay/request-v1.json",
                                                     kind: "requestSnapshot", root: output)],
            ],
            "settings": ["supplied": requestOptions, "resolved": resolvedOptions],
            "runtime": [
                "pythonExecutable": command.executableURL.path, "pythonVersion": "3.13.0",
                "platform": "fixture", "implementation": "CPython",
                "engineModulePath": runPy.path,
                "sourceVerification": [["path": runPy.path,
                    "sha256": try ProvenanceFileHasher.sha256(of: runPy),
                    "expectedSHA256": try ProvenanceFileHasher.sha256(of: runPy),
                    "byteSize": try ProvenanceFileHasher.fileSize(of: runPy)]],
                "environmentPrefix": environmentRoot.path,
                "distribution": distribution,
                "condaPackageRecord": [
                    "path": packageRecord.path,
                    "sha256": try ProvenanceFileHasher.sha256(of: packageRecord),
                    "byteSize": try ProvenanceFileHasher.fileSize(of: packageRecord),
                    "name": command.request.engine.rawValue,
                    "version": command.request.engineVersion,
                    "build": command.request.engine == .olivar ? "pyhdfd78af_3" : "pyhdfd78af_0",
                    "channel": "bioconda", "subdir": "noarch",
                    "url": "https://conda.anaconda.org/bioconda/noarch/fixture.conda",
                ],
            ],
            "inputs": [["id": requestInput.id.uuidString, "path": requestInput.path,
                         "sha256": inputHash, "byteSize": inputSize.intValue]],
            "auxiliaryInputs": [],
            "inputIntegrity": [
                "checkedBeforeExecution": true, "checkedAfterExecution": true,
                "unchanged": true,
                "postExecution": [["id": requestInput.id.uuidString, "path": requestInput.path,
                                   "sha256": inputHash, "byteSize": inputSize.intValue,
                                   "unchanged": true]],
            ],
            "outputs": correctArtifacts,
            "nativeEvents": [[
                "engine": command.request.engine.rawValue, "kind": "fixture",
                "module": "fixture", "function": "design", "arguments": [:],
                "durableArguments": [:], "status": "succeeded",
                "startedAt": "1970-01-01T00:00:01Z", "finishedAt": "1970-01-01T00:00:02Z",
                "wallTimeSeconds": 1.0, "exitStatus": 0,
            ]],
            "startedAt": "1970-01-01T00:00:01Z", "finishedAt": "1970-01-01T00:00:02Z",
            "wallTimeSeconds": 1.0, "exitStatus": 0,
            "stdoutPath": "logs/native-stdout.txt", "stderrPath": "logs/native-stderr.txt",
        ], to: provenance)

        try writeJSON([
            "schemaVersion": 1, "analysisID": command.request.analysisID.uuidString,
            "runID": command.request.runID.uuidString,
            "resultID": mutation == .mismatchedIDs ? UUID().uuidString : command.request.resultID.uuidString,
            "engine": command.request.engine.rawValue, "engineVersion": command.request.engineVersion,
            "adapterVersion": "1.0.0", "mode": mode.rawValue,
            "resolvedOptions": resolvedOptions,
            "results": [["id": resultID.uuidString,
                          "inputIDs": [requestInput.id.uuidString], "targets": [target]]],
            "artifacts": resultArtifacts, "provenancePath": "provenance-v1.json",
        ], to: output.appendingPathComponent("adapter-result-v1.json"))
    }

    private func oligo(id: UUID, name: String, role: String, sequence: String,
                       start: Int, end: Int, strand: String,
                       mode: PrimerSchemeMode) -> [String: Any] {
        ["id": id.uuidString, "name": name, "role": role, "sequence": sequence,
         "start": start, "end": end, "strand": strand,
         "assayIDs": [assayID.uuidString], "pool": mode == .tiled ? "1" : NSNull(),
         "nativeMetadata": [:]]
    }

    private func artifact(path: String, kind: String, root: URL) throws -> [String: Any] {
        let url = root.appendingPathComponent(path)
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! NSNumber
        return ["path": path, "sha256": try ProvenanceFileHasher.sha256(of: url),
                "byteSize": size.intValue, "kind": kind]
    }

    private func writeJSON(_ object: Any, to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: url, options: .atomic)
    }

    private func jsonObject(_ value: PrimerSchemeJSONValue) -> Any {
        switch value {
        case .string(let value): return value
        case .number(let value): return value
        case .integer(let value): return value
        case .boolean(let value): return value
        case .null: return NSNull()
        case .array(let values): return values.map(jsonObject)
        case .object(let values): return values.mapValues(jsonObject)
        }
    }

}

private extension PrimerSchemeDesignRequest {
    func replacingExpectedChecksums(_ checksums: [URL: String]) -> PrimerSchemeDesignRequest {
        .init(analysisID: analysisID, runID: runID, resultID: resultID,
              inputURLs: inputURLs, destinationURL: destinationURL, options: options,
              invocation: invocation, expectedInputChecksums: checksums,
              executableURL: executableURL, inputIDs: inputIDs)
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath, line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {}
}
