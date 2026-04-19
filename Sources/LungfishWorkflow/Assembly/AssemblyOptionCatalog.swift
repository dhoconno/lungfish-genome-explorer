// AssemblyOptionCatalog.swift - Curated v1 assembly option metadata
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Placement for a curated assembly control in the shared UI.
public enum AssemblyOptionPlacement: String, Sendable {
    case shared
    case capabilityScoped
    case advanced
}

/// Metadata for a single curated assembly control.
public struct AssemblyOptionDefinition: Sendable, Equatable {
    public let id: String
    public let title: String
    public let summary: String
    public let placement: AssemblyOptionPlacement
    public let toolMappings: [AssemblyTool: String]

    public init(
        id: String,
        title: String,
        summary: String,
        placement: AssemblyOptionPlacement,
        toolMappings: [AssemblyTool: String]
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.placement = placement
        self.toolMappings = toolMappings
    }

    public var tools: [AssemblyTool] {
        AssemblyTool.allCases.filter { toolMappings[$0] != nil }
    }

    public func applies(to tool: AssemblyTool) -> Bool {
        toolMappings[tool] != nil
    }
}

/// Grouped option sections for a single tool.
public struct AssemblyToolOptionSections: Sendable, Equatable {
    public let shared: [AssemblyOptionDefinition]
    public let capabilityScoped: [AssemblyOptionDefinition]
    public let advanced: [AssemblyOptionDefinition]
}

/// Curated control inventory for the v1 assembly experience.
public enum AssemblyOptionCatalog {
    public static let sharedControls: [AssemblyOptionDefinition] = [
        AssemblyOptionDefinition(
            id: "assembler",
            title: "Assembler",
            summary: "Selects which managed assembler runs the job.",
            placement: .shared,
            toolMappings: Dictionary(uniqueKeysWithValues: AssemblyTool.allCases.map { ($0, "Lungfish tool selection") })
        ),
        AssemblyOptionDefinition(
            id: "read-type",
            title: "Read Type",
            summary: "Confirms the single read class for the run and drives compatibility gating.",
            placement: .shared,
            toolMappings: Dictionary(uniqueKeysWithValues: AssemblyTool.allCases.map { ($0, "Lungfish compatibility model") })
        ),
        AssemblyOptionDefinition(
            id: "project-name",
            title: "Project Name",
            summary: "Controls the user-facing run name and output naming convention.",
            placement: .shared,
            toolMappings: [
                .spades: "Lungfish output subdirectory name",
                .megahit: "Lungfish output subdirectory plus optional --out-prefix",
                .skesa: "Lungfish-managed output FASTA filename",
                .flye: "Lungfish output subdirectory name",
                .hifiasm: "-o <prefix>"
            ]
        ),
        AssemblyOptionDefinition(
            id: "threads",
            title: "Threads",
            summary: "Sets the CPU thread count for assembly.",
            placement: .shared,
            toolMappings: [
                .spades: "--threads",
                .megahit: "--num-cpu-threads",
                .skesa: "--cores",
                .flye: "--threads",
                .hifiasm: "-t"
            ]
        ),
        AssemblyOptionDefinition(
            id: "output-location",
            title: "Output Location",
            summary: "Selects the host output directory or prefix location for the managed run.",
            placement: .shared,
            toolMappings: [
                .spades: "-o <output_dir>",
                .megahit: "-o/--out-dir",
                .skesa: "stdout redirected by Lungfish",
                .flye: "--out-dir",
                .hifiasm: "prefix path via -o"
            ]
        ),
    ]

    public static let capabilityScopedControls: [AssemblyOptionDefinition] = [
        AssemblyOptionDefinition(
            id: "memory-limit",
            title: "Memory Limit",
            summary: "Constrains memory for tools that expose an explicit memory budget.",
            placement: .capabilityScoped,
            toolMappings: [
                .spades: "--memory",
                .megahit: "--memory",
                .skesa: "--memory"
            ]
        ),
        AssemblyOptionDefinition(
            id: "minimum-contig-length",
            title: "Minimum Contig Length",
            summary: "Filters very short contigs from the reported result set.",
            placement: .capabilityScoped,
            toolMappings: [
                .spades: "Lungfish post-filter",
                .megahit: "--min-contig-len",
                .skesa: "--min_contig"
            ]
        ),
        AssemblyOptionDefinition(
            id: "profile",
            title: "Assembly Mode / Profile",
            summary: "Selects a curated profile when the assembler exposes meaningful run modes.",
            placement: .capabilityScoped,
            toolMappings: [
                .spades: "--isolate / --meta / --plasmid",
                .megahit: "--presets",
                .flye: "default / --meta"
            ]
        ),
        AssemblyOptionDefinition(
            id: "kmer-strategy",
            title: "K-mer Strategy",
            summary: "Controls curated k-mer selection when the assembler exposes k-mer tuning.",
            placement: .capabilityScoped,
            toolMappings: [
                .spades: "-k",
                .megahit: "--k-list or --k-min/--k-max/--k-step",
                .skesa: "--kmer with iteration settings"
            ]
        ),
        AssemblyOptionDefinition(
            id: "error-correction-or-polishing",
            title: "Error Correction / Polishing",
            summary: "Exposes the limited v1 refinement controls that fit the common UI model.",
            placement: .capabilityScoped,
            toolMappings: [
                .spades: "--only-assembler (inverse of error correction)",
                .flye: "--iterations"
            ]
        ),
    ]

    public static let advancedControlsByTool: [AssemblyTool: [AssemblyOptionDefinition]] = [
        .spades: [
            AssemblyOptionDefinition(
                id: "spades-mode",
                title: "SPAdes Mode",
                summary: "Choose isolate, metagenome, or plasmid assembly mode.",
                placement: .advanced,
                toolMappings: [.spades: "--isolate / --meta / --plasmid"]
            ),
            AssemblyOptionDefinition(
                id: "spades-careful",
                title: "Careful Mode",
                summary: "Reduce short indels and mismatches for suitable short-read runs.",
                placement: .advanced,
                toolMappings: [.spades: "--careful"]
            ),
            AssemblyOptionDefinition(
                id: "spades-coverage-cutoff",
                title: "Coverage Cutoff",
                summary: "Set explicit or automatic coverage filtering where supported.",
                placement: .advanced,
                toolMappings: [.spades: "--cov-cutoff"]
            ),
            AssemblyOptionDefinition(
                id: "spades-phred-offset",
                title: "PHRED Offset",
                summary: "Override PHRED offset when auto-detection is not appropriate.",
                placement: .advanced,
                toolMappings: [.spades: "--phred-offset"]
            ),
        ],
        .megahit: [
            AssemblyOptionDefinition(
                id: "megahit-presets",
                title: "MEGAHIT Preset",
                summary: "Switch between curated presets such as meta-sensitive or meta-large.",
                placement: .advanced,
                toolMappings: [.megahit: "--presets"]
            ),
            AssemblyOptionDefinition(
                id: "megahit-k-list",
                title: "K-mer List",
                summary: "Provide an explicit k-mer list or min/max/step strategy.",
                placement: .advanced,
                toolMappings: [.megahit: "--k-list or --k-min/--k-max/--k-step"]
            ),
            AssemblyOptionDefinition(
                id: "megahit-graph-cleaning",
                title: "Graph Cleaning",
                summary: "Tune pruning and graph simplification for harder short-read cases.",
                placement: .advanced,
                toolMappings: [.megahit: "--cleaning-rounds / --disconnect-ratio / --prune-level / --prune-depth"]
            ),
        ],
        .skesa: [
            AssemblyOptionDefinition(
                id: "skesa-kmer",
                title: "Minimal K-mer Length",
                summary: "Adjust the minimal k-mer length for assembly extension.",
                placement: .advanced,
                toolMappings: [.skesa: "--kmer"]
            ),
            AssemblyOptionDefinition(
                id: "skesa-insert-size",
                title: "Insert Size",
                summary: "Provide an expected paired-read insert size when auto-estimation is undesirable.",
                placement: .advanced,
                toolMappings: [.skesa: "--insert_size"]
            ),
            AssemblyOptionDefinition(
                id: "skesa-extension",
                title: "Extension Heuristics",
                summary: "Tune iteration depth and SNP joining for edge cases.",
                placement: .advanced,
                toolMappings: [.skesa: "--steps / --allow_snps"]
            ),
        ],
        .flye: [
            AssemblyOptionDefinition(
                id: "flye-read-mode",
                title: "ONT Read Mode",
                summary: "Choose ONT raw, HQ, or corrected input mode for the selected reads.",
                placement: .advanced,
                toolMappings: [.flye: "--nano-raw / --nano-hq / --nano-corr"]
            ),
            AssemblyOptionDefinition(
                id: "flye-genome-size",
                title: "Genome Size",
                summary: "Provide estimated genome size for memory-sensitive or large-genome runs.",
                placement: .advanced,
                toolMappings: [.flye: "--genome-size"]
            ),
            AssemblyOptionDefinition(
                id: "flye-overlap-and-coverage",
                title: "Overlap / Assembly Coverage",
                summary: "Tune overlap length and longest-read coverage for difficult long-read assemblies.",
                placement: .advanced,
                toolMappings: [.flye: "--min-overlap / --asm-coverage"]
            ),
            AssemblyOptionDefinition(
                id: "flye-haplotype-controls",
                title: "Haplotype Controls",
                summary: "Expose uneven-coverage and alternate-contig behavior when needed.",
                placement: .advanced,
                toolMappings: [.flye: "--meta / --keep-haplotypes / --no-alt-contigs / --scaffold"]
            ),
        ],
        .hifiasm: [
            AssemblyOptionDefinition(
                id: "hifiasm-small-genome-memory",
                title: "Small-Genome Memory Tuning",
                summary: "Disable the initial bloom filter for small genomes or adjust its memory cost.",
                placement: .advanced,
                toolMappings: [.hifiasm: "-f0 or -f<n>"]
            ),
            AssemblyOptionDefinition(
                id: "hifiasm-purge-duplication",
                title: "Purge Duplication",
                summary: "Control duplication purging aggressiveness for inbred or homozygous genomes.",
                placement: .advanced,
                toolMappings: [.hifiasm: "-l"]
            ),
            AssemblyOptionDefinition(
                id: "hifiasm-primary-output",
                title: "Primary / Alternate Output",
                summary: "Emit primary and alternate assemblies explicitly when desired.",
                placement: .advanced,
                toolMappings: [.hifiasm: "--primary"]
            ),
            AssemblyOptionDefinition(
                id: "hifiasm-haplotype-assumption",
                title: "Haplotype Assumption",
                summary: "Adjust ploidy assumption for non-diploid genomes.",
                placement: .advanced,
                toolMappings: [.hifiasm: "--n-hap"]
            ),
        ],
    ]

    public static func sections(for tool: AssemblyTool) -> AssemblyToolOptionSections {
        AssemblyToolOptionSections(
            shared: sharedControls.filter { $0.applies(to: tool) },
            capabilityScoped: capabilityScopedControls.filter { $0.applies(to: tool) },
            advanced: advancedControlsByTool[tool] ?? []
        )
    }
}
