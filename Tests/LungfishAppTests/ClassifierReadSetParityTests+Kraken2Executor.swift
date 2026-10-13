// ClassifierReadSetParityTests+Kraken2Executor.swift - The executor column of the read-set table for Kraken2
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.7 lane F3, wired to the command in Phase 2.8 lane Q4. The command the Operations panel
// records for the wizard's Kraken2 config, `kraken2 classify` since decision E11, is parsed by the
// shipped parser and run whole by `ClassifyCommand.execute`, the body `run()` calls. The column
// replaces only the registry, the materializer and the pipeline, so the input expansion, the
// destination, the cancel source, the events and the executor are the command's own and a change
// to that wiring shows in the table. `--format json` gives the command no text presentation and
// prints its events as JSON lines on standard output, where the column reads the `failed` one.
// The config the executor hands `ClassificationPipeline` is rendered, as the gui and cli columns
// render theirs, a stand-in kraken2 lets the run complete, and the read-set plan is read from the
// root record through the one reader from its one home (E13), as the EsViritu column reads it.

import ArgumentParser
import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
@testable import LungfishIO
@testable import LungfishWorkflow
import LungfishKitTestSupport
import LungfishTestSupport

extension ClassifierReadSetParityTests {
    /// The executor route for Kraken2. Renders the kraken2 argv of the config the executor hands
    /// the pipeline, the reads of each file after `--report-minimizer-data` and the read-set plan
    /// of the root record. A refused or failed command renders the reason its `failed` event gives.
    func executorKraken2(_ sample: MetagenomicsSampleInput, row: Row, run: URL, mask: PathMask) async throws -> String {
        let recorded = ClassifierLaunchReference.kraken2Command(for: await kraken2WizardConfig(sample, run: run))
        let arguments = try RecordedCLICommand.arguments(of: recorded)
        XCTAssertEqual(Array(arguments.prefix(2)), ["kraken2", "classify"], "the row records kraken2 classify (E11)")
        let command = try ClassifyCommand.parse(Array(arguments.dropFirst(2)) + ["--format", "json"])
        let kraken2 = try StandInKraken2(root: run.appendingPathComponent("tool", isDirectory: true), database: databaseURL)
        let database = MetagenomicsDatabaseInfo(
            name: command.databaseName, tool: "kraken2", version: "1", sizeBytes: 1, catalogID: "kraken2-viral",
            installationRecipe: nil, payloadDigest: nil, description: "", path: databaseURL,
            status: .ready, recommendedRAM: 1
        )
        let handed = HandedConfig()
        let output = URL(fileURLWithPath: try XCTUnwrap(command.outputDir), isDirectory: true)
        let (status, failure) = try await Self.executeWhole(
            command,
            eventsIn: run,
            database: database,
            materializer: materializer(for: row),
            pipeline: ClassificationPipeline(condaManager: kraken2.condaManager),
            handed: handed
        )
        guard status == 0 else {
            return "\(status == 3 ? "refused" : "exit \(status)"): \(mask(failure ?? "no reason"))"
        }
        let argv = try XCTUnwrap(handed.value, "the executor handed the pipeline no config").kraken2Arguments()
        let start = (argv.firstIndex(of: "--report-minimizer-data") ?? argv.endIndex - 1) + 1
        let record = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: output))
        let planText: String
        switch record.readSetPlan {
        case nil:
            planText = "none"
        case let plan? where plan.place == .resolvedDefaults:
            planText = Self.render(.dictionary([RecordedReadSetPlan.key: .dictionary(plan.fields)]), mask: mask)
        case let plan?:
            planText = "outside resolvedDefaults, in \(plan.place)"
        }
        return try render(argv: argv, inputs: Array(argv[start...]), planText: planText, mask: mask)
    }

    /// Runs `command` whole through `ClassifyCommand.execute`, the body `run()` calls, and returns
    /// its exit status with the reason on the last `failed` event it printed. `adjustServices`
    /// replaces the registry lookup, the materializer and the pipeline, which hands `handed` the
    /// config it was given, and leaves every other service as the command builds it. The events are
    /// the JSON lines `--format json` prints on standard output, which the route parity harness
    /// sends to a file in `folder` while the command runs (lane Q30), and the lines that are not
    /// events are skipped.
    private nonisolated static func executeWhole(
        _ command: ClassifyCommand,
        eventsIn folder: URL,
        database: MetagenomicsDatabaseInfo,
        materializer: any CLISequenceInputMaterializing & Sendable,
        pipeline: ClassificationPipeline,
        handed: HandedConfig
    ) async throws -> (status: Int32, failure: String?) {
        let (status, lines) = try await RouteParityHarness.capturingStandardOutput(in: folder) { () async throws -> Int32 in
            do {
                try await command.execute { services in
                    services.database = { _ in database }
                    services.availableDatabases = { [database] }
                    services.materializer = materializer
                    services.runPipeline = { config, progress in
                        handed.set(config)
                        return config.goal == .profile
                            ? try await pipeline.profile(config: config, progress: progress)
                            : try await pipeline.classify(config: config, progress: progress)
                    }
                }
                return 0
            } catch let exit as ExitCode {
                return exit.rawValue
            }
        }
        let decoder = CLIEventLineDecoder()
        let failures = lines.compactMap { line -> String? in
            guard case .failed(let message, _)? = (try? decoder.decodeLine(line))?.event else { return nil }
            return message
        }
        return (status, failures.last)
    }
}

/// The config the executor handed the pipeline.
private final class HandedConfig: @unchecked Sendable {
    private let lock = NSLock()
    private var config: ClassificationConfig?

    func set(_ value: ClassificationConfig) {
        lock.withLock { config = value }
    }

    var value: ClassificationConfig? {
        lock.withLock { config }
    }
}

/// A conda root whose stand-in micromamba runs a stand-in kraken2 2.1.3 over the database folder
/// the table masks as `<db>`. kraken2 counts the fragments it is given, one per pair with
/// `--paired`, and writes a report and one per-read line for each, so the pipeline's count check
/// holds and the run completes. Any other tool, Bracken, finds no reads and exits 1, so a profile
/// degrades as K6's does with real tools.
private struct StandInKraken2 {
    let condaManager: CondaManager

    init(root: URL, database: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: database, withIntermediateDirectories: true)
        for name in ["hash.k2d", "opts.k2d", "taxo.k2d"] where !fileManager.fileExists(atPath: database.appendingPathComponent(name).path) {
            try "stand-in\n".write(to: database.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let micromamba = root.appendingPathComponent("stand-in-micromamba")
        try """
            #!/bin/sh
            if [ "$1" = "--version" ]; then echo "micromamba 2.0.0"; exit 0; fi
            [ "$1" = "run" ] || { echo "unexpected micromamba invocation: $*" >&2; exit 64; }
            shift
            if [ "$1" = "-n" ]; then shift; shift; fi
            tool="$1"; shift
            if [ "$tool" != "kraken2" ]; then
              if [ "$1" = "--version" ] || [ "$1" = "-v" ]; then echo "Bracken v2.9"; exit 0; fi
              echo "Error: no reads found. Please check your Kraken report" >&2; exit 1
            fi
            if [ "$1" = "--version" ]; then echo "Kraken version 2.1.3"; exit 0; fi
            report=""; output=""; paired=0; files=""
            while [ "$#" -gt 0 ]; do
              case "$1" in
                --db|--threads|--confidence|--minimum-hit-groups) shift ;;
                --report) shift; report="$1" ;;
                --output) shift; output="$1" ;;
                --paired) paired=1 ;;
                --*) ;;
                *) files="$files $1" ;;
              esac
              shift
            done
            total=0; position=0
            for f in $files; do
              position=$((position + 1))
              if [ "$paired" = 1 ] && [ $((position % 2)) = 0 ]; then continue; fi
              case "$f" in
                *.fasta|*.fa) n=$(grep -c '^>' "$f") ;;
                *) n=$(awk 'END { print int(NR / 4) }' "$f") ;;
              esac
              total=$((total + n))
            done
            mkdir -p "$(dirname "$report")" "$(dirname "$output")"
            printf '100.00\\t1\\t0\\tR\\t1\\troot\\n100.00\\t1\\t1\\tS\\t562\\t  Escherichia coli\\n' > "$report"
            : > "$output"
            i=0
            while [ "$i" -lt "$total" ]; do printf 'C\\tread%s\\t562\\t4\\t0:4\\n' "$i" >> "$output"; i=$((i + 1)); done
            echo "$total sequences (0.00 Mbp) processed in 0.001s (1.0 Kseq/m, 0.01 Mbp/m)." >&2
            exit 0
            """.write(to: micromamba, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: micromamba.path)
        condaManager = CondaManager(
            rootPrefix: root.appendingPathComponent("conda", isDirectory: true),
            bundledMicromambaProvider: { micromamba },
            bundledMicromambaVersionProvider: { "2.0.0" }
        )
    }
}
