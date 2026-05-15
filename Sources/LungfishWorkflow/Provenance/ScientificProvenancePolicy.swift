// ScientificProvenancePolicy.swift - Coverage gates for scientific provenance
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

public struct ProvenancePolicyEntry: Sendable, Equatable {
    public let id: String
    public let createsOrModifiesScientificData: Bool
    public let requiresProvenance: Bool
    public let writer: String

    public init(
        id: String,
        createsOrModifiesScientificData: Bool,
        requiresProvenance: Bool,
        writer: String
    ) {
        self.id = id
        self.createsOrModifiesScientificData = createsOrModifiesScientificData
        self.requiresProvenance = requiresProvenance
        self.writer = writer
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
        "convert": required("cli.convert"),
        "analyze": required("cli.analyze"),
        "translate": required("cli.translate"),
        "sequence": required("cli.sequence"),
        "search": required("cli.search"),
        "universal-search": required("cli.universal-search"),
        "extract": required("cli.extract"),
        "fastq": required("cli.fastq"),
        "workflow": required("cli.workflow"),
        "run-headless": required("cli.run-headless"),
        "fetch": required("cli.fetch"),
        "bundle": required("cli.bundle"),
        "project": required("cli.project"),
        "blast": required("cli.blast"),
        "esviritu": required("cli.esviritu"),
        "taxtriage": required("cli.taxtriage"),
        "align": required("cli.align"),
        "msa": required("cli.msa"),
        "tree": required("cli.tree"),
        "assemble": required("cli.assemble"),
        "orient": required("cli.orient"),
        "map": required("cli.map"),
        "import": required("cli.import"),
        "import-fastq": required("cli.import-fastq"),
        "ops": required("cli.ops"),
        "provenance": required("cli.provenance", writer: "ProvenanceExporter"),
        "bam": required("cli.bam"),
        "variants": required("cli.variants"),
        "gatk": required("cli.gatk"),
        "nao-mgs": required("cli.nao-mgs"),
        "freyja": required("cli.freyja"),
        "nvd": required("cli.nvd"),
        "cz-id": required("cli.cz-id"),
        "czid": required("cli.cz-id"),
        "metadata": required("cli.metadata"),
        "build-db": required("cli.build-db"),
        "markdup": required("cli.markdup"),
        "primers": required("cli.primers"),
        "primer": required("cli.primers")
    ]

    public static let nativeToolPolicies: [String: ProvenancePolicyEntry] = [
        "samtools": required("native.samtools", writer: "NativeToolRunner/ProvenanceRunBuilder"),
        "bcftools": required("native.bcftools", writer: "NativeToolRunner/ProvenanceRunBuilder"),
        "bgzip": required("native.bgzip", writer: "NativeToolRunner/ProvenanceRunBuilder"),
        "tabix": required("native.tabix", writer: "NativeToolRunner/ProvenanceRunBuilder"),
        "bedToBigBed": required("native.bedToBigBed", writer: "NativeToolRunner/ProvenanceRunBuilder"),
        "bedGraphToBigWig": required("native.bedGraphToBigWig", writer: "NativeToolRunner/ProvenanceRunBuilder"),
        "pigz": required("native.pigz", writer: "NativeToolRunner/ProvenanceRunBuilder"),
        "seqkit": required("native.seqkit", writer: "NativeToolRunner/ProvenanceRunBuilder"),
        "fastp": required("native.fastp", writer: "NativeToolRunner/ProvenanceRunBuilder"),
        "vsearch": required("native.vsearch", writer: "NativeToolRunner/ProvenanceRunBuilder"),
        "cutadapt": required("native.cutadapt", writer: "NativeToolRunner/ProvenanceRunBuilder"),
        "ribodetector": required("native.ribodetector", writer: "NativeToolRunner/ProvenanceRunBuilder"),
        "clumpify": required("native.clumpify", writer: "NativeToolRunner/ProvenanceRunBuilder"),
        "bbduk": required("native.bbduk", writer: "NativeToolRunner/ProvenanceRunBuilder"),
        "bbmerge": required("native.bbmerge", writer: "NativeToolRunner/ProvenanceRunBuilder"),
        "repair": required("native.repair", writer: "NativeToolRunner/ProvenanceRunBuilder"),
        "tadpole": required("native.tadpole", writer: "NativeToolRunner/ProvenanceRunBuilder"),
        "reformat": required("native.reformat", writer: "NativeToolRunner/ProvenanceRunBuilder"),
        "bbmap": required("native.bbmap", writer: "NativeToolRunner/ProvenanceRunBuilder"),
        "mapPacBio": required("native.mapPacBio", writer: "NativeToolRunner/ProvenanceRunBuilder"),
        "fasterqDump": required("native.fasterqDump", writer: "NativeToolRunner/ProvenanceRunBuilder"),
        "prefetch": required("native.prefetch", writer: "NativeToolRunner/ProvenanceRunBuilder"),
        "deacon": required("native.deacon", writer: "NativeToolRunner/ProvenanceRunBuilder"),
        "lofreq": required("native.lofreq", writer: "NativeToolRunner/ProvenanceRunBuilder"),
        "ivar": required("native.ivar", writer: "NativeToolRunner/ProvenanceRunBuilder"),
        "medaka": required("native.medaka", writer: "NativeToolRunner/ProvenanceRunBuilder"),
        "clair3": required("native.clair3", writer: "NativeToolRunner/ProvenanceRunBuilder"),
        "whatshap": required("native.whatshap", writer: "NativeToolRunner/ProvenanceRunBuilder"),
        "freyja": required("native.freyja", writer: "NativeToolRunner/ProvenanceRunBuilder")
    ]

    private static func required(
        _ id: String,
        writer: String = "CLIProvenanceSupport"
    ) -> ProvenancePolicyEntry {
        ProvenancePolicyEntry(
            id: id,
            createsOrModifiesScientificData: true,
            requiresProvenance: true,
            writer: writer
        )
    }
}
