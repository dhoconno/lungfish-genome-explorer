// SidebarItem.swift - Sidebar hierarchy model types
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO

// MARK: - SidebarItem Model

/// Represents an item in the sidebar hierarchy
public class SidebarItem: NSObject {
    public var title: String
    public let type: SidebarItemType
    public let icon: String?
    /// Custom pre-rendered image for this item. When set, takes precedence over `icon`.
    public var customImage: NSImage?
    public var children: [SidebarItem]
    public var url: URL?
    /// Optional subtitle for additional context (e.g. read composition label).
    public var subtitle: String?
    /// Arbitrary key-value metadata for routing (e.g. sampleId for batch children).
    public var userInfo: [String: String] = [:]

    public init(title: String, type: SidebarItemType, icon: String? = nil, customImage: NSImage? = nil, children: [SidebarItem] = [], url: URL? = nil, subtitle: String? = nil) {
        self.title = title
        self.type = type
        self.icon = icon
        self.customImage = customImage
        self.children = children
        self.url = url
        self.subtitle = subtitle
        super.init()
    }
}

/// Types of sidebar items
///
/// `Sendable` so the off-main sidebar scan (see `SidebarScanNode`) can carry the
/// classification across actor boundaries; it is a plain payload-free enum.
public enum SidebarItemType: Sendable {
    case group
    case folder
    case sequence
    case annotation
    case alignment
    case coverage
    case project
    case document  // PDFs, text files, etc. - uses QuickLook preview
    case image     // Image files - uses QuickLook preview
    case unknown   // Unknown file type - uses QuickLook preview
    case referenceBundle  // .lungfishref reference genome bundle
    case mhcReferenceBundle  // .lungfishmhcref MHC amplicon reference bundle
    case multipleSequenceAlignmentBundle  // .lungfishmsa alignment bundle
    case phylogeneticTreeBundle  // .lungfishtree tree bundle
    case fastqBundle  // .lungfishfastq FASTQ package bundle
    case primerSchemeBundle  // .lungfishprimers primer-scheme bundle
    case genotypeResultBundle // .lungfishgenotype ONT genotyping result bundle
    case twelveSAmpliconResultBundle // .lungfish12s 12S amplicon result bundle
    case batchGroup   // Virtual node representing a batch operation across multiple bundles
    case classificationResult  // Kraken2 classification result folder
    case esvirituResult        // EsViritu viral detection result folder
    case taxTriageResult       // TaxTriage comprehensive triage result folder
    case naoMgsResult          // NAO-MGS surveillance result bundle
    case nvdResult             // NVD (Novel Virus Diagnostics) result bundle
    case czIdResult            // CZ-ID imported taxonomy result bundle
    case analysisResult        // Analysis result in Analyses/ folder

    var tintColor: NSColor {
        switch self {
        case .group: return .secondaryLabelColor
        case .folder: return .systemBlue
        case .sequence: return .systemGreen
        case .annotation: return .systemOrange
        case .alignment: return .systemPurple
        case .coverage: return .systemTeal
        case .project: return .systemGray
        case .document: return .systemBrown
        case .image: return .systemPink
        case .unknown: return .tertiaryLabelColor
        case .referenceBundle: return .systemIndigo
        case .mhcReferenceBundle: return .systemIndigo
        case .multipleSequenceAlignmentBundle: return .systemPurple
        case .phylogeneticTreeBundle: return .systemMint
        case .fastqBundle: return .systemGreen
        case .primerSchemeBundle: return .systemYellow
        case .genotypeResultBundle: return .lungfishOrange
        case .twelveSAmpliconResultBundle: return .systemTeal
        case .batchGroup: return .systemCyan
        case .classificationResult: return .lungfishOrange
        case .esvirituResult: return .lungfishOrange
        case .taxTriageResult: return .lungfishOrange
        case .naoMgsResult: return .lungfishOrange
        case .nvdResult: return .lungfishOrange
        case .czIdResult: return .lungfishOrange
        case .analysisResult: return .lungfishOrange
        }
    }

    /// Whether this item type should use QuickLook for preview
    var usesQuickLook: Bool {
        switch self {
        case .document, .image, .unknown:
            return true
        default:
            return false
        }
    }

    /// Whether this item type is a bundle that should appear as a single item
    var isBundle: Bool {
        switch self {
        case .referenceBundle, .mhcReferenceBundle, .multipleSequenceAlignmentBundle, .phylogeneticTreeBundle,
             .fastqBundle, .primerSchemeBundle, .genotypeResultBundle, .twelveSAmpliconResultBundle, .czIdResult:
            return true
        default:
            return false
        }
    }

    /// The sidebar context-menu actions this bundle kind genuinely supports.
    ///
    /// Introduced for task E2 (2026-08-08 repo review fix campaign): the
    /// context menu previously gated bundle-specific items behind
    /// `item.type == .referenceBundle` (or a second hardcoded check for
    /// `.fastqBundle`), so right-clicking any other bundle kind
    /// (`.mhcReferenceBundle`, `.multipleSequenceAlignmentBundle`,
    /// `.phylogeneticTreeBundle`, `.primerSchemeBundle`,
    /// `.genotypeResultBundle`, `.twelveSAmpliconResultBundle`,
    /// `.czIdResult`) showed none of the generic bundle actions even though
    /// `isBundle` already classified them as bundles with their own icon,
    /// viewer, and document section.
    ///
    /// This mapping is the single source of truth for "which bundle actions
    /// apply to which kind" so future bundle kinds don't repeat the bug by
    /// omission — the menu-building code consults `bundleCapabilities`
    /// instead of enumerating kinds inline.
    var bundleCapabilities: SidebarBundleCapabilities {
        guard isBundle else { return .none }

        switch self {
        case .referenceBundle:
            // .referenceBundle: full action set including sequence export
            // and (via BundleMergeSelection — owned by task GB1) merge.
            return SidebarBundleCapabilities(
                canOpen: true,
                canShowPackageContents: true,
                canGetBundleInfo: true,
                canShowInInspector: true,
                canExportSequences: true
            )
        case .mhcReferenceBundle, .fastqBundle, .multipleSequenceAlignmentBundle, .phylogeneticTreeBundle,
             .primerSchemeBundle, .genotypeResultBundle, .twelveSAmpliconResultBundle, .czIdResult:
            // .mhcReferenceBundle gets the baseline actions here, NOT
            // canExportSequences: exportSequences()'s sequence-loading path
            // (AppDelegate+ImportCenter.loadSequencesForExport) only knows
            // how to read a .lungfishref bundle's manifest.genome.path; an
            // MHC bundle's reference.fa lives under a different manifest
            // shape (MHCAmpliconReferenceBundleManifest.referenceFastaPath)
            // that path doesn't understand. Advertising Export Sequences
            // for MHC bundles without first teaching the export pipeline to
            // read that manifest would just relocate the AS3 bug instead of
            // fixing it. Left as a follow-up; see task E2 report.
            // Every other bundle kind: the baseline actions that are
            // kind-agnostic in their handlers (Open Bundle routes through
            // the same selection-change path used for double-click; Show
            // Package Contents just reveals the bundle directory in Finder;
            // Get Bundle Info reads the bundle's manifest.json generically;
            // Show in Inspector just posts a notification). FASTQ bundles
            // keep their own additional "Export as FASTQ" item, built
            // separately in the menu-delegate's FASTQ-specific section.
            return SidebarBundleCapabilities(
                canOpen: true,
                canShowPackageContents: true,
                canGetBundleInfo: true,
                canShowInInspector: true,
                canExportSequences: false
            )
        default:
            return .none
        }
    }

    /// Creates a sidebar item type from a LungfishIO UICategory.
    ///
    /// - Parameter category: The UICategory from format detection
    init(from category: UICategory) {
        switch category {
        case .sequence:
            self = .sequence
        case .annotation:
            self = .annotation
        case .alignment:
            self = .alignment
        case .variant:
            self = .annotation  // Variants shown as annotations
        case .coverage:
            self = .coverage
        case .index:
            self = .unknown  // Index files shown as unknown
        case .document:
            self = .document
        case .image:
            self = .image
        case .compressed:
            self = .unknown
        case .referenceBundle:
            self = .referenceBundle
        case .unknown:
            self = .unknown
        }
    }
}

/// The set of generic, kind-agnostic bundle actions the sidebar context
/// menu can offer for a given `SidebarItemType`. See
/// `SidebarItemType.bundleCapabilities`.
struct SidebarBundleCapabilities: Equatable {
    var canOpen: Bool
    var canShowPackageContents: Bool
    var canGetBundleInfo: Bool
    var canShowInInspector: Bool
    var canExportSequences: Bool

    static let none = SidebarBundleCapabilities(
        canOpen: false,
        canShowPackageContents: false,
        canGetBundleInfo: false,
        canShowInInspector: false,
        canExportSequences: false
    )
}

#if DEBUG
extension SidebarItemType {
    /// Every bundle kind, for exhaustive capability-mapping tests. Kept in
    /// sync manually with `isBundle`'s switch cases (a compiler-enforced
    /// exhaustive mapping isn't practical here since `isBundle` itself is a
    /// non-exhaustive `switch`/`default` over the full enum).
    static var allBundleKindsForTesting: [SidebarItemType] {
        [
            .referenceBundle, .mhcReferenceBundle, .multipleSequenceAlignmentBundle,
            .phylogeneticTreeBundle, .fastqBundle, .primerSchemeBundle,
            .genotypeResultBundle, .twelveSAmpliconResultBundle, .czIdResult,
        ]
    }
}
#endif
