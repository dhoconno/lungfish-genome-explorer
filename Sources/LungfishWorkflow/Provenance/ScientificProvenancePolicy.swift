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
        required("native.\(tool.rawValue)", writer: "ProvenanceRunBuilder")
    }

    public static func cliCommand(_ commandName: String) -> ProvenancePolicyEntry? {
        let key = commandName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return cliCommandPolicies[key]
    }

    public static let cliCommandPolicies: [String: ProvenancePolicyEntry] = [
        "convert": required("cli.convert"),
        "analyze": required("cli.analyze"),
        "translate": required("cli.translate"),
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
