// AnalysisToolRegistry.swift - The table of known analysis kinds
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension AnalysisToolID {
    public static let esviritu = AnalysisToolID(rawValue: "esviritu")
    public static let kraken2 = AnalysisToolID(rawValue: "kraken2")
    public static let taxtriage = AnalysisToolID(rawValue: "taxtriage")
    public static let minimap2 = AnalysisToolID(rawValue: "minimap2")
    public static let bwaMem2 = AnalysisToolID(rawValue: "bwa-mem2")
    public static let bowtie2 = AnalysisToolID(rawValue: "bowtie2")
    public static let bbmap = AnalysisToolID(rawValue: "bbmap")
    public static let spades = AnalysisToolID(rawValue: "spades")
    public static let megahit = AnalysisToolID(rawValue: "megahit")
    public static let skesa = AnalysisToolID(rawValue: "skesa")
    public static let flye = AnalysisToolID(rawValue: "flye")
    public static let hifiasm = AnalysisToolID(rawValue: "hifiasm")
    public static let naomgs = AnalysisToolID(rawValue: "naomgs")
    public static let nvd = AnalysisToolID(rawValue: "nvd")
    public static let czId = AnalysisToolID(rawValue: "cz-id")
    public static let mafft = AnalysisToolID(rawValue: "mafft")
    public static let ontGenotyping = AnalysisToolID(rawValue: "ont-genotyping")
    public static let viralrecon = AnalysisToolID(rawValue: "viralrecon")
    public static let primerOrder = AnalysisToolID(rawValue: "primer-order")
    public static let pbaa = AnalysisToolID(rawValue: "pbaa")
    public static let savont = AnalysisToolID(rawValue: "savont")
}

/// The directory name prefixes of one analysis kind, precomputed in registry order.
struct AnalysisDirectoryPrefix: Sendable, Hashable {
    let id: AnalysisToolID
    /// `"<id>-"`.
    let single: String
    /// `"<id>-batch-"`.
    let batch: String
}

/// The known analysis kinds. The order is fixed and is the order name parsing tries them in.
/// It is the order of the former `AnalysesFolder.knownTools` literal.
public enum AnalysisToolRegistry {
    public static let all: [AnalysisToolDescriptor] = [
        AnalysisToolDescriptor(
            id: .esviritu, displayName: "EsViritu", sidebarSymbolName: "e.circle",
            classifierBatchBadge: "ES", provisioning: .managedTool(ManagedToolID(rawValue: "esviritu"))),
        AnalysisToolDescriptor(
            id: .kraken2, displayName: "Kraken2", sidebarSymbolName: "k.circle",
            classifierBatchBadge: "K2", provisioning: .managedTool(ManagedToolID(rawValue: "kraken2"))),
        AnalysisToolDescriptor(
            id: .taxtriage, displayName: "TaxTriage", sidebarSymbolName: "t.circle",
            classifierBatchBadge: "TT", provisioning: .lockedPipeline("taxtriage")),
        AnalysisToolDescriptor(
            id: .minimap2, displayName: "Minimap2", sidebarSymbolName: "m.circle",
            provisioning: .managedTool(ManagedToolID(rawValue: "minimap2"))),
        AnalysisToolDescriptor(
            id: .bwaMem2, displayName: "BWA-MEM2", sidebarSymbolName: "m.circle",
            provisioning: .managedTool(ManagedToolID(rawValue: "bwa-mem2"))),
        AnalysisToolDescriptor(
            id: .bowtie2, displayName: "Bowtie2", sidebarSymbolName: "m.circle",
            provisioning: .managedTool(ManagedToolID(rawValue: "bowtie2"))),
        AnalysisToolDescriptor(
            id: .bbmap, displayName: "BBMap", sidebarSymbolName: "m.circle",
            provisioning: .managedTool(ManagedToolID(rawValue: "bbtools"))),
        AnalysisToolDescriptor(
            id: .spades, displayName: "SPAdes", sidebarSymbolName: "s.circle",
            provisioning: .managedTool(ManagedToolID(rawValue: "spades"))),
        AnalysisToolDescriptor(
            id: .megahit, displayName: "MEGAHIT", sidebarSymbolName: "s.circle",
            provisioning: .managedTool(ManagedToolID(rawValue: "megahit"))),
        AnalysisToolDescriptor(
            id: .skesa, displayName: "SKESA", sidebarSymbolName: "s.circle",
            provisioning: .managedTool(ManagedToolID(rawValue: "skesa"))),
        AnalysisToolDescriptor(
            id: .flye, displayName: "Flye", sidebarSymbolName: "s.circle",
            provisioning: .managedTool(ManagedToolID(rawValue: "flye"))),
        AnalysisToolDescriptor(
            id: .hifiasm, displayName: "Hifiasm", sidebarSymbolName: "s.circle",
            provisioning: .managedTool(ManagedToolID(rawValue: "hifiasm"))),
        AnalysisToolDescriptor(
            id: .naomgs, displayName: "NAO-MGS", acceptsImportedSampleNames: true,
            sidebarSymbolName: "n.circle", classifierBatchBadge: "NM", provisioning: .importedResult),
        AnalysisToolDescriptor(
            id: .nvd, displayName: "NVD", acceptsImportedSampleNames: true,
            sidebarSymbolName: nil, classifierBatchBadge: "NVD", provisioning: .importedResult),
        AnalysisToolDescriptor(
            id: .czId, displayName: "CZ-ID", acceptsImportedSampleNames: true,
            sidebarSymbolName: "c.circle", classifierBatchBadge: "CZ", provisioning: .importedResult),
        AnalysisToolDescriptor(
            id: .mafft, displayName: "MAFFT", sidebarSymbolName: "rectangle.grid.1x2",
            provisioning: .managedTool(ManagedToolID(rawValue: "mafft"))),
        AnalysisToolDescriptor(
            id: .ontGenotyping, displayName: "ONT Genotyping",
            sidebarSymbolName: "tablecells.badge.ellipsis", provisioning: .builtIn),
        AnalysisToolDescriptor(
            id: .viralrecon, displayName: "Viral Recon", sidebarSymbolName: "v.circle",
            provisioning: .lockedPipeline("nf-core-viralrecon")),
        AnalysisToolDescriptor(
            id: .primerOrder, displayName: "Primer Order", sidebarSymbolName: nil,
            provisioning: .builtIn),
        AnalysisToolDescriptor(
            id: .pbaa, displayName: "pbAA", sidebarSymbolName: nil, provisioning: .container),
        AnalysisToolDescriptor(
            id: .savont, displayName: "Savont", sidebarSymbolName: nil,
            provisioning: .managedTool(ManagedToolID(rawValue: "savont"))),
    ]

    private static let byRawID: [String: AnalysisToolDescriptor] =
        Dictionary(all.map { ($0.id.rawValue, $0) }, uniquingKeysWith: { first, _ in first })

    /// The ids of kinds whose imported results use `{id}-{sampleName}` naming.
    static let importedResultIDs: Set<String> =
        Set(all.filter(\.acceptsImportedSampleNames).map { $0.id.rawValue })

    /// The directory prefixes of every kind in registry order.
    static let directoryPrefixes: [AnalysisDirectoryPrefix] = all.map {
        AnalysisDirectoryPrefix(
            id: $0.id,
            single: "\($0.id.rawValue)-",
            batch: "\($0.id.rawValue)-batch-")
    }

    public static func descriptor(for id: AnalysisToolID) -> AnalysisToolDescriptor? {
        byRawID[id.rawValue]
    }

    public static func descriptor(forRawID raw: String) -> AnalysisToolDescriptor? {
        byRawID[raw]
    }

    /// The display name of a known id, or the capitalized raw id for an unknown one.
    public static func displayName(forRawID raw: String) -> String {
        byRawID[raw]?.displayName ?? raw.capitalized
    }
}
