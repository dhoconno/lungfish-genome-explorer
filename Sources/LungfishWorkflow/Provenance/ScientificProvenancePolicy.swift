// ScientificProvenancePolicy.swift - Coverage gates for scientific provenance
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

public enum ProvenanceWorkflowKind: String, Sendable, Equatable {
    case dataWriting
    case metadataOnly
    case inspectOnly
}

public enum ProvenanceOutputPathExpectation: String, Sendable, Equatable {
    case finalStoredPayload
    case metadataArtifact
    case none
}

public struct ProvenancePolicyEntry: Sendable, Equatable {
    public let id: String
    public let workflowKind: ProvenanceWorkflowKind
    public let createsOrModifiesScientificData: Bool
    public let requiresProvenance: Bool
    public let writer: String
    public let outputPathExpectation: ProvenanceOutputPathExpectation

    public init(
        id: String,
        createsOrModifiesScientificData: Bool,
        requiresProvenance: Bool,
        writer: String,
        workflowKind: ProvenanceWorkflowKind? = nil,
        outputPathExpectation: ProvenanceOutputPathExpectation? = nil
    ) {
        self.id = id
        let resolvedWorkflowKind = workflowKind
            ?? (createsOrModifiesScientificData ? .dataWriting : (requiresProvenance ? .metadataOnly : .inspectOnly))
        self.workflowKind = resolvedWorkflowKind
        self.createsOrModifiesScientificData = createsOrModifiesScientificData
        self.requiresProvenance = requiresProvenance
        self.writer = writer
        self.outputPathExpectation = outputPathExpectation
            ?? Self.defaultOutputPathExpectation(for: resolvedWorkflowKind)
    }

    private static func defaultOutputPathExpectation(
        for workflowKind: ProvenanceWorkflowKind
    ) -> ProvenanceOutputPathExpectation {
        switch workflowKind {
        case .dataWriting:
            return .finalStoredPayload
        case .metadataOnly:
            return .metadataArtifact
        case .inspectOnly:
            return .none
        }
    }
}

public enum ScientificProvenancePolicy {
    public static func nativeTool(_ tool: NativeTool) -> ProvenancePolicyEntry? {
        nativeToolPolicies[tool.rawValue]
    }

    public static func cliCommand(_ commandName: String) -> ProvenancePolicyEntry? {
        let key = commandName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return cliCommandPolicies[key]
    }

    /// The entry for a command given as its path below the executable, such as `["import", "bam"]`.
    ///
    /// The path takes the exact row of ``cliCommandPathPolicies``, else the row of its longest
    /// registered prefix there, else the entry of the command group that starts the path in
    /// ``cliCommandPolicies``. It never takes the entry of its last component, because another
    /// command can share that name (`import bam` is no `bam` command), and a leaf of a group that
    /// holds no entry, such as `conda search`, gets none (plan decision E16). Case and blanks are
    /// not part of the path.
    public static func cliCommand(path commandPath: [String]) -> ProvenancePolicyEntry? {
        let words = commandPath
            .flatMap { $0.split(whereSeparator: \.isWhitespace) }
            .map { $0.lowercased() }
        guard let group = words.first else { return nil }
        for length in stride(from: words.count, through: 2, by: -1) {
            if let row = cliCommandPathPolicies[words.prefix(length).joined(separator: " ")] {
                return row
            }
        }
        return cliCommandPolicies[group]
    }

    public static let canonicalCLICommandNames: [String] = [
        "convert",
        "analyze",
        "translate",
        "sequence",
        "search",
        "universal-search",
        "extract",
        "fastq",
        "workflow",
        "run-headless",
        "fetch",
        "bundle",
        "project",
        "blast",
        "kraken2",
        "esviritu",
        "taxtriage",
        "align",
        "msa",
        "tree",
        "assemble",
        "orient",
        "map",
        "import",
        "import-fastq",
        "ops",
        "provenance",
        "bam",
        "variants",
        "gatk",
        "nao-mgs",
        "freyja",
        "nvd",
        "cz-id",
        "metadata",
        "build-db",
        "markdup",
        "primers",
        "genotype",
        "haplotypes",
        "tools"
    ]

    /// The entry of each top-level command, by its name or an alias. Every leaf below a command takes
    /// the entry of its group unless ``cliCommandPathPolicies`` holds a row for it.
    public static let cliCommandPolicies: [String: ProvenancePolicyEntry] = [
        "convert": dataWriting("cli.convert"),
        "analyze": inspectOnly("cli.analyze"),
        "translate": dataWriting("cli.translate"),
        "sequence": dataWriting("cli.sequence"),
        "search": dataWriting("cli.search"),
        "universal-search": dataWriting("cli.universal-search"),
        "extract": dataWriting("cli.extract"),
        "fastq": dataWriting("cli.fastq"),
        "workflow": dataWriting("cli.workflow"),
        "run-headless": dataWriting("cli.run-headless"),
        "fetch": dataWriting("cli.fetch"),
        "bundle": dataWriting("cli.bundle"),
        "project": dataWriting("cli.project"),
        "blast": dataWriting("cli.blast"),
        // The group's one subcommand is `classify`, which writes the record.
        "kraken2": dataWriting("cli.kraken2", writer: "ClassifyCommand/ProvenanceRunBuilder"),
        "esviritu": dataWriting("cli.esviritu"),
        "taxtriage": dataWriting("cli.taxtriage"),
        "align": dataWriting("cli.align"),
        "msa": dataWriting("cli.msa"),
        "tree": dataWriting("cli.tree"),
        "assemble": dataWriting("cli.assemble"),
        "orient": dataWriting("cli.orient"),
        "map": dataWriting("cli.map"),
        "import": dataWriting("cli.import"),
        "import-fastq": dataWriting("cli.import-fastq"),
        "ops": inspectOnly("cli.ops"),
        "provenance": metadataOnly("cli.provenance", requiresProvenance: true, writer: "ProvenanceExporter"),
        "bam": dataWriting("cli.bam"),
        "variants": dataWriting("cli.variants"),
        "gatk": dataWriting("cli.gatk"),
        "nao-mgs": dataWriting("cli.nao-mgs"),
        "freyja": dataWriting("cli.freyja"),
        "nvd": dataWriting("cli.nvd"),
        "cz-id": dataWriting("cli.cz-id"),
        "czid": dataWriting("cli.cz-id"),
        "metadata": dataWriting("cli.metadata", writer: "MetadataCommand metadata CSV writers"),
        "build-db": dataWriting("cli.build-db"),
        "markdup": dataWriting("cli.markdup"),
        "primers": dataWriting("cli.primers"),
        "primer": dataWriting("cli.primers"),
        "genotype": dataWriting("cli.genotype", writer: "AIHaplotypingRevisionPublisher/CLIProvenanceSupport"),
        "haplotypes": dataWriting("cli.haplotypes", writer: "HaplotypeDefinitionCommandService"),
        // `tools update --apply` writes no scientific data, but the tool versions it puts in
        // place are exactly what a later result has to be traceable to, so the run records its
        // own envelope. `--plan` inspects only; the policy is per top-level command, and the
        // stricter of the two subcommand behaviours is what it has to describe.
        "tools": metadataOnly(
            "cli.tools",
            requiresProvenance: true,
            writer: "DependencyReconcilerProvenance"
        )
    ]

    /// The rows of a command path whose policy differs from the entry of its command group. A path
    /// with no row here takes the row of its longest registered prefix, else the entry of its group
    /// in ``cliCommandPolicies`` (``cliCommand(path:)``), so a leaf needs a row only when it differs.
    public static let cliCommandPathPolicies: [String: ProvenancePolicyEntry] = [
        "primers analysis inspect": inspectOnly("cli.primers.analysis.inspect"),
        "primers analysis history": dataWriting("cli.primers.analysis.history", writer: "PrimerAnalysisNativeInspectionService"),
        "primers analysis audit": dataWriting("cli.primers.analysis.audit", writer: "PrimerAnalysisNativeInspectionService"),
        "primers design primer3": dataWriting("cli.primers.design.primer3"),
        "primers design primalscheme3": dataWriting("cli.primers.design.primalscheme3"),
        "sequence add-annotation": dataWriting("cli.sequence.add-annotation", writer: "ReferenceBundleManualAnnotationService"),
        "sequence attach-track": dataWriting("cli.sequence.attach-track", writer: "ReferenceBundleAnnotationImportService"),
        "primers analysis annotated-reference": dataWriting("cli.primers.analysis.annotated-reference"),
        "primers analysis export-order": dataWriting("cli.primers.analysis.export-order", writer: "PrimerOrderExportService"),
        // `kraken2 classify` and `conda classify` are one command, `ClassifyCommand`, and both
        // spellings hold this entry (S19). It is read by tests only, so it changes no field a run
        // records.
        "kraken2 classify": dataWriting("cli.kraken2.classify", writer: "ClassifyCommand/ProvenanceRunBuilder"),
        "conda classify": dataWriting("cli.kraken2.classify", writer: "ClassifyCommand/ProvenanceRunBuilder"),
        // The `conda` group holds no entry, because most of its commands maintain the installation.
        // These two write scientific data.
        "conda db download": dataWriting(
            "cli.conda.db.download",
            writer: "CanonicalMetagenomicsDatabaseInstallProvenanceWriter"
        ),
        "conda extract": dataWriting("cli.conda.extract", writer: "TaxonomyExtractionPipeline"),
        "debug fastq-ingest": dataWriting("cli.debug.fastq-ingest", writer: "FASTQIngestSubcommand"),
        "fastq pbaa-cluster": dataWriting("cli.fastq.pbaa-cluster", writer: "PBAAClusteringPipeline"),
        "fastq savont-cluster": dataWriting(
            "cli.fastq.savont-cluster",
            writer: "SavontClusteringPipeline"
        ),
        // The 12S and MHC leaves of `fastq` keep the ids they had as top-level keys.
        "fastq 12s-match": dataWriting("cli.fastq.12s-match", writer: "TwelveSAmpliconMatchingWorkflow"),
        "fastq 12s-reference-metadata": dataWriting(
            "cli.fastq.12s-reference-metadata",
            writer: "TwelveSReferenceMetadataBuilder"
        ),
        "fastq 12s-reference-bundle": dataWriting(
            "cli.fastq.12s-reference-bundle",
            writer: "TwelveSReferenceBundleBuilder"
        ),
        "fastq mhc-reference-bundle": dataWriting(
            "cli.fastq.mhc-reference-bundle",
            writer: "MHCAmpliconReferenceBundleBuilder"
        ),
        "fastq 12s-export": dataWriting("cli.fastq.12s-export", writer: "TwelveSResultExportWorkflow"),
        "fastq 12s-export-unresolved": dataWriting(
            "cli.fastq.12s-export-unresolved",
            writer: "TwelveSUnresolvedFastaExportWorkflow"
        )
    ]

    public static let nativeToolPolicies: [String: ProvenancePolicyEntry] = [
        "samtools": dataWriting("native.samtools", writer: "NativeToolRunner/ProvenanceRunBuilder"),
        "bcftools": dataWriting("native.bcftools", writer: "NativeToolRunner/ProvenanceRunBuilder"),
        "bgzip": dataWriting("native.bgzip", writer: "NativeToolRunner/ProvenanceRunBuilder"),
        "tabix": dataWriting("native.tabix", writer: "NativeToolRunner/ProvenanceRunBuilder"),
        "bedGraphToBigWig": dataWriting("native.bedGraphToBigWig", writer: "NativeToolRunner/ProvenanceRunBuilder"),
        "pigz": dataWriting("native.pigz", writer: "NativeToolRunner/ProvenanceRunBuilder"),
        "seqkit": dataWriting("native.seqkit", writer: "NativeToolRunner/ProvenanceRunBuilder"),
        "fastp": dataWriting("native.fastp", writer: "NativeToolRunner/ProvenanceRunBuilder"),
        "vsearch": dataWriting("native.vsearch", writer: "NativeToolRunner/ProvenanceRunBuilder"),
        "blastn": dataWriting("native.blastn", writer: "NativeToolRunner/ProvenanceRunBuilder"),
        "cutadapt": dataWriting("native.cutadapt", writer: "NativeToolRunner/ProvenanceRunBuilder"),
        "trimGalore": dataWriting("native.trimGalore", writer: "NativeToolRunner/ProvenanceRunBuilder"),
        "ribodetector": dataWriting("native.ribodetector", writer: "NativeToolRunner/ProvenanceRunBuilder"),
        "clumpify": dataWriting("native.clumpify", writer: "NativeToolRunner/ProvenanceRunBuilder"),
        "bbduk": dataWriting("native.bbduk", writer: "NativeToolRunner/ProvenanceRunBuilder"),
        "bbmerge": dataWriting("native.bbmerge", writer: "NativeToolRunner/ProvenanceRunBuilder"),
        "repair": dataWriting("native.repair", writer: "NativeToolRunner/ProvenanceRunBuilder"),
        "tadpole": dataWriting("native.tadpole", writer: "NativeToolRunner/ProvenanceRunBuilder"),
        "reformat": dataWriting("native.reformat", writer: "NativeToolRunner/ProvenanceRunBuilder"),
        "bbmap": dataWriting("native.bbmap", writer: "NativeToolRunner/ProvenanceRunBuilder"),
        "mapPacBio": dataWriting("native.mapPacBio", writer: "NativeToolRunner/ProvenanceRunBuilder"),
        "fasterqDump": dataWriting("native.fasterqDump", writer: "NativeToolRunner/ProvenanceRunBuilder"),
        "prefetch": dataWriting("native.prefetch", writer: "NativeToolRunner/ProvenanceRunBuilder"),
        "deacon": dataWriting("native.deacon", writer: "NativeToolRunner/ProvenanceRunBuilder"),
        "lofreq": dataWriting("native.lofreq", writer: "NativeToolRunner/ProvenanceRunBuilder"),
        "ivar": dataWriting("native.ivar", writer: "NativeToolRunner/ProvenanceRunBuilder"),
        "medaka": dataWriting("native.medaka", writer: "NativeToolRunner/ProvenanceRunBuilder"),
        "medakaVariant": dataWriting("native.medakaVariant", writer: "NativeToolRunner/ProvenanceRunBuilder"),
        "clair3": dataWriting("native.clair3", writer: "NativeToolRunner/ProvenanceRunBuilder"),
        "whatshap": dataWriting("native.whatshap", writer: "NativeToolRunner/ProvenanceRunBuilder"),
        "freyja": dataWriting("native.freyja", writer: "NativeToolRunner/ProvenanceRunBuilder")
    ]

    private static func dataWriting(
        _ id: String,
        writer: String = "CLIProvenanceSupport"
    ) -> ProvenancePolicyEntry {
        ProvenancePolicyEntry(
            id: id,
            createsOrModifiesScientificData: true,
            requiresProvenance: true,
            writer: writer,
            workflowKind: .dataWriting,
            outputPathExpectation: .finalStoredPayload
        )
    }

    private static func metadataOnly(
        _ id: String,
        requiresProvenance: Bool = false,
        writer: String
    ) -> ProvenancePolicyEntry {
        ProvenancePolicyEntry(
            id: id,
            createsOrModifiesScientificData: false,
            requiresProvenance: requiresProvenance,
            writer: writer,
            workflowKind: .metadataOnly,
            outputPathExpectation: .metadataArtifact
        )
    }

    private static func inspectOnly(_ id: String) -> ProvenancePolicyEntry {
        ProvenancePolicyEntry(
            id: id,
            createsOrModifiesScientificData: false,
            requiresProvenance: false,
            writer: "",
            workflowKind: .inspectOnly,
            outputPathExpectation: ProvenanceOutputPathExpectation.none
        )
    }
}
