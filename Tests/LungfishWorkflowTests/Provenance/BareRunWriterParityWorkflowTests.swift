import Foundation
import Testing
import LungfishTestSupport
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow

/// Runs the bare-run writers of LungfishWorkflow in a temporary `.lungfish` project and compares
/// the facts of what each one wrote with the facts captured from the same run on unchanged code
/// (Phase 2.4, finding R8, lane W2B). The expected facts are in
/// Tests/Fixtures/provenance-writer-parity. The CLI, App and integration writers have their own
/// suites beside their commands.
@Suite("Bare-run writer parity (Workflow)")
struct BareRunWriterParityWorkflowTests {
    typealias Parity = BareRunWriterParity

    // MARK: GATKPipelineExecutor

    @Test("GATKPipelineExecutor: a failed command keeps the facts of its failed record")
    func gatkExecutorFailedRun() async throws {
        let project = try ProvenanceCompatScenarios.makeProject()
        defer { project.cleanup() }
        let analysis = try project.folder("Analyses/gatk-haplotype-caller")
        let inputs = project.root.appendingPathComponent("Inputs", isDirectory: true)
        let reference = try ProvenanceCompatScenarios.write(">chr1\nACGT\n", to: inputs.appendingPathComponent("reference.fa"))
        let bam = try ProvenanceCompatScenarios.write("bam-bytes", to: inputs.appendingPathComponent("sample.bam"))
        let output = analysis.appendingPathComponent("sample.g.vcf.gz")
        let command = GATKCommandBuilder.haplotypeCallerCommand(
            GATKHaplotypeCallerConfiguration(referenceFASTAURL: reference, inputBAMURL: bam, outputVCFURL: output)
        )
        let request = GATKPipelineExecutionRequest(
            workflowName: "GATK HaplotypeCaller",
            toolName: "gatk-haplotype-caller",
            toolVersion: "4.6.2.0",
            command: command,
            outputDirectory: analysis,
            inputs: [
                GATKFileArtifact(url: reference, format: .fasta, role: .reference),
                GATKFileArtifact(url: bam, format: .bam, role: .input),
            ],
            outputs: [GATKFileArtifact(url: output, format: .vcf, role: .output)],
            options: [:],
            resolvedDefaults: ["ploidy": "2"],
            runtimeIdentity: GATKRuntimeIdentity(condaEnvironment: "/opt/lungfish/envs/gatk-core"),
            packID: "gatk-core",
            packVersion: "1.0.0"
        )
        let executor = GATKPipelineExecutor(
            runner: FailingGATKRunner(),
            dateProvider: { Date(timeIntervalSince1970: 1_790_200_000) }
        )

        do {
            _ = try await executor.run(request)
            Issue.record("A non-zero GATK exit must throw")
        } catch let error as GATKPipelineExecutionError {
            guard case .commandFailed(let exitCode, _) = error else {
                Issue.record("Expected commandFailed, got \(error)")
                return
            }
            #expect(exitCode == 7)
        }

        try expectBeforeConversion(
            analysis.appendingPathComponent(ProvenanceRecorder.provenanceFilename),
            in: project,
            scenario: Parity.Scenarios.gatkExecutorFailed
        )
    }

    @Test("GATKPipelineExecutor: the containerized joint genotyping run keeps the corpus case's facts")
    func gatkExecutorContainerRun() async throws {
        let project = try ProvenanceCompatScenarios.makeProject()
        defer { project.cleanup() }
        let sidecar = try await ProvenanceCompatScenarios.gatkContainerRun(in: project)
        try expectBeforeConversion(sidecar, in: project, scenario: Parity.Scenarios.gatkExecutorContainer)
    }

    // MARK: Attachment services

    @Test("BundleVariantTrackAttachmentService: the variant call sidecar keeps its facts")
    func bundleVariantTrackAttachment() async throws {
        let project = try ProvenanceCompatScenarios.makeProject()
        defer { project.cleanup() }
        let bundleURL = try Self.makeAlignmentBundle(named: "test", in: project)
        let staging = try Self.makeStagedVariantArtifacts(in: project)
        let completedAt = Date(timeIntervalSince1970: 1_713_549_600)
        let service = BundleVariantTrackAttachmentService(dateProvider: { completedAt })

        let result = try await service.attach(
            request: BundleVariantTrackAttachmentRequest(
                bundleURL: bundleURL,
                alignmentTrackID: "aln-1",
                caller: .lofreq,
                outputTrackID: "variant-track-1",
                outputTrackName: "Sample BAM LoFreq",
                stagedVCFGZURL: staging.vcfGZURL,
                stagedTabixURL: staging.tbiURL,
                stagedDatabaseURL: staging.dbURL,
                variantCount: 99,
                variantCallerVersion: "2.1.5",
                variantCallerParametersJSON: #"{"min_af":0.05}"#,
                variantCallerCommandLine: "lofreq call-parallel --call-indels sample.bam",
                referenceStagedFASTASHA256: "ref-sha-256",
                workflowProvenance: VariantCallingWorkflowProvenance(
                    workflowName: "lungfish variants call",
                    workflowVersion: "lungfish-cli test",
                    command: ["lungfish", "variants", "call", "--caller", "lofreq"],
                    startedAt: Date(timeIntervalSince1970: 1_713_549_590),
                    completedAt: Date(timeIntervalSince1970: 1_713_549_595),
                    parameters: ["caller": "lofreq"],
                    steps: [
                        VariantCallingProvenanceStep(
                            toolName: "lofreq",
                            toolVersion: "2.1.5",
                            command: ["lofreq", "call-parallel", "sample.bam"],
                            inputs: [],
                            outputs: [ProvenanceRecorder.fileRecord(url: staging.vcfGZURL, format: .vcf, role: .output)],
                            exitCode: 0,
                            wallTime: 2.0,
                            stderr: "",
                            startedAt: Date(timeIntervalSince1970: 1_713_549_591),
                            completedAt: Date(timeIntervalSince1970: 1_713_549_593)
                        )
                    ]
                )
            )
        )

        try expectBeforeConversion(
            try #require(result.provenanceURL),
            in: project,
            scenario: Parity.Scenarios.bundleVariantTrackAttach
        )
    }

    @Test("GATKBundleVariantAttachmentService: the GATK attachment sidecar keeps its facts")
    func gatkBundleVariantAttachment() async throws {
        let project = try ProvenanceCompatScenarios.makeProject()
        defer { project.cleanup() }
        let bundleURL = project.root
            .appendingPathComponent("Reference Sequences/sample.lungfishref", isDirectory: true)
        let vcfURL = try Self.makeBundleWithGATKOutput(at: bundleURL)
        let executionProvenanceURL = bundleURL
            .appendingPathComponent("variants/gatk", isDirectory: true)
            .appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        try Data("{}".utf8).write(to: executionProvenanceURL)
        let executionRequest = GATKPipelineExecutionRequest.haplotypeCaller(
            configuration: GATKHaplotypeCallerConfiguration(
                referenceFASTAURL: bundleURL.appendingPathComponent("genome/reference.fa"),
                inputBAMURL: bundleURL.appendingPathComponent("alignments/sample.bam"),
                outputVCFURL: vcfURL,
                emitReferenceConfidence: .none
            ),
            toolVersion: "4.5.0.0",
            runtimeIdentity: GATKRuntimeIdentity(condaEnvironment: "/opt/lungfish/envs/gatk-core")
        )

        let result = try await GATKBundleVariantAttachmentService().attach(
            request: GATKBundleVariantAttachmentRequest(
                bundleURL: bundleURL,
                alignmentTrackID: "aln-1",
                outputTrackID: "gatk-track",
                outputTrackName: "Sample GATK",
                outputVCFURL: vcfURL,
                executionProvenanceURL: executionProvenanceURL,
                executionRequest: executionRequest,
                importProfile: .fast
            )
        )

        try expectBeforeConversion(result.provenanceURL, in: project, scenario: Parity.Scenarios.gatkBundleVariantAttach)
    }

    // MARK: Conda services

    @Test("CondaLockfileService: the requested specification receipt keeps its facts")
    func condaLockfileExport() throws {
        let project = try ProvenanceCompatScenarios.makeProject()
        defer { project.cleanup() }
        let output = project.root.appendingPathComponent("Exports/requested-environment.json")

        let result = try CondaLockfileService(platforms: ["osx-arm64", "linux-64"], channels: ["conda-forge"])
            .writeLockfile(
                for: Self.fixturePack(),
                to: output,
                commandLine: ["lungfish-cli", "conda", "lock", "--pack", "fixture"]
            )

        try expectBeforeConversion(result.provenanceURL, in: project, scenario: Parity.Scenarios.condaLockfileExport)
    }

    @Test("CondaOfflinePackService: the export record keeps its facts")
    func condaOfflineExport() async throws {
        let project = try ProvenanceCompatScenarios.makeProject()
        defer { project.cleanup() }
        let export = try await Self.exportPack(in: project)

        try expectBeforeConversion(export.provenanceURL, in: project, scenario: Parity.Scenarios.condaOfflineExport)
    }

    @Test("CondaOfflinePackService: the install record keeps its facts")
    func condaOfflineInstall() async throws {
        let project = try ProvenanceCompatScenarios.makeProject()
        defer { project.cleanup() }
        let export = try await Self.exportPack(in: project)
        let destination = project.root.appendingPathComponent("Tools/destination-conda", isDirectory: true)

        let install = try await CondaOfflinePackService().installPack(
            from: export.packDirectory,
            condaRoot: destination,
            overwrite: false,
            commandLine: ["lungfish-cli", "conda", "offline-install", "--pack-dir", export.packDirectory.path]
        )

        try expectBeforeConversion(install.provenanceURL, in: project, scenario: Parity.Scenarios.condaOfflineInstall)
    }

    @Test("CondaOfflinePackService: the record of a refused install keeps its facts")
    func condaOfflineInstallFailure() async throws {
        let project = try ProvenanceCompatScenarios.makeProject()
        defer { project.cleanup() }
        let export = try await Self.exportPack(in: project)
        let destination = project.root.appendingPathComponent("Tools/destination-no-overwrite", isDirectory: true)
        try ProvenanceCompatScenarios.write(
            "known-good destination\n",
            to: destination.appendingPathComponent("envs/samtools/known-good")
        )

        do {
            _ = try await CondaOfflinePackService().installPack(
                from: export.packDirectory,
                condaRoot: destination,
                overwrite: false,
                commandLine: ["lungfish-cli", "conda", "offline-install", "--pack-dir", export.packDirectory.path]
            )
            Issue.record("An existing environment must require explicit overwrite permission")
        } catch {
            #expect(error.localizedDescription.contains("already exists"))
        }

        try expectBeforeConversion(
            destination.appendingPathComponent(CondaOfflinePackService.installFailureProvenanceFilename),
            in: project,
            scenario: Parity.Scenarios.condaOfflineInstallFailure
        )
    }

    // MARK: BundleContainerExportService

    @Test("BundleContainerExportService: the provenance entry inside the archive keeps its facts")
    func bundleContainerExportArchiveEntry() async throws {
        let project = try ProvenanceCompatScenarios.makeProject()
        defer { project.cleanup() }
        let bundle = project.root.appendingPathComponent("Reference Sequences/Example.lungfishref", isDirectory: true)
        try ProvenanceCompatScenarios.write(#"{"name":"Example","identifier":"example"}"#, to: bundle.appendingPathComponent("manifest.json"))
        try ProvenanceCompatScenarios.write(">chr1\nACGT\n", to: bundle.appendingPathComponent("genome.fa"))
        let archive = project.root.appendingPathComponent("Exports/bundle.oci.tar")
        try FileManager.default.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)

        _ = try await BundleContainerExportService().export(
            bundle: bundle,
            output: archive,
            pluginPacks: [Self.minimapPack()],
            commandLine: ["lungfish", "bundle", "export", bundle.path, "--format", "container", "--output", archive.path]
        )

        let entries = try DeterministicTarReader.entries(in: archive)
        let entry = try #require(entries[ProvenanceRecorder.provenanceFilename], "the archive holds no provenance entry")
        let entryFolder = try project.folder("Exports/archive-entry")
        let sidecar = entryFolder.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        try entry.write(to: sidecar)

        try expectBeforeConversion(sidecar, in: project, scenario: Parity.Scenarios.bundleContainerExportArchiveEntry)
    }

    // MARK: Comparison

    /// The writer must still say what it said on unchanged code.
    private func expectBeforeConversion(
        _ sidecar: URL,
        in project: ProvenanceCompatScenarios.Project,
        scenario: Parity.Scenario,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let facts = try Parity.facts(of: sidecar, in: project, scenario: scenario)
        let problems = try Parity.problemsBeforeConversion(facts, scenario: scenario)
        #expect(problems.isEmpty, "\(scenario.id) changed: \(problems)", sourceLocation: sourceLocation)
    }

    // MARK: Fixtures

    /// The date every fixture manifest carries, so the manifest's checksum is the same on every run.
    private static let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    private static func exportPack(in project: ProvenanceCompatScenarios.Project) async throws -> CondaOfflinePackExportResult {
        let condaRoot = project.root.appendingPathComponent("Tools/source-conda", isDirectory: true)
        try ProvenanceCompatScenarios.write("samtools binary\n", to: condaRoot.appendingPathComponent("envs/samtools/samtools"))
        let pack = PluginPack(
            id: "read-mapping",
            name: "Read Mapping",
            description: "Read mapping tools",
            sfSymbol: "map",
            packages: ["samtools"],
            category: "Analysis"
        )
        return try await CondaOfflinePackService().exportPack(
            pack: pack,
            condaRoot: condaRoot,
            outputDirectory: project.root.appendingPathComponent("Exports/offline-packs", isDirectory: true),
            commandLine: ["lungfish-cli", "conda", "offline-export", "--pack", pack.id]
        )
    }

    private static func fixturePack() -> PluginPack {
        PluginPack(
            id: "fixture",
            name: "Fixture",
            description: "Local identity fixture",
            sfSymbol: "wrench",
            packages: [],
            category: "Testing",
            requirements: [
                PackToolRequirement(
                    id: "fixture-tool",
                    displayName: "Fixture Tool",
                    environment: "renamed-runtime",
                    installPackages: ["conda-forge::python=3.12=fixture_0", "conda-forge::make=4.4=fixture_1"],
                    executables: ["fixture"],
                    fallbackExecutablePaths: ["fixture": ["bin/custom"]],
                    version: "fixture-v1",
                    license: "MIT",
                    sourceURL: "https://example.invalid/source"
                )
            ]
        )
    }

    private static func minimapPack() -> PluginPack {
        PluginPack(
            id: "read-mapping",
            name: "Read Mapping",
            description: "Mapping",
            sfSymbol: "map",
            packages: ["minimap2"],
            category: "Mapping",
            requirements: [
                PackToolRequirement(
                    id: "minimap2",
                    displayName: "minimap2",
                    environment: "minimap2",
                    installPackages: ["bioconda::minimap2=2.30=hba9b596_0"],
                    executables: ["minimap2"],
                    version: "2.30",
                    license: "MIT",
                    sourceURL: "https://github.com/lh3/minimap2"
                )
            ]
        )
    }

    /// A bundle with a one-contig genome and one alignment track, as the variant track tests build it.
    private static func makeAlignmentBundle(named name: String, in project: ProvenanceCompatScenarios.Project) throws -> URL {
        let bundleURL = project.root.appendingPathComponent("Reference Sequences/\(name).lungfishref", isDirectory: true)
        let genomeDir = bundleURL.appendingPathComponent("genome", isDirectory: true)
        let alignmentsDir = bundleURL.appendingPathComponent("alignments", isDirectory: true)
        try FileManager.default.createDirectory(at: genomeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: alignmentsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: bundleURL.appendingPathComponent("variants", isDirectory: true),
            withIntermediateDirectories: true
        )
        try ">chr1\nACGTACGTACGTACGTACGT\n".write(
            to: genomeDir.appendingPathComponent("sequence.fa.gz"), atomically: true, encoding: .utf8
        )
        try "chr1\t20\t6\t20\t21\n".write(
            to: genomeDir.appendingPathComponent("sequence.fa.gz.fai"), atomically: true, encoding: .utf8
        )
        try Data("bam".utf8).write(to: alignmentsDir.appendingPathComponent("sample.sorted.bam"))
        try Data("bai".utf8).write(to: alignmentsDir.appendingPathComponent("sample.sorted.bam.bai"))
        let manifest = BundleManifest(
            formatVersion: "1.0",
            name: "Test Bundle",
            identifier: "test.bundle",
            createdDate: fixedDate,
            modifiedDate: fixedDate,
            source: SourceInfo(organism: "Test virus", assembly: "TestAssembly", database: "Test"),
            genome: GenomeInfo(
                path: "genome/sequence.fa.gz",
                indexPath: "genome/sequence.fa.gz.fai",
                totalLength: 20,
                chromosomes: [
                    ChromosomeInfo(name: "chr1", length: 20, offset: 6, lineBases: 20, lineWidth: 21, aliases: ["1"])
                ]
            ),
            alignments: [
                AlignmentTrackInfo(
                    id: "aln-1",
                    name: "Sample BAM",
                    format: .bam,
                    sourcePath: "alignments/sample.sorted.bam",
                    indexPath: "alignments/sample.sorted.bam.bai",
                    checksumSHA256: "bam-sha-256"
                )
            ]
        )
        try manifest.save(to: bundleURL)
        return bundleURL
    }

    private static func makeStagedVariantArtifacts(
        in project: ProvenanceCompatScenarios.Project
    ) throws -> (vcfGZURL: URL, tbiURL: URL, dbURL: URL) {
        let stagingDir = try project.folder("Staging/variant-call")
        let vcfContent = """
        ##fileformat=VCFv4.3
        ##contig=<ID=chr1,length=20>
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        chr1\t2\tvar1\tA\tG\t50\tPASS\tAF=0.5
        chr1\t5\tvar2\tC\tT\t45\tPASS\tAF=0.4
        """
        let vcfURL = stagingDir.appendingPathComponent("staged.vcf")
        let vcfGZURL = stagingDir.appendingPathComponent("staged.vcf.gz")
        let tbiURL = stagingDir.appendingPathComponent("staged.vcf.gz.tbi")
        let dbURL = stagingDir.appendingPathComponent("staged.db")
        try vcfContent.write(to: vcfURL, atomically: true, encoding: .utf8)
        try Data("fake-vcfgz".utf8).write(to: vcfGZURL)
        try Data("fake-tabix".utf8).write(to: tbiURL)
        try VariantDatabase.createFromVCF(vcfURL: vcfURL, outputURL: dbURL, importSemantics: .viralFrequency)
        return (vcfGZURL, tbiURL, dbURL)
    }

    /// A bundle holding the VCF a GATK run wrote, as the GATK attachment tests build it.
    private static func makeBundleWithGATKOutput(at bundleURL: URL) throws -> URL {
        let genomeDir = bundleURL.appendingPathComponent("genome", isDirectory: true)
        let alignmentsDir = bundleURL.appendingPathComponent("alignments", isDirectory: true)
        let variantsDir = bundleURL.appendingPathComponent("variants/gatk", isDirectory: true)
        try FileManager.default.createDirectory(at: genomeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: alignmentsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: variantsDir, withIntermediateDirectories: true)
        try Data(">chr1\nACGTACGTACGT\n".utf8).write(to: genomeDir.appendingPathComponent("reference.fa"))
        try Data("chr1\t12\t6\t12\t13\n".utf8).write(to: genomeDir.appendingPathComponent("reference.fa.fai"))
        try Data().write(to: alignmentsDir.appendingPathComponent("sample.bam"))
        try Data().write(to: alignmentsDir.appendingPathComponent("sample.bam.bai"))
        let vcfURL = variantsDir.appendingPathComponent("gatk-track.vcf")
        try Data(
            """
            ##fileformat=VCFv4.2
            ##contig=<ID=chr1,length=12>
            #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\tsample
            chr1\t4\t.\tT\tG\t60\tPASS\tDP=18\tGT:DP\t0/1:18
            """.utf8
        ).write(to: vcfURL)
        try Data().write(to: vcfURL.appendingPathExtension("idx"))
        let manifest = BundleManifest(
            name: "Sample",
            identifier: "sample-bundle",
            createdDate: fixedDate,
            modifiedDate: fixedDate,
            source: SourceInfo(organism: "Test organism", assembly: "test"),
            genome: GenomeInfo(
                path: "genome/reference.fa",
                indexPath: "genome/reference.fa.fai",
                totalLength: 12,
                chromosomes: [ChromosomeInfo(name: "chr1", length: 12, offset: 6, lineBases: 12, lineWidth: 13)]
            ),
            alignments: [
                AlignmentTrackInfo(
                    id: "aln-1",
                    name: "Sample BAM",
                    sourcePath: "alignments/sample.bam",
                    indexPath: "alignments/sample.bam.bai"
                )
            ]
        )
        try manifest.save(to: bundleURL)
        return vcfURL
    }
}

/// Stands in for GATK and exits 7 with an error line, as a missing sequence dictionary does.
private struct FailingGATKRunner: GATKCommandRunning {
    func run(_ command: GATKCommand) async throws -> GATKCommandExecutionResult {
        GATKCommandExecutionResult(exitCode: 7, stdout: "", stderr: "missing sequence dictionary", wallTime: 0.25)
    }
}
