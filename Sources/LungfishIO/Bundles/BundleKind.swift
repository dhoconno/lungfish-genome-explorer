// BundleKind.swift - Typed identifier and plain-data descriptor of a Lungfish bundle kind
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The identifier of a bundle kind, the type of folder a Lungfish project holds. A
/// reference bundle, a FASTQ bundle and a multiple sequence alignment are three kinds.
///
/// The raw value is a stable kebab-case token such as `reference` or `phylogenetic-tree`.
/// Unknown ids are valid, because an id can come from a newer build, a newer CLI or an
/// imported record, and an older reader must decode it instead of dropping the artifact.
/// It is deliberately not an enum and not `ExpressibleByStringLiteral`, so an analysis id
/// cannot stand in for a kind by accident. It is coded as a bare JSON string, the same way
/// as ``AnalysisToolID``.
public struct BundleKindID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }
}

extension BundleKindID {
    /// The `.lungfish` project folder.
    public static let project = BundleKindID(rawValue: "project")
    /// A `.lungfishref` genome reference bundle with its tracks.
    public static let reference = BundleKindID(rawValue: "reference")
    /// A `.lungfishfastq` read bundle.
    public static let fastq = BundleKindID(rawValue: "fastq")
    /// A `.lungfishmsa` multiple sequence alignment.
    public static let multipleSequenceAlignment = BundleKindID(rawValue: "multiple-sequence-alignment")
    /// A `.lungfishtree` phylogenetic tree.
    public static let phylogeneticTree = BundleKindID(rawValue: "phylogenetic-tree")
    /// A `.lungfishprimers` primer scheme.
    public static let primerScheme = BundleKindID(rawValue: "primer-scheme")
    /// A `.lungfishprimeranalysis` saved primer analysis.
    public static let primerAnalysis = BundleKindID(rawValue: "primer-analysis")
    /// A `.lungfishmhcref` MHC amplicon reference database.
    public static let mhcReference = BundleKindID(rawValue: "mhc-reference")
    /// A `.lungfishgenotype` genotyping result.
    public static let genotypeResult = BundleKindID(rawValue: "genotype-result")
    /// A `.lungfish12s` 12S amplicon match result.
    public static let twelveSResult = BundleKindID(rawValue: "12s-result")
    /// A `.lungfish12sref` 12S reference database. It is its own kind, not a genome reference.
    public static let twelveSReference = BundleKindID(rawValue: "12s-reference")
    /// A `.lungfishtax` CZ ID taxonomy import.
    public static let czIdResult = BundleKindID(rawValue: "cz-id-result")
    /// A `.lungfishrun` workflow run bundle.
    public static let workflowRun = BundleKindID(rawValue: "workflow-run")
    /// A retired `.lungfishflow` saved workflow bundle.
    public static let workflowBundle = BundleKindID(rawValue: "workflow-bundle")
    /// A `.lungfishflowpkg` workflow package.
    public static let workflowPackage = BundleKindID(rawValue: "workflow-package")
}

/// Everything the app knows about one kind of Lungfish folder as plain data.
///
/// The initializer has no defaulted parameters, so adding a field makes the compiler point at
/// every descriptor, and a new kind states every fact. The facts are the ones today's code
/// applies in the eleven places that decide a kind from the folder extension, frozen by
/// `BundleKindParityTests`. A descriptor changes no behavior until a caller reads it.
public struct BundleKindDescriptor: Sendable, Hashable {
    /// Whether the folder is the project itself or an item inside a project.
    public enum Role: String, Sendable, Hashable {
        case project
        case bundle
    }

    /// What a reader needs before it accepts a folder as this kind.
    public enum Recognition: String, Sendable, Hashable {
        /// The folder extension alone, wherever the kind is read today.
        case extensionOnly
        /// The extension plus the manifest file, in at least one reader today. The `.lungfishtax`
        /// sidebar row shows a CZ ID result only with its manifest. The typed `isBundleURL` of the
        /// MHC and 12S reference bundles needs theirs. The sidebar still classifies an MHC reference
        /// by extension alone, so a caller keeps its own rule until its lane converts it.
        case extensionAndManifest
    }

    /// How the sidebar shows a folder of this kind.
    public enum Presentation: String, Sendable, Hashable {
        /// One row that is never walked. The kind has its own viewport or preview.
        case atomicPackage
        /// A document row whose children are listed, because the kind has no viewport (plan row S10).
        case walkedPackage
        /// Never shown. The folder is a working artifact of another run.
        case hiddenPackage
    }

    /// How the deletion planner treats a folder of this kind.
    public struct Deletion: Sendable, Hashable {
        /// True when the planner treats the folder as one opaque project object and never reads inside it.
        public let isOpaqueProjectObject: Bool

        public init(isOpaqueProjectObject: Bool) {
            self.isOpaqueProjectObject = isOpaqueProjectObject
        }
    }

    /// How the cross-project copier treats a folder of this kind.
    public enum Copy: Sendable, Hashable {
        /// The copier returns nothing. The kind has its own import path or cannot be copied.
        case refused
        /// The copier keeps the item whole and lands it in `folder` of the target project when the
        /// source gives no hint. An empty folder is the project root. An item that must live under
        /// `Analyses/` is retargeted there.
        case copied(toFolder: String, requiresAnalysesFolder: Bool)
    }

    /// The provenance record names a kind uses.
    public enum SidecarNaming: Sendable, Hashable {
        /// One rule for new writes (plan row V10). A root record named ``rootRecordFileName`` plus
        /// a ``layoutFolderName`` folder with one record for each scientific output. A record file is
        /// never an output, so no record of a record is written, and an app cache is never an output.
        /// A manifest stays an output of its bundle record, because a reference manifest decides which
        /// BAM and VCF tracks the bundle shows.
        case rootRecordAndProvenanceFolder
        /// A format frozen as it is. It keeps its own record names, listed relative to the bundle,
        /// and the writer-wide rule never applies to it.
        case frozenException(recordPaths: [String])

        /// The root record of the standard rule, which is the file sidecar suffix with no stem.
        /// `ProvenanceWriter.provenanceFilename` holds the same name.
        public static let rootRecordFileName = BundleAttachmentFilenamePolicy.provenanceSidecarSuffix
        /// The folder of the standard rule. `ProvenanceWriter.bundleProvenanceDirectoryName` holds the same name.
        public static let layoutFolderName = "provenance"

        /// A path inside the layout folder, for a format that keeps one record there under its own name.
        public static func layoutPath(_ fileName: String) -> String {
            "\(layoutFolderName)/\(fileName)"
        }
    }

    public let id: BundleKindID
    public let role: Role
    /// The folder extensions of the kind, lowercase and without a dot. Each is unique across the registry.
    public let folderExtensions: [String]
    /// The manifest file inside the folder, or nil when the kind has no single manifest.
    public let manifestFileName: String?
    public let recognition: Recognition
    /// The `UTType` identifier that `Lungfish-Info.plist` declares for the extension, or nil when it declares none.
    public let utTypeIdentifier: String?
    /// The sidebar SF Symbol name of the row.
    public let sidebarSymbolName: String
    public let presentation: Presentation
    public let deletion: Deletion
    public let copy: Copy
    /// File names inside the folder that hold app state such as the viewport, not scientific data (plan row S11).
    public let appStateFileNames: [String]
    public let sidecarNaming: SidecarNaming
    /// The analyses whose sidebar row is a folder of this kind. Empty when none is.
    public let producedBy: [AnalysisToolID]

    public init(
        id: BundleKindID,
        role: Role,
        folderExtensions: [String],
        manifestFileName: String?,
        recognition: Recognition,
        utTypeIdentifier: String?,
        sidebarSymbolName: String,
        presentation: Presentation,
        deletion: Deletion,
        copy: Copy,
        appStateFileNames: [String],
        sidecarNaming: SidecarNaming,
        producedBy: [AnalysisToolID]
    ) {
        self.id = id
        self.role = role
        self.folderExtensions = folderExtensions
        self.manifestFileName = manifestFileName
        self.recognition = recognition
        self.utTypeIdentifier = utTypeIdentifier
        self.sidebarSymbolName = sidebarSymbolName
        self.presentation = presentation
        self.deletion = deletion
        self.copy = copy
        self.appStateFileNames = appStateFileNames
        self.sidecarNaming = sidecarNaming
        self.producedBy = producedBy
    }
}
