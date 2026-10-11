// FakeClassificationCondaFixture.swift - A conda root whose stand-in micromamba runs a fake kraken2 and Bracken
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Moved from ClassificationPipelineProvenanceSourceTests.swift by Phase 2.7
// lane F1, so the classifier freeze in LungfishAppTests drives the same fake
// tools. The fixture builds its conda root with the test initializer of
// `CondaManager` and checksums installed files with
// `ManagedToolSourceInstallationRecord.sha256(of:)`. Both are internal to
// LungfishWorkflow, so this file imports it `@testable`, the one such import
// in LungfishTestSupport. The package builds in the debug configuration,
// the app included (scripts/build-app.sh), which compiles LungfishWorkflow
// for testing.

import Foundation
import LungfishIO
@testable import LungfishWorkflow

public struct FakeClassificationCondaFixture {
    public enum ReportRank: String {
        case genus = "G"
        case species = "S"

        var taxID: Int { self == .genus ? 561 : 562 }
        var name: String { self == .genus ? "Escherichia" : "Escherichia coli" }
    }

    public enum DistributionState: CustomStringConvertible {
        case valid
        case missing
        case empty
        case directory
        case unreadable
        case symbolicLink

        public var description: String {
            switch self {
            case .valid: return "valid"
            case .missing: return "missing"
            case .empty: return "empty"
            case .directory: return "directory"
            case .unreadable: return "unreadable"
            case .symbolicLink: return "symbolicLink"
            }
        }
    }

    public enum BrackenBehavior {
        case success
        case nonzero(Int32)
        case unavailable
        case missingOutput
        case malformedOutput
        case unmatchedOutput
        case launchFailure
        case waitForCancellation
    }

    public enum KrakenBehavior {
        case success
        case nonzero(Int32)
    }

    /// What the fixture's bracken environment holds, which decides the version a run records.
    public enum BrackenInstall {
        /// The conda package bracken 1.0.0 stays as a stale record, and the v3.1 source overlay is
        /// installed and validated beside it, as the lock installs Bracken.
        case sourceOverlay(version: String)
        /// The conda package alone.
        case condaPackage(version: String)
        /// No record at all.
        case none
    }

    /// The help text `bracken --help` prints, which picks the dialect the pipeline speaks.
    public enum BrackenDialect: CaseIterable {
        case database
        case kmerDistribution

        var helpText: String {
            switch self {
            case .database:
                return "Usage: bracken -d MY_DB -i INPUT.kreport -o OUTPUT.bracken -r READ_LEN -l LEVEL -t THRESHOLD"
            case .kmerDistribution:
                return "usage: est_abundance.py [-h] -i INPUT -o OUTPUT -k KMER_DISTR -l LEVEL -t THRESHOLD"
            }
        }
    }

    public let root: URL
    public let condaManager: CondaManager
    public let distributionURL: URL
    private let invocationLogURL: URL
    private let reportRank: ReportRank
    private let distributionState: DistributionState

    public init(
        reportRank: ReportRank = .species,
        distributionState: DistributionState = .valid,
        krakenVersion: String = "2.1.3",
        krakenBehavior: KrakenBehavior = .success,
        brackenBehavior: BrackenBehavior = .success,
        brackenInstall: BrackenInstall = .sourceOverlay(version: "3.1"),
        brackenDialect: BrackenDialect = .database
    ) throws {
        self.reportRank = reportRank
        self.distributionState = distributionState
        let fm = FileManager.default
        root = fm.temporaryDirectory.appendingPathComponent(
            "classification-provenance-\(UUID().uuidString)",
            isDirectory: true
        )
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        invocationLogURL = root.appendingPathComponent("tool-invocations.log")
        distributionURL = root
            .appendingPathComponent("kraken-db", isDirectory: true)
            .appendingPathComponent("database150mers.kmer_distrib")

        let bundledMicromamba = root.appendingPathComponent("bundled-micromamba")
        try Self.scriptBody(
            reportRank: reportRank,
            krakenVersion: krakenVersion,
            krakenBehavior: krakenBehavior,
            brackenBehavior: brackenBehavior,
            brackenHelpText: brackenDialect.helpText,
            invocationLogURL: invocationLogURL
        )
            .write(to: bundledMicromamba, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundledMicromamba.path)

        condaManager = CondaManager(
            rootPrefix: root.appendingPathComponent("conda", isDirectory: true),
            bundledMicromambaProvider: { bundledMicromamba },
            bundledMicromambaVersionProvider: { "2.0.0" }
        )
        try Self.installBracken(
            brackenInstall, in: root.appendingPathComponent("conda/envs/bracken", isDirectory: true)
        )
    }

    /// Writes the conda-meta records and, for an overlay, the installed files and the receipt that
    /// `CondaManager.validatedSourceOverlayVersion` checks.
    private static func installBracken(_ install: BrackenInstall, in environment: URL) throws {
        let fm = FileManager.default
        let condaMeta = environment.appendingPathComponent("conda-meta", isDirectory: true)
        func writeCondaRecord(_ name: String, _ version: String, _ build: String) throws {
            try fm.createDirectory(at: condaMeta, withIntermediateDirectories: true)
            try #"{"name":"\#(name)","version":"\#(version)","build":"\#(build)","subdir":"osx-arm64"}"#.write(
                to: condaMeta.appendingPathComponent("\(name)-\(version)-\(build).json"),
                atomically: true, encoding: .utf8
            )
        }
        switch install {
        case .none:
            return
        case .condaPackage(let version):
            try writeCondaRecord("bracken", version, "0")
        case .sourceOverlay(let version):
            try writeCondaRecord("bracken", "1.0.0", "0")
            let runtimePackages = [("cxx-compiler", "1.9.0", "h1"), ("llvm-openmp", "21.1.8", "h2"), ("python", "3.11.13", "h3")]
            for (name, packageVersion, build) in runtimePackages {
                try writeCondaRecord(name, packageVersion, build)
            }
            let compiler = environment.appendingPathComponent("bin/c++")
            let openMP = environment.appendingPathComponent("lib/libomp.dylib")
            try fm.createDirectory(at: compiler.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createDirectory(at: openMP.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "#!/bin/sh\nexit 0\n".write(to: compiler, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: compiler.path)
            try Data("OpenMP runtime\n".utf8).write(to: openMP)
            let installedFiles = try ["bin/bracken", "bin/bracken-build", "bin/src/kmer2read_distr"].map { path in
                let url = environment.appendingPathComponent(path)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("fixture \(path)\n".utf8).write(to: url)
                let size = (try fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
                guard let sha256 = ManagedToolSourceInstallationRecord.sha256(of: url) else {
                    throw CocoaError(.fileReadUnknown)
                }
                return ManagedToolSourceInstallationRecord.InstalledFile(relativePath: path, sha256: sha256, sizeBytes: size)
            }
            let record = ManagedToolSourceInstallationRecord(
                source: PackToolSourceOverlay(
                    kind: .bracken, version: version,
                    sourceURL: URL(string: "https://example.test/Bracken-v\(version).tar.gz")!,
                    sha256: String(repeating: "a", count: 64)
                ),
                commands: [.init(argv: ["bracken-build", "-v"], reproducibleCommand: "bracken-build -v")],
                runtime: .init(
                    environmentPath: environment.path, compilerPath: compiler.path, openMPRuntimePath: openMP.path,
                    condaPackages: runtimePackages.map { .init(name: $0.0, version: $0.1, build: $0.2, subdir: "osx-arm64") }
                ),
                installedFiles: installedFiles,
                startedAt: .now, completedAt: .now, wallTimeSeconds: 0, exitStatus: 0, stderr: ""
            )
            try record.write(to: environment.appendingPathComponent("share/lungfish/managed-tools/bracken.json"))
        }
    }

    public func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    public func toolInvocations(named toolName: String) throws -> [String] {
        guard FileManager.default.fileExists(atPath: invocationLogURL.path) else { return [] }
        return try readRepositorySource(invocationLogURL)
            .split(separator: "\n")
            .map(String.init)
            .filter { $0 == toolName || $0.hasPrefix("\(toolName) ") }
    }

    /// Bracken invocations that are actual profiling runs, excluding the version
    /// probes and the `--help` CLI-dialect probe.
    public func brackenProfileInvocations() throws -> [String] {
        try toolInvocations(named: "bracken").filter {
            $0 != "bracken -v" && $0 != "bracken --version" && $0 != "bracken --help"
        }
    }

    public func makeConfig(
        goal: ClassificationConfig.Goal = .classify,
        databaseDigest: String? = "sha256:fixture-db",
        catalogID: String? = nil,
        installationRecipe: MetagenomicsDatabaseInstallationRecipe? = nil,
        profileRequest: BrackenProfileRequest? = nil,
        inputFormat: SequenceFormat = .fastq,
        memoryMapping: Bool = false,
        quickMode: Bool = false
    ) throws -> ClassificationConfig {
        let dbURL = root.appendingPathComponent("kraken-db", isDirectory: true)
        try FileManager.default.createDirectory(at: dbURL, withIntermediateDirectories: true)
        for filename in ["hash.k2d", "opts.k2d", "taxo.k2d"] {
            try "fake-db\n".write(to: dbURL.appendingPathComponent(filename), atomically: true, encoding: .utf8)
        }
        try materializeDistribution(in: dbURL)

        let readsURL = root.appendingPathComponent("reads.fastq")
        try "@read1\nACGT\n+\nIIII\n".write(to: readsURL, atomically: true, encoding: .utf8)

        return ClassificationConfig(
            goal: goal,
            inputFiles: [readsURL],
            isPairedEnd: false,
            databaseName: "FixtureDB",
            inputFormat: inputFormat,
            databaseVersion: "fixture-v1",
            databasePath: dbURL,
            databaseDigest: databaseDigest,
            databaseCatalogID: catalogID,
            databaseInstallationRecipe: installationRecipe,
            brackenProfileRequest: profileRequest,
            memoryMapping: memoryMapping,
            quickMode: quickMode,
            outputDirectory: root.appendingPathComponent("output", isDirectory: true)
        )
    }

    private func materializeDistribution(in databaseURL: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: distributionURL)
        switch distributionState {
        case .valid:
            try "synthetic 150-mer distribution\n".write(
                to: distributionURL,
                atomically: true,
                encoding: .utf8
            )
        case .missing:
            break
        case .empty:
            try Data().write(to: distributionURL)
        case .directory:
            try fm.createDirectory(at: distributionURL, withIntermediateDirectories: true)
        case .unreadable:
            try "unreadable\n".write(to: distributionURL, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: distributionURL.path)
        case .symbolicLink:
            let target = databaseURL.appendingPathComponent("distribution-target")
            try "target\n".write(to: target, atomically: true, encoding: .utf8)
            try fm.createSymbolicLink(at: distributionURL, withDestinationURL: target)
        }
    }

    private static func scriptBody(
        reportRank: ReportRank,
        krakenVersion: String,
        krakenBehavior: KrakenBehavior,
        brackenBehavior: BrackenBehavior,
        brackenHelpText: String,
        invocationLogURL: URL
    ) -> String {
        let krakenFailureBody: String
        switch krakenBehavior {
        case .success:
            krakenFailureBody = ":"
        case .nonzero(let exitCode):
            krakenFailureBody = """
            echo "synthetic kraken2 failure" >&2
            exit \(exitCode)
            """
        }
        let brackenBody: String
        switch brackenBehavior {
        case .success:
            brackenBody = """
            printf 'name\\ttaxonomy_id\\ttaxonomy_lvl\\tkraken_assigned_reads\\tadded_reads\\tnew_est_reads\\tfraction_total_reads\\n\(reportRank.name)\\t\(reportRank.taxID)\\t\(reportRank.rawValue)\\t1\\t0\\t1\\t1.0\\n' > "$output"
            exit 0
            """
        case .nonzero(let exitCode):
            brackenBody = """
            echo "synthetic bracken failure" >&2
            exit \(exitCode)
            """
        case .unavailable:
            brackenBody = """
            echo "bracken: executable not found" >&2
            exit 127
            """
        case .missingOutput:
            brackenBody = "exit 0"
        case .malformedOutput:
            brackenBody = """
            printf 'name\\ttaxonomy_id\\ttaxonomy_lvl\\tkraken_assigned_reads\\tadded_reads\\tnew_est_reads\\tfraction_total_reads\\n' > "$output"
            exit 0
            """
        case .unmatchedOutput:
            brackenBody = """
            printf 'name\\ttaxonomy_id\\ttaxonomy_lvl\\tkraken_assigned_reads\\tadded_reads\\tnew_est_reads\\tfraction_total_reads\\nUnknown taxon\\t999999\\t\(reportRank.rawValue)\\t1\\t0\\t1\\t1.0\\n' > "$output"
            exit 0
            """
        case .launchFailure:
            brackenBody = "exit 70"
        case .waitForCancellation:
            brackenBody = """
            sleep 30
            printf 'name\\ttaxonomy_id\\ttaxonomy_lvl\\tkraken_assigned_reads\\tadded_reads\\tnew_est_reads\\tfraction_total_reads\\n\(reportRank.name)\\t\(reportRank.taxID)\\t\(reportRank.rawValue)\\t1\\t0\\t1\\t1.0\\n' > "$output"
            exit 0
            """
        }
        let removeMicromamba: String
        if case .launchFailure = brackenBehavior {
            removeMicromamba = "rm -f \"$0\" \"\(invocationLogURL.deletingLastPathComponent().appendingPathComponent("bundled-micromamba").path)\""
        } else {
            removeMicromamba = ":"
        }

        return """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          echo "micromamba 2.0.0"
          exit 0
        fi
        if [ "$1" != "run" ]; then
          echo "unexpected micromamba invocation: $*" >&2
          exit 64
        fi
        shift
        if [ "$1" = "-n" ]; then
          shift
          shift
        fi
        tool="$1"
        shift
        printf '%s\\n' "$tool $*" >> "\(invocationLogURL.path)"
        case "$tool" in
          kraken2)
            if [ "$1" = "--version" ]; then
              echo "Kraken version \(krakenVersion)"
              exit 0
            fi
            \(krakenFailureBody)
            report=""
            output=""
            while [ "$#" -gt 0 ]; do
              case "$1" in
                --report)
                  shift
                  report="$1"
                  ;;
                --output)
                  shift
                  output="$1"
                  ;;
              esac
              shift
            done
            mkdir -p "$(dirname "$report")" "$(dirname "$output")"
            cat > "$report" <<'REPORT'
        100.00\t1\t0\tR\t1\troot
        100.00\t1\t1\t\(reportRank.rawValue)\t\(reportRank.taxID)\t  \(reportRank.name)
        REPORT
            printf 'C\tread1\t\(reportRank.taxID)\t4\t0:4\n' > "$output"
            echo "processed 1 sequence" >&2
            \(removeMicromamba)
            exit 0
            ;;
          bracken)
            if [ "$1" = "--version" ]; then
              echo "unsupported bracken version flag" >&2
              exit 64
            fi
            if [ "$1" = "-v" ]; then
              echo "Bracken v3.0.1"
              exit 0
            fi
            # This fixture models the real Bracken driver, which advertises -d;
            # the pipeline probes --help to choose between that and the
            # est_abundance.py passthrough CLI.
            if [ "$1" = "--help" ]; then
              echo "\(brackenHelpText)"
              exit 0
            fi
            output=""
            reportOutput=""
            while [ "$#" -gt 0 ]; do
              if [ "$1" = "-o" ]; then
                shift
                output="$1"
              elif [ "$1" = "-w" ]; then
                shift
                reportOutput="$1"
              fi
              shift
            done
            mkdir -p "$(dirname "$output")"
            if [ -n "$reportOutput" ]; then
              mkdir -p "$(dirname "$reportOutput")"
              printf '100.00\t1\t0\tR\t1\troot\n' > "$reportOutput"
            fi
            \(brackenBody)
            ;;
          *)
            echo "unexpected tool: $tool" >&2
            exit 64
            ;;
        esac
        """
    }
}
