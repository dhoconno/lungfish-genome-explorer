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
        "primers"
    ]

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
        "primer": dataWriting("cli.primers")
    ]

    public static let nativeToolPolicies: [String: ProvenancePolicyEntry] = [
        "samtools": dataWriting("native.samtools", writer: "NativeToolRunner/ProvenanceRunBuilder"),
        "bcftools": dataWriting("native.bcftools", writer: "NativeToolRunner/ProvenanceRunBuilder"),
        "bgzip": dataWriting("native.bgzip", writer: "NativeToolRunner/ProvenanceRunBuilder"),
        "tabix": dataWriting("native.tabix", writer: "NativeToolRunner/ProvenanceRunBuilder"),
        "bedToBigBed": dataWriting("native.bedToBigBed", writer: "NativeToolRunner/ProvenanceRunBuilder"),
        "bedGraphToBigWig": dataWriting("native.bedGraphToBigWig", writer: "NativeToolRunner/ProvenanceRunBuilder"),
        "pigz": dataWriting("native.pigz", writer: "NativeToolRunner/ProvenanceRunBuilder"),
        "seqkit": dataWriting("native.seqkit", writer: "NativeToolRunner/ProvenanceRunBuilder"),
        "fastp": dataWriting("native.fastp", writer: "NativeToolRunner/ProvenanceRunBuilder"),
        "vsearch": dataWriting("native.vsearch", writer: "NativeToolRunner/ProvenanceRunBuilder"),
        "cutadapt": dataWriting("native.cutadapt", writer: "NativeToolRunner/ProvenanceRunBuilder"),
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
