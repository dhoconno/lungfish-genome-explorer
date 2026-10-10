// BareRunWriterParity.swift - What each bare-run writer recorded before Phase 2.4 moved it to envelopes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Until lane W2B of Phase 2.4, eleven writers wrote a bare `WorkflowRun` file. A parity test runs
// one of them in a temporary `.lungfish` project, projects the sidecar with `ProvenanceCompatFacts`
// and compares the facts with the ones captured from the same run on unchanged code. The captured
// facts are committed in Tests/Fixtures/provenance-writer-parity/<scenario id>.facts.json. They
// are written once, with `LUNGFISH_CAPTURE_PROVENANCE_FACTS=1`, the variable the compatibility
// corpus uses, and are never replaced.
//
// A live writer puts values into its record that the frozen corpus bytes do not hold: the app
// version and the name of the host, the tool versions of the lock, a run's own clock, and the
// checksum of a SQLite file or a BAM. A `Scenario` names which of these its run has, and
// `facts(of:in:scenario:replacing:)` turns them into tokens or clears them in the same way when
// the facts are captured and when they are compared. Everything else compares exactly, through
// `ProvenanceCompatFacts.differences(from:ignoring:)`.

import Foundation
import LungfishCore
import LungfishWorkflow

public enum BareRunWriterParity {
    // MARK: Normalization inputs

    /// A string of the host, the build or the tool lock, and the token it becomes in the facts.
    public struct Replacement: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            case literal
            case regularExpression
        }

        public let pattern: String
        public let token: String
        public let kind: Kind

        /// Every occurrence of `value` becomes `token`.
        public static func literal(_ value: String, as token: String) -> Replacement {
            Replacement(pattern: value, token: token, kind: .literal)
        }

        /// Every match of `pattern` becomes `token`.
        public static func regularExpression(_ pattern: String, as token: String) -> Replacement {
            Replacement(pattern: pattern, token: token, kind: .regularExpression)
        }

        /// A tool or release version that stands alone, so `2.3` does not match inside `12.34`.
        public static func version(_ value: String, as token: String) -> Replacement {
            let boundary = "[0-9A-Za-z.]"
            return .regularExpression(
                "(?<!\(boundary))\(NSRegularExpression.escapedPattern(for: value))(?!\(boundary))",
                as: token
            )
        }
    }

    /// Which times of a scenario are the same on every run.
    public enum Timing: Sendable, Equatable {
        /// The test injects every date and wall time, so all of them compare exactly.
        case injected
        /// The run's own dates come from a real clock, while each step's wall time is injected.
        case clockedRun
        /// The run and its steps read a real clock, so no wall time compares.
        case clockedRunAndSteps
    }

    /// Where a scenario's expected facts come from.
    public enum Source: Sendable, Equatable {
        /// A file this lane captured, in Tests/Fixtures/provenance-writer-parity.
        case parityFixture
        /// A case of the frozen compatibility corpus, whose scenario already exists.
        case corpusCase
    }

    public struct Scenario: Sendable, Equatable {
        /// The scenario's name. It names the expected facts file.
        public let id: String
        public let timing: Timing
        public let source: Source
        /// A file whose path ends with one of these has its checksum and size cleared, because its
        /// bytes depend on the host or the run (a SQLite database, a BAM written by samtools).
        public let volatileFileSuffixes: [String]
        /// Replacements that only this scenario needs, beside the host values every scenario has.
        public let replacements: [Replacement]
        /// True when the writer's steps carry a container identity of their own. The envelope holds
        /// one for the whole run, so a converted record's steps no longer carry it.
        public let stepsCarryContainerIdentity: Bool

        public init(
            id: String,
            timing: Timing,
            source: Source = .parityFixture,
            volatileFileSuffixes: [String] = [],
            replacements: [Replacement] = [],
            stepsCarryContainerIdentity: Bool = false
        ) {
            self.id = id
            self.timing = timing
            self.source = source
            self.volatileFileSuffixes = volatileFileSuffixes
            self.replacements = replacements
            self.stepsCarryContainerIdentity = stepsCarryContainerIdentity
        }
    }

    /// The scenarios, one per way a bare-run writer is driven. The registry is complete, so a test
    /// can tell an expected facts file with no scenario from a scenario with no file.
    public enum Scenarios {
        // Workflow
        public static let gatkExecutorFailed = Scenario(id: "gatk-executor-failed", timing: .clockedRun)
        /// The corpus case s3-gatk-container-bare-run, run again by `ProvenanceCompatScenarios.gatkContainerRun`.
        public static let gatkExecutorContainer = Scenario(
            id: "s3-gatk-container-bare-run",
            timing: .clockedRun,
            source: .corpusCase,
            stepsCarryContainerIdentity: true
        )
        // A SQLite file's bytes change from run to run and with the macOS version, so no scenario compares a `.db` checksum.
        public static let bundleVariantTrackAttach = Scenario(
            id: "bundle-variant-track-attach",
            timing: .injected,
            volatileFileSuffixes: [".db"]
        )
        // The attach stamps the time into the bundle manifest it saves, so that manifest's bytes differ on every run.
        public static let gatkBundleVariantAttach = Scenario(
            id: "gatk-bundle-variant-attach",
            timing: .clockedRunAndSteps,
            volatileFileSuffixes: [".db", "manifest.json"]
        )
        public static let condaLockfileExport = Scenario(id: "conda-lockfile-export", timing: .clockedRunAndSteps)
        // The pack manifest records when the pack was exported, so its bytes differ on every run.
        public static let condaOfflineExport = Scenario(
            id: "conda-offline-export",
            timing: .clockedRunAndSteps,
            volatileFileSuffixes: ["offline-pack-manifest.json"]
        )
        public static let condaOfflineInstall = Scenario(
            id: "conda-offline-install",
            timing: .clockedRunAndSteps,
            volatileFileSuffixes: ["offline-pack-manifest.json"]
        )
        public static let condaOfflineInstallFailure = Scenario(
            id: "conda-offline-install-failure",
            timing: .clockedRunAndSteps,
            volatileFileSuffixes: ["offline-pack-manifest.json"]
        )
        public static let bundleContainerExportArchiveEntry = Scenario(
            id: "bundle-container-export-archive-entry",
            timing: .clockedRunAndSteps,
            stepsCarryContainerIdentity: true
        )

        // CLI
        public static let variantsExtractSample = Scenario(
            id: "variants-extract-sample",
            timing: .clockedRunAndSteps,
            volatileFileSuffixes: [".db"]
        )
        public static let variantsQuery = Scenario(
            id: "variants-query",
            timing: .clockedRunAndSteps,
            volatileFileSuffixes: [".db"]
        )
        // The command plan files hold the absolute paths of the temporary project, so their bytes differ on every run.
        public static let variantsPhaseDryRun = Scenario(
            id: "variants-phase-dry-run",
            timing: .clockedRunAndSteps,
            volatileFileSuffixes: ["phased-variant-command-plan.json"]
        )
        public static let variantsPhaseExecute = Scenario(
            id: "variants-phase-execute",
            timing: .clockedRunAndSteps,
            volatileFileSuffixes: ["phased-variant-command-plan.json"]
        )
        public static let freyjaDemixDryRun = Scenario(
            id: "freyja-demix-dry-run",
            timing: .clockedRunAndSteps,
            volatileFileSuffixes: ["freyja-command-plan.json"]
        )
        public static let projectMigrateBrowserSummary = Scenario(
            id: "project-migrate-browser-summary",
            timing: .clockedRunAndSteps
        )
        public static let sraDownloadToolkitFallback = Scenario(
            id: "sra-download-toolkit-fallback",
            timing: .clockedRunAndSteps
        )
        public static let sraDownloadENAPaired = Scenario(id: "sra-download-ena-paired", timing: .clockedRunAndSteps)

        // App
        public static let sraWindowToolkitAfterFailedENA = Scenario(
            id: "sra-window-toolkit-after-failed-ena",
            timing: .injected
        )
        public static let sraWindowKeepsCLIRecord = Scenario(id: "sra-window-keeps-cli-record", timing: .injected)

        // Integration
        public static let bamAdoptMapping = Scenario(
            id: "bam-adopt-mapping",
            timing: .clockedRunAndSteps,
            volatileFileSuffixes: [".bam", ".bai", ".stats.db"]
        )

        public static let all: [Scenario] = [
            gatkExecutorFailed, gatkExecutorContainer, bundleVariantTrackAttach, gatkBundleVariantAttach,
            condaLockfileExport, condaOfflineExport, condaOfflineInstall, condaOfflineInstallFailure,
            bundleContainerExportArchiveEntry,
            variantsExtractSample, variantsQuery, variantsPhaseDryRun, variantsPhaseExecute, freyjaDemixDryRun,
            projectMigrateBrowserSummary, sraDownloadToolkitFallback, sraDownloadENAPaired,
            sraWindowToolkitAfterFailedENA, sraWindowKeepsCLIRecord,
            bamAdoptMapping,
        ]
    }

    // MARK: Errors

    public enum ParityError: Error, LocalizedError, Equatable {
        case unregisteredScenario(String)
        case noExpectedFacts(id: String)
        case factsAreNotAnObject
        case invalidReplacement(String)

        public var errorDescription: String? {
            switch self {
            case .unregisteredScenario(let id):
                return "Scenario \(id) is not in BareRunWriterParity.Scenarios.all"
            case .noExpectedFacts(let id):
                return "Scenario \(id) has no expected facts. Run its test once on unchanged code with "
                    + "\(ProvenanceCompatCorpus.captureFactsVariable)=1 to capture them."
            case .factsAreNotAnObject:
                return "The facts did not encode as a JSON object"
            case .invalidReplacement(let pattern):
                return "The replacement pattern is not a valid regular expression: \(pattern)"
            }
        }
    }

    // MARK: Locations

    /// `Tests/Fixtures/provenance-writer-parity`, found from the corpus helper's own path.
    public static var fixtureRoot: URL {
        ProvenanceCompatCorpus.repositoryRoot
            .appendingPathComponent("Tests/Fixtures/provenance-writer-parity", isDirectory: true)
    }

    public static func expectedFactsURL(for scenario: Scenario) -> URL {
        fixtureRoot.appendingPathComponent("\(scenario.id).facts.json")
    }

    // MARK: Facts

    /// The values of the host and the build that every scenario's facts hold in place of a token.
    /// A scenario that runs a CLI command adds the CLI version, because LungfishTestSupport cannot
    /// import LungfishCLI.
    public static func hostReplacements() -> [Replacement] {
        var result: [Replacement] = [
            .literal(WorkflowRun.currentAppVersion, as: "<app-version>"),
            .literal(WorkflowRun.currentHostOS, as: "<host-os>"),
            .literal(ProcessInfo.processInfo.hostName, as: "<host-name>"),
        ]
        if let version = try? ManagedToolLock.loadFromBundle().tool(named: "sra-tools")?.version, !version.isEmpty {
            result.append(.literal("sra-tools \(version)", as: "sra-tools <sra-tools-version>"))
        }
        return result
    }

    /// Projects `sidecar` and normalizes the result for `scenario`.
    ///
    /// - Parameters:
    ///   - sidecar: The record the writer produced inside `project`.
    ///   - extraReplacements: Host values only the caller knows, such as the CLI version.
    public static func facts(
        of sidecar: URL,
        in project: ProvenanceCompatScenarios.Project,
        scenario: Scenario,
        replacing extraReplacements: [Replacement] = []
    ) throws -> ProvenanceCompatFacts {
        let projected = try ProvenanceCompatFacts.project(sidecar: sidecar, projectRoot: project.root)
        try dumpSidecarForReview(sidecar, in: project, scenario: scenario)
        return try normalized(projected, scenario: scenario, replacing: extraReplacements)
    }

    /// Set to a folder to receive a copy of each sidecar a scenario writes and the project it sat in,
    /// so a reviewer can read the captured facts against the bytes. The gate never sets it.
    public static let dumpVariable = "LUNGFISH_PARITY_DUMP_DIR"

    private static func dumpSidecarForReview(
        _ sidecar: URL,
        in project: ProvenanceCompatScenarios.Project,
        scenario: Scenario
    ) throws {
        guard let folder = ProcessInfo.processInfo.environment[dumpVariable], !folder.isEmpty else { return }
        let destination = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data(contentsOf: sidecar).write(to: destination.appendingPathComponent("\(scenario.id).sidecar.json"))
        try Data(project.root.path.utf8).write(to: destination.appendingPathComponent("\(scenario.id).project.txt"))
    }

    /// The facts with host values replaced by tokens, the run-specific values cleared and the
    /// checksum of each volatile file cleared. The result is the same on every Mac and every run.
    public static func normalized(
        _ facts: ProvenanceCompatFacts,
        scenario: Scenario,
        replacing extraReplacements: [Replacement] = []
    ) throws -> ProvenanceCompatFacts {
        let data = try JSONEncoder().encode(facts)
        var tree = try JSONDecoder().decode(ProvenanceCompatFacts.Value.self, from: data)

        let replacements = hostReplacements() + scenario.replacements + extraReplacements
        let literals = replacements.filter { $0.kind == .literal && !$0.pattern.isEmpty }
            .sorted { $0.pattern.count > $1.pattern.count }
        let expressions = replacements.filter { $0.kind == .regularExpression }
        for expression in expressions {
            guard (try? NSRegularExpression(pattern: expression.pattern)) != nil else {
                throw ParityError.invalidReplacement(expression.pattern)
            }
        }
        tree = tree.mappingStrings { text in
            var result = text
            for literal in literals {
                result = result.replacingOccurrences(of: literal.pattern, with: literal.token)
            }
            for expression in expressions {
                result = result.replacingOccurrences(
                    of: expression.pattern,
                    with: expression.token,
                    options: .regularExpression
                )
            }
            return result
        }
        tree = clearingChecksums(ofFilesEndingWith: scenario.volatileFileSuffixes, in: tree)

        guard case .object(var members) = tree else { throw ParityError.factsAreNotAnObject }
        // The host values under `recorded` are what the corpus never compares, and a live run
        // records a process id and a creation date in them.
        members["recorded"] = .object([:])
        if scenario.timing != .injected {
            members["wallTimeSeconds"] = nil
            if case .object(var ops)? = members["opsStats"] {
                ops["totalWallTimeSeconds"] = .integer(0)
                members["opsStats"] = .object(ops)
            }
        }
        if scenario.timing == .clockedRunAndSteps {
            members["steps"] = removing("wallTimeSeconds", fromElementsOf: members["steps"])
            members["legacyRunSteps"] = removing("wallTime", fromElementsOf: members["legacyRunSteps"])
            members["canonicalRunSteps"] = removing("wallTime", fromElementsOf: members["canonicalRunSteps"])
        }
        let normalizedData = try JSONEncoder().encode(ProvenanceCompatFacts.Value.object(members))
        return try JSONDecoder().decode(ProvenanceCompatFacts.self, from: normalizedData)
    }

    // MARK: Expected facts

    /// The expected facts of `scenario`, or nil when none are captured yet.
    public static func expectedFacts(for scenario: Scenario) throws -> ProvenanceCompatFacts? {
        guard Scenarios.all.contains(scenario) else { throw ParityError.unregisteredScenario(scenario.id) }
        switch scenario.source {
        case .corpusCase:
            guard let data = ProvenanceCompatCorpus.expectedFactsData(for: scenario.id) else { return nil }
            return try ProvenanceCompatFacts.decode(data)
        case .parityFixture:
            guard let data = try? Data(contentsOf: expectedFactsURL(for: scenario)) else { return nil }
            return try ProvenanceCompatFacts.decode(data)
        }
    }

    /// Writes `facts` as the expected facts of `scenario`. It runs only with
    /// `LUNGFISH_CAPTURE_PROVENANCE_FACTS=1`, only for a scenario with a fixture of its own, and it
    /// never replaces a file.
    public static func capture(_ facts: ProvenanceCompatFacts, as scenario: Scenario) throws {
        guard Scenarios.all.contains(scenario) else { throw ParityError.unregisteredScenario(scenario.id) }
        guard ProvenanceCompatCorpus.captureFactsRequested else {
            throw ProvenanceCompatCorpusError.captureNotRequested(ProvenanceCompatCorpus.captureFactsVariable)
        }
        let destination = expectedFactsURL(for: scenario)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw ProvenanceCompatCorpusError.wouldOverwrite("\(scenario.id).facts.json")
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try facts.canonicalJSON().write(to: destination, options: .withoutOverwriting)
    }

    // MARK: Comparison

    /// The fields a comparison leaves out because the scenario's run decides them for itself.
    public static func runSpecificFields(of scenario: Scenario) -> Set<ProvenanceCompatFacts.Field> {
        switch scenario.timing {
        case .injected:
            // Every date is injected, so only the host values under `recorded` belong to the run.
            return [.recorded]
        case .clockedRun:
            // The run's own dates come from a clock, and each step's wall time is fixed by the test.
            return ProvenanceCompatFacts.runSpecific
        case .clockedRunAndSteps:
            // The writer measures each step with a real clock, as a real tool would, so no two runs agree.
            return ProvenanceCompatFacts.realToolRun
        }
    }

    /// How a writer's facts differ from the facts captured on unchanged code. The writer must still
    /// say exactly what it said. The first call for a scenario with no captured facts writes them
    /// when `LUNGFISH_CAPTURE_PROVENANCE_FACTS=1`, and reports no difference.
    public static func problemsBeforeConversion(
        _ facts: ProvenanceCompatFacts,
        scenario: Scenario
    ) throws -> [String] {
        guard let expected = try expectedFacts(for: scenario) else {
            guard scenario.source == .parityFixture, ProvenanceCompatCorpus.captureFactsRequested else {
                throw ParityError.noExpectedFacts(id: scenario.id)
            }
            try capture(facts, as: scenario)
            return []
        }
        return facts.differences(from: expected, ignoring: runSpecificFields(of: scenario))
    }
}

// MARK: - Tree helpers

extension BareRunWriterParity {
    /// Clears `sha256` and `size` in every file fact whose path ends with one of `suffixes`. A file
    /// fact is an object with a string `path` and a string `role`.
    fileprivate static func clearingChecksums(
        ofFilesEndingWith suffixes: [String],
        in value: ProvenanceCompatFacts.Value
    ) -> ProvenanceCompatFacts.Value {
        guard !suffixes.isEmpty else { return value }
        switch value {
        case .object(let members):
            var mapped = members.mapValues { clearingChecksums(ofFilesEndingWith: suffixes, in: $0) }
            if case .string(let path)? = mapped["path"], case .string? = mapped["role"],
               suffixes.contains(where: { path.hasSuffix($0) }) {
                mapped["sha256"] = nil
                mapped["size"] = nil
            }
            return .object(mapped)
        case .array(let items):
            return .array(items.map { clearingChecksums(ofFilesEndingWith: suffixes, in: $0) })
        default:
            return value
        }
    }

    fileprivate static func removing(
        _ key: String,
        fromElementsOf value: ProvenanceCompatFacts.Value?
    ) -> ProvenanceCompatFacts.Value? {
        guard case .array(let elements)? = value else { return value }
        return .array(elements.map { element in
            guard case .object(var members) = element else { return element }
            members[key] = nil
            return .object(members)
        })
    }
}
