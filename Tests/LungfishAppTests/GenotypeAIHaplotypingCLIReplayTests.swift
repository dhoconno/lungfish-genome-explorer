// GenotypeAIHaplotypingCLIReplayTests.swift - The AI Haplotyping row's command replayed through the built CLI
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.19 (L11) M3, Q-S10, X15 and the `.remoteRequest` row of
// docs/contracts/CLI-EQUIVALENCE.md. The app runs AI Haplotyping on
// `GenotypeAIHaplotypingRunFixture`, whose provider is a loopback stand-in with
// a recorded reply and whose key sits in an in-memory secret lookup. The
// command the row recorded is rebased onto a copy of the bundle made before
// the app run, then replayed through the built lungfish-cli, placed in an app
// layout as it ships, against the same stand-in. The child's environment is built, not inherited. It holds `PATH`,
// `HOME`, `TMPDIR` and `LANG` from this process and the throwaway key as
// `AZURE_OPENAI_API_KEY`, so no key of the shell that runs the tests reaches
// it. The two provider requests are compared as `.remoteRequest`.
//
// It launches the built CLI, so its name ends in ReplayTests, which sends it
// to the integration tier (REPLAY_SUITES in scripts/full-suite-gate.sh).

import Foundation
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishTestSupport
import LungfishWorkflow

@MainActor
final class GenotypeAIHaplotypingCLIReplayTests: XCTestCase {
    /// How long the child may run. It reads one small bundle and makes one
    /// loopback request.
    private static let childWait: Duration = .seconds(30)

    func testRecordedCommandReplaysThroughTheBuiltCLIWithTheSameProviderRequest() async throws {
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        guard let built = CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products) else {
            try ToolAvailability.skipOrFail("No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH")
        }
        let cli = try appLayout(of: built)
        let fixture = try await GenotypeAIHaplotypingRunFixture(testCase: self)
        let key = fixture.throwawayKey

        // The app run publishes a revision into its bundle, so the child's
        // bundle is a copy made first.
        let replayRoot = try makeRoot("replay")
        let replayBundle = replayRoot.appendingPathComponent(fixture.bundleURL.lastPathComponent, isDirectory: true)
        try FileManager.default.copyItem(at: fixture.bundleURL, to: replayBundle)
        try await fixture.makeService().run(bundleURL: fixture.bundleURL, mode: .aiDiscovery)
        let recorded = try XCTUnwrap(fixture.operationCenter.items.first?.cliCommand)
        let arguments = try RecordedCLICommand.arguments(
            of: RecordedCLICommand.rebased(recorded, from: fixture.root, to: replayRoot)
        )
        XCTAssertFalse(arguments.contains { $0.contains(key) }, "the key reached the replayed argv")

        let environment = Self.childEnvironment(key: key)
        XCTAssertEqual(Set(environment.keys), ["PATH", "HOME", "TMPDIR", "LANG", "AZURE_OPENAI_API_KEY"])
        let run = try ToolProcess.start(ToolProcessSpec(
            executableURL: cli,
            arguments: arguments,
            environment: environment,
            workingDirectory: replayRoot,
            timeout: Self.childWait,
            label: "lane-12-19-ai-haplotyping-replay"
        ))
        let result: ToolProcessResult
        do {
            result = try await run.result()
        } catch {
            return XCTFail("The replay did not finish: \(Self.redacting(key, in: String(describing: error)))")
        }
        XCTAssertEqual(result.status, 0, "the replay failed: \(Self.redacting(key, in: result.stderrText))")

        // Q-S10 and X15. The key reaches no line the child printed, its
        // progress events included, and no file under its root.
        XCTAssertFalse(result.stdoutText.contains(key), "the key reached the child's standard output")
        XCTAssertFalse(result.stderrText.contains(key), "the key reached the child's standard error")
        XCTAssertEqual(try fixture.filesContaining(key, under: replayRoot), [], "the key reached a file of the replay")

        // One request from each side, the app's first.
        let requests = fixture.server.requests
        XCTAssertEqual(requests.map(\.path), ["/openai/v1/responses", "/openai/v1/responses"])
        guard requests.count == 2 else { return }
        let (app, child) = (requests[0], requests[1])
        XCTAssertEqual(app.method, child.method)
        XCTAssertEqual(app.target, child.target)
        // The child's key came from its environment, since a keychain fallback
        // would send another value. Booleans only, so no message prints a key.
        XCTAssertTrue(child.headerLines.contains("api-key: " + key), "the child sent a key other than its environment's")
        XCTAssertTrue(app.headerLines.contains("api-key: " + key), "the app sent a key other than its lookup's")

        // CLI-EQUIVALENCE.md `.remoteRequest`. The two bodies are the same request.
        let compareRoot = try makeRoot("requests")
        let sideA = compareRoot.appendingPathComponent("app", isDirectory: true)
        let sideB = compareRoot.appendingPathComponent("cli", isDirectory: true)
        try FileManager.default.createDirectory(at: sideA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sideB, withIntermediateDirectories: true)
        try app.body.write(to: sideA.appendingPathComponent("responses.json"))
        try child.body.write(to: sideB.appendingPathComponent("responses.json"))
        OutputEquivalence.assertSame(sideA, sideB, kind: .remoteRequest)

        // The one declared difference sits in the records, not the request.
        // Each side's record names the source its key came from.
        let appSource = AIHaplotypingCredentialSource.keychainOpenAI.rawValue
        let childSource = AIHaplotypingCredentialSource.environmentAzureOpenAI.rawValue
        XCTAssertNotEqual(try fixture.filesContaining(appSource, under: fixture.bundleURL), [])
        XCTAssertEqual(try fixture.filesContaining(childSource, under: fixture.bundleURL), [])
        XCTAssertNotEqual(try fixture.filesContaining(childSource, under: replayBundle), [])
        XCTAssertEqual(try fixture.filesContaining(appSource, under: replayBundle), [])
    }

    /// The child's whole environment, built rather than inherited.
    private static func childEnvironment(key: String) -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        return [
            "PATH": inherited["PATH"] ?? "/usr/bin:/bin",
            "HOME": inherited["HOME"] ?? NSHomeDirectory(),
            "TMPDIR": inherited["TMPDIR"] ?? NSTemporaryDirectory(),
            "LANG": inherited["LANG"] ?? "en_US.UTF-8",
            "AZURE_OPENAI_API_KEY": key,
        ]
    }

    /// `text` with every copy of `key` replaced, and at most its last 2,000
    /// characters, for a failure message.
    private static func redacting(_ key: String, in text: String) -> String {
        String(text.replacingOccurrences(of: key, with: "<KEY>").suffix(2_000))
    }

    /// A hard link of the built CLI in an app of its own,
    /// `Lungfish.app/Contents/MacOS`, with a copy of the workflow resource
    /// bundle in `Contents/Resources` and links to the other bundles.
    /// `RuntimeResourceLocator` reads a CLI's resources from its app only, so
    /// outside one the CLI finds no MCM specialist prompt. The links follow
    /// `copyOfTheCLIWithoutThePin` in NextflowWorkflowContractParityReplayTests+Route.swift.
    /// The workflow bundle is a copy, since the locator refuses a resource
    /// whose real path leaves the app.
    private func appLayout(of built: URL) throws -> URL {
        let products = built.deletingLastPathComponent()
        let contents = try makeRoot("cli").appendingPathComponent("Lungfish.app/Contents", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: resources, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: contents.appendingPathComponent("MacOS", isDirectory: true), withIntermediateDirectories: true)
        // A CLI in an app takes the app's identity, so the app states the Stable one a standalone CLI has.
        let identity = LungfishAppIdentity.stable
        let info: [String: Any] = [
            "CFBundleDisplayName": identity.fullName, "CFBundleName": identity.shortName,
            "CFBundleIdentifier": identity.bundleIdentifier, "LungfishReleaseChannel": identity.releaseChannel.rawValue,
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let workflow = "LungfishGenomeBrowser_LungfishWorkflow.bundle"
        for item in try fileManager.contentsOfDirectory(atPath: products.path) where item.hasSuffix(".bundle") {
            let source = products.appendingPathComponent(item)
            let destination = resources.appendingPathComponent(item)
            if item == workflow {
                try fileManager.copyItem(at: source, to: destination)
            } else {
                try fileManager.createSymbolicLink(at: destination, withDestinationURL: source)
            }
        }
        XCTAssertTrue(fileManager.fileExists(atPath: resources.appendingPathComponent(workflow).path), "no \(workflow) beside the CLI")
        let cli = contents.appendingPathComponent("MacOS/lungfish-cli")
        try fileManager.linkItem(at: built, to: cli)
        return cli
    }

    private func makeRoot(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lane-12-19-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
}
