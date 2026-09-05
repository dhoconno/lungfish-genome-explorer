import XCTest
@testable import LungfishWorkflow

final class CondaLockfileServiceTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("CondaLockfileServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
        try super.tearDownWithError()
    }

    private func fixturePack() -> PluginPack {
        PluginPack(id: "fixture", name: "Fixture", description: "Local identity fixture",
                   sfSymbol: "wrench", packages: [], category: "Testing", requirements: [
            PackToolRequirement(id: "fixture-tool", displayName: "Fixture Tool", environment: "renamed-runtime",
                installPackages: ["conda-forge::python=3.12=fixture_0", "conda-forge::make=4.4=fixture_1"],
                executables: ["fixture"], fallbackExecutablePaths: ["fixture": ["bin/custom"]],
                version: "fixture-v1", license: "MIT", sourceURL: "https://example.invalid/source",
                sourceOverlay: .init(kind: .bracken, version: "fixture-v1",
                    sourceURL: URL(string: "https://example.invalid/fixture.tar.gz")!,
                    sha256: String(repeating: "a", count: 64)))
        ], postInstallHooks: [.init(description: "Fixture setup", environment: "renamed-runtime",
            command: ["fixture-setup", "--mode", "literal value"], requiresNetwork: false)])
    }

    func testExportRetainsCompleteRequestedIdentityWithoutClaimingResolution() throws {
        let pack = fixturePack()
        let output = tempRoot.appendingPathComponent("requested-environment.json")
        let result = try CondaLockfileService(platforms: ["osx-arm64", "linux-64"], channels: ["conda-forge"])
            .writeLockfile(for: pack, to: output, commandLine: ["lungfish-cli", "conda", "lock"])
        let data = try Data(contentsOf: output)
        let document = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        XCTAssertNotNil(document, "Export must use the versioned Lungfish requested-specification contract")
        guard let document else { return }
        XCTAssertEqual(document["kind"] as? String, "lungfish.conda-request-specification")
        XCTAssertEqual(document["schemaVersion"] as? Int, 1)
        XCTAssertEqual(document["resolution"] as? String, "unresolved")
        XCTAssertEqual(document["platforms"] as? [String], ["osx-arm64", "linux-64"])
        XCTAssertEqual(document["channels"] as? [String], ["conda-forge"])
        let requirements = try XCTUnwrap(document["requirements"])
        let decoded = try JSONDecoder().decode([PackToolRequirement].self,
            from: JSONSerialization.data(withJSONObject: requirements))
        XCTAssertEqual(decoded, pack.toolRequirements)
        let hooks = try XCTUnwrap(document["postInstallHooks"])
        XCTAssertEqual(try JSONDecoder().decode([PostInstallHook].self,
            from: JSONSerialization.data(withJSONObject: hooks)), pack.postInstallHooks)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.provenanceURL.path))
    }

    func testRequestedSpecificationRoundTripsAndRejectsUnsupportedSchemaAndPlatforms() throws {
        let service = CondaLockfileService(platforms: ["osx-arm64", "linux-64"])
        let output = tempRoot.appendingPathComponent("roundtrip.json")
        _ = try service.writeLockfile(for: fixturePack(), to: output, commandLine: [])
        let specification = try service.readSpecification(from: output)
        XCTAssertEqual(specification.requirements, fixturePack().toolRequirements)
        XCTAssertEqual(specification.postInstallHooks, fixturePack().postInstallHooks)
        XCTAssertEqual(specification.platforms, ["osx-arm64", "linux-64"])
        let roundtrip = try JSONDecoder().decode(CondaRequestedEnvironmentSpecification.self,
            from: JSONEncoder().encode(specification))
        XCTAssertEqual(roundtrip, specification)
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any])
        for (key, value) in [("schemaVersion", 999 as Any), ("platforms", ["unsupported-platform"] as Any), ("resolution", "resolved" as Any)] {
            var malformed = document
            malformed[key] = value
            try JSONSerialization.data(withJSONObject: malformed).write(to: output)
            XCTAssertThrowsError(try service.readSpecification(from: output))
        }
        document["requirements"] = []
        try JSONSerialization.data(withJSONObject: document).write(to: output)
        XCTAssertThrowsError(try service.readSpecification(from: output))
    }

    func testMultipleExportsRetainIndependentProvenance() throws {
        let service = CondaLockfileService()
        let first = try service.writeLockfile(for: fixturePack(), to: tempRoot.appendingPathComponent("first.json"), commandLine: ["first export"])
        let firstReceipt = try Data(contentsOf: first.provenanceURL)
        let second = try service.writeLockfile(for: fixturePack(), to: tempRoot.appendingPathComponent("second.json"), commandLine: ["second export"])
        XCTAssertNotEqual(first.provenanceURL, second.provenanceURL)
        XCTAssertEqual(try Data(contentsOf: first.provenanceURL), firstReceipt)
    }

    func testFailedReceiptPublicationRestoresPreviousSpecificationAndReceipt() throws {
        let output = tempRoot.appendingPathComponent("previous.json")
        let old = try CondaLockfileService().writeLockfile(for: fixturePack(), to: output, commandLine: ["old export"])
        let oldOutput = try Data(contentsOf: output)
        let oldReceipt = try Data(contentsOf: old.provenanceURL)
        var service = CondaLockfileService(platforms: ["linux-64"])
        service.publicationDidOccur = { url in
            if url == old.provenanceURL { throw CocoaError(.fileWriteUnknown) }
        }
        XCTAssertThrowsError(try service.writeLockfile(for: fixturePack(), to: output, commandLine: ["new export"]))
        XCTAssertEqual(try Data(contentsOf: output), oldOutput)
        XCTAssertEqual(try Data(contentsOf: old.provenanceURL), oldReceipt)
    }

    func testFailedExportPreservesNewerWriterAndRetainsRecoverablePreviousPair() throws {
        let output = tempRoot.appendingPathComponent("concurrent.json")
        let old = try CondaLockfileService().writeLockfile(for: fixturePack(), to: output, commandLine: ["old export"])
        let oldOutput = try Data(contentsOf: output)
        let oldReceipt = try Data(contentsOf: old.provenanceURL)
        let newer = Data("newer writer's bytes".utf8)
        var service = CondaLockfileService(platforms: ["linux-64"])
        service.publicationDidOccur = { url in
            if url == old.provenanceURL {
                try newer.write(to: output, options: .atomic)
                throw CocoaError(.fileWriteUnknown)
            }
        }
        do {
            _ = try service.writeLockfile(for: fixturePack(), to: output, commandLine: ["failed export"])
            XCTFail("Injected receipt failure must fail export")
        } catch let recovery as ScientificPublicationRecoveryRequired {
            defer { for url in recovery.recoveryURLs { try? FileManager.default.removeItem(at: url) } }
            let recoveryRoot = try XCTUnwrap(recovery.recoveryURLs.first)
            let files = try FileManager.default.contentsOfDirectory(at: recoveryRoot, includingPropertiesForKeys: nil)
            let bytes = files.compactMap { try? Data(contentsOf: $0) }
            XCTAssertTrue(bytes.contains(oldOutput), "Previous specification must remain recoverable")
            XCTAssertTrue(bytes.contains(oldReceipt), "Previous receipt must remain recoverable")
        } catch {
            XCTFail("Expected explicit recoverable publication failure, got \(error)")
        }
        XCTAssertEqual(try Data(contentsOf: output), newer)
    }

    func testInvalidEmptyRequirementIsRejectedBeforePublishing() throws {
        let pack = PluginPack(id: "fixture", name: "Fixture", description: "", sfSymbol: "wrench",
            packages: [], category: "Testing", requirements: [
                PackToolRequirement(id: "", displayName: "Invalid", environment: "runtime",
                    installPackages: [], executables: [])])
        let output = tempRoot.appendingPathComponent("invalid.json")
        XCTAssertThrowsError(try CondaLockfileService().writeLockfile(for: pack, to: output, commandLine: []))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testExactInstallRejectsRequestedSpecificationWithoutInvokingSolver() async throws {
        let output = tempRoot.appendingPathComponent("requested.json")
        _ = try CondaLockfileService().writeLockfile(for: fixturePack(), to: output, commandLine: [])
        try await assertExactInstallRejected(output)
    }

    func testExactInstallRejectsLegacyExternalAndMalformedDocumentsWithoutMutation() async throws {
        let documents = [
            "version: 1\npackage:\n  - name: python\n    version: \"3.12\"\n    build: \"fixture_0\"\n",
            "{\"kind\":\"lungfish.conda-request-specification\",\"schemaVersion\":999}",
            "this is not a supported environment identity"
        ]
        for (index, content) in documents.enumerated() {
            let input = tempRoot.appendingPathComponent("unsupported-\(index).txt")
            try content.write(to: input, atomically: true, encoding: .utf8)
            try await assertExactInstallRejected(input)
        }
    }

    private func assertExactInstallRejected(_ input: URL) async throws {
        let root = tempRoot.appendingPathComponent("not-created-\(UUID().uuidString)")
        let recorder = RecordingCondaLockInstaller()
        do {
            _ = try await CondaLockfileService().install(fromLockfile: input, condaRoot: root,
                installer: recorder, commandLine: ["lungfish-cli", "conda", "install", "--from-lockfile", input.path])
            XCTFail("Exact reconstruction must reject unsupported locks instead of solving a reduced specification")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("exact reconstruction"), error.localizedDescription)
        }
        let calls = await recorder.calls
        XCTAssertTrue(calls.isEmpty, "Unsupported reconstruction must never invoke a fresh solver")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

}

private actor RecordingCondaLockInstaller: CondaLockInstalling {
    struct Call: Equatable {
        let environment: String
        let packageSpecs: [String]
        let condaRoot: URL
    }

    private(set) var calls: [Call] = []

    func install(environment: String, packageSpecs: [String], condaRoot: URL) async throws {
        try FileManager.default.createDirectory(
            at: condaRoot.appendingPathComponent("envs/\(environment)", isDirectory: true),
            withIntermediateDirectories: true
        )
        calls.append(.init(environment: environment, packageSpecs: packageSpecs, condaRoot: condaRoot))
    }
}

private extension JSONDecoder {
    static var lungfishProvenance: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
