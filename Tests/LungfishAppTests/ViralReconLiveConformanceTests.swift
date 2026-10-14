// ViralReconLiveConformanceTests.swift - Viral Recon on the real Nextflow with V1b's two samples
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane Q37, plan decision N6, BIO's ruling 4 on Q35's V1 and the QA ruling on owner direction O5
// of Phase 2.9. A stand-in Nextflow prints and writes what its author believes a Viral Recon run does, and
// only a real run shows what the pinned release does. Q35's V1b and V2 ran two samples for real on the
// managed Nextflow 26.04.6 with Docker, 70 tasks in 168.7 s for V2 once the images were local. This class runs
// the same inputs through ViralReconWorkflowExecutionService and the built lungfish-cli, as
// ViralReconReferenceAnnotationRealRunTests does for one sample, and pins what V1b recorded, so that it holds
// before and after A30 (the route) and B31 (the record).
//
//   sampleA    Tests/Fixtures/sarscov2 test_1 and test_2, 100 pairs, and no iVar variant
//   sample.B   SRR36291587 of the SARS-CoV-2 Amplicons demo, 85,199 pairs of QIAseq Direct, 82 variants
//   reference  MN908947.3 by `fetch genome`, with the fixture's MN908947.3.gff3 at genome/genes.gff3
//   scheme     QIASeqDIRECT-SARS2, whose primer FASTA the wizard's staging cuts from the reference
//
// It runs its body only when the live switch is on (LUNGFISH_LIVE_NEXTFLOW_ROOT, or LUNGFISH_REQUIRE_TOOLS=1
// with LUNGFISH_STORAGE_ROOT naming the managed root), this process resolves its managed tools from that root,
// Docker answers `docker info`, LUNGFISH_DEMO_ARCHIVE_DIR holds the SARS-CoV-2 Amplicons archive and a
// lungfish-cli is found (LUNGFISH_CLI_PATH, built at the head under test). It downloads MN908947.3, on a
// Docker with none of the viralrecon images about 18.5 GB in 22 images (V1b), and never starts Docker Desktop. Its name
// holds Conformance, so the unit tier never runs it. ViralReconRunRecordTests, ViralReconReferenceAnnotationStagingTests
// and NextflowStandInEngineReplayTests on the stand-in stay the default and the fallback.
//
// The run is bounded at LiveNextflowRun.runTimeout, 10 minutes. The launch drops the agent switches
// (WorkflowEngineLaunch, V3-BIO 2.4), so a run from a shell that sets CLAUDECODE must still print Nextflow's
// banner, and the class prints the switches this process has.

import CryptoKit
import Foundation
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishTestSupport
import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

@MainActor
final class ViralReconLiveConformanceTests: XCTestCase {
    /// What Q35's V1b run recorded, each digest read again from the saved files in `SCR/realrun/V1`.
    private enum V1b {
        static let sampleAR1 = "0515ba304cb1bf7abcdd9c156b6affad7e580273f983dfed2e8fe2d918e800ff"
        static let sampleAR2 = "0080f40cab58c7e7b85443e37de22775e3ed6b7afdef9a3271ac3147576f3027"
        static let sampleBReads = "50a00009810389fca9e5edc04ea9caa3fe256609cdae2f721e92239c5294f3a3"
        static let gff3 = "7edcb9f6c6de7ba570106926e5af55f7e45ed5f8b92b9a33664fb9ca2711ae32"
        static let referenceFASTA = "7783895b07e909ab0c87ead938976ac6ae350a4595e37b2f2be16a755fd85844"
        static let primerBED = "17fe71eef82858e9b56ac48e9e22963cfe5cab8c434c1fcf410086f08984a64d"
        static let primerFASTA = "ca871061b99da8f3fffd8d139d6b5e191bd667dde2eaf8262f76b8485a3373b2"
        /// The decompressed `variants/ivar/sample.B.vcf.gz`, 82 records and 19 header lines that carry no date.
        static let vcfText = "2666be2893b1efbaaa56abc1feb0e2e0b4f739894ae79d14a40f3141db88133e"
        static let vcfRecords = 82
        static let consensus = "43b2dc433c1c45ef6290eef3c45aa6fe31409a85c43383edf37f9d9d04a688d9"
        /// `pipeline_info/nf_core_viralrecon_software_mqc_versions.yml` byte for byte. It names the version of every process's
        /// tool, `v3.0.0-g395079f` for the pipeline and Nextflow 26.04.6. V2's copy is identical.
        static let softwareVersions = "03d329e3aef82dae428decf5d7f7ff16296179d6a39d0a72d33f59e8729c03b2"
        /// The `pipeline_info/params_*.json` of V1b through `normalizedParameters`, 102 parameters with the pipeline's defaults.
        /// V2's file gives the same digest.
        static let parameters = "485410bbedde156de676630e15b882fe2e0f8ef763be75e4f2bcb5cc333343fd"
    }

    /// The groups of tasks `NextflowStandInWorkflow.viralRecon` names in its documentation as left out of its
    /// list (NextflowStandInWorkflow.swift, the paragraph on genome preparation), as a part of a task name.
    private static let writerGroups: [(group: String, part: String)] = [
        ("genome preparation", ":PREPARE_GENOME:"),
        ("VARIANTS_QC, the SnpEff annotation", ":VARIANTS_QC:"),
        ("MAKE_BED_MASK", ":MAKE_BED_MASK"),
        ("BEDTOOLS_MERGE", ":BEDTOOLS_MERGE"),
        ("BEDTOOLS_MASKFASTA", ":BEDTOOLS_MASKFASTA"),
        ("PLOT_BASE_DENSITY", ":PLOT_BASE_DENSITY ("),
        ("QUAST", ":QUAST ("),
        ("PANGOLIN_UPDATEDATA", ":PANGOLIN_UPDATEDATA ("),
        ("the Mosdepth plots", ":PLOT_MOSDEPTH_REGIONS_"),
        ("VARIANTS_LONG_TABLE", ":VARIANTS_LONG_TABLE:"),
    ]

    func testTheRealRunOfV1bsTwoSamplesHoldsTheBaseEvidence() async throws {
        let run = try LiveNextflowRun.begin()
        var engineWorkFolders: [URL] = []
        defer { XCTAssertEqual(run.teardown(engineWorkFolders: engineWorkFolders).problems, []) }
        try run.requireProcessRoot()
        guard let cli = CLIBinaryLocator.cliBinaryPath() else {
            try ToolAvailability.skipOrFail("No lungfish-cli was found. Set LUNGFISH_CLI_PATH to one built at the head under test.")
        }
        let environment = ProcessInfo.processInfo.environment
        let agentSwitches = ["CLAUDECODE", "NXF_AGENT_MODE", "AGENT"].compactMap { name in environment[name].map { "\(name)=\($0)" } }
        note("CLI \(cli.path)")
        note("agent switches in this process: \(agentSwitches.isEmpty ? "none" : agentSwitches.joined(separator: " "))")

        // The inputs, in a project of the run's own. The scratch of a run in a .lungfish folder is <project>/.tmp,
        // where the teardown looks for the containers of an engine that a failed test left behind.
        let fileManager = FileManager.default
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let project = run.directory.appendingPathComponent("viralrecon.lungfish", isDirectory: true)
        engineWorkFolders = [project.appendingPathComponent(".tmp", isDirectory: true)]
        let downloads = project.appendingPathComponent("Downloads", isDirectory: true)
        let analyses = project.appendingPathComponent("Analyses", isDirectory: true)
        for folder in [downloads, project.appendingPathComponent("Imports", isDirectory: true), analyses] {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        // sample.B's reads, cloned out of the demo archive as Q35's V1b cloned them out of the demo project.
        let demo = try await run.installDemoProject(try LiveNextflowRun.demoProject(id: "sarscov2-amplicons"))
        let readsBundle = project.appendingPathComponent("Imports/SRR36291587.lungfishfastq", isDirectory: true)
        try fileManager.copyItem(at: demo.appendingPathComponent("Imports/SRR36291587.lungfishfastq", isDirectory: true), to: readsBundle)
        let readsB = readsBundle.appendingPathComponent("SRR36291587.fastq.gz")
        let fixtures = repository.appendingPathComponent("Tests/Fixtures/sarscov2", isDirectory: true)
        try pin(fixtures.appendingPathComponent("test_1.fastq.gz"), V1b.sampleAR1, "sampleA R1")
        try pin(fixtures.appendingPathComponent("test_2.fastq.gz"), V1b.sampleAR2, "sampleA R2")
        try pin(readsB, V1b.sampleBReads, "sample.B reads")

        // The reference, as ViralReconReferenceDownloader fetches it, with the fixture's GFF3 where the service looks for one.
        let download = ViralReconReferenceDownloader.live()
        do {
            try await download(ViralReconReferenceCatalog.canonicalAccession, downloads)
        } catch {
            try ToolAvailability.skipOrFail("lungfish-cli fetch genome \(ViralReconReferenceCatalog.canonicalAccession) failed: \(error)")
        }
        let referenceBundle = ViralReconReferenceCatalog.bundleURL(inProject: project)
        let bundleGFF3 = referenceBundle.appendingPathComponent("genome/genes.gff3")
        try? fileManager.removeItem(at: bundleGFF3)
        try fileManager.copyItem(
            at: repository.appendingPathComponent("Tests/Fixtures/sarscov2-srr36291587/MN908947.3.gff3"),
            to: bundleGFF3
        )
        try pin(referenceBundle.appendingPathComponent("genome/sequence.fa.gz"), V1b.referenceFASTA, "reference sequence.fa.gz")
        try pin(bundleGFF3, V1b.gff3, "reference genes.gff3")

        // The request the wizard builds, with the real-run test's two settings (a floor of 1 read and 4 CPUs) as Q35 ran them.
        let token = String(UUID().uuidString.prefix(8)).lowercased()
        let staging = analyses.appendingPathComponent(".viralrecon-inputs-\(token)", isDirectory: true)
        let samples = [
            ViralReconSample(
                sampleName: "sampleA",
                sourceBundleURL: fixtures,
                fastqURLs: [fixtures.appendingPathComponent("test_1.fastq.gz"), fixtures.appendingPathComponent("test_2.fastq.gz")],
                barcode: nil,
                sequencingSummaryURL: nil
            ),
            ViralReconSample(sampleName: "sample.B", sourceBundleURL: readsBundle, fastqURLs: [readsB], barcode: nil, sequencingSummaryURL: nil),
        ]
        let primer = try ViralReconWizardPrimerStaging.stageForCanonicalReference(
            primerBundleURL: repository.appendingPathComponent(
                "Sources/LungfishApp/Resources/PrimerSchemes/QIASeqDIRECT-SARS2.lungfishprimers",
                isDirectory: true
            ),
            projectURL: project,
            destinationDirectory: staging
        )
        try pin(primer.bedURL, V1b.primerBED, "primers.bed")
        try pin(try XCTUnwrap(primer.fastaURL, "the scheme staged no primer FASTA"), V1b.primerFASTA, "primers.fasta")
        let pinnedRelease = try NextflowWorkflowDescriptor.viralRecon.resolveBundledPin()
        let request = try ViralReconRunRequest(
            samples: samples,
            platform: .illumina,
            protocol: .amplicon,
            samplesheetURL: try ViralReconSamplesheetBuilder.writeIlluminaSamplesheet(samples: samples, in: staging),
            outputDirectory: analyses.appendingPathComponent("viralrecon-results-\(token)", isDirectory: true),
            executor: .docker,
            version: pinnedRelease.revision,
            reference: .genome(ViralReconReferenceCatalog.canonicalAccession),
            primer: primer,
            minimumMappedReads: 1,
            variantCaller: .ivar,
            consensusCaller: .bcftools,
            skipOptions: Array(ViralReconSkipOption.defaultSelection).sorted { $0.rawValue < $1.rawValue },
            advancedParams: ["max_cpus": "4", "max_memory": "8.GB"]
        )

        let operationCenter = OperationCenter()
        let service = ViralReconWorkflowExecutionService(
            operationCenter: operationCenter,
            processRunner: ProcessViralReconWorkflowProcessRunner(),
            referenceDownloader: { _, _ in XCTFail("the project already holds the reference bundle") }
        )
        // The run gets the bound and no more: at LiveNextflowRun.runTimeout the watchdog gives the window's Cancel.
        let watchdog = Task { @MainActor in
            try await Task.sleep(for: .seconds(LiveNextflowRun.runTimeout))
            for item in operationCenter.items where item.state == .running { operationCenter.cancel(id: item.id) }
        }
        let clock = ContinuousClock()
        let started = clock.now
        var runResult: ViralReconWorkflowExecutionService.RunResult?
        var runFailure: Error?
        do {
            runResult = try await service.run(request, bundleRoot: analyses, projectURL: project)
        } catch {
            runFailure = error
        }
        watchdog.cancel()
        let elapsed = started.duration(to: clock.now).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        note(String(format: "service.run took %.1f s of the %.0f s bound, %.0f s left", seconds, LiveNextflowRun.runTimeout, LiveNextflowRun.runTimeout - seconds))
        XCTAssertLessThan(seconds, LiveNextflowRun.runTimeout, "the run passed the bound, so the watchdog cancelled it")

        let item = operationCenter.items.first { runResult == nil || $0.id == runResult?.operationID }
        note("operation \(item?.state.rawValue ?? "none"): \(item?.cliCommand ?? "no command")")
        for entry in item?.logEntries.suffix(6) ?? [] { note("log [\(entry.level)] \(entry.message.prefix(300))") }
        if let runFailure { XCTFail("service.run threw \(runFailure), \(item?.errorDetail ?? "no error detail")") }
        let result = try XCTUnwrap(runResult, "the run did not finish")
        XCTAssertEqual(item?.state, .completed, item?.errorDetail ?? item?.detail ?? "")
        let manifest = try NFCoreRunBundleStore.read(from: result.bundleURL)
        XCTAssertEqual(manifest.executionStatus, .completed)
        XCTAssertEqual(manifest.exitCode, 0)

        // Item 3. The trace holds each task of the writer's list for sample.B, the first 20 for sampleA (which has no
        // iVar variant and stops after IVAR_VARIANTS) and MULTIQC, all COMPLETED, and every other task is in a group
        // the writer names. Genome preparation, the SnpEff annotation and the rest run once or for sample.B only.
        let results = request.outputDirectory
        let info = results.appendingPathComponent("pipeline_info", isDirectory: true)
        let traceFile = try XCTUnwrap(
            try fileManager.contentsOfDirectory(atPath: info.path).sorted().last { $0.hasPrefix("execution_trace") && $0.hasSuffix(".txt") },
            "pipeline_info holds no execution trace"
        )
        let trace = Self.traceRows(try String(contentsOf: info.appendingPathComponent(traceFile), encoding: .utf8))
        let workflow = NextflowStandInWorkflow.viralRecon
        let ran = trace.map(\.name)
        let expectedB = workflow.processNames.map { $0.replacingOccurrences(of: "@SAMPLE@", with: "sample.B") }
        let expectedA = workflow.processNames.prefix(20).map { $0.replacingOccurrences(of: "@SAMPLE@", with: "sampleA") }
        let runLevel = workflow.leadingProcessNames + workflow.trailingProcessNames
        note("trace \(trace.count) tasks, by status \(Dictionary(grouping: trace, by: \.status).mapValues(\.count))")
        XCTAssertEqual(trace.filter { $0.status != "COMPLETED" }.map { "\($0.name) \($0.status)" }, [])
        XCTAssertEqual(expectedB.filter { !ran.contains($0) }, [], "tasks of sample.B the writer names that the real run did not start")
        XCTAssertEqual(expectedA.filter { !ran.contains($0) }, [], "tasks of sampleA the writer names that the real run did not start")
        XCTAssertEqual(Set(ran.filter { $0.hasSuffix(" (sampleA)") }), Set(expectedA), "sampleA runs the first 20 tasks and no more")
        XCTAssertEqual(runLevel.filter { !ran.contains($0) }, [], "the run-level tasks, MULTIQC among them, that the real run did not start")
        let named = Set(expectedB + expectedA + runLevel)
        let others = ran.filter { !named.contains($0) }
        for (group, part) in Self.writerGroups { note("group \(group): \(others.filter { $0.contains(part) }.count) tasks") }
        XCTAssertEqual(others.filter { name in !Self.writerGroups.contains { name.contains($0.part) } }, [], "tasks in no group the writer names")

        // Item 4. The inventory finds both BAMs and their indexes for each sample, the VCF, its index and the consensus of
        // sample.B, and no VCF for sampleA. It names the primer-trimmed BAM, the alignment the variants came from.
        let bowtie2 = results.appendingPathComponent("variants/bowtie2", isDirectory: true)
        for sample in ["sampleA", "sample.B"] {
            for name in ["sorted.bam", "sorted.bam.bai", "ivar_trim.sorted.bam", "ivar_trim.sorted.bam.bai"] {
                XCTAssertTrue(fileManager.fileExists(atPath: bowtie2.appendingPathComponent("\(sample).\(name)").path), "variants/bowtie2/\(sample).\(name)")
            }
            let inventory = ViralReconResultInventory.discover(in: results, sampleName: sample)
            XCTAssertEqual(inventory.sortedBAM?.lastPathComponent, "\(sample).ivar_trim.sorted.bam")
            XCTAssertEqual(inventory.bamIndex?.lastPathComponent, "\(sample).ivar_trim.sorted.bam.bai")
        }
        let inventoryA = ViralReconResultInventory.discover(in: results, sampleName: "sampleA")
        XCTAssertNil(inventoryA.variantVCF, "sampleA has no iVar variant, so no VCF")
        XCTAssertNil(inventoryA.consensusFASTA, "sampleA has no VCF, so no consensus")
        let inventoryB = ViralReconResultInventory.discover(in: results, sampleName: "sample.B")
        let vcf = try XCTUnwrap(inventoryB.variantVCF, "no VCF for sample.B")
        let consensus = try XCTUnwrap(inventoryB.consensusFASTA, "no consensus for sample.B")
        XCTAssertEqual(vcf.lastPathComponent, "sample.B.vcf.gz")
        XCTAssertTrue(fileManager.fileExists(atPath: vcf.path + ".tbi"), "the VCF has no index")
        let consensusData = try Data(contentsOf: consensus)
        XCTAssertTrue(String(decoding: consensusData.prefix(40), as: UTF8.self).hasPrefix(">sample.B "), "the consensus header names the sample")

        // Item 5. sample.B's VCF, without its date lines, and its consensus are V1b's. No Pangolin or Nextclade table is
        // pinned, since PANGOLIN_UPDATEDATA fetches the current data.
        let dateFree = Self.withoutDates(vcf: try GzipInputStream(url: vcf).readAllSync())
        let vcfDigest = Self.sha256(Data(dateFree.text.utf8))
        note("sample.B VCF \(dateFree.records) records, \(dateFree.header) header lines, text sha256 \(vcfDigest), consensus sha256 \(Self.sha256(consensusData))")
        XCTAssertEqual(dateFree.records, V1b.vcfRecords)
        XCTAssertEqual(vcfDigest, V1b.vcfText, "sample.B's records and header differ from V1b's")
        if vcfDigest != V1b.vcfText { note("VCF text follows\n\(dateFree.text)") }
        XCTAssertEqual(Self.sha256(consensusData), V1b.consensus, "sample.B's consensus differs from V1b's")

        // The engine's own words. An agent log, the `[PIPELINE]`, `[WORKDIR]` and `[PROCESS ` lines of Nextflow 26.04 with
        // CLAUDECODE or NXF_AGENT_MODE set, means the launch kept the agent switches of the shell (V3-BIO 2.4).
        let stdoutLog = try String(contentsOf: result.bundleURL.appendingPathComponent("logs/stdout.log"), encoding: .utf8)
        let stdoutLines = stdoutLog.components(separatedBy: "\n")
        let agentLines = stdoutLines.filter { $0.hasPrefix("[PIPELINE] ") || $0.hasPrefix("[WORKDIR] ") || $0.hasPrefix("[PROCESS ") }
        XCTAssertEqual(agentLines.count, 0, "logs/stdout.log holds Nextflow's agent log, so the engine saw an agent switch: \(agentLines.prefix(3))")

        // Item 6. logs/stdout.log holds the lines of the console in the order a real run prints them (V1-BIO 2, commit 2):
        // the version line first, the `Launching` line, the logo as eight lines in a row, the `[xx/nnnnnn] Submitted process`
        // line of every task of the trace, and nf-core's completion line last. The warnings, plugin downloads and the
        // parameter summary between them depend on the machine, and the blank lines are not kept, so neither is pinned.
        note("logs/stdout.log \(stdoutLines.count) lines")
        let version = Self.firstLine(matching: #"^N E X T F L O W  ~  version ([0-9][0-9A-Za-z.\-]*)$"#, in: stdoutLines)
        let launching = Self.firstLine(
            matching: #"^Launching `https://github\.com/nf-core/viralrecon` \[[a-z_]+\] - revision: ([0-9a-f]{10}) \[3\.0\.0\]$"#,
            in: stdoutLines
        )
        let logoStart = stdoutLines.firstIndex(of: Self.logo[0])
        let submitted = stdoutLines.enumerated().compactMap { index, line in
            Self.firstLine(matching: #"^\[[0-9a-f]{2}/[0-9a-f]{6}\] Submitted process > (.+)$"#, in: [line]).map { (index: index, name: $0.capture) }
        }
        let completion = stdoutLines.lastIndex { !$0.isEmpty }
        XCTAssertEqual(version?.index, stdoutLines.firstIndex { !$0.isEmpty }, "the version line is not the first line")
        if let logoStart {
            XCTAssertEqual(Array(stdoutLines[logoStart..<min(logoStart + Self.logo.count, stdoutLines.count)]), Self.logo, "the logo")
        }
        XCTAssertEqual(completion.map { stdoutLines[$0] }, Self.completionLine, "the last line is not nf-core's completion line")
        let order = [version?.index, launching?.index, logoStart, submitted.first?.index, submitted.last?.index, completion]
        XCTAssertEqual(order.compactMap { $0 }.count, order.count, "a line is missing, in order \(order)")
        XCTAssertEqual(order.compactMap { $0 }, order.compactMap { $0 }.sorted(), "the version, Launching, logo, first and last task and completion lines are out of order")
        XCTAssertEqual(submitted.map(\.name).sorted(), ran.sorted(), "logs/stdout.log submits the tasks of the trace, once each")

        // N2, N3 and Q33 fix 8, each a fact of the record at this head (V3-BIO 1, Q33 fix 8). The step names the full commit
        // the wizard sent, whose first ten characters the engine's Launching line prints and the stand-in's writer carries.
        // It names the Nextflow that ran, as the banner does, and the manifest records the command the launch ran, which
        // the engine's own log opens with.
        let provenance = try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(from: result.bundleURL))
        let step = try XCTUnwrap(provenance.steps.first)
        XCTAssertEqual(step.toolVersion, pinnedRelease.revision, "N2, the record names the commit that was sent")
        XCTAssertEqual(String(step.toolVersion.prefix(10)), "395079f1d2", "N2, the commit of tag 3.0.0")
        XCTAssertEqual(launching?.capture, String(step.toolVersion.prefix(10)), "N2, the Launching line and the record name one commit")
        XCTAssertEqual(launching?.capture, workflow.pinnedCommit, "N2, the stand-in writer prints the commit the real run printed")
        XCTAssertNil(step.resolvedOptions["resolvedCommit"], "N2, a step that names a full commit has nothing to resolve")
        XCTAssertEqual(version?.capture, "26.04.6", "N3, the managed Nextflow of V1b")
        XCTAssertEqual(step.resolvedOptions["nextflowVersion"], .string(version?.capture ?? ""), "N3, the record names the Nextflow that ran")
        let engineLog = try String(contentsOf: result.bundleURL.appendingPathComponent("logs/nextflow.log"), encoding: .utf8)
        let launchLine = try XCTUnwrap(engineLog.components(separatedBy: "\n").first { $0.hasPrefix("nextflow_command: ") }, "logs/nextflow.log opens with no command")
        XCTAssertEqual(manifest.nextflowLogPath, "logs/nextflow.log")
        XCTAssertEqual(
            manifest.commandPreview,
            "nextflow" + launchLine.dropFirst("nextflow_command: ".count).drop { $0 != " " },
            "Q33 fix 8, the manifest records the launch argv after the executable"
        )
        for part in [" -c ", " -work-dir ", " --gff "] {
            XCTAssertTrue(manifest.commandPreview.contains(part), "Q33 fix 8, the recorded command lacks \(part)")
        }
        for part in [" --max_cpus", " --max_memory"] {
            XCTAssertFalse(manifest.commandPreview.contains(part), "Q33 fix 8, the recorded command passes \(part), which the launch does not")
        }

        // BIO 3 and BIO 4, the review of Q37 (fix 1). The tag stands beside the commit, the engine records the version of
        // every process as in V1b, and the run's effective parameters, the pipeline's own defaults included, are V1b's. A
        // parameter the launch drops, such as `--variant_caller ivar` or `--consensus_caller bcftools`, moves the digest.
        XCTAssertEqual(provenance.options.explicit["github_release_version"], .string("3.0.0"), "N2, the tag beside the commit")
        let versionsDigest = Self.sha256(try Data(contentsOf: info.appendingPathComponent("nf_core_viralrecon_software_mqc_versions.yml")))
        note("pipeline_info software versions sha256 \(versionsDigest)")
        XCTAssertEqual(versionsDigest, V1b.softwareVersions, "BIO 4, the tool versions the engine recorded differ from V1b's")
        let paramsFile = try XCTUnwrap(
            try fileManager.contentsOfDirectory(atPath: info.path).sorted().last { $0.hasPrefix("params_") && $0.hasSuffix(".json") },
            "pipeline_info holds no params file"
        )
        let parameters = try Self.normalizedParameters(try Data(contentsOf: info.appendingPathComponent(paramsFile)))
        let parametersDigest = Self.sha256(Data(parameters.utf8))
        note("\(paramsFile) normalized \(parameters.utf8.count) bytes, sha256 \(parametersDigest)")
        XCTAssertEqual(parametersDigest, V1b.parameters, "BIO 3, the effective parameters differ from V1b's")
        if parametersDigest != V1b.parameters { note("normalized parameters follow\n\(parameters)") }
    }

    /// The normalization behind `V1b.parameters`, on a file shaped like Nextflow's `params_*.json`. It needs no tool and no
    /// Docker. The folder and the stamp of a run do not move the text, and a dropped, added or changed parameter does.
    func testTheParameterNormalizationDropsTheRunStampsAndKeepsEveryParameter() throws {
        func file(folder: String, stamp: String, changing change: (inout [String: Any]) -> Void = { _ in }) throws -> Data {
            var parameters: [String: Any] = [
                "input": "/\(folder)/inputs/samplesheet.paired.csv",
                "outdir": "/\(folder)/results-\(stamp)",
                "trace_report_suffix": stamp,
                "fasta": "/\(folder)/Downloads/MN908947.3.lungfishref/genome/sequence.fa.gz",
                "gff": "/\(folder)/inputs/reference/genes.gff",
                "primer_bed": "/\(folder)/inputs/primers/primers.bed",
                "primer_fasta": "/\(folder)/inputs/primers/primers.fasta",
                "variant_caller": "ivar",
                "consensus_caller": "bcftools",
                "skip_assembly": true,
                "min_perc_contig_aligned": 0.7,
                "genome": NSNull(),
                "genomes": [
                    "codfreq": ["fasta": "https://example.org/genome/codfreq.fa"],
                    "MN908947.3": ["fasta": "https://example.org/genome/MN908947.3.fa"],
                ],
            ]
            change(&parameters)
            return try JSONSerialization.data(withJSONObject: parameters)
        }
        let v1b = try Self.normalizedParameters(try file(folder: "v1b.lungfish/Analyses/viralrecon.lungfishrun", stamp: "2026-10-13_20-11-16"))
        let v2 = try Self.normalizedParameters(try file(folder: "run.lungfish/Analyses/viralrecon.lungfishrun", stamp: "2026-10-13_22-41-16"))
        XCTAssertEqual(v1b, v2, "two runs of the same parameters in two folders at two times")
        XCTAssertEqual(
            v1b,
            #"{"consensus_caller":"bcftools","fasta":"sequence.fa.gz","genome":null,"#
                + #""genomes":{"MN908947.3":{"fasta":"https://example.org/genome/MN908947.3.fa"},"codfreq":{"fasta":"https://example.org/genome/codfreq.fa"}},"#
                + #""gff":"genes.gff","input":"samplesheet.paired.csv","min_perc_contig_aligned":0.69999999999999996,"primer_bed":"primers.bed","primer_fasta":"primers.fasta","#
                + #""skip_assembly":true,"variant_caller":"ivar"}"#,
            "keys in byte order (MN908947.3 before codfreq), compact, the five paths cut to their file names, outdir and trace_report_suffix gone"
        )
        let mutations: [(what: String, change: (inout [String: Any]) -> Void)] = [
            ("a dropped variant_caller", { $0["variant_caller"] = nil }),
            ("a changed consensus_caller", { $0["consensus_caller"] = "ivar" }),
            ("a changed switch", { $0["skip_assembly"] = false }),
            ("a changed number", { $0["min_perc_contig_aligned"] = 0.8 }),
            ("an added parameter, as a launch that passes the caps would add", { $0["max_cpus"] = 4 }),
            ("another file name for the GFF", { $0["gff"] = "/x/annotations.gff" }),
            ("a changed path inside genomes", { $0["genomes"] = ["MN908947.3": ["fasta": "https://example.org/genome/other.fa"]] }),
        ]
        for mutation in mutations {
            let text = try Self.normalizedParameters(try file(folder: "v1b.lungfish/Analyses/viralrecon.lungfishrun", stamp: "2026-10-13_20-11-16", changing: mutation.change))
            XCTAssertNotEqual(text, v1b, "\(mutation.what) must move the text")
        }
    }

    // MARK: - Helpers

    /// The logo Viral Recon 3.0.0 prints, with its escapes, as the eight lines of Q35's V1 `logs/stdout.log`
    /// (`before_text` of `subworkflows/local/utils_nfcore_viralrecon_pipeline/main.nf`). The stand-in writer prints the same.
    private static let logo: [String] = {
        let esc = "\u{1B}"
        return [
            "-\(esc)[2m----------------------------------------------------\(esc)[0m-",
            "                                        \(esc)[0;32m,--.\(esc)[0;30m/\(esc)[0;32m,-.\(esc)[0m",
            "\(esc)[0;34m        ___     __   __   __   ___     \(esc)[0;32m/,-._.--~'\(esc)[0m",
            "\(esc)[0;34m  |\\ | |__  __ /  ` /  \\ |__) |__         \(esc)[0;33m}  {\(esc)[0m",
            "\(esc)[0;34m  | \\| |       \\__, \\__/ |  \\ |___     \(esc)[0;32m\\`-._,-`-,\(esc)[0m",
            "                                        \(esc)[0;32m`._,._,'\(esc)[0m",
            "\(esc)[0;35m  nf-core/viralrecon 3.0.0\(esc)[0m",
            "-\(esc)[2m----------------------------------------------------\(esc)[0m-",
        ]
    }()

    /// The last line of a completed run, the one the stand-in prints.
    private static let completionLine = "-\u{1B}[0;35m[nf-core/viralrecon]\u{1B}[0;32m Pipeline completed successfully\u{1B}[0m-"

    /// The first line that matches `pattern` as a whole, with its position and its first capture group.
    private static func firstLine(matching pattern: String, in lines: [String]) -> (index: Int, capture: String)? {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        for (index, line) in lines.enumerated() {
            guard let match = expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { continue }
            let capture = match.numberOfRanges > 1 ? Range(match.range(at: 1), in: line).map { String(line[$0]) } : nil
            return (index, capture ?? "")
        }
        return nil
    }

    private func note(_ message: String) {
        print("[live-viralrecon] \(message)")
    }

    /// Checks one input against the digest V1b recorded for it, and prints both.
    private func pin(_ url: URL, _ expected: String, _ label: String) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let digest = Self.sha256(data)
        note("input \(label) sha256 \(digest), \(data.count) bytes")
        XCTAssertEqual(digest, expected, "\(label) is not the file Q35's V1b ran on, \(url.path)")
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The text of a `pipeline_info/params_*.json` without what differs from run to run. `outdir` and `trace_report_suffix`
    /// are left out, the five parameters that name a file the run reads (`input`, `fasta`, `gff`, `primer_bed` and
    /// `primer_fasta`) keep their last path component, and every other parameter, the pipeline's defaults included, is
    /// written with sorted keys and no spaces. `V1b.parameters` digests that text. Foundation writes the one fractional
    /// default (`min_perc_contig_aligned`) with 17 digits, 0.69999999999999996.
    private static func normalizedParameters(_ data: Data) throws -> String {
        var parameters = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any], "the params file is not a JSON object")
        for key in ["outdir", "trace_report_suffix"] { parameters[key] = nil }
        for key in ["input", "fasta", "gff", "primer_bed", "primer_fasta"] {
            if let path = parameters[key] as? String { parameters[key] = (path as NSString).lastPathComponent }
        }
        return try sortedJSON(parameters)
    }

    /// JSON text with the keys of every object in UTF-8 byte order. `JSONSerialization.sortedKeys` is not used because it
    /// puts `codfreq` before `KY484034.1`, the names `genomes` holds, an order that a locale or a Foundation release could move.
    private static func sortedJSON(_ value: Any) throws -> String {
        switch value {
        case let object as [String: Any]:
            let members = try object.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }.map { key in
                try sortedJSON(key) + ":" + sortedJSON(object[key] ?? NSNull())
            }
            return "{" + members.joined(separator: ",") + "}"
        case let array as [Any]:
            return "[" + (try array.map(sortedJSON)).joined(separator: ",") + "]"
        default:
            let scalar = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
            return String(decoding: scalar, as: UTF8.self)
        }
    }

    private struct TraceRow {
        let name: String
        let status: String
    }

    /// The rows of Nextflow's trace file, by the `name` and `status` columns of its header line.
    private static func traceRows(_ text: String) -> [TraceRow] {
        let lines = text.split(separator: "\n").map(String.init)
        guard let header = lines.first?.components(separatedBy: "\t"),
              let name = header.firstIndex(of: "name"),
              let status = header.firstIndex(of: "status") else {
            return []
        }
        return lines.dropFirst().compactMap { line in
            let columns = line.components(separatedBy: "\t")
            return columns.count > max(name, status) ? TraceRow(name: columns[name], status: columns[status]) : nil
        }
    }

    /// A VCF's text with every header line that carries a date left out, and the count of its header lines and records.
    /// bcftools writes `Date=` into the command line it records (`##bcftools_filterCommand`), and iVar's VCF has none.
    private static func withoutDates(vcf text: String) -> (text: String, header: Int, records: Int) {
        var lines = text.components(separatedBy: "\n")
        let endsWithNewline = lines.last == ""
        if endsWithNewline { lines.removeLast() }
        let kept = lines.filter { !($0.hasPrefix("##") && $0.range(of: "Date=") != nil) }
        return (
            kept.joined(separator: "\n") + (endsWithNewline ? "\n" : ""),
            kept.filter { $0.hasPrefix("#") }.count,
            kept.filter { !$0.hasPrefix("#") }.count
        )
    }
}
