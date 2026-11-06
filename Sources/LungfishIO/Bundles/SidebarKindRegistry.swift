// SidebarKindRegistry.swift - The one table of the kinds the sidebar lists
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os

/// The sidebar row a kind lists as. The App maps each case onto one `SidebarItemType` case.
public enum SidebarRowType: String, Sendable, Hashable, CaseIterable {
    case referenceBundle, mhcReferenceBundle, multipleSequenceAlignmentBundle, phylogeneticTreeBundle, fastqBundle
    case primerAnalysisBundle, primerSchemeBundle, genotypeResultBundle, twelveSAmpliconResultBundle, czIdResult
    case classificationResult, esvirituResult, taxTriageResult, naoMgsResult, nvdResult, analysisResult
    /// A kind that joined by registration alone. It opens in the viewport its descriptor names.
    case registeredBundle
}

/// The viewport a kind opens, as plain data. Kit's `SurfaceKind` has the same three shapes.
public enum SidebarViewportKind: Sendable, Hashable {
    case bundle(BundleKindID)
    case analysis(AnalysisToolID)
    case view(String)
}

/// The Inspector tab a row asks for when an import or a run selects it.
public enum SidebarInspectorTab: String, Sendable, Hashable {
    /// The Document tab.
    case document
    /// The tab the result's own viewer sets through its content mode, so the selection leaves the tab alone.
    case setByViewer
}

/// Everything the sidebar knows about one kind it lists, as plain data.
public struct SidebarKindDescriptor: Sendable, Hashable {
    /// How the sidebar recognises a folder of the kind. The kind's own record comes first.
    public enum Recognition: Sendable, Hashable {
        /// A saved bundle, by its folder extension in any case. With `manifestRequired` the folder lists as this
        /// kind only when the kind's manifest is in it, as a CZ-ID `.lungfishtax` folder needs.
        case bundle(BundleKindDescriptor, manifestRequired: Bool)
        /// An analysis result, by the tool its `analysis-metadata.json` names.
        case analysis(AnalysisToolID)
    }

    /// The one read-only fallback, for a result folder older than `analysis-metadata.json`. It is recognised by the
    /// name prefix it was given and one marker file or folder inside it. Nothing here writes into the folder.
    public struct LegacyFolder: Sendable, Hashable {
        public let namePrefixes: [String]
        /// Any one of these, inside the folder, confirms the kind.
        public let markerNames: [String]

        public init(namePrefixes: [String], markerNames: [String]) {
            self.namePrefixes = namePrefixes
            self.markerNames = markerNames
        }

        public func matchesName(_ name: String) -> Bool {
            namePrefixes.contains { name.hasPrefix($0) }
        }
    }

    /// `bundle:<id>` or `analysis:<id>` for a built-in kind, as Kit's `SurfaceKind` spells it.
    public let id: String
    public let recognition: Recognition
    public let rowType: SidebarRowType
    public let sidebarSymbolName: String
    /// The kind in words, such as "Phylogenetic tree".
    public let displayName: String
    /// The viewport the row opens, or nil when it opens none of its own (a primer scheme shows in the Inspector).
    public let viewport: SidebarViewportKind?
    public let inspectorTab: SidebarInspectorTab
    /// True when a project deletion plan treats a legacy folder of this kind that holds a `manifest.json` as one
    /// analysis object. Only NAO-MGS and NVD need it, since every other result kind has a named result file that the
    /// deletion planner looks for.
    public let deletionTreatsLegacyFolderAsAnalysis: Bool
    public let legacyFolder: LegacyFolder?

    public init(
        id: String,
        recognition: Recognition,
        rowType: SidebarRowType,
        sidebarSymbolName: String,
        displayName: String,
        viewport: SidebarViewportKind?,
        inspectorTab: SidebarInspectorTab = .document,
        deletionTreatsLegacyFolderAsAnalysis: Bool = false,
        legacyFolder: LegacyFolder? = nil
    ) {
        self.id = id
        self.recognition = recognition
        self.rowType = rowType
        self.sidebarSymbolName = sidebarSymbolName
        self.displayName = displayName
        self.viewport = viewport
        self.inspectorTab = inspectorTab
        self.deletionTreatsLegacyFolderAsAnalysis = deletionTreatsLegacyFolderAsAnalysis
        self.legacyFolder = legacyFolder
    }
}

/// The kinds the sidebar lists, over ``BundleKindRegistry`` and ``AnalysisToolRegistry``.
///
/// The sidebar scan, the content display route, the Inspector tab an import selects and the project deletion plan
/// read this one table. A new kind joins with ``register(_:)`` and a surface factory in the viewer's surface
/// registry, and needs no other App edit.
public enum SidebarKindRegistry {
    private static func bundle(_ id: BundleKindID) -> BundleKindDescriptor {
        guard let descriptor = BundleKindRegistry.descriptor(for: id) else {
            preconditionFailure("SidebarKindRegistry names a bundle kind that BundleKindRegistry lacks: \(id)")
        }
        return descriptor
    }

    private static func bundleKind(
        _ id: BundleKindID, _ row: SidebarRowType, _ name: String, opens viewport: SidebarViewportKind?,
        manifestRequired: Bool = false
    ) -> SidebarKindDescriptor {
        let descriptor = bundle(id)
        return SidebarKindDescriptor(
            id: "bundle:\(id.rawValue)", recognition: .bundle(descriptor, manifestRequired: manifestRequired), rowType: row,
            sidebarSymbolName: descriptor.sidebarSymbolName, displayName: name, viewport: viewport)
    }

    /// The saved bundle kinds with a row of their own. A Lungfish folder of any other kind lists as a document.
    public static let bundleKinds: [SidebarKindDescriptor] = [
        bundleKind(.fastq, .fastqBundle, "FASTQ reads", opens: .bundle(.fastq)),
        bundleKind(.reference, .referenceBundle, "Reference genome", opens: .bundle(.reference)),
        bundleKind(.mhcReference, .mhcReferenceBundle, "MHC reference", opens: .bundle(.mhcReference)),
        bundleKind(.multipleSequenceAlignment, .multipleSequenceAlignmentBundle, "Multiple sequence alignment",
                   opens: .bundle(.multipleSequenceAlignment)),
        bundleKind(.phylogeneticTree, .phylogeneticTreeBundle, "Phylogenetic tree", opens: .bundle(.phylogeneticTree)),
        bundleKind(.primerAnalysis, .primerAnalysisBundle, "Primer analysis", opens: .bundle(.primerAnalysis)),
        bundleKind(.primerScheme, .primerSchemeBundle, "Primer scheme", opens: nil),
        bundleKind(.genotypeResult, .genotypeResultBundle, "Genotype result", opens: .bundle(.genotypeResult)),
        bundleKind(.twelveSResult, .twelveSAmpliconResultBundle, "12S amplicon result", opens: .bundle(.twelveSResult)),
        bundleKind(.czIdResult, .czIdResult, "CZ-ID result", opens: .analysis(.czId), manifestRequired: true),
    ]

    /// What differs from an analysis kind's defaults: an `.analysisResult` row, no viewport, the Document tab.
    private struct AnalysisFacts {
        var row: SidebarRowType = .analysisResult
        var viewport: SidebarViewportKind?
        var tab: SidebarInspectorTab = .document
        var deletion = false
        var legacy: SidebarKindDescriptor.LegacyFolder?
    }

    private static func legacy(_ prefixes: [String], _ markers: [String]) -> SidebarKindDescriptor.LegacyFolder {
        .init(namePrefixes: prefixes, markerNames: markers)
    }

    /// Kraken2 imports keep the `classification-` name the first releases gave them. A `kraken2-` run folder carries
    /// its metadata sidecar, so the fallback needs no `kraken2-` prefix, and the scanner never hid one by name.
    private static let analysisFacts: [AnalysisToolID: AnalysisFacts] = [
        .esviritu: .init(row: .esvirituResult, viewport: .analysis(.esviritu), tab: .setByViewer,
                         legacy: legacy(["esviritu-"], ["esviritu-result.json"])),
        .kraken2: .init(row: .classificationResult, viewport: .analysis(.kraken2), tab: .setByViewer,
                        legacy: legacy(["classification-"], ["classification-result.json"])),
        .taxtriage: .init(row: .taxTriageResult, viewport: .analysis(.taxtriage), tab: .setByViewer,
                          legacy: legacy(["taxtriage-"], ["taxtriage-result.json", "kraken2"])),
        .naomgs: .init(row: .naoMgsResult, viewport: .analysis(.naomgs), tab: .setByViewer, deletion: true,
                       legacy: legacy(["naomgs-"], ["manifest.json"])),
        .nvd: .init(row: .nvdResult, viewport: .analysis(.nvd), tab: .setByViewer, deletion: true,
                    legacy: legacy(["nvd-"], ["manifest.json"])),
        .czId: .init(row: .czIdResult, viewport: .analysis(.czId), legacy: legacy(["cz-id-"], ["cz-id-manifest.json"])),
        .mafft: .init(row: .multipleSequenceAlignmentBundle, viewport: .bundle(.multipleSequenceAlignment)),
        .ontGenotyping: .init(row: .genotypeResultBundle, viewport: .bundle(.genotypeResult)),
        .spades: .init(viewport: .analysis(.spades)), .megahit: .init(viewport: .analysis(.megahit)),
        .skesa: .init(viewport: .analysis(.skesa)), .flye: .init(viewport: .analysis(.flye)),
        .hifiasm: .init(viewport: .analysis(.hifiasm)),
        .minimap2: .init(viewport: .bundle(.reference)), .bwaMem2: .init(viewport: .bundle(.reference)),
        .bowtie2: .init(viewport: .bundle(.reference)), .bbmap: .init(viewport: .bundle(.reference)),
        .viralrecon: .init(viewport: .bundle(.reference)),
        .primerOrder: .init(viewport: .analysis(.primerOrder)),
    ]

    /// Every analysis kind, in ``AnalysisToolRegistry`` order. A kind with no facts above lists as an analysis row.
    public static let analysisKinds: [SidebarKindDescriptor] = AnalysisToolRegistry.all.map { tool in
        let facts = analysisFacts[tool.id] ?? AnalysisFacts()
        return SidebarKindDescriptor(
            id: "analysis:\(tool.id.rawValue)", recognition: .analysis(tool.id), rowType: facts.row,
            sidebarSymbolName: tool.sidebarSymbolName ?? "circle", displayName: tool.displayName,
            viewport: facts.viewport, inspectorTab: facts.tab,
            deletionTreatsLegacyFolderAsAnalysis: facts.deletion, legacyFolder: facts.legacy)
    }

    private static let registrations = OSAllocatedUnfairLock<[SidebarKindDescriptor]>(initialState: [])

    // MARK: - Registration

    /// Adds `descriptor`, in place of a registered kind with its id. A built-in kind cannot be replaced.
    public static func register(_ descriptor: SidebarKindDescriptor) {
        registrations.withLock { kinds in
            kinds.removeAll { $0.id == descriptor.id }
            kinds.append(descriptor)
        }
    }

    /// Removes the registered kind `id`, as a test does when it ends.
    public static func unregister(id: String) {
        registrations.withLock { kinds in kinds.removeAll { $0.id == id } }
    }

    /// The built-in kinds, then the registered ones.
    public static var all: [SidebarKindDescriptor] {
        bundleKinds + analysisKinds + registrations.withLock { $0 }
    }

    public static func descriptor(id: String) -> SidebarKindDescriptor? {
        all.first { $0.id == id }
    }

    // MARK: - Lookup

    /// The bundle kind of a folder by its extension, ignoring case. It reads the file system only to ask whether a
    /// manifest the kind requires is in the folder, and a folder without it is no kind here.
    public static func bundleKind(ofFolder url: URL, fileManager: FileManager = .default) -> SidebarKindDescriptor? {
        let ext = url.pathExtension.lowercased()
        let kinds = bundleKinds + registrations.withLock { $0 }
        for kind in kinds {
            guard case .bundle(let bundle, let manifestRequired) = kind.recognition,
                  bundle.folderExtensions.contains(ext) else { continue }
            if manifestRequired, let manifest = bundle.manifestFileName,
               !fileManager.fileExists(atPath: url.appendingPathComponent(manifest).path) {
                return nil
            }
            return kind
        }
        return nil
    }

    /// The analysis kind the tool id `raw` names.
    public static func analysisKind(forTool raw: String) -> SidebarKindDescriptor? {
        all.first { kind in
            if case .analysis(let id) = kind.recognition { return id.rawValue == raw }
            return false
        }
    }

    /// The analysis kind of a result folder. Its `analysis-metadata.json` decides, and only a folder without one
    /// goes to the read-only fallback, ``legacyAnalysisKind(ofFolder:fileManager:)``.
    public static func analysisKind(ofFolder url: URL, fileManager: FileManager = .default) -> SidebarKindDescriptor? {
        if let tool = AnalysesFolder.readAnalysisMetadata(from: url)?.tool {
            return analysisKind(forTool: tool)
        }
        return legacyAnalysisKind(ofFolder: url, fileManager: fileManager)
    }

    /// The read-only fallback. The kind whose legacy name prefix `url` carries and whose marker is inside it. A
    /// folder with a Lungfish bundle extension is a bundle and never a legacy result folder. It asks only whether
    /// files exist and writes nothing.
    public static func legacyAnalysisKind(ofFolder url: URL, fileManager: FileManager = .default) -> SidebarKindDescriptor? {
        guard BundleKindRegistry.descriptor(forLowercasedExtensionOf: url) == nil else { return nil }
        return legacyAnalysisKinds(forFolderNamed: url.lastPathComponent).first { kind in
            kind.legacyFolder?.markerNames.contains {
                fileManager.fileExists(atPath: url.appendingPathComponent($0).path)
            } ?? false
        }
    }

    /// The kinds whose legacy name prefix `name` carries, by name alone.
    public static func legacyAnalysisKinds(forFolderNamed name: String) -> [SidebarKindDescriptor] {
        all.filter { $0.legacyFolder?.matchesName(name) ?? false }
    }
}
