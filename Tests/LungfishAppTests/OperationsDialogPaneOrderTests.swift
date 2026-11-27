// OperationsDialogPaneOrderTests.swift - The order of the words in the Operations dialogs, pinned (5.6 TV-SHELL)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Sub-phase 5.6, lane TV-SHELL, the tests-only first commit (5.6 Q1, UX 5). A pin is every `Text` of one pane in the order ViewInspector
// meets them, so a section title, a control label and a sentence each hold their place. The readiness pins hold each dialog's readiness
// text and the number of times it is drawn. The pins hold at the base of the sub-phase. The move commit updates each one to the state
// after the move: the removed sections leave and nothing else moves.

import XCTest
import SwiftUI
import ViewInspector
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishKit
@testable import LungfishWorkflow
import LungfishTestSupport

@MainActor
private final class PinDisabledFASTQLibrary: WorkflowLibraryEnabling {
    func isWorkflowEnabled(_ toolID: FASTQOperationToolID) -> Bool { false }
}

private struct PinNoPackStatusProvider: PluginPackStatusProviding {
    func visibleStatuses() async -> [PluginPackStatus] { [] }

    func status(for pack: PluginPack) async -> PluginPackStatus {
        PluginPackStatus(pack: pack, state: .needsInstall, toolStatuses: [], failureMessage: nil)
    }

    func invalidateVisibleStatusesCache() async {}

    func install(
        pack: PluginPack,
        reinstall: Bool,
        progress: (@Sendable (PluginPackInstallProgress) -> Void)?
    ) async throws {}
}

/// The states the Operations dialog tests host. Both OperationsDialogPaneOrderTests and OperationsDialogReadinessLineTests read them.
@MainActor
enum OperationsDialogFixtures {
    static func strings(_ texts: [InspectableView<ViewType.Text>], normalizing paths: [String] = []) -> [String] {
        let longestFirst = paths.sorted { $0.count > $1.count }
        return texts.compactMap { try? $0.string() }.map { text in
            var out = text
            for path in longestFirst where !path.isEmpty { out = out.replacingOccurrences(of: path, with: "<root>") }
            out = out.replacingOccurrences(
                of: #"[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}"#, with: "<uuid>", options: .regularExpression)
            return out.replacingOccurrences(of: #"-again-[0-9A-Fa-f]{8}"#, with: "-again-<id>", options: .regularExpression)
        }
    }

    static func drawn(_ text: String, in texts: [InspectableView<ViewType.Text>]) -> Int {
        texts.filter { (try? $0.string()) == text }.count
    }

    static func footerLines(_ texts: [InspectableView<ViewType.Text>]) -> [String] {
        texts.filter { (try? $0.accessibilityIdentifier())?.hasSuffix("status-text") == true }.compactMap { try? $0.string() }
    }

    /// The Text views that carry the readiness help tag: the footer's, and at the base a pane's Readiness section.
    static func helpLines(_ texts: [InspectableView<ViewType.Text>]) -> Int {
        texts.filter { (try? $0.help().string()) == LungfishHelpContent.operationReadiness.summary }.count
    }

    /// The readiness text, the number of times it is drawn, the footer lines found by their `status-text` identifier
    /// and the lines that carry the readiness help tag.
    static func readiness(_ texts: [InspectableView<ViewType.Text>], _ readinessText: String) -> [String] {
        [
            readinessText, "drawn \(drawn(readinessText, in: texts))", "footer lines \(footerLines(texts).count)",
            "readiness-help lines \(helpLines(texts))",
        ]
    }

    static func fastqState(_ tool: FASTQOperationToolID) -> FASTQOperationDialogState {
        let state = FASTQOperationDialogState(
            initialCategory: tool.categoryID,
            selectedInputURLs: [URL(fileURLWithPath: "/tmp/reads.fastq")],
            workflowLibrary: PinDisabledFASTQLibrary(),
            savontRuntimeStatusProvider: PinNoPackStatusProvider()
        )
        state.selectTool(tool)
        return state
    }

    static func workflowState(
        selecting title: String, defaults: UserDefaults, enabling enable: (WorkflowLibraryEnablementStore) -> Void
    ) throws -> WorkflowOperationDialogState {
        let enablement = WorkflowLibraryEnablementStore(userDefaults: defaults)
        enable(enablement)
        let state = WorkflowOperationDialogState(
            projectURL: nil, enablementStore: enablement,
            packageStore: WorkflowLibraryImportedPackageStore(userDefaults: defaults))
        let tool = try XCTUnwrap(state.tools.first { $0.title == title })
        state.selectTool(tool.id)
        return state
    }

    static func workflowDialog(_ state: WorkflowOperationDialogState) -> WorkflowOperationsDialog {
        WorkflowOperationsDialog(
            state: state, onRun: { _ in }, onCreateTwelveSReferenceBundle: { _ in }, onOpenPreviousRun: {}, onCancel: {})
    }

    /// The texts of the detail pane, the second scroll view of the dialog after the sidebar.
    static func workflowDetailTexts(_ state: WorkflowOperationDialogState, paths: [String] = []) throws -> [String] {
        let scrolls = try workflowDialog(state).inspect().findAll(ViewType.ScrollView.self)
        XCTAssertGreaterThanOrEqual(scrolls.count, 2)
        return strings(scrolls[1].findAll(ViewType.Text.self), normalizing: paths)
    }

    struct PackageFixture {
        let root: URL
        let state: WorkflowOperationDialogState
        let configuration: LocalWorkflowReplayConfiguration
        var paths: [String] { [root.path, root.resolvingSymlinksInPath().path, "/private" + root.path] }
    }

    /// An invented local package, selected in the Workflow dialog, with the replay configuration of one of its runs.
    static func packageFixture(defaults: UserDefaults) throws -> PackageFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OperationsDialogPaneOrder-\(UUID().uuidString)", isDirectory: true)
        let package = root.appendingPathComponent("Fixture.lungfishflowpkg")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try "// invented fixture; never executed".write(
            to: package.appendingPathComponent("main.nf"), atomically: true, encoding: .utf8)
        let manifest = WorkflowPackageManifest(
            id: "invented-repeat", name: "Invented Repeat", version: "1", category: "Local Test",
            runner: WorkflowPackageRunner(kind: .nextflow, entrypoint: "main.nf"),
            inputs: [
                WorkflowPackageInput(id: "reference", name: "Reference", bundleTypes: [.lungfishref]),
                WorkflowPackageInput(id: "reads", name: "Reads", bundleTypes: [.lungfishfastq]),
            ],
            outputs: [
                WorkflowPackageOutput(
                    id: "result", name: "Result", bundleType: .lungfishref, pathTemplate: "{outputName}.lungfishref")
            ]
        )
        try JSONEncoder().encode(manifest).write(to: package.appendingPathComponent("manifest.json"))
        let inputs = [
            root.appendingPathComponent("reference.lungfishref"), root.appendingPathComponent("reads.lungfishfastq"),
        ]
        for input in inputs {
            try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
            try "invented local payload".write(
                to: input.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        }
        let output = root.appendingPathComponent("original-results")
        let request = LocalWorkflowRunRequest(
            workflowURL: package.appendingPathComponent("main.nf"), engine: .nextflow, inputURLs: inputs,
            outputDirectory: output, expectedOutputURLs: [output.appendingPathComponent("retained-name.lungfishref")],
            params: [
                "reference": inputs[0].path, "reference_bundle": inputs[0].path,
                "reads": inputs[1].path, "reads_bundle": inputs[1].path, "outdir": output.path,
            ],
            cpus: 3, memory: nil
        )
        let identity = try LocalWorkflowReplayIdentity.capture(for: request)
        let history = request.manifest(replayIdentity: identity, executionStatus: .completed, exitCode: 0)
        let configuration = try LocalWorkflowReplayConfiguration.restored(from: history)
        let enablement = WorkflowLibraryEnablementStore(userDefaults: defaults)
        let packages = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        let validated = try WorkflowPackageValidator.validatePackage(at: package)
        packages.addPackage(at: package)
        _ = packages.validatedPackages()
        enablement.setUserWorkflow(validated, enabled: true)
        let state = WorkflowOperationDialogState(projectURL: nil, enablementStore: enablement, packageStore: packages)
        state.selectTool("package.invented-repeat")
        return PackageFixture(root: root, state: state, configuration: configuration)
    }

    static func bamState(tool: BAMVariantCallingToolID? = nil) throws -> BAMVariantCallingDialogState {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OperationsDialogPaneOrder-\(UUID().uuidString).lungfishref", isDirectory: true)
        let alignment = AlignmentTrackInfo(
            id: "aln-1", name: "Sample 1", format: .bam, sourcePath: "alignments/sample.sorted.bam",
            indexPath: "alignments/sample.sorted.bam.bai", checksumSHA256: "bam-sha")
        for relative in [alignment.sourcePath, alignment.indexPath] {
            let file = bundleURL.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data("fixture".utf8)))
        }
        let manifest = BundleManifest(
            name: "Bundle", identifier: "bundle.test",
            source: SourceInfo(organism: "Virus", assembly: "TestAssembly", database: "Test"),
            genome: GenomeInfo(
                path: "genome/reference.fa.gz", indexPath: "genome/reference.fa.gz.fai", totalLength: 29_903,
                chromosomes: [ChromosomeInfo(name: "chr1", length: 29_903, offset: 0, lineBases: 60, lineWidth: 61)]),
            variants: [],
            alignments: [alignment]
        )
        let state = BAMVariantCallingDialogState(bundle: ReferenceBundle(url: bundleURL, manifest: manifest))
        if let tool { state.selectTool(named: tool.rawValue) }
        return state
    }

    static func iqTreeState() -> IQTreeInferenceDialogState {
        let request = MultipleSequenceAlignmentTreeInferenceRequest(
            bundleURL: URL(fileURLWithPath: "/project/Analyses/Multiple Sequence Alignments/alignment.lungfishmsa"),
            rows: "row-1,row-2,row-3,row-4", columns: "10-200",
            suggestedName: "alignment-tree.lungfishtree", displayName: "alignment")
        let names = ["Homo sapiens", "Macaca mulatta", "Pan troglodytes", "Gorilla gorilla", "Mus musculus"]
        return IQTreeInferenceDialogState(
            request: request, projectURL: URL(fileURLWithPath: "/project"),
            alignment: IQTreeAlignmentSummary(
                rows: names.enumerated().map { IQTreeAlignmentSummary.Row(id: "row-\($0.offset + 1)", displayName: $0.element) },
                alignedLength: 300, alphabet: "dna"))
    }

    static func orfState() -> SequenceORFOperationDialogState {
        SequenceORFOperationDialogState(
            bundleURL: URL(fileURLWithPath: "/project/Genomes/genome.lungfishref"), sequenceName: "chr1", range: 0..<3000,
            defaultTrackName: "ORFs", defaultTrackID: "orfs")
    }
}

@MainActor
final class OperationsDialogPaneOrderTests: XCTestCase {
    private typealias Fx = OperationsDialogFixtures

    private var defaults: UserDefaults { makeTestDefaultsSuite(prefix: "OperationsDialogPaneOrderTests").defaults }

    private static let expected: [String: [String]] = [
        "bam.variantCalling.ivar": [
            "Overview",
            "Sample 1",
            "Alignment Track",
            "Select the analysis-ready BAM track to use as variant-calling input.",
            "Select the analysis-ready BAM track to use as variant-calling input.",
            "Select the analysis-ready BAM track to use as variant-calling input.",
            "Output Variant Track Name",
            "Name the variant track that will be added to the bundle.",
            "Name the variant track that will be added to the bundle.",
            "Name the variant track that will be added to the bundle.",
            "Thresholds",
            "Minimum Allele Frequency",
            "0.05",
            "Leave blank to use caller defaults, or enter explicit thresholds.",
            "Leave blank to use caller defaults, or enter explicit thresholds.",
            "Leave blank to use caller defaults, or enter explicit thresholds.",
            "Minimum Depth",
            "10",
            "Leave blank to use caller defaults, or enter explicit thresholds.",
            "Leave blank to use caller defaults, or enter explicit thresholds.",
            "Leave blank to use caller defaults, or enter explicit thresholds.",
            "iVar settings",
            "This BAM has already been primer-trimmed for iVar.",
            "Mark only if primers were removed from this exact BAM.",
            "Mark only if primers were removed from this exact BAM.",
            "iVar options",
            "Consensus allele frequency",
            "0.75",
            "Allele-frequency threshold for including bases in iVar consensus.",
            "Allele-frequency threshold for including bases in iVar consensus.",
            "Allele-frequency threshold for including bases in iVar consensus.",
            "Merge AF distance",
            "0.25",
            "Allele-frequency distance used when merging nearby iVar calls.",
            "Allele-frequency distance used when merging nearby iVar calls.",
            "Allele-frequency distance used when merging nearby iVar calls.",
            "Minimum ALT quality",
            "20",
            "Minimum ALT base quality required before iVar keeps a variant.",
            "Minimum ALT base quality required before iVar keeps a variant.",
            "Minimum ALT base quality required before iVar keeps a variant.",
            "Ignore strand bias (recommended for amplicons)",
            "Disable strand-bias filtering when amplicon design makes it inappropriate.",
            "Disable strand-bias filtering when amplicon design makes it inappropriate.",
            "Extra arguments",
            "--call-indels",
            "Pass extra arguments directly to the underlying command.",
            "Pass extra arguments directly to the underlying command.",
            "Pass extra arguments directly to the underlying command.",
        ],
        "bam.variantCalling": [
            "Overview",
            "Sample 1",
            "Alignment Track",
            "Select the analysis-ready BAM track to use as variant-calling input.",
            "Select the analysis-ready BAM track to use as variant-calling input.",
            "Select the analysis-ready BAM track to use as variant-calling input.",
            "Output Variant Track Name",
            "Name the variant track that will be added to the bundle.",
            "Name the variant track that will be added to the bundle.",
            "Name the variant track that will be added to the bundle.",
            "Thresholds",
            "Minimum Allele Frequency",
            "0.05",
            "Leave blank to use caller defaults, or enter explicit thresholds.",
            "Leave blank to use caller defaults, or enter explicit thresholds.",
            "Leave blank to use caller defaults, or enter explicit thresholds.",
            "Minimum Depth",
            "10",
            "Leave blank to use caller defaults, or enter explicit thresholds.",
            "Leave blank to use caller defaults, or enter explicit thresholds.",
            "Leave blank to use caller defaults, or enter explicit thresholds.",
            "LoFreq settings",
            "LoFreq is ready to run directly on the selected bundle alignment track.",
            "Extra arguments",
            "--call-indels",
            "Pass extra arguments directly to the underlying command.",
            "Pass extra arguments directly to the underlying command.",
            "Pass extra arguments directly to the underlying command.",
        ],
        "fastq.mafft": [
            "Inputs",
            "/tmp/reads.fastq",
            "Select the reference, database, or barcode file required by this tool.",
            "Select the reference, database, or barcode file required by this tool.",
            "Primary settings",
            "Aligning all 0 sequences.",
            "Automatic",
            "L-INS-i",
            "G-INS-i",
            "E-INS-i",
            "FFT-NS-2",
            "PartTree",
            "Strategy",
            "Choose the MAFFT algorithm preset for the sequence set.",
            "Choose the MAFFT algorithm preset for the sequence set.",
            "Auto",
            "Nucleotide",
            "Protein",
            "Sequence Type",
            "Tell MAFFT whether inputs are nucleotide, protein, or auto-detected.",
            "Tell MAFFT whether inputs are nucleotide, protein, or auto-detected.",
            "Tell MAFFT whether inputs are nucleotide, protein, or auto-detected.",
            "Input Order",
            "Aligned Order",
            "Output Order",
            "Choose whether aligned records keep input order or MAFFT order.",
            "Choose whether aligned records keep input order or MAFFT order.",
            "Choose whether aligned records keep input order or MAFFT order.",
            "MAFFT will run through lungfish-cli and write native .lungfishmsa provenance with the resolved options.",
            "Advanced settings",
            "Off",
            "Adjust Direction",
            "Adjust Direction Accurately",
            "Direction Adjustment",
            "Allow MAFFT to reverse-complement nucleotide records when needed.",
            "Allow MAFFT to reverse-complement nucleotide records when needed.",
            "Strict Alphabet",
            "Allow Any Symbol",
            "Symbol Policy",
            "Choose how unexpected sequence symbols are handled before alignment.",
            "Choose how unexpected sequence symbols are handled before alignment.",
            "Threads",
            "",
            "Number of worker threads to request. Leave blank for default when allowed.",
            "Number of worker threads to request. Leave blank for default when allowed.",
            "Deterministic threading",
            "Use one thread when exact deterministic alignment is required.",
            "Use one thread when exact deterministic alignment is required.",
            "Treat FASTQ records as assembled or consensus sequences",
            "Allow FASTQ records that represent assembled or consensus sequences.",
            "Allow FASTQ records that represent assembled or consensus sequences.",
            "MAFFT Parameters",
            "",
            "Pass extra arguments directly to the underlying command.",
            "Pass extra arguments directly to the underlying command.",
            "These arguments are passed directly to MAFFT after the selected strategy.",
            "Pass extra arguments directly to the underlying command.",
            "Pass extra arguments directly to the underlying command.",
            "Advanced Options",
        ],
        "fastq.qualityTrim": [
            "Inputs",
            "/tmp/reads.fastq",
            "Select the reference, database, or barcode file required by this tool.",
            "Select the reference, database, or barcode file required by this tool.",
            "Primary settings",
            "Threshold",
            "",
            "Minimum base quality used when trimming low-quality read ends.",
            "Minimum base quality used when trimming low-quality read ends.",
            "Window Size",
            "",
            "Number of bases evaluated together by sliding-window trimming.",
            "Number of bases evaluated together by sliding-window trimming.",
            "Cut Right",
            "Cut Front",
            "Cut Tail",
            "Cut Both",
            "Mode",
            "Choose which read ends are scanned for quality trimming.",
            "Choose which read ends are scanned for quality trimming.",
            "Choose which read ends are scanned for quality trimming.",
            "Extra arguments",
            "",
            "Pass extra arguments directly to the underlying command.",
            "Pass extra arguments directly to the underlying command.",
            "Output",
            "Per Input",
            "Grouped Result",
            "Output Strategy",
            "Choose whether outputs stay per input or combine compatible inputs.",
            "Choose whether outputs stay per input or combine compatible inputs.",
            "Choose whether outputs stay per input or combine compatible inputs.",
        ],
        "fastq.rnaSeqQuant": [
            "Inputs",
            "/tmp/reads.fastq",
            "Reference set",
            // With no set installed the group says where to get one, in place of the empty picker (2026-11-26).
            "Download a reference set in Plugin Manager to count these reads.",
            "Download Reference Set\u{2026}",
            "Lungfish counts on the reference set's own index and never builds one here. A set downloaded in Plugin Manager has its index at k 31 with the genome as decoys.",
            "Index",
            "k-mer length",
            "k",
            "k-mer length of the index, an odd number up to 31 (default: 31)",
            "Genome",
            "None",
            "Decoys",
            "genome (the default) for the index with the genome as decoys, or none",
            "Trimming",
            "Trim with Trim Galore",
            "Trim the reads with Trim Galore before salmon (default: not trimmed)",
            "Off",
            "On",
            "Poly-G trimming",
            "With --trim: on passes --poly_g to Trim Galore, off (the default) --no_poly_g",
        ],
        "iqtree.dialog": [
            "Build Tree with IQ-TREE",
            "Infer a maximum-likelihood tree from an alignment.",
            "alignment",
            "Build Tree with IQ-TREE",
            "Infer a maximum-likelihood tree from an alignment.",
            "Choose the operation to run on the selected scientific inputs.",
            "Choose the operation to run on the selected scientific inputs.",
            "Choose the operation to run on the selected scientific inputs.",
            "Choose the operation to run on the selected scientific inputs.",
            "Choose the operation to run on the selected scientific inputs.",
            "Analyses/Multiple Sequence Alignments/alignment.lungfishmsa",
            "Alignment",
            "Whole alignment (5 sequences, 300 columns)",
            "Selected rows and columns (4 sequences, columns 10-200)",
            "Build from",
            "Inputs",
            "Find best model (ModelFinder)",
            "JC",
            "HKY+F+G4",
            "GTR+F+I+G4",
            "GTR+F+R4",
            "Custom…",
            "Model",
            "Detect automatically",
            "DNA",
            "Codon",
            "Sequence type",
            "Model",
            "Ultrafast bootstrap (UFBoot)",
            "UFBoot replicates",
            "UFBoot replicates",
            "UFBoot replicates",
            "IQ-TREE requires at least 1000.",
            "SH-aLRT test",
            "SH-aLRT replicates",
            "SH-aLRT replicates",
            "SH-aLRT replicates",
            "UFBoot 95 or higher and SH-aLRT 80 or higher indicate a well-supported clade.",
            "Branch support",
            "Homo sapiens",
            "Macaca mulatta",
            "Pan troglodytes",
            "Gorilla gorilla",
            "Outgroup",
            "The outgroup sets where the tree is rooted. It does not change the inferred relationships.",
            "Rooting",
            "Name",
            "Name",
            "Output",
            "Seed",
            "Random",
            "Seed",
            "A random seed is drawn and recorded in the command.",
            "Threads",
            "Threads",
            "One thread gives the same tree on every run. More threads can be faster on large alignments, but IQ-TREE then gives slightly different branch lengths each run.",
            "Run",
            "Safe numerical mode",
            "Slower. Use it if IQ-TREE reports numerical underflow.",
            "Keep identical sequences",
            "When off, IQ-TREE drops third and later identical copies from the search and adds them back as zero-length tips.",
            "IQ-TREE executable",
            "Bundled iqtree3",
            "IQ-TREE executable",
            "Additional IQ-TREE parameters",
            "Additional IQ-TREE parameters",
            "Advanced parameters are passed directly to IQ-TREE after the curated options.",
            "Advanced",
            "Ready to build a tree.",
            "Shows whether the selected inputs and settings are ready to run.",
            "Shows whether the selected inputs and settings are ready to run.",
            "Shows whether the selected inputs and settings are ready to run.",
            "Shows whether the selected inputs and settings are ready to run.",
            "Cancel",
            "Build Tree",
            "Run with the visible settings and write output provenance.",
            "Run with the visible settings and write output provenance.",
            "Run with the visible settings and write output provenance.",
            "Run with the visible settings and write output provenance.",
            "Run with the visible settings and write output provenance.",
            "Run with the visible settings and write output provenance.",
        ],
        "orf.dialog": [
            "FIND ORFS",
            "Create an annotation track for open reading frames.",
            "chr1:1-3000",
            "Find ORFs",
            "Add ORF annotations with translated products.",
            "Choose the operation to run on the selected scientific inputs.",
            "Choose the operation to run on the selected scientific inputs.",
            "Choose the operation to run on the selected scientific inputs.",
            "Choose the operation to run on the selected scientific inputs.",
            "Choose the operation to run on the selected scientific inputs.",
            "+1",
            "+2",
            "+3",
            "-1",
            "-2",
            "-3",
            "Reading frames",
            "1 - Standard",
            "2 - Vertebrate Mitochondrial",
            "3 - Yeast Mitochondrial",
            "4 - Mold, Protozoan, and Coelenterate Mitochondrial",
            "5 - Invertebrate Mitochondrial",
            "6 - Ciliate, Dasycladacean, and Hexamita Nuclear",
            "11 - Bacterial, Archaeal and Plant Plastid",
            "Codon table",
            "Minimum ORF length",
            "Translation",
            "Track name",
            "Track ID",
            "Output",
            "Include partial ORFs",
            "Allow alternative starts",
            "Options",
            "Ready",
            "Shows whether the selected inputs and settings are ready to run.",
            "Shows whether the selected inputs and settings are ready to run.",
            "Shows whether the selected inputs and settings are ready to run.",
            "Shows whether the selected inputs and settings are ready to run.",
            "Cancel",
            "Run",
            "Run with the visible settings and write output provenance.",
            "Run with the visible settings and write output provenance.",
            "Run with the visible settings and write output provenance.",
            "Run with the visible settings and write output provenance.",
            "Run with the visible settings and write output provenance.",
            "Run with the visible settings and write output provenance.",
        ],
        "readiness.bamVariantCalling": [
            "Ready to run LoFreq on Sample 1.",
            "drawn 1",
            "footer lines 0",
            "readiness-help lines 1",
        ],
        "readiness.databaseSearch": [
            "Ready",
            "drawn 1",
            "footer lines 1",
            "readiness-help lines 1",
        ],
        "readiness.fastq": [
            "Ready to configure output.",
            "drawn 1",
            "footer lines 0",
            "readiness-help lines 1",
        ],
        "readiness.iqTree": [
            "Ready to build a tree.",
            "drawn 1",
            "footer lines 1",
            "readiness-help lines 1",
        ],
        "readiness.orf": [
            "Ready",
            "drawn 1",
            "footer lines 1",
            "readiness-help lines 1",
        ],
        "readiness.primerDesign": [
            "Select sequence or alignment bundles in the project sidebar.",
            "drawn 1",
            "footer lines 1",
            "readiness-help lines 1",
        ],
        "readiness.workflow": [
            "Select a reference bundle or FASTA file.",
            "drawn 1",
            "footer lines 1",
            "readiness-help lines 1",
        ],
        "workflow.ontGenotyping": [
            "Overview",
            "Open Previous Run…",
            "Inputs",
            "Reference",
            "MHC bundles contain allele sequences, haplotype definitions and display order. FASTA files contain sequences; choose a separate definition to call haplotypes.",
            "MHC bundles contain allele sequences, haplotype definitions and display order. FASTA files contain sequences; choose a separate definition to call haplotypes.",
            "No reference selected",
            "No reference selected",
            "No reference selected",
            "Choose…",
            "FASTQ Bundles",
            "No read bundles selected",
            "No read bundles selected",
            "No read bundles selected",
            "No read bundles selected",
            "Primary settings",
            "Report",
            "Report Name",
            "Report Name",
            "Name the report file written by this workflow.",
            "Name the report file written by this workflow.",
            "Run Parameters",
            "Threads",
            "Threads",
            "Number of worker threads to request. Leave blank for default when allowed.",
            "Number of worker threads to request. Leave blank for default when allowed.",
            "Minimum supporting reads",
            "Minimum supporting reads",
            "Minimum supporting reads used to evaluate haplotype evidence.",
            "Minimum supporting reads used to evaluate haplotype evidence.",
            "ONT sample bundles",
            "Haplotyping",
            "Deterministic haplotyping",
            "Genotyping only",
            "Analysis Mode",
            "Report detected alleles and supporting reads without assigning haplotypes.",
            "Report detected alleles and supporting reads without assigning haplotypes.",
            "Report detected alleles and supporting reads without assigning haplotypes.",
            "Report detected alleles and supporting reads without assigning haplotypes.",
            "Advanced settings",
            "minimap2 arguments",
            "minimap2 arguments",
            "Pass extra arguments directly to the underlying command.",
            "Pass extra arguments directly to the underlying command.",
            "Keep Intermediates",
            "Keeps large regenerable work files for troubleshooting. Off is recommended for normal runs.",
            "Additional arguments follow the mapping preset for the selected read platform.",
            "Advanced Options",
            "Output",
            "Directory",
            "No output directory selected",
            "No output directory selected",
            "No output directory selected",
            "Choose…",
        ],
        "workflow.package": [
            "Overview",
            "Open Previous Run…",
            "Inputs",
            "Reference",
            "No reference selected",
            "No reference selected",
            "No reference selected",
            "Choose…",
            "FASTQ Bundles",
            "No read bundles selected",
            "No read bundles selected",
            "No read bundles selected",
            "No read bundles selected",
            "Primary settings",
            "Output Name",
            "Output Name",
            "Cores",
            "Cores",
            "Nextflow package, version 1.",
            "Inputs: Reference, Reads",
            "Outputs: {outputName}.lungfishref",
            "Runtime: none",
            "Output",
            "Directory",
            "No output directory selected",
            "No output directory selected",
            "No output directory selected",
            "Choose…",
        ],
        "workflow.package.runAgain": [
            "Overview",
            "Open Previous Run…",
            "Run Again: Invented Repeat, version 1",
            "<root>/original.lungfishrun",
            "2 retained inputs · 3 cores · fresh output directory",
            "Only the original package and input bytes are accepted. Locate missing copies, then check the configuration. The previous run stays unchanged.",
            "Open Workflow Library…",
            "Open Tool Setup…",
            "Check Configuration",
            "Inputs",
            "Reference",
            "<root>/reference.lungfishref",
            "<root>/reference.lungfishref",
            "<root>/reference.lungfishref",
            "Replace…",
            "Clear",
            "FASTQ Bundles",
            "Locate Original Reads…",
            "<root>/reads.lungfishfastq",
            "<root>/reads.lungfishfastq",
            "<root>/reads.lungfishfastq",
            "<root>/reads.lungfishfastq",
            "Primary settings",
            "Output Name",
            "Output Name",
            "Cores",
            "Cores",
            "Nextflow package, version 1.",
            "Inputs: Reference, Reads",
            "Outputs: {outputName}.lungfishref",
            "Runtime: none",
            "Output",
            "Directory",
            "<root>/original-results-again-<id>",
            "<root>/original-results-again-<id>",
            "<root>/original-results-again-<id>",
            "Replace…",
        ],
        "workflow.pseudobulk": [
            "Inputs",
            "Single-cell RNA-seq result",
            "No single-cell result selected",
            "Choose…",
            "Labels table",
            "No labels table selected",
            "Choose…",
            "A tab-separated table with barcode and label columns, and sample for a result of two or more samples.",
            "Groups under 10 cells and cells with no label are left out. The Operations row says which.",
            "Primary settings",
            "Result name",
            "Result name",
            "Output",
            "Directory",
            "No output directory selected",
            "No output directory selected",
            "No output directory selected",
            "Choose…",
        ],
    ]

    private func pin(_ name: String, _ actual: [String], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual, Self.expected[name], name, file: file, line: line)
    }

    // MARK: Pane order, FASTQ

    func testQualityTrimPaneOrder() throws {
        let state = Fx.fastqState(.qualityTrim)
        pin("fastq.qualityTrim", Fx.strings(try FASTQOperationToolPanes(state: state).inspect().findAll(ViewType.Text.self)))
    }

    func testMafftPaneOrderWithItsAdvancedControls() throws {
        let state = Fx.fastqState(.mafft)
        state.mafftAdvancedOptionsExpanded = true
        pin("fastq.mafft", Fx.strings(try FASTQOperationToolPanes(state: state).inspect().findAll(ViewType.Text.self)))
    }

    func testRNASeqQuantPaneOrder() throws {
        let state = Fx.fastqState(.rnaSeqQuant)
        pin("fastq.rnaSeqQuant", Fx.strings(try FASTQOperationToolPanes(state: state).inspect().findAll(ViewType.Text.self)))
    }

    // MARK: Pane order, Workflow

    func testPseudobulkPaneOrderWithNoReplay() throws {
        let state = try Fx.workflowState(selecting: "Pseudobulk RNA-seq Cells", defaults: defaults, enabling: { $0.setWorkflow(WorkflowLibraryCatalog.rnaSeqPseudobulkItem, enabled: true) })
        // E0 and F are help tags, which ViewInspector lists again for each help modifier and hint, so the drawn list leaves them out.
        let helpTags = Set(RNASeqPseudobulkHelp.items.map(\.summary))
        pin("workflow.pseudobulk", try Fx.workflowDetailTexts(state).filter { !helpTags.contains($0) })
    }

    func testONTGenotypingPaneOrder() throws {
        let state = try Fx.workflowState(selecting: "MiSeq Amplicon MHC Genotyping", defaults: defaults, enabling: { $0.setWorkflow(.ontGenotyping, enabled: true) })
        pin("workflow.ontGenotyping", try Fx.workflowDetailTexts(state))
    }

    func testImportedPackagePaneOrder() throws {
        let fixture = try Fx.packageFixture(defaults: defaults)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        pin("workflow.package", try Fx.workflowDetailTexts(fixture.state, paths: fixture.paths))
    }

    func testRunAgainPaneOrder() throws {
        let fixture = try Fx.packageFixture(defaults: defaults)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.state.restoreReplayConfiguration(
            fixture.configuration, sourceBundleURL: fixture.root.appendingPathComponent("original.lungfishrun"))
        pin("workflow.package.runAgain", try Fx.workflowDetailTexts(fixture.state, paths: fixture.paths))
    }

    // MARK: Pane order, BAM variant calling, IQ-TREE and ORF

    func testBAMVariantCallingPaneOrder() throws {
        let state = try Fx.bamState()
        pin("bam.variantCalling", Fx.strings(try BAMVariantCallingToolPanes(state: state).inspect().findAll(ViewType.Text.self)))
    }

    func testBAMVariantCallingPaneOrderForIVar() throws {
        let state = try Fx.bamState(tool: .ivar)
        pin("bam.variantCalling.ivar", Fx.strings(try BAMVariantCallingToolPanes(state: state).inspect().findAll(ViewType.Text.self)))
    }

    func testIQTreeDialogOrder() throws {
        let dialog = IQTreeInferenceDialog(state: Fx.iqTreeState(), onCancel: {}, onRun: {})
        pin("iqtree.dialog", Fx.strings(try dialog.inspect().findAll(ViewType.Text.self)))
    }

    func testORFDialogOrder() throws {
        let dialog = SequenceORFOperationDialog(state: Fx.orfState(), onCancel: {}, onRun: {})
        pin("orf.dialog", Fx.strings(try dialog.inspect().findAll(ViewType.Text.self)))
    }

    // MARK: Readiness texts of the seven dialogs

    func testReadinessTextOfTheFASTQDialog() throws {
        let state = Fx.fastqState(.qualityTrim)
        let texts = try FASTQOperationDialog(state: state, onCancel: {}, onRun: {}).inspect().findAll(ViewType.Text.self)
        pin("readiness.fastq", Fx.readiness(texts, state.readinessText))
    }

    func testReadinessTextOfTheWorkflowDialog() throws {
        let state = try Fx.workflowState(selecting: "MiSeq Amplicon MHC Genotyping", defaults: defaults, enabling: { $0.setWorkflow(.ontGenotyping, enabled: true) })
        let texts = try Fx.workflowDialog(state).inspect().findAll(ViewType.Text.self)
        pin("readiness.workflow", Fx.readiness(texts, state.readinessText))
    }

    func testReadinessTextOfThePrimerDesignDialog() throws {
        let state = PrimerDesignDialogState()
        let texts = try PrimerDesignDialog(state: state, onRun: {}, onClose: {}).inspect().findAll(ViewType.Text.self)
        let text = state.errorMessage ?? state.validationMessage ?? state.inputReadinessMessage ?? "Ready. Progress will appear in Operations."
        pin("readiness.primerDesign", Fx.readiness(texts, text))
    }

    func testReadinessTextOfTheBAMVariantCallingDialog() throws {
        let state = try Fx.bamState()
        let texts = try BAMVariantCallingDialog(state: state, onCancel: {}, onRun: {}).inspect().findAll(ViewType.Text.self)
        pin("readiness.bamVariantCalling", Fx.readiness(texts, state.readinessText))
    }

    func testReadinessTextOfTheORFDialog() throws {
        let state = Fx.orfState()
        let texts = try SequenceORFOperationDialog(state: state, onCancel: {}, onRun: {}).inspect().findAll(ViewType.Text.self)
        pin("readiness.orf", Fx.readiness(texts, state.readinessText))
    }

    func testReadinessTextOfTheDatabaseSearchDialog() throws {
        let state = DatabaseSearchDialogState(initialDestination: .genBankGenomes)
        let texts = try DatabaseSearchDialog(state: state).inspect().findAll(ViewType.Text.self)
        pin("readiness.databaseSearch", Fx.readiness(texts, DatabaseSearchDialogPresentation(state: state).statusText))
    }

    func testReadinessTextOfTheIQTreeDialog() throws {
        let state = Fx.iqTreeState()
        let texts = try IQTreeInferenceDialog(state: state, onCancel: {}, onRun: {}).inspect().findAll(ViewType.Text.self)
        pin("readiness.iqTree", Fx.readiness(texts, state.readinessText))
    }
}
