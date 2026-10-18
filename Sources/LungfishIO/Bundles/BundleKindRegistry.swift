// BundleKindRegistry.swift - The table of known bundle kinds
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The known kinds of Lungfish folder, with the facts today's code applies to each.
///
/// Eleven tables across the app map a folder extension to a fact about a bundle, and they
/// disagree. This registry holds the facts once. Six of those tables read it since lane B7. Every value here is
/// frozen by `BundleKindParityTests` in the App tests, which records what each table answers, and
/// `BundleKindRegistryTests` checks the facts below against that record. A caller that reads the
/// registry must keep the answer its old table gave, case rules included.
///
/// The order is the order of the Phase 2.6 inventory. The extension index is built from it
/// once. A lookup by extension does no file system access. The functions that read the file
/// system are ``recognizedKind(at:fileManager:)`` and
/// ``BundleKindDescriptor/recognizes(folder:fileManager:)``.
public enum BundleKindRegistry {
    /// The root record name that the alignment and tree formats write in their own schema.
    private static let rootRecord = BundleKindDescriptor.SidecarNaming.rootRecordFileName

    public static let all: [BundleKindDescriptor] = [
        // The project folder. Its row is the sidebar root. Nested in another project it is a walked package.
        BundleKindDescriptor(
            id: .project, role: .project, folderExtensions: ["lungfish"],
            manifestFileName: "metadata.json", recognition: .extensionOnly, utTypeIdentifier: nil,
            sidebarSymbolName: "folder.badge.gearshape", presentation: .walkedPackage,
            deletion: .init(isOpaqueProjectObject: false), copy: .refused,
            appStateFileNames: [], sidecarNaming: .rootRecordAndProvenanceFolder, producedBy: []
        ),
        // T8 shows Viral Recon and mapping results as generic analysis rows, so producedBy is empty.
        BundleKindDescriptor(
            id: .reference, role: .bundle, folderExtensions: ["lungfishref"],
            manifestFileName: "manifest.json", recognition: .extensionOnly,
            utTypeIdentifier: "org.lungfish.reference-bundle",
            sidebarSymbolName: "cylinder.split.1x2", presentation: .atomicPackage,
            deletion: .init(isOpaqueProjectObject: true),
            copy: .copied(toFolder: "Reference Sequences", requiresAnalysesFolder: false),
            appStateFileNames: [".viewstate.json"], sidecarNaming: .rootRecordAndProvenanceFolder, producedBy: []
        ),
        // A read bundle has no single manifest. A derived bundle has derived.manifest.json, a
        // multi-file bundle has read-manifest.json, and each FASTQ file has a .lungfish-meta.json beside it.
        BundleKindDescriptor(
            id: .fastq, role: .bundle, folderExtensions: ["lungfishfastq"],
            manifestFileName: nil, recognition: .extensionOnly, utTypeIdentifier: nil,
            sidebarSymbolName: "doc.text", presentation: .atomicPackage,
            deletion: .init(isOpaqueProjectObject: true),
            copy: .copied(toFolder: "Imports", requiresAnalysesFolder: false),
            appStateFileNames: [], sidecarNaming: .rootRecordAndProvenanceFolder, producedBy: []
        ),
        // The alignment, tree, primer and primer analysis formats keep their own record names.
        // An alignment also writes metadata/annotation-edit-provenance.json after an annotation edit.
        // The alignment and tree .viewstate.json is created with the bundle and covered by the
        // manifest checksums, so it is not declared app state (S11). A reference bundle's .viewstate.json is outside them.
        BundleKindDescriptor(
            id: .multipleSequenceAlignment, role: .bundle, folderExtensions: ["lungfishmsa"],
            manifestFileName: "manifest.json", recognition: .extensionOnly,
            utTypeIdentifier: "org.lungfish.msa-bundle",
            sidebarSymbolName: "rectangle.grid.1x2", presentation: .atomicPackage,
            deletion: .init(isOpaqueProjectObject: true),
            copy: .copied(toFolder: "Analyses/Multiple Sequence Alignments", requiresAnalysesFolder: false),
            appStateFileNames: [],
            sidecarNaming: .frozenException(recordPaths: [rootRecord]),
            producedBy: [.mafft]
        ),
        BundleKindDescriptor(
            id: .phylogeneticTree, role: .bundle, folderExtensions: ["lungfishtree"],
            manifestFileName: "manifest.json", recognition: .extensionOnly,
            utTypeIdentifier: "org.lungfish.tree-bundle",
            sidebarSymbolName: "point.3.connected.trianglepath.dotted", presentation: .atomicPackage,
            deletion: .init(isOpaqueProjectObject: true),
            copy: .copied(toFolder: "Phylogenetic Trees", requiresAnalysesFolder: false),
            appStateFileNames: [],
            sidecarNaming: .frozenException(recordPaths: [rootRecord]),
            producedBy: []
        ),
        BundleKindDescriptor(
            id: .primerScheme, role: .bundle, folderExtensions: ["lungfishprimers"],
            manifestFileName: "manifest.json", recognition: .extensionOnly, utTypeIdentifier: nil,
            sidebarSymbolName: "line.horizontal.3.decrease.circle", presentation: .atomicPackage,
            deletion: .init(isOpaqueProjectObject: true),
            copy: .copied(toFolder: "Primer Schemes", requiresAnalysesFolder: false),
            appStateFileNames: [], sidecarNaming: .frozenException(recordPaths: ["PROVENANCE.md"]), producedBy: []
        ),
        BundleKindDescriptor(
            id: .primerAnalysis, role: .bundle, folderExtensions: ["lungfishprimeranalysis"],
            manifestFileName: "manifest.json", recognition: .extensionOnly,
            utTypeIdentifier: "org.lungfish.primer-analysis",
            sidebarSymbolName: "list.bullet.rectangle", presentation: .atomicPackage,
            deletion: .init(isOpaqueProjectObject: true),
            copy: .copied(toFolder: "Analyses", requiresAnalysesFolder: false),
            appStateFileNames: [], sidecarNaming: .frozenException(recordPaths: [BundleKindDescriptor.SidecarNaming.layoutPath("wrapper.json")]), producedBy: []
        ),
        // The MHC reference database is imported through its own path, so the copier refuses it.
        BundleKindDescriptor(
            id: .mhcReference, role: .bundle, folderExtensions: ["lungfishmhcref"],
            manifestFileName: "mhc-reference.json", recognition: .extensionAndManifest,
            utTypeIdentifier: "org.lungfish.mhc-reference-bundle",
            sidebarSymbolName: "cylinder.split.1x2", presentation: .atomicPackage,
            deletion: .init(isOpaqueProjectObject: true), copy: .refused,
            appStateFileNames: [], sidecarNaming: .rootRecordAndProvenanceFolder, producedBy: []
        ),
        BundleKindDescriptor(
            id: .genotypeResult, role: .bundle, folderExtensions: ["lungfishgenotype"],
            manifestFileName: "genotype-result.json", recognition: .extensionOnly, utTypeIdentifier: nil,
            sidebarSymbolName: "tablecells.badge.ellipsis", presentation: .atomicPackage,
            deletion: .init(isOpaqueProjectObject: true),
            copy: .copied(toFolder: "Analyses", requiresAnalysesFolder: true),
            appStateFileNames: [GenotypeResultViewState.filename], sidecarNaming: .rootRecordAndProvenanceFolder, producedBy: [.ontGenotyping]
        ),
        BundleKindDescriptor(
            id: .twelveSResult, role: .bundle, folderExtensions: ["lungfish12s"],
            manifestFileName: "12s-result.json", recognition: .extensionOnly, utTypeIdentifier: nil,
            sidebarSymbolName: "tablecells", presentation: .atomicPackage,
            deletion: .init(isOpaqueProjectObject: true),
            copy: .copied(toFolder: "Analyses", requiresAnalysesFolder: false),
            appStateFileNames: [], sidecarNaming: .rootRecordAndProvenanceFolder, producedBy: []
        ),
        // The 12S reference database is its own kind (plan row S10). The sidebar has no viewport for it
        // yet, so it stays a walked document row, and FileTypeUtility no longer calls it a reference bundle.
        BundleKindDescriptor(
            id: .twelveSReference, role: .bundle, folderExtensions: ["lungfish12sref"],
            manifestFileName: "12s-reference.json", recognition: .extensionAndManifest, utTypeIdentifier: nil,
            sidebarSymbolName: "shippingbox", presentation: .walkedPackage,
            deletion: .init(isOpaqueProjectObject: true),
            copy: .copied(toFolder: "", requiresAnalysesFolder: false),
            appStateFileNames: [], sidecarNaming: .rootRecordAndProvenanceFolder, producedBy: []
        ),
        // Without cz-id-manifest.json the sidebar shows a walked document row, and the copier treats the
        // folder as an other native bundle that lands in the project root.
        BundleKindDescriptor(
            id: .czIdResult, role: .bundle, folderExtensions: ["lungfishtax"],
            manifestFileName: "cz-id-manifest.json", recognition: .extensionAndManifest, utTypeIdentifier: nil,
            sidebarSymbolName: "c.circle", presentation: .atomicPackage,
            deletion: .init(isOpaqueProjectObject: true),
            copy: .copied(toFolder: "Classifications", requiresAnalysesFolder: false),
            appStateFileNames: [], sidecarNaming: .rootRecordAndProvenanceFolder, producedBy: [.czId]
        ),
        // A run bundle is a working artifact of a pipeline. The sidebar hides it by its lowercase extension only.
        BundleKindDescriptor(
            id: .workflowRun, role: .bundle, folderExtensions: ["lungfishrun"],
            manifestFileName: "manifest.json", recognition: .extensionOnly, utTypeIdentifier: nil,
            sidebarSymbolName: "shippingbox", presentation: .hiddenPackage,
            deletion: .init(isOpaqueProjectObject: false),
            copy: .copied(toFolder: "", requiresAnalysesFolder: false),
            appStateFileNames: [], sidecarNaming: .rootRecordAndProvenanceFolder, producedBy: []
        ),
        // Retired. Nothing creates it, but the Info.plist still declares the type and the copier still lands it.
        BundleKindDescriptor(
            id: .workflowBundle, role: .bundle, folderExtensions: ["lungfishflow"],
            manifestFileName: nil, recognition: .extensionOnly, utTypeIdentifier: "org.lungfish.workflow",
            sidebarSymbolName: "shippingbox", presentation: .walkedPackage,
            deletion: .init(isOpaqueProjectObject: false),
            copy: .copied(toFolder: "Workflows", requiresAnalysesFolder: false),
            appStateFileNames: [], sidecarNaming: .rootRecordAndProvenanceFolder, producedBy: []
        ),
        BundleKindDescriptor(
            id: .workflowPackage, role: .bundle, folderExtensions: ["lungfishflowpkg"],
            manifestFileName: "manifest.json", recognition: .extensionOnly, utTypeIdentifier: nil,
            sidebarSymbolName: "shippingbox", presentation: .walkedPackage,
            deletion: .init(isOpaqueProjectObject: false), copy: .refused,
            appStateFileNames: [], sidecarNaming: .rootRecordAndProvenanceFolder, producedBy: []
        ),
    ]

    /// The one index. Every folder extension, already lowercase, maps to its descriptor.
    private static let byFolderExtension: [String: BundleKindDescriptor] = Dictionary(
        all.flatMap { descriptor in descriptor.folderExtensions.map { ($0, descriptor) } },
        uniquingKeysWith: { first, _ in first }
    )

    // MARK: - Lookup without file system access

    public static func descriptor(for id: BundleKindID) -> BundleKindDescriptor? {
        all.first { $0.id == id }
    }

    /// The kind whose folder extension is exactly `ext`. The registry spells extensions in
    /// lowercase, so `LUNGFISHREF` finds nothing. This is the lookup for a site that compares
    /// case-sensitively today and keeps that answer until a reviewed change.
    public static func descriptor(forExactExtension ext: String) -> BundleKindDescriptor? {
        byFolderExtension[ext]
    }

    /// The kind whose folder extension equals `ext` after lowercasing it, so `LUNGFISHREF` finds the
    /// reference kind. This is the lookup for a site that lowercases today.
    public static func descriptor(forLowercasedExtension ext: String) -> BundleKindDescriptor? {
        byFolderExtension[ext.lowercased()]
    }

    /// ``descriptor(forExactExtension:)`` for the path extension of `url`.
    public static func descriptor(forExactExtensionOf url: URL) -> BundleKindDescriptor? {
        descriptor(forExactExtension: url.pathExtension)
    }

    /// ``descriptor(forLowercasedExtension:)`` for the path extension of `url`.
    public static func descriptor(forLowercasedExtensionOf url: URL) -> BundleKindDescriptor? {
        descriptor(forLowercasedExtension: url.pathExtension)
    }

    // MARK: - Recognition that reads the file system

    /// The kind of a folder, ignoring the case of its extension.
    ///
    /// A kind whose recognition is `.extensionAndManifest` is returned only when its manifest exists
    /// in the folder. A kind recognized by extension alone is returned without touching the file
    /// system. A scan loop that needs no gate calls ``descriptor(forLowercasedExtensionOf:)`` instead.
    public static func recognizedKind(at url: URL, fileManager: FileManager = .default) -> BundleKindDescriptor? {
        guard let descriptor = descriptor(forLowercasedExtensionOf: url),
              descriptor.recognizes(folder: url, fileManager: fileManager) else {
            return nil
        }
        return descriptor
    }
}

extension BundleKindDescriptor {
    /// True when `url` passes this kind's recognition rule.
    ///
    /// The extension is not checked. Reads the file system only for `.extensionAndManifest`, and then
    /// only to ask whether the manifest file exists.
    public func recognizes(folder url: URL, fileManager: FileManager = .default) -> Bool {
        guard recognition == .extensionAndManifest, let manifestFileName else { return true }
        return fileManager.fileExists(atPath: url.appendingPathComponent(manifestFileName).path)
    }
}

extension BundleKindRegistry {
    /// The tails that turn a record file's name into the name of its signature file and of its public
    /// key file. `ProvenanceSigningConfiguration` in LungfishWorkflow spells the same two names. This
    /// module cannot see it, so `BundleKindAgreementTests` checks that they agree.
    private static let signingArtifactSuffixes = [".signature.json", ".pub"]

    /// True when the standard record rule keeps the file at `relativePath` out of the outputs of the
    /// bundle record of the folder at `bundleURL` (plan decision V10 and Phase 2.7 decision P6).
    ///
    /// `relativePath` is the path of the file inside the folder, with `/` between components. Three
    /// kinds of file are never an output, so a bundle holds no record of a record, of a signature or
    /// of a viewer setting.
    ///
    /// - A record file, at any depth. Its name ends in
    ///   ``BundleKindDescriptor/SidecarNaming/rootRecordFileName``, which covers the root record, the
    ///   record written beside a file and the roll-up.
    /// - The signature file or the public key file of a record, at any depth, named
    ///   `<record name>.signature.json` and `<record name>.pub`.
    /// - The app state file that the kind of the folder declares in
    ///   ``BundleKindDescriptor/appStateFileNames``, at the root of the folder, such as
    ///   `.viewstate.json` in a reference bundle.
    ///
    /// Nothing else is dropped. A manifest stays an output, because a reference manifest decides which
    /// tracks the bundle shows. A typed record such as `retained-demux-genotyping-provenance.json` or
    /// `<name>.xlsx.provenance.json` stays an output, because the genotype roll-up cites its digest.
    /// A folder of a kind with a frozen record format drops nothing, because the writer-wide rule never
    /// applies to it. A folder whose extension names no kind follows the rule with no app state.
    /// The kind comes from the extension of `bundleURL`, ignoring case, and no file is touched.
    public static func excludesFromBundleOutputs(relativePath: String, inBundleAt bundleURL: URL) -> Bool {
        let descriptor = descriptor(forLowercasedExtensionOf: bundleURL)
        if let naming = descriptor?.sidecarNaming, case .frozenException = naming {
            return false
        }
        let components = relativePath.split(separator: "/").filter { $0 != "." }.map(String.init)
        guard let fileName = components.last else { return false }
        let recordSuffix = BundleKindDescriptor.SidecarNaming.rootRecordFileName
        if fileName.hasSuffix(recordSuffix) {
            return true
        }
        if signingArtifactSuffixes.contains(where: { fileName.hasSuffix(recordSuffix + $0) }) {
            return true
        }
        return components.count == 1 && (descriptor?.appStateFileNames.contains(fileName) ?? false)
    }

    /// True when `url` is an app state file of the folder that holds it. The file sits directly in the
    /// folder, and its name is one that the kind of that folder declares in
    /// ``BundleKindDescriptor/appStateFileNames``, such as `.viewstate.json` in a reference bundle.
    ///
    /// App state is what the viewer rewrites as the user pans and zooms. No result takes it as an input
    /// and no listing or index stores anything from it, so code that reacts to file changes can skip it.
    /// The temporary file of an atomic write of that file counts too, such as `.viewstate.json.sb-e7881877-TeusD9`,
    /// because the watcher reports it before the rename.
    /// The kind comes from the extension of the folder, ignoring case, and no file is touched.
    public static func isAppStateFile(at url: URL) -> Bool {
        let folderURL = url.deletingLastPathComponent()
        guard let descriptor = descriptor(forLowercasedExtensionOf: folderURL) else { return false }
        let name = url.lastPathComponent
        return descriptor.appStateFileNames.contains { name == $0 || name.hasPrefix($0 + ".") }
    }
}
