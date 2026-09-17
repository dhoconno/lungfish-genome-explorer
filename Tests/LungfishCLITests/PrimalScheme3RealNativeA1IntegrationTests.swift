import Foundation
import LungfishCore
import LungfishIO
@testable import LungfishCLI
@testable import LungfishWorkflow
import XCTest

/// Opt-in validation of a retained, independently produced native Mamu-A1 panel.
///
/// This test never runs panel design and never modifies the supplied native panel or audit.
/// The fixture stays outside the repository and is selected with environment variables.
final class PrimalScheme3RealNativeA1IntegrationTests: XCTestCase {
    private static let panelEnvironment = "LUNGFISH_REAL_NATIVE_A1_PANEL"
    private static let auditEnvironment = "LUNGFISH_REAL_NATIVE_A1_AUDIT"
    private static let executableEnvironment = "LUNGFISH_REAL_NATIVE_EXECUTABLE"
    private static let outputEnvironment = "LUNGFISH_REAL_NATIVE_LGE_OUTPUT"

    func testRealConcreteSecondaryPanelValidatesWrapsAndInspectsWithoutChangingSource() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let panelPath = environment[Self.panelEnvironment],
              let auditPath = environment[Self.auditEnvironment],
              let executablePath = environment[Self.executableEnvironment],
              let outputPath = environment[Self.outputEnvironment] else {
            throw XCTSkip(
                "Set \(Self.panelEnvironment), \(Self.auditEnvironment), "
                    + "\(Self.executableEnvironment), and \(Self.outputEnvironment) "
                    + "to run the retained native Mamu-A1 integration test."
            )
        }

        let panel = URL(fileURLWithPath: panelPath, isDirectory: true).standardizedFileURL
        let existingAudit = URL(fileURLWithPath: auditPath, isDirectory: true).standardizedFileURL
        let executable = URL(fileURLWithPath: executablePath).standardizedFileURL
        let retainedRoot = URL(fileURLWithPath: outputPath, isDirectory: true).standardizedFileURL
        try Self.requireDirectory(panel, label: "native panel")
        try Self.requireDirectory(existingAudit, label: "existing native audit")
        try Self.requireRegularFile(executable, label: "native executable")
        try FileManager.default.createDirectory(at: retainedRoot, withIntermediateDirectories: true)

        let sourceInventory = try Self.inventory(panel)
        let configuration = try Self.object(at: panel.appendingPathComponent("config.json"))
        let panelProvenance = try Self.object(at: panel.appendingPathComponent("panel-provenance.json"))
        let validation = try Self.object(at: panel.appendingPathComponent("panel-validation.json"))
        let auditProvenanceURL = existingAudit.appendingPathComponent("provenance.json")
        let auditValidationURL = existingAudit.appendingPathComponent("validation.json")
        let auditProvenance = try Self.object(at: auditProvenanceURL)
        let panelArgv = try Self.commandArgv(panelProvenance, label: "panel provenance")
        let auditArgv = try Self.commandArgv(auditProvenance, label: "audit provenance")
        XCTAssertEqual(panelArgv.first, executable.path)
        XCTAssertEqual(auditArgv.first, executable.path)
        XCTAssertEqual(Self.argument("--output", in: panelArgv), panel.path)
        XCTAssertEqual(Self.argument("--bundle", in: auditArgv), panel.path)
        XCTAssertEqual((panelProvenance["exitStatus"] as? NSNumber)?.int32Value, 0)
        XCTAssertEqual((auditProvenance["exitStatus"] as? NSNumber)?.int32Value, 0)

        let reuseDiscovery = try XCTUnwrap(
            Self.argument("--reuse-discovery", in: panelArgv),
            "The retained control must bind the independently requested discovery cache."
        )
        let expectedOptions = Self.expectedOptions(reuseDiscovery: URL(fileURLWithPath: reuseDiscovery))
        let probe = try await NativeToolRunner().runProcess(
            executableURL: executable,
            arguments: ["--capabilities-json"],
            workingDirectory: retainedRoot,
            timeout: 30,
            toolName: "PrimalScheme3 capability probe"
        )
        XCTAssertEqual(probe.exitCode, 0, probe.stderr)
        let capabilitiesData = try XCTUnwrap(probe.stdout.data(using: .utf8))
        let capabilities = try PrimalScheme3AlleleContract.validateCapabilities(
            capabilitiesData,
            requestedPhaseScheduling: .serial,
            requestedIntendedProductPolicy: .concreteDesignatedSites,
            requestedSecondaryProductPolicy: .orderedDisjointConcreteDesignatedSites
        )
        try PrimalScheme3AlleleContract.validateNativeOutput(
            at: panel,
            configuration: configuration,
            capabilities: capabilities,
            options: expectedOptions,
            inputCount: 1,
            executedArgv: panelArgv,
            auditValidation: try Data(contentsOf: auditValidationURL),
            auditProvenance: try Data(contentsOf: auditProvenanceURL),
            auditExecutedArgv: auditArgv,
            auditExitStatus: 0
        )

        let intended = try Self.objectArray(validation["allowed_intended_products"],
                                            label: "allowed intended products")
        let secondary = try Self.objectArray(validation["allowed_secondary_products"],
                                             label: "allowed secondary products")
        let concreteSecondary = secondary.filter {
            $0["classification"] as? String == "nonexact-ordered-concrete-secondary-product"
        }
        XCTAssertEqual((validation["allowed_intended_product_count"] as? NSNumber)?.intValue, 403)
        XCTAssertEqual(intended.count, 403)
        XCTAssertEqual((validation["allowed_secondary_product_count"] as? NSNumber)?.intValue, 1_740)
        XCTAssertEqual(secondary.count, 1_740)
        XCTAssertEqual(concreteSecondary.count, 1_380)
        try concreteSecondary.forEach(Self.requireCompleteFourSiteCertificate)

        let runRoot = retainedRoot.appendingPathComponent(
            "mamu-a1-real07-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: runRoot, withIntermediateDirectories: false)
        let resultID = UUID()
        let inputID = UUID()
        let destination = runRoot.appendingPathComponent(
            "mamu-a1-concrete-secondary.lungfishprimeranalysis", isDirectory: true)
        let bundle = try PrimerAnalysisBundleWriter().write(.init(
            analysisID: UUID(),
            runID: UUID(),
            grouping: .independent,
            inputs: [.init(
                id: inputID,
                label: "Mamu-A1 retained native source",
                artifactPaths: ["inputs/\(inputID.uuidString)/primary.aligned.fasta"]
            )],
            results: [.init(
                id: resultID,
                label: "Mamu-A1 retained native concrete-secondary validation",
                inputIDs: [inputID],
                artifactPaths: sourceInventory.map {
                    "native/\(resultID.uuidString)/\($0.relativePath)"
                }
            )],
            artifacts: [
                .init(
                    sourceURL: panel.appendingPathComponent("work/0000-primary.aligned.fasta"),
                    relativePath: "inputs/\(inputID.uuidString)/primary.aligned.fasta",
                    role: "input",
                    format: "fasta"
                )
            ] + sourceInventory.map {
                .init(
                    sourceURL: panel.appendingPathComponent($0.relativePath),
                    relativePath: "native/\(resultID.uuidString)/\($0.relativePath)",
                    role: "nativeOutput",
                    format: Self.format(for: $0.relativePath)
                )
            },
            destinationURL: destination,
            invocation: .init(
                argv: CommandLine.arguments,
                callerVersion: LungfishAppVersion.cliToolVersion,
                explicitOptions: [
                    "sourceNativePanel": .string(panel.path),
                    "sourceNativeAudit": .string(existingAudit.path),
                    "nativeExecutable": .string(executable.path),
                    "destination": .string(destination.path),
                    "validationPurpose": .string("opt-in-retained-native-contract-integration")
                ],
                runtimeIdentity: .init(executablePath: CommandLine.arguments.first ?? "swift-test")
            )
        ))
        XCTAssertEqual(bundle.url, destination)

        let inspect = try XCTUnwrap(try LungfishCLI.parseAsRoot([
            "primers", "analysis", "inspect", destination.path, "--json"
        ]) as? PrimerAnalysisInspectCommand)
        let inspected = try JSONDecoder().decode(
            PrimerAnalysisManifest.self, from: Data(try inspect.inspectionOutput().utf8))
        XCTAssertEqual(inspected.results.map(\.id), [resultID])

        let historyOutput = runRoot.appendingPathComponent("history", isDirectory: true)
        var history = try XCTUnwrap(try LungfishCLI.parseAsRoot([
            "primers", "analysis", "history", destination.path,
            "--result-id", resultID.uuidString,
            "--primalscheme3-path", executable.path,
            "--output", historyOutput.path,
            "--stage", "strict", "--limit", "10"
        ]) as? PrimerAnalysisHistoryCommand)
        try await history.run()
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: historyOutput.appendingPathComponent("query.json").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: historyOutput.appendingPathComponent("lungfish-provenance.json").path))

        let freshAuditOutput = runRoot.appendingPathComponent("audit", isDirectory: true)
        var audit = try XCTUnwrap(try LungfishCLI.parseAsRoot([
            "primers", "analysis", "audit", destination.path,
            "--result-id", resultID.uuidString,
            "--primalscheme3-path", executable.path,
            "--output", freshAuditOutput.path,
            "--tier", "strict"
        ]) as? PrimerAnalysisAuditCommand)
        try await audit.run()
        let freshAudit = try Self.object(at: freshAuditOutput.appendingPathComponent("validation.json"))
        XCTAssertEqual(freshAudit["valid"] as? Bool, true)
        XCTAssertEqual(freshAudit["raw_inputs_reparsed"] as? Bool, true)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: freshAuditOutput.appendingPathComponent("lungfish-provenance.json").path))

        XCTAssertEqual(try Self.inventory(panel), sourceInventory)
        print("Retained real native LGE bundle: \(destination.path)")
        print("Retained relocated history: \(historyOutput.path)")
        print("Retained relocated audit: \(freshAuditOutput.path)")
    }

    private static func expectedOptions(reuseDiscovery: URL) -> PrimalScheme3DesignOptions {
        PrimalScheme3DesignOptions(
            ampliconSize: 200,
            poolCount: 2,
            minOverlap: 10,
            minimumBaseFrequency: 0,
            highGC: false,
            coreCount: 4,
            terminalGapPolicy: .observedOnly,
            dimerScore: -26,
            useMatchDB: true,
            backtrack: false,
            ignoreN: false,
            panelMode: .equal,
            maxAmplicons: nil,
            maxAmpliconsPerMSA: nil,
            ampliconSizeMinimum: 150,
            ampliconSizeMaximum: 250,
            selectionAlgorithm: .alleleCoverage,
            coverageMetric: .observedAllelePrimerTrimmed,
            coverageTarget: 0.95,
            optimizerSeed: 0,
            optimizerStarts: 4,
            optimizerRepairRounds: 2,
            optimizerTimeLimit: 600,
            misprimingProductSize: 2_000,
            alleleOptions: .init(
                preset: "allele-balanced-v1",
                candidateProfiles: "union",
                reuseDiscovery: reuseDiscovery,
                variantSelection: "subsets",
                phaseScheduling: .serial,
                intendedProductPolicy: .concreteDesignatedSites,
                discoveryLengthMode: "first-compatible",
                specificityTerminalK: 17,
                secondaryProductPolicy: .orderedDisjointConcreteDesignatedSites,
                salvage: "off",
                primaryTier: "strict"
            )
        )
    }

    private struct InventoryEntry: Equatable {
        let relativePath: String
        let sha256: String
        let byteSize: UInt64
    }

    private static func inventory(_ root: URL) throws -> [InventoryEntry] {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ))
        var entries: [InventoryEntry] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey
            ])
            guard values.isSymbolicLink != true else {
                throw XCTSkip("The retained native panel contains a symbolic link: \(url.path)")
            }
            guard values.isRegularFile == true else { continue }
            let relative = url.standardizedFileURL.pathComponents
                .dropFirst(root.standardizedFileURL.pathComponents.count)
                .joined(separator: "/")
            entries.append(.init(
                relativePath: relative,
                sha256: try ProvenanceFileHasher.sha256(of: url),
                byteSize: try ProvenanceFileHasher.fileSize(of: url)
            ))
        }
        return entries.sorted { $0.relativePath < $1.relativePath }
    }

    private static func requireCompleteFourSiteCertificate(_ witness: [String: Any]) throws {
        XCTAssertEqual(witness["policy_id"] as? String,
                       PrimalScheme3SecondaryProductPolicy.orderedDisjointConcreteDesignatedSites.rawValue)
        XCTAssertEqual((witness["coverage_credit"] as? NSNumber)?.intValue, 0)
        XCTAssertEqual(witness["uncertain"] as? Bool, false)
        let siteIDs = try objectArrayOrStrings(witness["site_ids"], label: "secondary site IDs")
        XCTAssertEqual(siteIDs.count, 4)
        let certificate = try object(witness["certificate"], label: "secondary certificate")
        for name in ["left_forward", "left_reverse", "right_forward", "right_reverse"] {
            let projection = try object(certificate[name], label: "secondary \(name) projection")
            _ = try nonemptyString(projection["site_id"], label: "secondary \(name) site ID")
            let terminalHit = try object(projection["terminal_hit"], label: "secondary \(name) terminal hit")
            _ = try nonemptyString(terminalHit["oligo"], label: "secondary \(name) terminal oligo")
            _ = try nonemptyString(terminalHit["orientation"], label: "secondary \(name) terminal orientation")
            XCTAssertNotNil(terminalHit["start"] as? NSNumber)
            XCTAssertNotNil(terminalHit["end"] as? NSNumber)
            XCTAssertNotNil(terminalHit["terminal_interval"] as? [Any])
            XCTAssertNotNil(terminalHit["owners"] as? [String])
        }
    }

    private static func commandArgv(_ root: [String: Any], label: String) throws -> [String] {
        let command = try object(root["command"], label: "\(label) command")
        guard let argv = command["argv"] as? [String], !argv.isEmpty else {
            throw NSError(domain: "PrimalScheme3RealNativeA1IntegrationTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "\(label) command argv is missing."])
        }
        return argv
    }

    private static func argument(_ flag: String, in argv: [String]) -> String? {
        guard let index = argv.firstIndex(of: flag), argv.indices.contains(index + 1) else { return nil }
        return argv[index + 1]
    }

    private static func object(at url: URL) throws -> [String: Any] {
        try object(JSONSerialization.jsonObject(with: Data(contentsOf: url)), label: url.lastPathComponent)
    }

    private static func object(_ value: Any?, label: String) throws -> [String: Any] {
        guard let object = value as? [String: Any] else {
            throw NSError(domain: "PrimalScheme3RealNativeA1IntegrationTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "\(label) is missing or malformed."])
        }
        return object
    }

    private static func objectArray(_ value: Any?, label: String) throws -> [[String: Any]] {
        guard let objects = value as? [[String: Any]] else {
            throw NSError(domain: "PrimalScheme3RealNativeA1IntegrationTests", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "\(label) is missing or malformed."])
        }
        return objects
    }

    private static func objectArrayOrStrings(_ value: Any?, label: String) throws -> [String] {
        guard let strings = value as? [String], strings.allSatisfy({ !$0.isEmpty }) else {
            throw NSError(domain: "PrimalScheme3RealNativeA1IntegrationTests", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "\(label) is missing or malformed."])
        }
        return strings
    }

    private static func nonemptyString(_ value: Any?, label: String) throws -> String {
        guard let string = value as? String, !string.isEmpty else {
            throw NSError(domain: "PrimalScheme3RealNativeA1IntegrationTests", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "\(label) is missing or malformed."])
        }
        return string
    }

    private static func requireDirectory(_ url: URL, label: String) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw NSError(domain: "PrimalScheme3RealNativeA1IntegrationTests", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "The \(label) is not a safe directory: \(url.path)"])
        }
    }

    private static func requireRegularFile(_ url: URL, label: String) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw NSError(domain: "PrimalScheme3RealNativeA1IntegrationTests", code: 7,
                          userInfo: [NSLocalizedDescriptionKey: "The \(label) is not a safe regular file: \(url.path)"])
        }
    }

    private static func format(for path: String) -> String {
        if path.hasSuffix(".json.gz") { return "json.gz" }
        let extensionName = URL(fileURLWithPath: path).pathExtension
        return extensionName.isEmpty ? "unknown" : extensionName
    }
}
