// ClassifierLegacyRuns.swift - Today's classifier writers driven with fake tools, as the GUI and CLI drive them
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.7 lane F1, the unit-tier freeze of today's classifier records
// (panel decisions T2, T3 and T9, docs/plans/2026-10-11-phase-2-7.md). Each
// function runs one writer the way its route runs it at the base of 2.7, with
// the fake kraken2 and Bracken of `FakeClassificationCondaFixture` or the
// stand-in EsViritu below, so `ClassifierWriterFactsTests` and
// `ClassifierLegacyRecordPinTests` read the records the base writes.

import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
@testable import LungfishIO
@testable import LungfishWorkflow
import LungfishTestSupport

enum ClassifierLegacyRuns {

    // MARK: - conda classify

    /// What one `lungfish-cli conda classify` run left in its output folder.
    struct CondaClassifyRun {
        let command: ClassifyCommand
        /// The argv the wrapper record names, `lungfish-cli conda classify ...`.
        let argv: [String]
        let result: ClassificationResult
        /// The pipeline's own record, read before the wrapper replaced it.
        let pipelineEnvelope: ProvenanceEnvelope?
        /// The wrapper record `lungfish.classify`.
        let wrapperEnvelope: ProvenanceEnvelope
        let outputDirectory: URL
        /// How the command ends, `Kraken classification ... completed` or exit 64.
        let terminalPolicy: ClassifyTerminalPolicy
    }

    /// The arguments after `lungfish-cli conda classify` that the Operations
    /// panel records for `config` (`AppDelegate.classificationCLICommand(for:)`).
    static func recordedClassifyArguments(for config: ClassificationConfig) throws -> [String] {
        Array(try RecordedCLICommand.arguments(of: AppDelegate.classificationCLICommand(for: config)).dropFirst(2))
    }

    /// Runs `lungfish-cli conda classify <arguments>` in the order
    /// `ClassifyCommand.run` runs it after the registry lookup, which here
    /// finds `databasePath` under the recorded name. It resolves, configures,
    /// plans, runs the pipeline over `condaManager`, writes the wrapper record
    /// and takes the terminal policy.
    static func condaClassify(
        arguments: [String],
        databasePath: URL,
        condaManager: CondaManager,
        materializer: any CLISequenceInputMaterializing & Sendable = FASTQCLIMaterializer(runner: .shared)
    ) async throws -> CondaClassifyRun {
        let command = try ClassifyCommand.parse(arguments)
        let argv = [CLICommandIdentity.executableName, "conda", "classify"] + arguments
        let startedAt = Date()
        let inputs = try CLIClassificationFolderResolver.expandInputArguments(command.fastqFiles, recursive: command.recursive)
        let outputDirectory = URL(fileURLWithPath: try XCTUnwrap(command.outputDir), isDirectory: true)
        let materializationDirectory = outputDirectory.appendingPathComponent(".lungfish-classify-inputs", isDirectory: true)
        let resolved = try await ClassifyCommand.resolveExecutionInputs(
            for: inputs, tempDirectory: materializationDirectory, materializer: materializer
        )
        let durableReplayArgv = CLISequenceInputMaterialization.durableReplayArgv(
            argv: argv,
            originalInputArguments: resolved.argumentsPerExecutionFile(command.fastqFiles),
            originalInputURLs: resolved.originalInputURLs,
            executionInputURLs: resolved.executionInputURLs
        )
        let database = MetagenomicsDatabaseInfo(
            name: command.databaseName, tool: "kraken2", version: "fixture-v1", sizeBytes: 1, catalogID: nil,
            installationRecipe: nil, payloadDigest: "sha256:fixture-db", description: "", path: databasePath,
            status: .ready, recommendedRAM: 1
        )
        var config = try command.makeConfigForTesting(
            inputURLs: inputs,
            databaseInfo: database,
            inputFormat: try ClassifyCommand.inferInputFormat(from: inputs),
            outputDirectory: outputDirectory
        )
        config.inputFiles = resolved.executionInputURLs
        if let confidence = command.confidence { config.confidence = confidence }
        if let minimumHitGroups = command.minHitGroups { config.minimumHitGroups = minimumHitGroups }
        config.originalInputFiles = inputs.map(\.standardizedFileURL)
        config.sampleDisplayName = inputs.first?.deletingPathExtension().lastPathComponent
        let readSet = try await command.planReadSet(
            inputURLs: inputs,
            executionInputURLs: resolved.executionInputURLs,
            config: &config,
            materializationDirectory: materializationDirectory
        )

        let pipeline = ClassificationPipeline(condaManager: condaManager)
        let result = command.profile
            ? try await pipeline.profile(config: config)
            : try await pipeline.classify(config: config)
        let pipelineEnvelope = ProvenanceRecorder.loadEnvelope(from: outputDirectory)
        let sidecar = try ClassifyCommand.writeProvenance(
            result: result,
            originalInputURLs: readSet?.originalInputURLs ?? resolved.originalInputURLs,
            executionInputURLs: readSet?.executionInputURLs ?? resolved.executionInputURLs,
            argv: argv,
            durableReplayArgv: readSet == nil ? durableReplayArgv : nil,
            preset: command.preset.rawValue,
            startedAt: startedAt,
            endedAt: Date(),
            materializationStartedAt: resolved.materializationStartedAt,
            materializationEndedAt: resolved.materializationEndedAt,
            recursive: command.recursive,
            writer: ProvenanceWriter(signingProvider: nil)
        )
        return CondaClassifyRun(
            command: command,
            argv: argv,
            result: result,
            pipelineEnvelope: pipelineEnvelope,
            wrapperEnvelope: try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: sidecar)),
            outputDirectory: outputDirectory,
            terminalPolicy: ClassifyCommand.terminalPolicy(for: result)
        )
    }

    // MARK: - Kraken2 batch

    /// A Kraken2 batch of two samples as `runClassificationBatch` leaves it
    /// when both complete: each sample's pipeline record, the summary TSV from
    /// `ClassificationBatchOutcomePolicy`, the batch manifest, a stand-in for
    /// the `kraken2.sqlite` that `lungfish-cli build-db` writes, and the batch
    /// record with the `/bin/sh -c` replay command as its argv.
    static func kraken2Batch(fixture: FakeClassificationCondaFixture) async throws -> (batchRoot: URL, configs: [ClassificationConfig]) {
        let batchRoot = fixture.root.appendingPathComponent("Analyses/kraken2-batch", isDirectory: true)
        let secondInput = fixture.root.appendingPathComponent("reads-b.fastq")
        try "@read2\nTGCA\n+\nIIII\n".write(to: secondInput, atomically: true, encoding: .utf8)
        let startedAt = Date()
        var configs: [ClassificationConfig] = []
        var rows: [ClassificationBatchSummaryRow] = []
        var records: [MetagenomicsBatchSampleRecord] = []
        for (sampleID, input) in [("SampleA", nil), ("SampleB", secondInput)] {
            var config = try fixture.makeConfig(goal: .profile, profileRequest: .automaticDefault)
            if let input { config.inputFiles = [input] }
            config.outputDirectory = batchRoot.appendingPathComponent(sampleID, isDirectory: true)
            let result = try await ClassificationPipeline(condaManager: fixture.condaManager).profile(config: config)
            let row = ClassificationBatchOutcomePolicy.row(sampleId: sampleID, result: result)
            configs.append(config)
            rows.append(row)
            records.append(MetagenomicsBatchSampleRecord(
                sampleId: sampleID, resultDirectory: sampleID, inputFiles: config.inputFiles.map(\.path),
                isPairedEnd: config.isPairedEnd, status: row.status, message: row.message.isEmpty ? nil : row.message
            ))
        }
        let evaluation = ClassificationBatchOutcomePolicy.evaluate(rows: rows, sqliteWarning: nil)
        let summaryURL = batchRoot.appendingPathComponent("classification-batch-summary.tsv")
        try ClassificationBatchOutcomePolicy.summaryTSV(rows: rows).write(to: summaryURL, atomically: true, encoding: .utf8)
        let manifest = ClassificationBatchResultManifest(
            header: MetagenomicsBatchManifestHeader(schemaVersion: 2, createdAt: Date(), sampleCount: configs.count),
            goal: configs[0].goal.rawValue,
            databaseName: configs[0].databaseName,
            databaseVersion: configs[0].databaseVersion,
            summaryTSV: summaryURL.lastPathComponent,
            samples: records,
            completedCount: evaluation.completedCount,
            degradedCount: evaluation.degradedCount,
            failedCount: evaluation.failedCount
        )
        try MetagenomicsBatchResultStore.saveClassification(manifest, to: batchRoot)
        let sqliteURL = batchRoot.appendingPathComponent("kraken2.sqlite")
        try Data("stand-in for the build-db index\n".utf8).write(to: sqliteURL)
        try MetagenomicsBatchProvenanceWriter.writeClassificationBatchProvenance(
            batchRoot: batchRoot,
            manifest: manifest,
            summaryURL: summaryURL,
            sqliteURL: sqliteURL,
            command: AppDelegate.classificationBatchReplayCommand(configurations: configs),
            additionalStderr: [],
            additionalInputURLs: configs.flatMap(\.inputFiles),
            additionalSampleDirectories: [],
            context: ClassificationBatchProvenanceContext(configurations: configs, startedAt: startedAt, completedAt: Date())
        )
        return (batchRoot, configs)
    }

    // MARK: - EsViritu

    /// The config the EsViritu wizard builds for one sample file.
    static func esVirituConfig(input: URL, sampleName: String, outputDirectory: URL, databasePath: URL) -> EsVirituConfig {
        EsVirituConfig(
            inputFiles: [input],
            isPairedEnd: false,
            sampleName: sampleName,
            outputDirectory: outputDirectory,
            databasePath: databasePath,
            threads: 4,
            readFormat: .unpaired
        )
    }

    /// An EsViritu batch of two samples as `runEsVirituBatch` leaves it when
    /// both complete: each sample's pipeline record, a summary TSV, the batch
    /// manifest, a stand-in for the `esviritu.sqlite` that `lungfish-cli
    /// build-db` writes, and the batch record whose argv folds every input into
    /// one `esviritu detect` (`EsVirituCLIInvocationBuilder.esVirituBatchCLIArguments(for:)`).
    static func esVirituBatch(root: URL, esviritu: StandInEsVirituConda) async throws -> (batchRoot: URL, configs: [EsVirituConfig]) {
        let batchRoot = root.appendingPathComponent("Analyses/esviritu-batch", isDirectory: true)
        var configs: [EsVirituConfig] = []
        var summary = ["sample_id\tstatus\tvirus_count\tfamilies\tspecies\terror"]
        for sampleID in ["SampleA", "SampleB"] {
            let input = root.appendingPathComponent("inputs/\(sampleID).fastq")
            try FileManager.default.createDirectory(at: input.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "@\(sampleID)-1\nACGTACGTAC\n+\nIIIIIIIIII\n".write(to: input, atomically: true, encoding: .utf8)
            let config = esVirituConfig(
                input: input,
                sampleName: sampleID,
                outputDirectory: batchRoot.appendingPathComponent(sampleID, isDirectory: true),
                databasePath: esviritu.databaseURL
            )
            let result = try await EsVirituPipeline(condaManager: esviritu.condaManager).detect(config: config)
            summary.append("\(sampleID)\tok\t\(result.virusCount)\t0\t0\t")
            configs.append(config)
        }
        let summaryURL = batchRoot.appendingPathComponent("esviritu-batch-summary.tsv")
        try summary.joined(separator: "\n").write(to: summaryURL, atomically: true, encoding: .utf8)
        let manifest = EsVirituBatchResultManifest(
            header: MetagenomicsBatchManifestHeader(schemaVersion: 1, createdAt: Date(), sampleCount: configs.count),
            summaryTSV: summaryURL.lastPathComponent,
            samples: configs.map {
                MetagenomicsBatchSampleRecord(
                    sampleId: $0.sampleName, resultDirectory: $0.sampleName,
                    inputFiles: $0.inputFiles.map(\.path), isPairedEnd: $0.readFormat.runsAsPairs
                )
            }
        )
        try MetagenomicsBatchResultStore.saveEsViritu(manifest, to: batchRoot)
        let sqliteURL = batchRoot.appendingPathComponent("esviritu.sqlite")
        try Data("stand-in for the build-db index\n".utf8).write(to: sqliteURL)
        try MetagenomicsBatchProvenanceWriter.writeEsVirituBatchProvenance(
            batchRoot: batchRoot,
            manifest: manifest,
            summaryURL: summaryURL,
            sqliteURL: sqliteURL,
            command: [CLICommandIdentity.executableName, "esviritu", "detect"]
                + EsVirituCLIInvocationBuilder.esVirituBatchCLIArguments(for: configs)
        )
        return (batchRoot, configs)
    }

    /// A conda root whose stand-in micromamba runs a stand-in kraken2 2.1.3
    /// that writes one per-read line for each pair or single read, as kraken2
    /// does and as the pipeline checks, so a planned read set classifies. It
    /// runs no Bracken, as the CLI suites' `ReadSetStandInKraken2` does not.
    struct StandInKraken2Conda {
        let condaManager: CondaManager
        let databaseURL: URL

        init(root: URL) throws {
            let fm = FileManager.default
            databaseURL = root.appendingPathComponent("kraken-db", isDirectory: true)
            try fm.createDirectory(at: databaseURL, withIntermediateDirectories: true)
            for filename in ["hash.k2d", "opts.k2d", "taxo.k2d"] {
                try "fake-db\n".write(to: databaseURL.appendingPathComponent(filename), atomically: true, encoding: .utf8)
            }
            let micromamba = root.appendingPathComponent("stand-in-kraken2-micromamba")
            try Self.script.write(to: micromamba, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: micromamba.path)
            condaManager = CondaManager(
                rootPrefix: root.appendingPathComponent("kraken2-conda", isDirectory: true),
                bundledMicromambaProvider: { micromamba },
                bundledMicromambaVersionProvider: { "2.0.0" }
            )
        }

        private static let script = """
            #!/bin/sh
            if [ "$1" = "--version" ]; then echo "micromamba 2.0.0"; exit 0; fi
            [ "$1" = "run" ] || { echo "unexpected micromamba invocation: $*" >&2; exit 64; }
            shift
            if [ "$1" = "-n" ]; then shift; shift; fi
            tool="$1"; shift
            [ "$tool" = "kraken2" ] || { echo "unexpected tool: $tool" >&2; exit 64; }
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
              total=$((total + $(awk 'END { print int(NR / 4) }' "$f")))
            done
            mkdir -p "$(dirname "$report")" "$(dirname "$output")"
            printf '100.00\\t1\\t0\\tR\\t1\\troot\\n100.00\\t1\\t1\\tS\\t562\\t  Escherichia coli\\n' > "$report"
            : > "$output"
            i=0
            while [ "$i" -lt "$total" ]; do printf 'C\\tread%s\\t562\\t4\\t0:4\\n' "$i" >> "$output"; i=$((i + 1)); done
            echo "$total sequences (0.00 Mbp) processed in 0.001s (1.0 Kseq/m, 0.01 Mbp/m)." >&2
            exit 0
            """
    }

    /// A conda root whose stand-in micromamba runs a stand-in EsViritu 1.3.3.
    /// It writes an empty detection table for the sample in the `-o` folder,
    /// as the CLI suites' `StandInEsViritu` does, and keeps nothing else.
    struct StandInEsVirituConda {
        let condaManager: CondaManager
        let databaseURL: URL

        init(root: URL) throws {
            let fm = FileManager.default
            databaseURL = root.appendingPathComponent("esviritu-db", isDirectory: true)
            try fm.createDirectory(at: databaseURL, withIntermediateDirectories: true)
            let micromamba = root.appendingPathComponent("stand-in-micromamba")
            try Self.script.write(to: micromamba, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: micromamba.path)
            condaManager = CondaManager(
                rootPrefix: root.appendingPathComponent("conda", isDirectory: true),
                bundledMicromambaProvider: { micromamba },
                bundledMicromambaVersionProvider: { "2.0.0" }
            )
        }

        private static let script = """
            #!/bin/sh
            if [ "$1" = "--version" ]; then echo "micromamba 2.0.0"; exit 0; fi
            [ "$1" = "run" ] || { echo "unexpected micromamba invocation: $*" >&2; exit 64; }
            shift
            if [ "$1" = "-n" ]; then shift; shift; fi
            tool="$1"; shift
            [ "$tool" = "EsViritu" ] || { echo "unexpected tool: $tool" >&2; exit 64; }
            if [ "$1" = "--version" ] || [ "$1" = "-v" ]; then echo "EsViritu 1.3.3"; exit 0; fi
            sample=""; output=""
            while [ "$#" -gt 0 ]; do
              case "$1" in
                -s) shift; sample="$1" ;;
                -o) shift; output="$1" ;;
              esac
              shift
            done
            mkdir -p "$output"
            printf 'sample_ID\\tName\\tdescription\\tLength\\tSegment\\tAccession\\tAssembly\\tAsm_length\\tkingdom\\tphylum\\ttclass\\torder\\tfamily\\tgenus\\tspecies\\tsubspecies\\tRPKMF\\tread_count\\tcovered_bases\\tmean_coverage\\tavg_read_identity\\tPi\\tfiltered_reads_in_sample\\n' > "$output/$sample.detected_virus.info.tsv"
            echo "EsViritu stand-in finished" >&2
            exit 0
            """
    }
}
