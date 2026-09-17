import Darwin
import Foundation
import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class PrimerAnalysisNativeInspectionServiceTests: XCTestCase {
    func testNativeFailureRetainsOutputsAndCompleteWrapperProvenance() async throws {
        let fixture = try makeFixture(mode: "native-failure")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let argv = ["lungfish-cli", "primers", "analysis", "history", fixture.bundle.url.path]

        do {
            _ = try await service(fixture, argv: argv)
            XCTFail("Expected native failure")
        } catch {}

        let envelope = try loadEnvelope(fixture.output)
        XCTAssertEqual(envelope.argv, argv)
        XCTAssertEqual(envelope.exitStatus, 1)
        XCTAssertEqual(envelope.options.resolvedDefaults["status"], .string("failed"))
        XCTAssertEqual(envelope.options.resolvedDefaults["nativeExitStatus"], .integer(9))
        XCTAssertTrue(envelope.stderr?.contains("intentional native failure") == true)
        XCTAssertTrue(envelope.files.contains { $0.role == .input && $0.path.hasSuffix("/manifest.json") && $0.checksumSHA256 != nil && $0.fileSize != nil })
        XCTAssertTrue(envelope.files.contains { $0.role == .input && $0.path.hasSuffix("/panel-provenance.json") && $0.checksumSHA256 != nil && $0.fileSize != nil })
        for suffix in ["query.json", "provenance.json", "inspection-attempt.json"] {
            XCTAssertTrue(envelope.outputs.contains { $0.path.hasSuffix("/\(suffix)") && $0.checksumSHA256 != nil && $0.fileSize != nil })
        }
    }

    func testProbeAndReceiptValidationFailuresStillWriteWrapperProvenance() async throws {
        for mode in ["probe-failure", "invalid-receipt"] {
            let fixture = try makeFixture(mode: mode)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            do {
                _ = try await service(fixture, argv: ["lungfish-cli", mode])
                XCTFail("Expected \(mode)")
            } catch {}
            let envelope = try loadEnvelope(fixture.output)
            XCTAssertEqual(envelope.exitStatus, 1)
            XCTAssertEqual(envelope.options.resolvedDefaults["status"], .string("failed"))
            if mode == "probe-failure" {
                XCTAssertEqual(envelope.options.resolvedDefaults["nativeProbeExitStatus"], .integer(8))
                XCTAssertEqual(envelope.options.resolvedDefaults["nativeExitStatus"], .null)
            } else {
                XCTAssertEqual(envelope.options.resolvedDefaults["nativeExitStatus"], .integer(0))
                XCTAssertTrue(envelope.outputs.contains { $0.path.hasSuffix("/query.json") })
            }
        }
    }

    func testCancellationRetainsWrapperReceiptAndPartialNativeEvidence() async throws {
        let fixture = try makeFixture(mode: "sleep")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let task = Task {
            try await PrimerAnalysisNativeInspectionService().history(
                analysisURL: fixture.bundle.url, resultID: fixture.resultID,
                executableURL: fixture.executable, outputURL: fixture.output,
                query: .init(stage: "strict", limit: 100),
                invocationArgv: ["lungfish-cli", "cancelled-history"])
        }
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: fixture.output.appendingPathComponent("query.json").path) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.output.appendingPathComponent("query.json").path))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {} catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        let envelope = try loadEnvelope(fixture.output)
        XCTAssertEqual(envelope.exitStatus, 130)
        XCTAssertEqual(envelope.options.resolvedDefaults["status"], .string("cancelled"))
        XCTAssertTrue(envelope.outputs.contains { $0.path.hasSuffix("/query.json") && $0.checksumSHA256 != nil })
    }

    private struct Fixture: Sendable {
        let root: URL
        let bundle: PrimerAnalysisBundle
        let resultID: UUID
        let executable: URL
        let output: URL
    }

    private func service(_ fixture: Fixture, argv: [String]) async throws -> URL {
        try await PrimerAnalysisNativeInspectionService().history(
            analysisURL: fixture.bundle.url, resultID: fixture.resultID,
            executableURL: fixture.executable, outputURL: fixture.output,
            query: .init(stage: "strict", limit: 100), invocationArgv: argv)
    }

    private func makeFixture(mode: String) throws -> Fixture {
        let physicalPath = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(physicalPath) }
        let root = URL(fileURLWithPath: String(cString: physicalPath))
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.txt")
        let nativeProvenance = root.appendingPathComponent("panel-provenance.json")
        try Data("input\n".utf8).write(to: source)
        try Data("{\"native\":true}\n".utf8).write(to: nativeProvenance)
        let resultID = UUID(), inputID = UUID()
        let nativePath = "native/\(resultID.uuidString)/panel-provenance.json"
        let bundle = try PrimerAnalysisBundleWriter().write(.init(
            analysisID: UUID(), runID: UUID(), grouping: .combined,
            inputs: [.init(id: inputID, artifactPaths: ["inputs/source.txt"])],
            results: [.init(id: resultID, inputIDs: [inputID], artifactPaths: [nativePath])],
            artifacts: [
                .init(sourceURL: source, relativePath: "inputs/source.txt", role: "input", format: "text"),
                .init(sourceURL: nativeProvenance, relativePath: nativePath, role: "nativeOutput", format: "json")
            ], destinationURL: root.appendingPathComponent("input.lungfishprimeranalysis"),
            invocation: .init(argv: ["fixture"], callerVersion: "test", explicitOptions: [:], runtimeIdentity: .init())))
        let executable = root.appendingPathComponent("fake-primalscheme3")
        let capabilities = String(decoding: try JSONSerialization.data(withJSONObject: capabilitiesObject()), as: UTF8.self)
        let script = """
        #!/bin/sh
        if [ "$1" = "--capabilities-json" ]; then
          if [ "\(mode)" = "probe-failure" ]; then echo "probe rejected" >&2; exit 8; fi
          cat <<'JSON'
        \(capabilities)
        JSON
          exit 0
        fi
        output=""
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "--output" ]; then shift; output="$1"; fi
          shift
        done
        mkdir "$output"
        printf '{"valid":true}\n' > "$output/query.json"
        printf '{"detached":true}\n' > "$output/provenance.json"
        if [ "\(mode)" = "native-failure" ]; then echo "intentional native failure" >&2; exit 9; fi
        if [ "\(mode)" = "sleep" ]; then sleep 30; fi
        exit 0
        """
        try Data(script.utf8).write(to: executable)
        XCTAssertEqual(chmod(executable.path, S_IRUSR | S_IWUSR | S_IXUSR), 0)
        return .init(root: root, bundle: bundle, resultID: resultID, executable: executable,
                     output: root.appendingPathComponent("inspection-output"))
    }

    private func loadEnvelope(_ output: URL) throws -> ProvenanceEnvelope {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ProvenanceEnvelope.self,
            from: Data(contentsOf: output.appendingPathComponent("lungfish-provenance.json")))
    }

    private func capabilitiesObject() -> [String: Any] {
        let digest = String(repeating: "a", count: 64)
        let source: [String: Any] = ["root": "/fixture/source", "kind": "git", "gitCommit": "fixture",
            "sourceDigest": digest, "build": ["path": "pyproject.toml", "sha256": digest, "size": 1],
            "files": [["path": "primalscheme3/cli.py", "sha256": digest, "size": 1]]]
        let runtime: [String: Any] = ["pythonExecutable": "/fixture/python",
            "pythonExecutableResolved": "/fixture/python3.12", "pythonVersion": "3.12",
            "pythonImplementation": "CPython", "pythonPrefix": "/fixture", "platform": "fixture-os",
            "machine": "arm64", "kernel": ["system": "Darwin"],
            "declaredRuntimeDependencies": [["distribution": "primer3-py", "version": "2.2.0"]],
            "nativeKernels": [["distribution": "primer3-py", "package": "primer3", "version": "2.2.0",
                "files": [["path": "/fixture/primer3.so", "sha256": digest, "size": 1]]]]]
        return ["schemaVersion": "primalscheme3.capabilities/v1", "tool": "primalscheme3",
            "toolVersion": PrimalScheme3DesignPipeline.alleleToolVersion,
            "selectionAlgorithms": ["legacy", "coverage", "allele-coverage"],
            "alleleCoverage": ["sourceContractVersion": PrimalScheme3DesignPipeline.alleleToolVersion,
                "algorithm": "bounded-allele-coverage/v1", "metric": "observed-allele-primer-trimmed/v1",
                "preset": "allele-balanced-v1", "catalogSchemaVersion": "primalscheme3.variant-catalog/v2",
                "configurationLedgerSchemaVersion": "primalscheme3.configuration-ledger/v2",
                "validationSchemaVersion": "primalscheme3.allele-panel-validation/v2",
                "profile": ["name": "allele-panel-v1", "specificityRevision": "selected-sites-v2"],
                "supportedScope": ["mode": "equal", "mapping": "first", "ampliconSizeMetric": "reference-span",
                    "freshDesign": true, "linear": true, "suppliedMsaSpecificity": true,
                    "terminalGapPolicies": ["observed-only"]]],
            "source": source, "runtime": runtime]
    }
}
