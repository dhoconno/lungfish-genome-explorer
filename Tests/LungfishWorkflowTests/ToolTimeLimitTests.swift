// ToolTimeLimitTests.swift - An analysis tool run has no wall-clock limit unless its caller sets one
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import os
@testable import LungfishWorkflow
import LungfishCore
import LungfishTestSupport

/// `docs/contracts/SCOPE-AND-DELIVERY.md`, Tool run time. An analysis tool has no wall-clock limit by default,
/// and a limit is a named option that its caller sets. Each conda test reads the limit through
/// `CondaToolTimeLimit.specProbe`, so no test runs a tool for the length of a limit.
final class ToolTimeLimitTests: XCTestCase {

    // MARK: - CondaManager.runTool

    func testRunToolWithNoTimeoutArgumentGetsNoWallClockLimit() async throws {
        let (manager, sandbox) = try await makeScriptedManager()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let limits = try await limitsOfLaunches {
            _ = try await manager.runTool(name: "analysis-tool", environment: "analysis-env")
        }

        XCTAssertEqual(limits, [nil], "runTool builds one launch, and with no timeout argument it carries no wall-clock limit")
    }

    func testRunToolWithAStdoutHandlerAndNoTimeoutArgumentGetsNoWallClockLimit() async throws {
        let (manager, sandbox) = try await makeScriptedManager()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let limits = try await limitsOfLaunches {
            _ = try await manager.runTool(name: "analysis-tool", environment: "analysis-env", stdoutHandler: { _ in })
        }

        XCTAssertEqual(limits, [nil], "the streaming overload has its own default, and it carries no wall-clock limit")
    }

    func testRunToolKeepsTheLimitItsCallerSets() async throws {
        let (manager, sandbox) = try await makeScriptedManager()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let limits = try await limitsOfLaunches {
            _ = try await manager.runTool(name: "analysis-tool", environment: "analysis-env", timeout: 42)
        }

        XCTAssertEqual(limits, [.seconds(42)], "a caller that sets a limit keeps it")
    }

    // MARK: - The limit a person sets

    func testTheLimitOfARunReachesItsTasksAndEndsWithIt() async {
        XCTAssertNil(AnalysisTimeLimit.current)
        XCTAssertEqual(AnalysisTimeLimit.launchTimeout, .infinity, "a run no command scoped has no limit")
        await AnalysisTimeLimit.withLimit(AnalysisTimeLimit(minutes: 90)) {
            XCTAssertEqual(AnalysisTimeLimit.launchTimeout, 5_400)
            let child = await Task { AnalysisTimeLimit.launchTimeout }.value
            XCTAssertEqual(child, 5_400, "a task the run starts reads the limit of the run")
            await AnalysisTimeLimit.withLimit(nil) {
                XCTAssertEqual(AnalysisTimeLimit.launchTimeout, .infinity, "a run scoped to no limit has none")
            }
        }
        XCTAssertEqual(AnalysisTimeLimit.launchTimeout, .infinity, "the limit ends with the run")
    }

    func testOnlyAWholeNumberOfMinutesIsALimit() {
        XCTAssertNil(AnalysisTimeLimit(minutes: 0))
        XCTAssertNil(AnalysisTimeLimit(minutes: -5))
        XCTAssertNil(AnalysisTimeLimit(minutes: AnalysisTimeLimit.maximumMinutes + 1))
        XCTAssertEqual(AnalysisTimeLimit(minutes: 1)?.seconds, 60)
        XCTAssertEqual(AnalysisTimeLimit(minutes: AnalysisTimeLimit.maximumMinutes)?.minutes, AnalysisTimeLimit.maximumMinutes)
    }

    func testALaunchOfALimitedRunCarriesTheLimitAndAnUnlimitedRunCarriesNone() async throws {
        let (manager, sandbox) = try await makeScriptedManager()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let limited = try await limitsOfLaunches {
            try await AnalysisTimeLimit.withLimit(AnalysisTimeLimit(minutes: 90)) {
                _ = try await manager.runTool(name: "analysis-tool", environment: "analysis-env",
                                              timeout: AnalysisTimeLimit.launchTimeout)
            }
        }
        let unlimited = try await limitsOfLaunches {
            _ = try await manager.runTool(name: "analysis-tool", environment: "analysis-env",
                                          timeout: AnalysisTimeLimit.launchTimeout)
        }

        XCTAssertEqual(limited, [.seconds(5_400)], "a run under --time-limit 90 stops its launches after 90 minutes")
        XCTAssertEqual(unlimited, [nil], "a run with no --time-limit carries no wall-clock limit")
    }

    // MARK: - Other analysis defaults

    func testGATKRunnersHaveNoWallClockLimitByDefault() {
        let manager = CondaManager(rootPrefix: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true))

        XCTAssertNil(CondaFamilyProcess.limit(seconds: ManagedGATKCommandRunner(condaManager: manager).timeout),
                     "the managed GATK runner has no wall-clock limit unless its caller sets one")
        XCTAssertNil(CondaFamilyProcess.limit(seconds: ProcessGATKCommandRunner().timeout),
                     "the process GATK runner has no wall-clock limit unless its caller sets one")
    }

    // MARK: - Fixed limits in the source

    /// What the fixed limits of one source file stand for. `helper` counts the lines whose limit stays, which are
    /// a probe, a version check, an install or database step, a network call or a viewer query, and a stop of such
    /// a limit says why. `fixed` counts analysis tools that still stop at a fixed limit. They wait for a lane that
    /// lifts them (backlog row TTL-FIXED-LIMITS-REST) and the guard keeps them from growing.
    private struct Entry {
        let file: String
        let helper: Int
        let fixed: Int
        let reason: String
        var count: Int { helper + fixed }
    }

    private static func entry(_ file: String, helper: Int = 0, fixed: Int = 0, _ reason: String) -> Entry {
        Entry(file: "Sources/" + file, helper: helper, fixed: fixed, reason: reason)
    }

    /// Every file of `Sources` that holds a fixed limit, with how many lines of each kind. A file the lane lifted
    /// holds only the helper lines it kept.
    private static let entries: [Entry] = [
        entry("LungfishApp/Views/DatabaseBrowser/DatabaseBrowserViewModel+SRAWindowDownload.swift", helper: 1, "network request"),
        entry("LungfishApp/Views/Viewer/ProgressOverlayView.swift", helper: 1, "overlay delay, no tool"),
        entry("LungfishCLI/Commands/BuildDbCommand+SamtoolsProvenance.swift", fixed: 1, "samtools step of build-db"),
        entry("LungfishCLI/Commands/DebugCommand.swift", helper: 2, "debug probes"),
        entry("LungfishCLI/Commands/FreyjaCommand.swift", fixed: 1, "freyja, 24 h"),
        entry("LungfishCLI/Commands/ImportCommand+BAM.swift", helper: 1, fixed: 2, "idxstats lookup, samtools index, samtools flagstat of the plain import"),
        entry("LungfishCLI/Commands/ImportCommand.swift", helper: 1, "version probe"),
        entry("LungfishCLI/Commands/MarkdupCommand.swift", helper: 1, "version probe"),
        entry("LungfishCLI/LungfishCLI.swift", helper: 1, "exit code 124, no limit"),
        entry("LungfishCLI/Support/CLIProvenanceSupport.swift", helper: 1, "version probe"),
        entry("LungfishCore/Process/ProcessTreeTerminator.swift", helper: 1, "wait after a kill"),
        entry("LungfishCore/Services/AI/AnthropicProvider.swift", helper: 1, "network request"),
        entry("LungfishCore/Services/AI/GeminiProvider.swift", helper: 1, "network request"),
        entry("LungfishCore/Services/AI/OpenAIProvider.swift", helper: 2, "network request"),
        entry("LungfishCore/Services/Blast/BlastService.swift", helper: 1, "network request"),
        entry("LungfishCore/Services/ENA/ENAService.swift", helper: 1, "network request"),
        entry("LungfishCore/Services/NCBI/NCBIService.swift", helper: 4, "network request"),
        entry("LungfishCore/Services/NCBI/SRAService+ENADownload.swift", helper: 1, "network request"),
        entry("LungfishCore/Services/NCBI/SRAService.swift", helper: 1, "network request"),
        entry("LungfishCore/Services/Pathoplexus/PathoplexusService.swift", helper: 1, "network request"),
        entry("LungfishGenotypeUI/GenotypeAnnotationPublicationChain.swift", helper: 1, "wait for a save"),
        entry("LungfishIO/Bundles/AlignmentDataProvider.swift", helper: 15, "viewer queries on a region or an index"),
        entry("LungfishIO/Bundles/VariantDatabase+Cache.swift", helper: 2, "cache warm wait"),
        entry("LungfishKit/CLIBinaryLocator.swift", helper: 1, "probe"),
        entry("LungfishNaoMgsUI/NaoMgsResultViewController.swift", helper: 1, "viewer query"),
        entry("LungfishOperations/AI/AIAssistantService.swift", helper: 1, "network request"),
        entry("LungfishPortable/FASTQ/PortableStorageStep+WriterProbe.swift", helper: 1, "bgzip probe"),
        entry("LungfishWorkflow/Alignment/AlignmentMarkdupPipeline.swift", helper: 1, fixed: 2, "version probe, samtools index, markdup scaled limit"),
        entry("LungfishWorkflow/Alignment/BAMHeaderPathSanitizer.swift", helper: 1, fixed: 2, "header read, reheader and index"),
        entry("LungfishWorkflow/Alignment/BundleAlignmentFilterService.swift", fixed: 4, "samtools view, sort, index, count"),
        entry("LungfishWorkflow/Alignment/Minimap2Pipeline.swift", fixed: 3, "minimap2 scaled limit, samtools index and stats"),
        entry("LungfishWorkflow/AnalysisRun/AnalysisTimeLimit.swift", helper: 1, "the carrier reads the limit of the run and sets none"),
        entry("LungfishWorkflow/Conda/ManagedPythonRuntimeInstaller.swift", helper: 1, "install step"),
        entry("LungfishWorkflow/Conda/ManagedToolLock.swift", helper: 11, "smoke probes"),
        entry("LungfishWorkflow/Conda/ManagedToolSourceInstaller.swift", helper: 2, "runtime probe and install step"),
        entry("LungfishWorkflow/Conda/PackToolSmokeTest.swift", helper: 4, "smoke probes"),
        entry("LungfishWorkflow/Conda/PluginPack.swift", helper: 20, "smoke probes"),
        entry("LungfishWorkflow/Conda/PluginPackStatusService.swift", helper: 2, "probe and install hook"),
        entry("LungfishWorkflow/Databases/DatabaseRegistry.swift", helper: 3, "database fetch, index info and version probe"),
        entry("LungfishWorkflow/DemoProjects/DemoProjectArchiveLoader.swift", helper: 1, "network request"),
        entry("LungfishWorkflow/Demultiplex/DemultiplexingPipeline+Scout.swift", helper: 4, "scout on a bounded read subset"),
        entry("LungfishWorkflow/Demultiplex/DemultiplexingPipeline.swift", helper: 1, "preview head of 1000 reads"),
        entry("LungfishWorkflow/Dependencies/ReconcilerServices.swift", helper: 1, "version probe"),
        entry("LungfishWorkflow/Engines/ContainerRuntimeProbe.swift", helper: 2, "probe"),
        entry("LungfishWorkflow/Engines/DockerRuntime.swift", helper: 4, fixed: 1, "docker control commands, container run to completion"),
        entry("LungfishWorkflow/Extraction/BAMRegionMatcher.swift", helper: 1, "header read"),
        entry("LungfishWorkflow/Extraction/ClassifierReadResolver.swift", fixed: 3, "samtools view"),
        entry("LungfishWorkflow/Ingestion/FASTQBatchImporter.swift", helper: 1, "stats sample of the first reads"),
        entry("LungfishWorkflow/Ingestion/FASTQLengthFilterPlan.swift", helper: 1, "the plan reads the limit of the run and sets none"),
        entry("LungfishWorkflow/Ingestion/ONTBAMImportMaterializer.swift", fixed: 3, "samtools, pigz, collate scaled limit"),
        entry("LungfishWorkflow/Mapping/BAMImportService.swift", fixed: 2, "samtools index, sort scaled limit"),
        entry("LungfishWorkflow/Mapping/MappingToolVersionProbe.swift", helper: 1, "version probe"),
        entry("LungfishWorkflow/Metagenomics/ClassificationPipeline.swift", helper: 1, "bracken --help probe"),
        entry("LungfishWorkflow/Metagenomics/MetagenomicsDatabaseInstaller.swift", fixed: 2, "kraken2-build, bracken-build"),
        entry("LungfishWorkflow/Metagenomics/MetagenomicsImportService.swift", helper: 1, "faidx lookup"),
        entry("LungfishWorkflow/MSA/MAFFTAlignmentPipeline.swift", helper: 1, "version probe"),
        entry("LungfishWorkflow/Native/NativeToolRunner.swift", helper: 1, "version probe"),
        entry("LungfishWorkflow/Native/ShellUtilities.swift", helper: 1, "version check"),
        entry("LungfishWorkflow/Nextflow/NextflowEngineProcess+DockerWait.swift", helper: 1, "wait for the engine"),
        entry("LungfishWorkflow/Nextflow/NextflowVersionProbe.swift", helper: 1, "version probe"),
        entry("LungfishWorkflow/ONTGenotyping/FullLengthONTMHCGenotypingPipeline+SampleExecution.swift", fixed: 2, "samtools, blastn"),
        entry("LungfishWorkflow/ONTGenotyping/FullLengthONTMHCGenotypingPipeline+Savont.swift", fixed: 1, "savont"),
        entry("LungfishWorkflow/ONTGenotyping/ONTBarcodeDemuxGenotypingPipeline.swift", fixed: 2, "mapping and pysam, 24 h"),
        entry("LungfishWorkflow/Orient/OrientPipeline.swift", fixed: 1, "vsearch"),
        entry("LungfishWorkflow/PrimerAnalysis/PrimerOrderSheetWriter.swift", helper: 2, "order sheet tool and its version"),
        entry("LungfishWorkflow/PrimerDesign/PrimalScheme3DesignPipeline.swift", helper: 3, "probes"),
        entry("LungfishWorkflow/PrimerDesign/Primer3DesignRunner.swift", helper: 1, "version probe"),
        entry("LungfishWorkflow/PrimerDesign/PrimerAnalysisNativeInspectionService.swift", helper: 1, "probe"),
        entry("LungfishWorkflow/PrimerDesign/PrimerScreeningDatabaseBuilder.swift", helper: 1, fixed: 1, "version probe, database build"),
        entry("LungfishWorkflow/Primers/BAMPrimerTrimPipeline.swift", fixed: 3, "ivar, samtools sort and index"),
        entry("LungfishWorkflow/Savont/SavontClusteringPipeline.swift", fixed: 1, "savont, 2 h"),
        entry("LungfishWorkflow/Variants/BAMVariantCallingPreflight.swift", helper: 1, "header read"),
        entry("LungfishWorkflow/Variants/GATKInstalledToolVersion.swift", helper: 1, "version check"),
        entry("LungfishWorkflow/Variants/VCFHeaderPathSanitizer.swift", helper: 1, fixed: 3, "header read, reheader and index"),
        entry("LungfishWorkflow/Variants/ViralVariantCallingPipeline.swift", helper: 1, "samtools view -H header read"),
    ]

    /// The forms a fixed limit takes in source. A literal after a `timeout` label at a call site (`timeout: 7200`,
    /// `timeout: 24 * 3_600`, `timeoutSeconds: 10`), a default of any numeric type, a constant named for a timeout,
    /// a limit built from `.seconds`, a limit scaled from the input size, a product of 24 and 3,600 and a computed limit.
    private static let forms: [NSRegularExpression] = [
        #"[Tt]imeout\w*\s*:\s*[0-9]"#,
        #"[Tt]imeout\w*\s*:\s*(TimeInterval|Double|Int|Duration)\??\s*=\s*(\.seconds\()?[0-9]"#,
        #"[Tt]imeout\w*\s*=\s*[0-9]"#,
        #"[Tt]imeout\w*\s*:\s*[A-Za-z.]*seconds\(\s*[0-9]"#,
        #"ImportToolTimeout\.seconds\("#,
        #"24\s*\*\s*3_?600"#,
        #"\bvar\s+\w*[Tt]imeout\w*\s*:\s*TimeInterval\s*\{"#,
        #"[Tt]imeout\w*\s*=\s*(max|min)\("#,
    ].map { try! NSRegularExpression(pattern: $0) }

    func testNoAnalysisToolFixesAWallClockLimitAtACallSite() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var found: [String: [Int]] = [:]
        for url in try repositoryFiles(under: root.appendingPathComponent("Sources")) where url.pathExtension == "swift" {
            let rel = url.path.replacingOccurrences(of: root.path + "/", with: "")
            let source = try readRepositorySource(url)
            guard ["imeout", "24 *", "24*"].contains(where: { source.contains($0) }) else { continue }
            let lines = source.components(separatedBy: "\n")
            for (index, raw) in lines.enumerated() {
                let text = raw.trimmingCharacters(in: .whitespaces)
                guard !text.hasPrefix("//"), ["imeout", "24 *", "24*"].contains(where: { text.contains($0) }) else { continue }
                let range = NSRange(text.startIndex..., in: text)
                if Self.forms.contains(where: { $0.firstMatch(in: text, range: range) != nil }) {
                    found[rel, default: []].append(index + 1)
                }
            }
        }
        let allowed = Dictionary(uniqueKeysWithValues: Self.entries.map { ($0.file, $0.count) })
        let offenders = found.keys.sorted().compactMap { file -> String? in
            let lines = found[file] ?? []
            guard lines.count > (allowed[file] ?? 0) else { return nil }
            return "\(file): \(lines.count) fixed limits, \(allowed[file] ?? 0) allowed, at lines \(lines.map(String.init).joined(separator: ","))"
        }
        XCTAssertTrue(offenders.isEmpty,
                      "An analysis tool has no wall-clock limit by default. Lift the limit, or list the file in entries as a helper with its reason:\n"
                      + offenders.joined(separator: "\n"))
        let stale = Self.entries.filter { (found[$0.file]?.count ?? 0) < $0.count }
            .map { "\($0.file): lists \($0.count), finds \(found[$0.file]?.count ?? 0)" }
        XCTAssertTrue(stale.isEmpty, "entries lists limits that no longer exist. Lower or remove the entry:\n" + stale.joined(separator: "\n"))
    }

    // MARK: - Words of a stop by a limit

    func testCondaTimeLimitStopSaysWhatHappenedAndWhatToTry() {
        assertStoppedWords(CondaError.timeout(tool: "kraken2", seconds: 3600).errorDescription,
                           subject: "Tool 'kraken2'", after: "60 minutes")
        assertStoppedWords(CondaError.timeout(tool: "EsViritu", seconds: 7200).errorDescription,
                           subject: "Tool 'EsViritu'", after: "2 hours")
        assertStoppedWords(CondaError.timeout(tool: "samtools", seconds: 90).errorDescription,
                           subject: "Tool 'samtools'", after: "90 seconds")
    }

    func testGATKTimeLimitStopSaysWhatHappenedAndWhatToTry() {
        assertStoppedWords(ProcessGATKCommandRunnerError.timedOut(executable: "gatk", seconds: 7200).errorDescription,
                           subject: "gatk", after: "2 hours")
    }

    func testMappingSummaryTimeLimitStopSaysWhatHappenedAndWhatToTry() {
        assertStoppedWords(MappingSummaryBuilderError.samtoolsTimedOut(step: "samtools coverage", seconds: 1800).errorDescription,
                           subject: "samtools coverage", after: "30 minutes")
    }

    // MARK: - Helpers

    /// The words name what was stopped, after how long, that a time limit did it and what to try next.
    private func assertStoppedWords(_ words: String?, subject: String, after duration: String,
                                    file: StaticString = #filePath, line: UInt = #line) {
        guard let words else { return XCTFail("the error has no words", file: file, line: line) }
        XCTAssertTrue(words.hasPrefix("\(subject) was stopped after \(duration) by its time limit."), words, file: file, line: line)
        XCTAssertTrue(words.hasSuffix("If you started the run with --time-limit, run it again without that option or with a longer time. Otherwise report this so the limit can be lifted."), words, file: file, line: line)
    }

    /// The wall-clock limit of each launch that `call` makes, in launch order, nil for none.
    private func limitsOfLaunches(_ call: () async throws -> Void) async rethrows -> [Duration?] {
        let limits = OSAllocatedUnfairLock<[Duration?]>(initialState: [])
        try await CondaToolTimeLimit.$specProbe.withValue({ spec in
            limits.withLock { $0.append(spec.timeout) }
        }) { try await call() }
        return limits.withLock { $0 }
    }

    /// A manager whose micromamba is a script that reports a version, and for `run` prints a line and exits 0.
    private func makeScriptedManager() async throws -> (manager: CondaManager, sandbox: URL) {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        let bundledMicromamba = sandbox.appendingPathComponent("bundled-micromamba")
        let script = """
        #!/bin/sh
        case "$1" in
            --version)
                echo "2.0.5-0"
                exit 0
                ;;
            run)
                echo "ok"
                exit 0
                ;;
            *)
                echo "unexpected args: $@" >&2
                exit 1
                ;;
        esac
        """
        try script.write(to: bundledMicromamba, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundledMicromamba.path)
        let manager = CondaManager(
            rootPrefix: sandbox.appendingPathComponent("conda"),
            bundledMicromambaProvider: { bundledMicromamba },
            bundledMicromambaVersionProvider: { "2.0.5-0" }
        )
        _ = try await manager.ensureMicromamba()
        return (manager, sandbox)
    }
}
