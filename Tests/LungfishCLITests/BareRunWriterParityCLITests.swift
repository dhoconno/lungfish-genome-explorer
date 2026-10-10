import XCTest
import LungfishCore
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishIO
@testable import LungfishWorkflow

/// Runs the bare-run writers of LungfishCLI in a temporary `.lungfish` project and compares the
/// facts of what each one wrote with the facts captured from the same run on unchanged code
/// (Phase 2.4, finding R8, lane W2B). The expected facts are in
/// Tests/Fixtures/provenance-writer-parity. Every command runs in process, with a scripted tool
/// runtime where it would start a tool, so no test needs a managed tool or the network.
final class BareRunWriterParityCLITests: XCTestCase {
    typealias Parity = BareRunWriterParity

    // MARK: variants extract-sample and variants query (VariantsCommand.writeProvenance)

    func testVariantsExtractSample() async throws {
        let project = try ProvenanceCompatScenarios.makeProject()
        defer { project.cleanup() }
        let bundleURL = try Self.makeVariantBundle(in: project)
        let outputURL = project.root.appendingPathComponent("Exports/NA12878.vcf")
        let command = try VariantsCommand.ExtractSampleSubcommand.parse([
            "extract-sample", bundleURL.path, "--sample", "NA12878", "--output", outputURL.path, "--quiet",
        ])

        try await command.executeForTesting()

        try expectBeforeConversion(
            ProvenanceRecorder.fileSidecarURL(for: outputURL),
            in: project,
            scenario: Parity.Scenarios.variantsExtractSample
        )
    }

    func testVariantsQuery() async throws {
        let project = try ProvenanceCompatScenarios.makeProject()
        defer { project.cleanup() }
        let bundleURL = try Self.makeVariantBundle(in: project)
        let outputURL = project.root.appendingPathComponent("Exports/filtered.vcf")
        let command = try VariantsCommand.QuerySubcommand.parse([
            "query", bundleURL.path, "--filter", "Sample[NA12878].GT=1/1", "--output", outputURL.path, "--quiet",
        ])

        try await command.executeForTesting()

        try expectBeforeConversion(
            ProvenanceRecorder.fileSidecarURL(for: outputURL),
            in: project,
            scenario: Parity.Scenarios.variantsQuery
        )
    }

    // MARK: variants phase and freyja demix (VariantsCommand.writeCommandPlanProvenance)

    func testVariantsPhaseDryRun() async throws {
        let project = try ProvenanceCompatScenarios.makeProject()
        defer { project.cleanup() }
        let command = try Self.phaseCommand(in: project, folder: "Analyses/phase-plan", execute: false)

        try await command.executeForTesting { _ in }

        try expectBeforeConversion(
            project.root.appendingPathComponent("Analyses/phase-plan/\(ProvenanceRecorder.provenanceFilename)"),
            in: project,
            scenario: Parity.Scenarios.variantsPhaseDryRun,
            extra: Self.toolVersionReplacements()
        )
    }

    func testVariantsPhaseExecute() async throws {
        let project = try ProvenanceCompatScenarios.makeProject()
        defer { project.cleanup() }
        let command = try Self.phaseCommand(in: project, folder: "Analyses/phase-execute", execute: true)
        let runtime = VariantsCommand.PhaseRuntime { phaseCommand in
            switch phaseCommand.executable {
            case "gatk":
                let outputPath = try XCTUnwrap(Self.argument(after: "-O", in: phaseCommand.arguments))
                try "unphased-vcf\n".write(to: URL(fileURLWithPath: outputPath), atomically: true, encoding: .utf8)
            case "whatshap":
                let outputPath = try XCTUnwrap(Self.argument(after: "-o", in: phaseCommand.arguments))
                try "phased-vcf\n".write(to: URL(fileURLWithPath: outputPath), atomically: true, encoding: .utf8)
            default:
                XCTFail("Unexpected phased variant command: \(phaseCommand.executable)")
            }
            return VariantsCommand.PhaseToolResult(
                stdout: "\(phaseCommand.executable) stdout",
                stderr: "\(phaseCommand.executable) stderr",
                exitCode: 0
            )
        }

        try await command.executeForTesting(runtime: runtime) { _ in }

        try expectBeforeConversion(
            project.root.appendingPathComponent("Analyses/phase-execute/\(ProvenanceRecorder.provenanceFilename)"),
            in: project,
            scenario: Parity.Scenarios.variantsPhaseExecute,
            extra: Self.toolVersionReplacements()
        )
    }

    func testFreyjaDemixDryRun() async throws {
        let project = try ProvenanceCompatScenarios.makeProject()
        defer { project.cleanup() }
        let inputs = project.root.appendingPathComponent("Inputs", isDirectory: true)
        let variants = try ProvenanceCompatScenarios.write("site\tdepth\n", to: inputs.appendingPathComponent("variants.tsv"))
        let depths = try ProvenanceCompatScenarios.write("site\tdepth\n", to: inputs.appendingPathComponent("depths.tsv"))
        let outputDir = project.root.appendingPathComponent("Analyses/freyja-plan", isDirectory: true)
        let command = try FreyjaCommand.DemixSubcommand.parse([
            "demix", "--variants", variants.path, "--depths", depths.path, "--output-dir", outputDir.path,
            "--sample", "WW-001", "--extra-args", "--eps 0.001",
        ])

        try await command.executeForTesting { _ in }

        try expectBeforeConversion(
            outputDir.appendingPathComponent(ProvenanceRecorder.provenanceFilename),
            in: project,
            scenario: Parity.Scenarios.freyjaDemixDryRun,
            extra: Self.toolVersionReplacements()
        )
    }

    // MARK: project migrate (ProjectCommand.writeMigrationProvenance)

    func testProjectMigrateBrowserSummary() async throws {
        let project = try ProvenanceCompatScenarios.makeProject()
        defer { project.cleanup() }
        let bundleURL = try Self.makeLegacyReferenceBundle(named: "LegacySummary", in: project)
        try ProvenanceCompatScenarios.write(
            #"{"run":"creation-provenance","outputs":["payload"]}"#,
            to: bundleURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        )
        let command = try ProjectCommand.MigrateSubcommand.parse([project.root.path, "--quiet"])

        try await command.run()

        let migrations = bundleURL
            .appendingPathComponent(".lungfish", isDirectory: true)
            .appendingPathComponent("migrations", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: migrations, includingPropertiesForKeys: nil)
        let sidecar = try XCTUnwrap(files.first { $0.lastPathComponent.hasSuffix(".project-migrate-provenance.json") })
        try expectBeforeConversion(
            sidecar,
            in: project,
            scenario: Parity.Scenarios.projectMigrateBrowserSummary,
            // The migration folder names its files after the run's start, to the millisecond.
            extra: [.regularExpression(#"\d{4}-\d{2}-\d{2}T\d{9}Z"#, as: "<run-start>")]
        )
    }

    // MARK: fetch sra download (SRADownloadSubcommand.writeSRADownloadProvenance)

    func testSRADownloadToolkitFallback() async throws {
        let project = try ProvenanceCompatScenarios.makeProject()
        defer { project.cleanup() }
        let folder = try project.folder("Imports/sra-download")
        // Another run downloaded here earlier, and a mate of this run from an earlier ENA download.
        for name in ["SRR100_1.fastq", "SRR100_2.fastq", "SRR200_2.fastq.gz"] {
            try ProvenanceCompatScenarios.write("@\(name)\n", to: folder.appendingPathComponent(name))
        }

        _ = try await SRADownloadSubcommandProvenanceTests.download(into: folder, portal: .outage)

        try expectBeforeConversion(
            folder.appendingPathComponent(ProvenanceRecorder.provenanceFilename),
            in: project,
            scenario: Parity.Scenarios.sraDownloadToolkitFallback,
            extra: Self.fasterqFolderReplacements
        )
    }

    func testSRADownloadENAPairedRun() async throws {
        let project = try ProvenanceCompatScenarios.makeProject()
        defer { project.cleanup() }
        let folder = try project.folder("Imports/sra-download")

        _ = try await SRADownloadSubcommandProvenanceTests.download(into: folder, portal: .pairedRun)

        try expectBeforeConversion(
            folder.appendingPathComponent(ProvenanceRecorder.provenanceFilename),
            in: project,
            scenario: Parity.Scenarios.sraDownloadENAPaired,
            extra: Self.fasterqFolderReplacements
        )
    }

    // MARK: Comparison

    /// The writer must still say what it said on unchanged code.
    private func expectBeforeConversion(
        _ sidecar: URL,
        in project: ProvenanceCompatScenarios.Project,
        scenario: Parity.Scenario,
        extra: [Parity.Replacement] = [],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let facts = try Parity.facts(of: sidecar, in: project, scenario: scenario, replacing: Self.cliReplacements + extra)
        let problems = try Parity.problemsBeforeConversion(facts, scenario: scenario)
        XCTAssertTrue(problems.isEmpty, "\(scenario.id) changed: \(problems)", file: file, line: line)
    }

    // MARK: Host values

    /// The CLI version, which every record of a command holds as its app version or tool version.
    private static var cliReplacements: [Parity.Replacement] {
        let version = LungfishCLI.configuration.version
        return [
            .literal("lungfish-cli \(version)", as: "lungfish-cli <cli-version>"),
            .version(version, as: "<cli-version>"),
        ]
    }

    /// The tool versions the commands take from the tools lock, which change when the lock does.
    private static func toolVersionReplacements() -> [Parity.Replacement] {
        var result = [Parity.Replacement.version(GATKCLICommand.defaultToolVersion(), as: "<gatk-version>")]
        let whatsHap = PluginPack.builtInPack(id: "phasing")?.toolRequirements.first { $0.id == "whatshap" }?.version
        if let whatsHap { result.append(.version(whatsHap, as: "<whatshap-version>")) }
        let freyja = PluginPack.builtInPack(id: "wastewater-surveillance")?.toolRequirements.first { $0.id == "freyja" }?.version
        if let freyja { result.append(.version(freyja, as: "<freyja-version>")) }
        return result
    }

    /// fasterq-dump's temporary folder, which is named with a fresh UUID on every run.
    private static let fasterqFolderReplacements: [Parity.Replacement] = [
        .regularExpression(#"fasterq-[0-9A-Fa-f-]{36}"#, as: "fasterq-<UUID>"),
    ]

    // MARK: Fixtures

    private static func phaseCommand(
        in project: ProvenanceCompatScenarios.Project,
        folder: String,
        execute: Bool
    ) throws -> VariantsCommand.PhaseSubcommand {
        let inputs = project.root.appendingPathComponent("Inputs", isDirectory: true)
        let reference = try ProvenanceCompatScenarios.write(">chr1\nACGT\n", to: inputs.appendingPathComponent("ref.fa"))
        let bam = try ProvenanceCompatScenarios.write("bam-bytes", to: inputs.appendingPathComponent("sample.bam"))
        let outputDir = project.root.appendingPathComponent(folder, isDirectory: true)
        let outputVCF = outputDir.appendingPathComponent("phased.vcf.gz")
        var arguments = [
            "phase",
            "--reference", reference.path,
            "--bam", bam.path,
            "--output-vcf", outputVCF.path,
            "--output-dir", outputDir.path,
            "--threads", "2",
        ]
        if execute {
            arguments.insert("--execute", at: 1)
        } else {
            arguments += ["--extra-gatk-args", "--sample-ploidy 1", "--extra-whatshap-args", "--ignore-read-groups"]
        }
        return try VariantsCommand.PhaseSubcommand.parse(arguments)
    }

    private static func argument(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(arguments.index(after: index)) else {
            return nil
        }
        return arguments[arguments.index(after: index)]
    }

    /// A bundle with a three-site, two-sample variant database, as the extract-sample tests build it.
    private static func makeVariantBundle(in project: ProvenanceCompatScenarios.Project) throws -> URL {
        let bundleURL = project.root.appendingPathComponent("Reference Sequences/Cohort.lungfishref", isDirectory: true)
        let variantsDir = bundleURL.appendingPathComponent("variants", isDirectory: true)
        try FileManager.default.createDirectory(at: variantsDir, withIntermediateDirectories: true)
        let vcfURL = try ProvenanceCompatScenarios.write(cohortVCF, to: project.root.appendingPathComponent("Inputs/cohort.vcf"))
        let dbURL = variantsDir.appendingPathComponent("cohort.db")
        try VariantDatabase.createFromVCF(vcfURL: vcfURL, outputURL: dbURL, parseGenotypes: true)

        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let manifest = BundleManifest(
            formatVersion: "1.0",
            name: "Cohort",
            identifier: "test.cohort",
            createdDate: fixedDate,
            modifiedDate: fixedDate,
            source: SourceInfo(organism: "Test", assembly: "TestAssembly", database: "Fixture"),
            genome: nil,
            variants: [
                VariantTrackInfo(
                    id: "cohort",
                    name: "Cohort",
                    path: "variants/cohort.vcf.gz",
                    indexPath: "variants/cohort.vcf.gz.tbi",
                    databasePath: "variants/cohort.db",
                    variantType: .mixed,
                    variantCount: 3,
                    source: "Fixture"
                )
            ]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: bundleURL.appendingPathComponent(BundleManifest.filename))
        return bundleURL
    }

    private static let cohortVCF = """
    ##fileformat=VCFv4.2
    ##contig=<ID=chr1,length=1000>
    ##FORMAT=<ID=GT,Number=1,Type=String,Description="Genotype">
    ##FORMAT=<ID=DP,Number=1,Type=Integer,Description="Depth">
    ##FORMAT=<ID=AD,Number=R,Type=Integer,Description="Allele depths">
    #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\tNA12878\tNA12879
    chr1\t100\trs100\tA\tG\t60\tPASS\t.\tGT:DP:AD\t1/1:35:0,35\t0/1:32:16,16
    chr1\t200\trs200\tC\tT\t50\tPASS\t.\tGT:DP:AD\t0/1:20:10,10\t0/1:22:11,11
    chr1\t300\trs300\tG\tA\t70\tPASS\t.\tGT:DP:AD\t1/1:31:0,31\t1/1:34:0,34
    """

    /// A reference bundle whose manifest has no `browser_summary`, as the project migrate tests build it.
    private static func makeLegacyReferenceBundle(
        named name: String,
        in project: ProvenanceCompatScenarios.Project
    ) throws -> URL {
        let bundleURL = project.root.appendingPathComponent("\(name).lungfishref", isDirectory: true)
        try ProvenanceCompatScenarios.write(">chr1\nACGT\n", to: bundleURL.appendingPathComponent("genome/sequence.fa"))
        try ProvenanceCompatScenarios.write("chr1\t4\t6\t4\t5\n", to: bundleURL.appendingPathComponent("genome/sequence.fa.fai"))
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let manifest = BundleManifest(
            formatVersion: "1.0",
            name: name,
            identifier: "org.lungfish.test.\(name.lowercased())",
            createdDate: fixedDate,
            modifiedDate: fixedDate,
            source: SourceInfo(organism: "Test organism", assembly: "Test assembly"),
            genome: GenomeInfo(
                path: "genome/sequence.fa",
                indexPath: "genome/sequence.fa.fai",
                totalLength: 4,
                chromosomes: [ChromosomeInfo(name: "chr1", length: 4, offset: 6, lineBases: 4, lineWidth: 5)]
            )
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: bundleURL.appendingPathComponent(BundleManifest.filename), options: .atomic)
        return bundleURL
    }
}
