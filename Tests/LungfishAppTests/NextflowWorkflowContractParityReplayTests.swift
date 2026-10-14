// NextflowWorkflowContractParityReplayTests.swift - Today's Viral Recon route on the stand-in against the Nextflow workflow contract
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane Q33 M2, plan N1 and N6, 2.9 N11 and O5. A30 M2 moves `lungfish-cli workflow run nf-core/viralrecon`
// onto `NextflowEngineProcess` with the Viral Recon descriptor's argv, and this stand-in class is the move's
// acceptance (N6). Each case runs today's route through the built `lungfish-cli` on `NextflowStandInEngine` with
// `.viralRecon`, with the command the app records (`ViralReconRunRequest.cliArguments(bundlePath:)`), and pins what
// the engine recorded (the argv and the environment LGE adds), the project's tree and the records, so the move
// changes each fact in a commit that shows it. The argv against the descriptor's argv for the same launch gives the
// fit differences, which NextflowWorkflowContractParityKnownDifferences.swift declares. The stand-in reports
// Nextflow 25.04.6, so no case asserts the lock's version, and a live class is Q35's (O5).
//
// The class starts processes and needs the built lungfish-cli beside the test bundle or named by LUNGFISH_CLI_PATH,
// so it runs serially in the replay tier. `LUNGFISH_PARITY_DUMP=<folder>` writes each case's observed facts there.

import Foundation
import LungfishCore
import LungfishTestSupport
import LungfishWorkflow
import XCTest

final class NextflowWorkflowContractParityReplayTests: XCTestCase {
    var root: URL!
    var engines: [NextflowStandInEngine] = []

    enum ParityError: Error {
        case missingCLI
    }

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "viralrecon-contract-parity")
    }

    override func tearDown() async throws {
        for engine in engines { await engine.stopLeftoverProcesses() }
        engines = []
        TestTempDirectory.cleanup(root)
        try await super.tearDown()
    }

    // MARK: - Cases

    /// Docker, the one executor today's route runs, launches the stand-in once. The argv, the environment LGE adds,
    /// the tree and the records are today's, and the argv differs from the descriptor's only as declared.
    func testDockerLaunchesTheStandInAsTheAppRecordsIt() throws {
        let run = try runRoute(.docker, case: "docker")
        XCTAssertEqual(run.status, 0, run.stderr)
        XCTAssertEqual(run.launches.count, 1, "one launch")
        let launch = try XCTUnwrap(run.launches.first, "the route launched nothing")
        XCTAssertEqual(run.observed, try Self.fixture("docker"))
        XCTAssertEqual(run.digestGapCandidates, Self.digestGap.map { "\($0.record) \($0.key)" }.sorted(), "digest gap, Q30 finding 1")
        assertDeclared(Self.argvDifferences(launch.arguments), .docker)
        // The docker profile waits for the daemon. The wait asked the stand-in once and started nothing (Q33 R4).
        XCTAssertEqual(dockerStandInCalls(case: "docker"), ["version --format {{.Client.Version}}|{{if .Server}}{{.Server.Version}}{{end}}"])
    }

    /// Conda and local are refused before the run bundle's manifest is written, so the engine never starts. The read
    /// pairing decision is already in the bundle.
    func testCondaAndLocalAreRefusedBeforeTheEngineStarts() throws {
        for executor in [NFCoreExecutor.conda, .local] {
            let run = try runRoute(executor, case: executor.rawValue)
            XCTAssertEqual(run.launches.count, 0, executor.rawValue)
            XCTAssertEqual(run.observed, try Self.fixture(executor.rawValue), executor.rawValue)
        }
    }

    /// Fit difference 3. A bare `workflow run` call, with no `--version`, on a built CLI whose lock holds no Viral
    /// Recon pin still launches release 3.0.0, where the descriptor refuses the run with 126 (N4).
    func testALockWithoutThePinStillLaunchesTheFallbackRelease() throws {
        let cli = try copyOfTheCLIWithoutThePin()
        let run = try runRoute(.docker, case: "lock-without-pin", cli: cli, passesVersion: false)
        var found: [String] = []
        if let launch = run.launches.first, run.status == 0 {
            found.append("lock without the pin: the route launches -r \(launch.revision ?? "nothing") where the contract refuses with 126")
        } else {
            XCTAssertEqual(run.status, 126, "a run on a lock without the pin either launches or is refused with 126: \(run.stderr)")
        }
        assertDeclared(found, .lockWithoutPin)
    }

    /// The fit differences of `parityCase` against the declared list.
    private func assertDeclared(_ found: [String], _ parityCase: ViralReconContractCase, file: StaticString = #filePath, line: UInt = #line) {
        dump(found.joined(separator: "\n"), as: "\(parityCase.rawValue)-differences")
        let failures = ViralReconContractKnownDifferences.failures(found: found, parityCase: parityCase)
        if !failures.isEmpty {
            XCTFail("\(parityCase.rawValue):\n" + failures.joined(separator: "\n"), file: file, line: line)
        }
    }

    /// The launch's argv against the descriptor's argv for the same launch, built from the argv's own facts (the `-c`
    /// files, `-r`, the samplesheet, the output and work folders, the profile and the workflow's options): where `-c`
    /// and `-work-dir` sit, and every other word once both are taken out.
    static func argvDifferences(_ arguments: [String]) -> [String] {
        func value(_ option: String) -> String? {
            arguments.firstIndex(of: option).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        }
        guard let pin = try? NextflowWorkflowDescriptor.viralRecon.resolveBundledPin() else {
            return ["contract: the lock holds no Viral Recon pin"]
        }
        var options: [String] = []
        var index = arguments.firstIndex(of: "run").map { $0 + 2 } ?? arguments.count
        while index < arguments.count {
            let word = arguments[index]
            let takesValue = word.hasPrefix("-") && word != "-resume" && index + 1 < arguments.count
            if takesValue, word.hasPrefix("--"), word != "--input", word != "--outdir" {
                options += [word, arguments[index + 1]]
            }
            index += takesValue ? 2 : 1
        }
        let launch = NextflowLaunchRequest(
            configFiles: arguments.indices.filter { arguments[$0] == "-c" && $0 + 1 < arguments.count }.map { URL(fileURLWithPath: arguments[$0 + 1]) },
            target: .pinned(NextflowPipelinePin(
                pipelineID: pin.pipelineID, repository: pin.repository, revision: value("-r") ?? pin.revision,
                releaseVersion: pin.releaseVersion)),
            samplesheet: URL(fileURLWithPath: value("--input") ?? "/no-input"),
            outputDirectory: URL(fileURLWithPath: value("--outdir") ?? "/no-outdir"),
            workDirectory: value("-work-dir").map { URL(fileURLWithPath: $0) },
            profile: value("-profile"),
            resume: arguments.contains("-resume"),
            pipelineArguments: options)
        let contract = NextflowWorkflowDescriptor.viralRecon.nextflowArguments(for: launch)
        func placement(_ option: String, in words: [String]) -> String? {
            guard let at = words.firstIndex(of: option) else { return nil }
            guard let run = words.firstIndex(of: "run"), at > run else { return "before run" }
            return at > (words.firstIndex { $0.hasPrefix("--") } ?? words.count) ? "after the parameters" : "after -r"
        }
        var found: [String] = []
        for option in ["-c", "-work-dir"] where placement(option, in: arguments) != placement(option, in: contract) {
            found.append("argv: \(option) \(placement(option, in: arguments) ?? "missing"), the contract writes it \(placement(option, in: contract) ?? "nowhere")")
        }
        func withoutPlacedOptions(_ words: [String]) -> [String] {
            var kept: [String] = []
            var index = 0
            while index < words.count {
                if ["-c", "-work-dir"].contains(words[index]) { index += 2 } else { kept.append(words[index]); index += 1 }
            }
            return kept
        }
        if withoutPlacedOptions(arguments) != withoutPlacedOptions(contract) {
            found.append("argv: the other words differ, \(withoutPlacedOptions(arguments)) against \(withoutPlacedOptions(contract))")
        }
        return found
    }
}

// MARK: - Today's facts

extension NextflowWorkflowContractParityReplayTests {
    /// The observed text a case pins, Tests/LungfishAppTests/Fixtures/ViralReconContractParity/<name>.txt: the
    /// status, standard error, argv, the environment LGE adds, the tree, the digest gap and the records. The commit
    /// that changes a fact runs the class with LUNGFISH_PARITY_DUMP set and copies the case's dump over its fixture.
    static func fixture(_ name: String) throws -> String {
        try String(
            contentsOf: ProvenanceCompatCorpus.repositoryRoot.appendingPathComponent(
                "Tests/LungfishAppTests/Fixtures/ViralReconContractParity/\(name).txt"),
            encoding: .utf8)
    }

    // The checksum and size a record states for a folder in the project (Q30 M2 finding 1). The run bundle holds
    // files that name the run's own temporary root, so these values change on every run. This class reads records
    // through its own masks and not through OutputEquivalence, so the contract's folder mask does not reach it, and
    // it masks exactly these. A lane that changes which folders a record names updates this list in the same commit,
    // and the docker case fails until it does. Never declare them as known differences.
    static let digestGap: [(record: String, key: String)] = {
        let results = "Analyses/viralrecon-results/.lungfish-provenance.json"
        let bundle = "Analyses/viralrecon.lungfishrun/.lungfish-provenance.json"
        let entries = [
            (results, ["files[1]", "files[2]", "output", "outputs[0]", "steps[0].outputs[0]", "steps[0].outputs[1]"]),
            (bundle, ["files[1]", "files[2]", "files[4]", "output", "outputs[0]", "outputs[1]", "outputs[3]",
                      "steps[0].outputs[0]", "steps[0].outputs[1]", "steps[0].outputs[3]"]),
        ]
        return entries.flatMap { record, folders in
            folders.flatMap { folder in ["checksumSHA256", "fileSize"].map { (record: record, key: "\(folder).\($0)") } }
        }
    }()
}
