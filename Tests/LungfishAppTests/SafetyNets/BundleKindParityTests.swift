// BundleKindParityTests.swift - What the bundle kind tables answer today
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Safety net for Phase 2.6 lane B1 (plan rows S9 to S11, V9 and V10). The app decides
// what a Lungfish folder is in many places, each keyed on the folder extension, and
// the places disagree. The sidebar scanner, the deletion planner, the cross-project
// copier, DocumentType, the provenance coverage monitor, the MSA action runner, the
// open panel, FileTypeUtility, FormatIdentifier, ProvenanceWriter and the typed
// `isBundleURL` recognizers each hold a table. A registry will replace them one lane
// at a time, so this suite freezes what every table answers for the committed fixture
// bundles and for copies of each of the fifteen kinds in three spellings: as
// committed, with an uppercase extension and with the manifest removed.
//
// The answers are read by calling the real functions. Nothing here repeats their
// logic. A table with no public entry point is read through the nearest behaviour,
// for example the deletion planner through `impact(ofDeleting:in:)` and the MSA
// runner through the URL it hands back. Four more groups freeze what picks a viewer
// or a folder. They are the route a reference bundle with BAM and VCF tracks takes,
// the sibling bundle of a raw genotype BAM, the Viral Recon bundle locator and the
// package gate of DocumentLoader. Each has an uppercase copy, and it also has a
// manifest-less copy wherever a manifest can change the answer.
//
// Uppercase and manifest-less copies get their own base names in their own folders,
// because APFS and ExFAT ignore case and a copy beside the original would be the
// original. The viewer rows that rely on a lowercase path finding an uppercase
// folder skip on a case-sensitive volume. The ten cached demo archives of
// LUNGFISH_DEMO_ARCHIVE_DIR are not probes, because the suite must give one answer on
// every Mac. The committed demo archive stands in for them.
//
// Expected answers live in Tests/Fixtures/bundle-kinds. After an intended change,
// rewrite them, review the diff line by line and commit it with the change:
//
//     LUNGFISH_UPDATE_BUNDLE_KIND_PARITY=1 swift test --skip-update \
//         --filter LungfishAppTests.BundleKindParityTests
//
// In update mode every test writes its file and passes.

import AppKit
import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishWorkflow
import LungfishTestSupport

// LungfishIO re-exports LungfishCore, whose DocumentType would be ambiguous here.
private typealias AppDocumentType = LungfishApp.DocumentType

// MARK: - Kinds

/// One of the fifteen folder kinds, the bundle its probes are copied from and the
/// files whose removal leaves a manifest-less copy. A name starting with `*` matches
/// every top-level file with that suffix.
private struct KindSetup {
    enum Base {
        case probe(String)
        case shell([String: String])
    }

    let ext: String
    let base: Base
    let manifests: [String]

    static let all: [KindSetup] = [
        KindSetup(ext: "lungfish", base: .probe("fixture-project-sarscov2-mafft"), manifests: ["metadata.json", ".project.db"]),
        KindSetup(ext: "lungfishref", base: .probe("fixture-ref-testgenome"), manifests: ["manifest.json"]),
        KindSetup(ext: "lungfishfastq", base: .probe("demo-fastq-a"), manifests: ["derived.manifest.json", "read-manifest.json", "*.lungfish-meta.json"]),
        KindSetup(ext: "lungfishmsa", base: .probe("fixture-msa-in-project"), manifests: ["manifest.json"]),
        KindSetup(ext: "lungfishtree", base: .shell(["manifest.json": "{}", "tree/primary.nwk": "(a,b);", ".viewstate.json": "{}"]), manifests: ["manifest.json"]),
        KindSetup(ext: "lungfishprimers", base: .probe("fixture-primers-qiaseqdirect-sars2"), manifests: ["manifest.json", "PROVENANCE.md"]),
        KindSetup(ext: "lungfishprimeranalysis", base: .shell(["manifest.json": "{}", "provenance/wrapper.json": "{}"]), manifests: ["manifest.json"]),
        KindSetup(ext: "lungfishmhcref", base: .probe("fixture-mhcref-mcm-resource"), manifests: ["mhc-reference.json"]),
        KindSetup(ext: "lungfishgenotype", base: .shell(["genotype-result.json": "{}", "payload/calls.csv": "a,b\n"]), manifests: ["genotype-result.json"]),
        KindSetup(ext: "lungfish12s", base: .shell(["12s-result.json": "{}", "payload/table.tsv": "a\tb\n"]), manifests: ["12s-result.json"]),
        KindSetup(ext: "lungfish12sref", base: .shell(["12s-reference.json": "{}", "reference.fa": ">a\nACGT\n"]), manifests: ["12s-reference.json"]),
        KindSetup(ext: "lungfishtax", base: .shell(["cz-id-manifest.json": "{}", "classification.kreport": "x\n"]), manifests: ["cz-id-manifest.json"]),
        KindSetup(ext: "lungfishrun", base: .shell(["manifest.json": "{}", "run.json": "{}"]), manifests: ["manifest.json"]),
        KindSetup(ext: "lungfishflow", base: .shell(["flow.json": "{}"]), manifests: []),
        KindSetup(ext: "lungfishflowpkg", base: .probe("fixture-flowpkg-hello-nextflow"), manifests: ["manifest.json"]),
    ]
}

// MARK: - Probes

/// A folder the tables are asked about, with a stable id for the expected file.
private struct KindProbe {
    let id: String
    let source: String
    let url: URL
}

/// Builds every probe under one scratch root.
@MainActor
private final class ProbeBuilder {
    let root: URL
    private(set) var probes: [KindProbe] = []
    private var urlsByID: [String: URL] = [:]

    init(root: URL) {
        self.root = root
    }

    private func register(_ id: String, source: String, at url: URL) {
        probes.append(KindProbe(id: id, source: source, url: url))
        urlsByID[id] = url
    }

    private func slot(_ id: String, _ name: String) -> URL {
        root.appendingPathComponent("probes/\(id)/\(name)", isDirectory: true)
    }

    /// Copies a committed fixture into the scratch root, so nothing opens it in place.
    @discardableResult
    private func fixture(_ id: String, _ relativePath: String) throws -> URL {
        let source = SafetyNetPaths.repositoryRoot.appendingPathComponent(relativePath)
        let url = try SafetyNetFiles.copy(source, to: slot(id, source.lastPathComponent))
        register(id, source: relativePath, at: url)
        return url
    }

    func build() async throws {
        try fixture("fixture-ref-testgenome", "TestData/TestGenome.lungfishref")
        try fixture("fixture-ref-hepatitisb", "TestData/HepatitisB.lungfishref")
        try fixture("fixture-ref-simulated-mhc-released", "Tests/Fixtures/provenance-display/Reference Sequences/SIMULATED-MHC-annotated-reference.lungfishref")
        let project = try fixture("fixture-project-sarscov2-mafft", "Tests/Fixtures/alignment/sarscov2-mafft-e2e.lungfish")
        let msa = "Multiple Sequence Alignments/sars-cov-2-genomes-mafft.lungfishmsa"
        register("fixture-msa-in-project", source: "inside fixture-project-sarscov2-mafft, \(msa)", at: project.appendingPathComponent(msa))
        try fixture("fixture-msa-compat-record-only", "Tests/Fixtures/provenance-compat/cases/s4-msa-mafft-2026-05/\(msa)")
        let mcm = "MCM-MHC-miSeq-20260617.lungfishmhcref"
        try fixture("fixture-mhcref-compat-record-only", "Tests/Fixtures/provenance-compat/cases/s4-mcm-mhcref-shipped/\(mcm)")
        try fixture("fixture-mhcref-mcm-resource", "Sources/LungfishWorkflow/Resources/MCMHaplotyping/\(mcm)")
        for scheme in [
            "ARTIC-SARS-CoV-2-V4.1", "ARTIC-SARS-CoV-2-V4", "ARTIC-SARS-CoV-2-V5.3.2", "ARTIC-nCoV-2019-V3",
            "Midnight-1200-V1", "NEB-VarSkip-Long-vsl1", "NEB-VarSkip-vss1", "QIASeqDIRECT-SARS2",
        ] {
            try fixture("fixture-primers-\(scheme.lowercased())", "Sources/LungfishApp/Resources/PrimerSchemes/\(scheme).lungfishprimers")
        }
        try fixture("fixture-primers-iotests-valid-simple", "Tests/LungfishIOTests/Resources/primerschemes/valid-simple.lungfishprimers")
        try fixture("fixture-primers-workflowtests-mt192765", "Tests/LungfishWorkflowTests/Resources/primerschemes/mt192765-integration.lungfishprimers")
        try fixture("fixture-primers-workflowtests-valid-simple", "Tests/LungfishWorkflowTests/Resources/primerschemes/valid-simple.lungfishprimers")
        try fixture("fixture-flowpkg-hello-nextflow", "Examples/WorkflowPackages/hello-world-nextflow.lungfishflowpkg")
        try fixture("fixture-flowpkg-hello-snakemake", "Examples/WorkflowPackages/hello-world-snakemake.lungfishflowpkg")

        // The released demo archive holds the only real FASTQ bundles and nested references.
        let archive = "lge-demo-mhc-genotyping-2026.9.58.zip"
        let demo = root.appendingPathComponent("demo", isDirectory: true)
        try await SafeZipExtractor().extract(SafetyNetPaths.fixture("demo-projects/\(archive)"), to: demo)
        let demoProject = demo.appendingPathComponent("MHC Genotyping.lungfish", isDirectory: true)
        register("demo-project", source: "\(archive), MHC Genotyping.lungfish", at: demoProject)
        let mhc = "Reference allele databases/SIMULATED-MHC-MCM-teaching.lungfishmhcref"
        for (id, path) in [
            ("demo-fastq-a", "Imports/SIMULATED-MHC-A-pairs.lungfishfastq"),
            ("demo-fastq-b", "Imports/SIMULATED-MHC-B-pairs.lungfishfastq"),
            ("demo-ref", "Reference Sequences/SIMULATED-MHC-annotated-reference.lungfishref"),
            ("demo-mhcref", mhc),
            ("demo-mhcref-nested-ref", "\(mhc)/reference/SIMULATED-MHC-MCM-teaching.lungfishref"),
            ("demo-mhcref-record-only-ref", "\(mhc)/provenance/reference/SIMULATED-MHC-MCM-teaching.lungfishref"),
        ] {
            register(id, source: "\(archive), \(path)", at: demoProject.appendingPathComponent(path))
        }

        for kind in KindSetup.all {
            try deriveSpellings(of: kind)
        }
        // Folders that are no kind, or a kind nothing creates.
        for (id, name) in [
            ("control-plain-folder", "plain-folder"),
            ("control-unknown-lungfish-extension", "unknown.lungfishbundle"),
            ("control-near-miss-extension", "near-miss.zlungfishref"),
        ] {
            let url = try makeShell(slot(id, name), files: ["payload/readme.txt": "x\n"])
            register(id, source: "an empty stand-in named \(name)", at: url)
        }
    }

    /// Lower, upper and manifest-less copies of one kind. Each lives in its own folder under its own base name.
    private func deriveSpellings(of kind: KindSetup) throws {
        let lowerID = "lower-\(kind.ext)"
        let lower: URL
        switch kind.base {
        case .probe(let sourceID):
            lower = try SafetyNetFiles.copy(try XCTUnwrap(urlsByID[sourceID]), to: slot(lowerID, "\(lowerID).\(kind.ext)"))
            register(lowerID, source: "copy of \(sourceID)", at: lower)
        case .shell(let files):
            lower = try makeShell(slot(lowerID, "\(lowerID).\(kind.ext)"), files: files.merging(["payload/readme.txt": "x\n"]) { first, _ in first })
            register(lowerID, source: "small stand-in with the manifest", at: lower)
        }
        let upperID = "upper-\(kind.ext)"
        let upper = try SafetyNetFiles.copy(lower, to: slot(upperID, "\(upperID).\(kind.ext.uppercased())"))
        register(upperID, source: "\(lowerID) under an uppercase extension", at: upper)
        let bareID = "nomanifest-\(kind.ext)"
        let bare = try SafetyNetFiles.copy(lower, to: slot(bareID, "\(bareID).\(kind.ext)"))
        try Self.removeManifests(kind.manifests, from: bare)
        register(bareID, source: "\(lowerID) without \(kind.manifests.isEmpty ? "a manifest (it has none)" : kind.manifests.joined(separator: ", "))", at: bare)
    }

    private func makeShell(_ url: URL, files: [String: String]) throws -> URL {
        try SafetyNetFiles.makeDirectory(url)
        for (path, text) in files {
            try SafetyNetFiles.write(text, to: url.appendingPathComponent(path))
        }
        return url
    }

    static func removeManifests(_ names: [String], from bundle: URL) throws {
        let fileManager = FileManager.default
        let entries = try fileManager.contentsOfDirectory(atPath: bundle.path)
        for name in names {
            let matches = name.hasPrefix("*") ? entries.filter { $0.hasSuffix(String(name.dropFirst())) } : [name]
            for match in matches {
                try? fileManager.removeItem(at: bundle.appendingPathComponent(match))
            }
        }
    }
}

// MARK: - Answers

/// Answers that are read once per extension spelling instead of once per probe.
private struct ParityContext {
    let panelTypes: [UTType]
    let deletion: [String: String]
    let msaOutputIsDirectory: [String: Bool]

    @MainActor
    static func make(spellings: [String], root: URL) async throws -> ParityContext {
        ParityContext(
            panelTypes: AppFilePanelFactory.documentOpenPanel().allowedContentTypes,
            deletion: try deletionAnswers(spellings: spellings, root: root),
            msaOutputIsDirectory: try await msaOutputAnswers(spellings: spellings, root: root)
        )
    }

    /// Asks the real deletion planner, in one small project, whether a folder with each
    /// spelling is an opaque project object. An opaque object is reported as a dependent
    /// itself. Any other folder is walked, so the file inside it is reported instead.
    @MainActor
    private static func deletionAnswers(spellings: [String], root: URL) throws -> [String: String] {
        let project = root.appendingPathComponent("planner/Planner.lungfish", isDirectory: true)
        let target = try SafetyNetFiles.write(">t\nACGT\n", to: project.appendingPathComponent("target.fa"))
        var folders: [String: URL] = [:]
        for (index, spelling) in spellings.enumerated() {
            let folder = project.appendingPathComponent(spelling.isEmpty ? "probe-\(index)" : "probe-\(index).\(spelling)", isDirectory: true)
            try SafetyNetFiles.write(#"{"inputPath":"\#(target.path)"}"#, to: folder.appendingPathComponent("info.json"))
            folders[spelling] = folder
        }
        let impact = ProjectDeletionPlanner(fileManager: .default).impact(ofDeleting: [target], in: project)
        let dependents = Set(impact.dependentURLs.map { $0.standardizedFileURL.path })
        return folders.mapValues { folder in
            let path = folder.standardizedFileURL.path
            if dependents.contains(path) { return "opaqueObject" }
            return dependents.contains(path + "/info.json") ? "walkedInside" : "unseen"
        }
    }

    /// Runs the real MSA action runner against a stand-in CLI that echoes the one argument
    /// as its output path. The runner marks the URL it returns as a directory only for the
    /// extensions its private native-bundle table lists.
    @MainActor
    private static func msaOutputAnswers(spellings: [String], root: URL) async throws -> [String: Bool] {
        let script = root.appendingPathComponent("echo-output-cli")
        try SafetyNetFiles.write(
            #"""
            #!/bin/sh
            printf '{"event":"complete","output":"%s","outputs":["%s"]}\n' "$1" "$1"
            """#,
            to: script
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let runner = CLIMSAActionRunner(cliURLOverride: script)
        var answers: [String: Bool] = [:]
        for spelling in spellings {
            let path = "/nonexistent/probe" + (spelling.isEmpty ? "" : ".\(spelling)")
            let result = try await runner.run(arguments: [path], operationID: UUID(), ownsOperationLifecycle: false)
            answers[spelling] = result.outputURL.hasDirectoryPath
        }
        return answers
    }
}

/// The tables in output order, with the function each one reads.
private enum ParityTables {
    static let all: [(name: String, source: String)] = [
        ("sidebar.classification", "SidebarProjectScanner.bundleClassification(for:), the sidebar type and symbol"),
        ("sidebar.isNativePackage", "SidebarProjectScanner.isNativePackage(_:)"),
        ("sidebar.listed", "SidebarProjectScanner.shouldIncludeEntry(_:isDirectory:context:) in a regular folder"),
        ("sidebar.scanNode", "SidebarProjectScanner.scanTree(from:), the row type, symbol and whether the children are shown"),
        ("sidebar.scanRoot", "SidebarProjectScanner.scanTree(from:isRoot: true), only for a project folder"),
        ("sidebar.isBundle", "SidebarItemType.isBundle of the classified type"),
        ("sidebar.capabilities", "SidebarItemType.bundleCapabilities of the classified type"),
        ("sidebar.tint", "SidebarItemType.tintColor of the classified type"),
        ("deletion.object", "ProjectDeletionPlanner.impact(ofDeleting:in:), opaque object or walked"),
        ("copier.kind", "CrossProjectItemCopier.kind(of:) with its default folder"),
        ("document.type", "DocumentType.detect(from:) with isDirectoryFormat"),
        ("provenance.coverage", "ProvenanceCoverageMonitor.requirement(for:) for the URL alone"),
        ("msa.nativeBundleOutput", "CLIMSAActionRunner, whether its returned output URL is a directory"),
        ("openPanel.accepts", "AppFilePanelFactory.documentOpenPanel().allowedContentTypes"),
        ("fileType.detect", "FileTypeUtility.detect(url:)"),
        ("format.identifier", "the FormatIdentifier bundle constants, by lowercased extension"),
        ("provenanceWriter.isBundleDirectory", "ProvenanceWriter.isBundleDirectory(_:)"),
        ("typedRecognizers", "the isBundleURL recognizers of the typed bundle enums"),
    ]
}

@MainActor
private func answers(for probe: KindProbe, context: ParityContext) -> [String: String] {
    let url = probe.url
    let ext = url.pathExtension
    var result: [String: String] = [:]

    let classification = SidebarProjectScanner.bundleClassification(for: url)
    result["sidebar.classification"] = classification.map { "\(SidebarItemTypeCatalog.caseName($0.type)) \($0.icon)" } ?? "nil"
    result["sidebar.isNativePackage"] = "\(SidebarProjectScanner.isNativePackage(url))"
    result["sidebar.listed"] = "\(SidebarProjectScanner.shouldIncludeEntry(url, isDirectory: true, context: .regularDirectory))"
    result["sidebar.scanNode"] = describe(SidebarProjectScanner.scanTree(from: url))
    if ext.lowercased() == "lungfish" {
        result["sidebar.scanRoot"] = describe(SidebarProjectScanner.scanTree(from: url, isRoot: true))
    }
    if let type = classification?.type {
        result["sidebar.isBundle"] = "\(type.isBundle)"
        result["sidebar.capabilities"] = describe(type.bundleCapabilities)
        result["sidebar.tint"] = describe(type.tintColor)
    }
    result["deletion.object"] = context.deletion[ext] ?? "unread"
    result["copier.kind"] = CrossProjectItemCopier.kind(of: url).map {
        "\($0) folder=\"\($0.defaultRelativeFolder)\" analysesOnly=\($0.mustLiveUnderAnalyses)"
    } ?? "nil"
    result["document.type"] = AppDocumentType.detect(from: url).map { "\($0.rawValue) directory=\($0.isDirectoryFormat)" } ?? "nil"
    let item = ProvenanceInspectableItem(url: url, sidebarType: nil, contentMode: .empty, displayName: nil)
    result["provenance.coverage"] = ProvenanceCoverageMonitor().requirement(for: item).isNotRequired ? "notRequired" : "required"
    result["msa.nativeBundleOutput"] = "\(context.msaOutputIsDirectory[ext] ?? false)"
    result["openPanel.accepts"] = "\(UTType(filenameExtension: ext).map { context.panelTypes.contains($0) } ?? false)"
    let info = FileTypeUtility.detect(url: url)
    result["fileType.detect"] = "\(info.category.rawValue) \(info.iconName) quickLook=\(info.supportsQuickLook)"
    let identifiers = [FormatIdentifier.lungfishRef, FormatIdentifier.lungfish12SRef, FormatIdentifier.lungfishMHCRef]
    result["format.identifier"] = identifiers.first { $0.extensions.contains(ext.lowercased()) }?.id ?? "nil"
    result["provenanceWriter.isBundleDirectory"] = "\(ProvenanceWriter.isBundleDirectory(url))"
    var recognizers: [String] = []
    if FASTQBundle.isBundleURL(url) { recognizers.append("fastq") }
    if MHCAmpliconReferenceBundle.isBundleURL(url) { recognizers.append("mhcref") }
    if TwelveSReferenceBundle.isBundleURL(url) { recognizers.append("12sref") }
    if ONTGenotypeResultBundle.isBundleURL(url) { recognizers.append("genotype") }
    if TwelveSAmpliconResultBundle.isBundleURL(url) { recognizers.append("12s") }
    result["typedRecognizers"] = recognizers.isEmpty ? "none" : recognizers.joined(separator: ",")
    return result
}

private func describe(_ node: SidebarScanNode) -> String {
    let badge: String
    switch node.badge {
    case .symbol(let name): badge = "symbol \(name)"
    case .text(let text): badge = "text \(text)"
    case nil: badge = "no badge"
    }
    return "\(SidebarItemTypeCatalog.caseName(node.type)) \(badge) \(node.children.isEmpty ? "atomic" : "walked")"
}

private func describe(_ capabilities: SidebarBundleCapabilities) -> String {
    let flags: [(Bool, String)] = [
        (capabilities.canOpen, "open"), (capabilities.canShowPackageContents, "package"),
        (capabilities.canGetBundleInfo, "info"), (capabilities.canShowInInspector, "inspector"),
        (capabilities.canExportSequences, "exportSequences"), (capabilities.canExportAnnotations, "exportAnnotations"),
        (capabilities.canExportAlignment, "exportAlignment"),
    ]
    let names = flags.filter(\.0).map(\.1)
    return names.isEmpty ? "none" : names.joined(separator: ",")
}

private func describe(_ color: NSColor) -> String {
    if color.type == .catalog {
        return "\(color.catalogNameComponent)/\(color.colorNameComponent)"
    }
    guard let rgb = color.usingColorSpace(.sRGB) else { return "unreadable" }
    return String(format: "rgb %.3f %.3f %.3f", rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
}

// MARK: - Expected files

private enum ParityUpdate {
    static let environmentKey = "LUNGFISH_UPDATE_BUNDLE_KIND_PARITY"
    static var isOn: Bool { ProcessInfo.processInfo.environment[environmentKey] == "1" }
}

private struct ExpectedFile {
    let url: URL

    func check(_ rendered: String, isUpdating: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
        if isUpdating {
            try SafetyNetFiles.write(rendered, to: url)
            return
        }
        guard let data = try? Data(contentsOf: url), let committed = String(data: data, encoding: .utf8) else {
            XCTFail("No committed answers at \(url.path). Run with \(ParityUpdate.environmentKey)=1 to write them.", file: file, line: line)
            return
        }
        // A plain comparison keeps both whole files out of the failure message.
        if rendered != committed {
            XCTFail(
                "The answers frozen in \(url.lastPathComponent) changed. Lines marked + are new, lines marked - were committed:\n\(Self.difference(rendered, committed))",
                file: file, line: line
            )
        }
    }

    static func difference(_ rendered: String, _ committed: String) -> String {
        let change = rendered.components(separatedBy: "\n").difference(from: committed.components(separatedBy: "\n"))
        return change.map { step -> String in
            switch step {
            case .insert(_, let line, _): return "+ \(line)"
            case .remove(_, let line, _): return "- \(line)"
            }
        }.joined(separator: "\n")
    }

    /// The committed lines of one expected file, keyed by their first two columns.
    func committedAnswers() -> [String: String] {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for line in text.components(separatedBy: "\n") where !line.hasPrefix("#") {
            let columns = line.components(separatedBy: "\t")
            if columns.count == 3 { result["\(columns[0])\t\(columns[1])"] = columns[2] }
        }
        return result
    }
}

// MARK: - Viewer routes

/// One frozen viewer answer. `run` builds the row under its own scratch folder and
/// returns the answer, and `expected` lets a route stop waiting as soon as it matches.
private struct ViewerRow {
    let group: String
    let id: String
    let run: @MainActor (_ rowRoot: URL, _ expected: String?) async throws -> String
}

/// The sites that pick a viewer or a folder from the extension, asked with the real code.
@MainActor
private enum ViewerRoutes {
    static var rows: [ViewerRow] {
        let loaderKinds = ["lungfishref", "lungfishmsa", "lungfishtree", "lungfishfastq"]
        return ["lower", "upper", "nomanifest"].map(referenceRow)
            + [("md", "lower"), ("md", "sibling-upper"), ("md", "sibling-nomanifest"), ("md", "bam-upper"),
               ("retained", "lower"), ("retained", "sibling-upper"), ("retained", "sibling-nomanifest")]
                .map { rawBAMRow(kind: $0.0, variant: $0.1) }
            + ["s.md.sorted.bam", "s.retained.demuxed.bam", "s.MD.SORTED.BAM", "s.Md.Sorted.Bam", "s.RETAINED.DEMUXED.BAM", "s.sorted.bam", "s.bam"].map(siblingNameRow)
            + [("lower", [("sample.lungfishref", true)]), ("upper", [("sample.LUNGFISHREF", true)]),
               ("nomanifest", [("sample.lungfishref", false)]),
               ("lower-and-upper", [("a.LUNGFISHREF", true), ("b.lungfishref", true)]),
               ("two-lower", [("b.lungfishref", true), ("a.lungfishref", true)]), ("empty", [])]
                .map { locatorRow($0.0, bundles: $0.1) }
            + loaderKinds.flatMap { kind in ["lower", "upper"].map { loaderRow(kind: kind, variant: $0) } }
    }

    /// A reference bundle with a published BAM track and VCF track, opened from the sidebar.
    private static func referenceRow(_ variant: String) -> ViewerRow {
        ViewerRow(group: "referenceWithTracks", id: variant) { rowRoot, expected in
            let stage = rowRoot.appendingPathComponent("stage", isDirectory: true)
            let built = try RoutingSafetyNetFixtures.sarsCoV2ReferenceBundle(named: "MT192765.1", in: stage, publishTracks: true)
            let folder = rowRoot.appendingPathComponent("Reference Sequences", isDirectory: true)
            let name = ["upper": "upper-sample.LUNGFISHREF", "nomanifest": "nomanifest-sample.lungfishref"][variant] ?? "MT192765.1.lungfishref"
            let bundle = try relocate(built, to: folder.appendingPathComponent(name), removing: variant == "nomanifest" ? ["manifest.json"] : [])
            return try await route(RoutingSafetyNetItems.scanned(bundle), rowRoot: rowRoot, expected: expected)
        }
    }

    /// A raw genotype BAM with the prepared reference bundle that sits beside it.
    private static func rawBAMRow(kind: String, variant: String) -> ViewerRow {
        ViewerRow(group: "rawGenotypeBAM", id: "\(kind)-\(variant)") { rowRoot, expected in
            let isMD = kind == "md"
            let bamSuffix = isMD ? "md.sorted.bam" : "retained.demuxed.bam"
            let siblingBase = "DW472." + (isMD ? "mapped" : "retained-demux")
            let directory = rowRoot.appendingPathComponent("Genotyping", isDirectory: true)
            let built = try RoutingSafetyNetFixtures.sarsCoV2ReferenceBundle(
                named: siblingBase, in: rowRoot.appendingPathComponent("stage", isDirectory: true), publishTracks: true
            )
            _ = try relocate(
                built,
                to: directory.appendingPathComponent("\(siblingBase).\(variant == "sibling-upper" ? "LUNGFISHREF" : "lungfishref")"),
                removing: variant == "sibling-nomanifest" ? ["manifest.json"] : []
            )
            let bam = try SafetyNetFiles.copy(
                RoutingSafetyNetFixtures.sarsCoV2.appendingPathComponent("test.paired_end.sorted.bam"),
                to: directory.appendingPathComponent("DW472." + (variant == "bam-upper" ? bamSuffix.uppercased() : bamSuffix))
            )
            return try await route(RoutingSafetyNetItems.scanned(bam), rowRoot: rowRoot, expected: expected)
        }
    }

    /// The pure name rule of the sibling lookup.
    private static func siblingNameRow(_ name: String) -> ViewerRow {
        ViewerRow(group: "rawGenotypeBAMSibling", id: name) { _, _ in
            MainSplitViewController.ontGenotypingViewerBundleURL(forRawBAM: URL(fileURLWithPath: "/nonexistent/\(name)"))?
                .lastPathComponent ?? "nil"
        }
    }

    /// The Viral Recon analysis folder and the bundle the locator picks from it.
    private static func locatorRow(_ id: String, bundles: [(name: String, withManifest: Bool)]) -> ViewerRow {
        ViewerRow(group: "viralReconLocator", id: id) { rowRoot, _ in
            let analysis = try SafetyNetFiles.makeDirectory(rowRoot.appendingPathComponent("viralrecon-2026-01-01", isDirectory: true))
            for bundle in bundles {
                try SafetyNetFiles.write(bundle.withManifest ? "{}" : "x\n", to: analysis.appendingPathComponent("\(bundle.name)/\(bundle.withManifest ? "manifest.json" : "payload.txt")"))
            }
            return ViralReconAnalysisBundleLocator.viewableBundleURL(in: analysis)?.lastPathComponent ?? "nil"
        }
    }

    /// The package gate of DocumentLoader, with a FASTA file inside the package.
    /// A gated package is one result. Without the gate the inner file would show.
    private static func loaderRow(kind: String, variant: String) -> ViewerRow {
        ViewerRow(group: "documentLoaderPackageGate", id: "\(kind)-\(variant)") { rowRoot, _ in
            let folder = rowRoot.appendingPathComponent("scan", isDirectory: true)
            let bundle = folder.appendingPathComponent("sample.\(variant == "upper" ? kind.uppercased() : kind)", isDirectory: true)
            try SafetyNetFiles.write(">a\nACGT\n", to: bundle.appendingPathComponent("inner.fa"))
            let found = try DocumentLoader.scanFolder(at: folder).map { "\($0.type.rawValue):\($0.url.lastPathComponent)" }.sorted()
            return found.isEmpty ? "none" : found.joined(separator: ", ")
        }
    }

    // MARK: Helpers

    /// Moves a freshly built bundle to its final name, then removes the named files from it.
    private static func relocate(_ bundle: URL, to destination: URL, removing names: [String]) throws -> URL {
        try SafetyNetFiles.makeDirectory(destination.deletingLastPathComponent())
        try FileManager.default.moveItem(at: bundle, to: destination)
        try ProbeBuilder.removeManifests(names, from: destination)
        return destination
    }

    /// Selects the row on a fresh split controller with no window and returns the settled observation as one line.
    /// With an expected line it waits for that line, up to two minutes, because a loaded machine can take
    /// seconds to settle a viewport. Without one, when a file is being recorded, it waits until the
    /// observation has held still for a second.
    private static func route(_ item: SidebarItem, rowRoot: URL, expected: String?) async throws -> String {
        let paths = SafetyNetPathRenderer(root: rowRoot)
        let split = MainSplitViewController()
        split.loadViewIfNeeded()
        RecordingFilePreviewRenderer.install(on: split.viewerController)
        let recorder = LoadedDocumentRecorder()
        let loader = split.externalDocumentLoader
        split.externalDocumentLoader = { url in
            recorder.urls.append(url)
            return try await loader(url)
        }
        split.displayContent(for: item)

        var last = ""
        var heldStill = 0
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        var text = ""
        while true {
            text = RoutingObserver.observe(split, paths: paths, loaded: recorder.urls).description
                .replacingOccurrences(of: "\n", with: " ; ")
            if text == expected { break }
            heldStill = text == last ? heldStill + 1 : 0
            last = text
            if (expected == nil && heldStill >= 20) || ContinuousClock.now >= deadline { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        split.invalidateDisplayRequest()
        split.cancelFASTQLoadIfNeeded(hideProgress: true, reason: "bundle kind parity row finished")
        split.viewerController.clearViewport()
        split.inspectorController.clearSelection()
        return text
    }
}

// MARK: - Tests

@MainActor
final class BundleKindParityTests: XCTestCase {
    private var isUpdating: Bool { ParityUpdate.isOn }

    func testKindListNamesEveryFolderExtensionTheTypedConstantsDeclare() {
        let listed = Set(KindSetup.all.map(\.ext))
        XCTAssertEqual(KindSetup.all.count, 15)
        XCTAssertEqual(listed.count, 15, "Each kind is listed once")
        let declared: Set<String> = [
            ProjectFile.fileExtension, FASTQBundle.directoryExtension, MultipleSequenceAlignmentBundle.directoryExtension,
            MHCAmpliconReferenceBundle.directoryExtension, ONTGenotypeResultBundle.directoryExtension,
            TwelveSAmpliconResultBundle.directoryExtension, TwelveSReferenceBundle.directoryExtension,
            NFCoreRunBundleStore.directoryExtension, WorkflowPackageValidator.packageExtension,
            CrossProjectItemCopier.ItemKind.workflowBundleExtension,
        ]
        XCTAssertTrue(declared.isSubset(of: listed), "A typed constant names a kind the parity list lacks: \(declared.subtracting(listed))")
    }

    func testKindTablesMatchTheFrozenAnswers() async throws {
        let root = try TestTempDirectory.make(prefix: "BundleKindParity").resolvingSymlinksInPath()
        defer { TestTempDirectory.cleanup(root) }
        let builder = ProbeBuilder(root: root)
        try await builder.build()
        let spellings = Array(Set(builder.probes.map { $0.url.pathExtension })).sorted()
        let context = try await ParityContext.make(spellings: spellings, root: root)
        let perProbe = builder.probes.map { ($0, answers(for: $0, context: context)) }

        var lines = [
            "# Bundle kind parity answers, Phase 2.6 lane B1. Recorded from the real functions, never written by hand.",
            "# Lines are tab separated. A probe line is: probe, id, source. An answer line is: table, probe id, answer.",
            "# Rewrite with LUNGFISH_UPDATE_BUNDLE_KIND_PARITY=1 swift test --skip-update --filter LungfishAppTests.BundleKindParityTests",
            "# and review the diff before committing it. Tables:",
        ]
        lines += ParityTables.all.map { "#   \($0.name): \($0.source)" }
        lines += perProbe.map { "probe\t\($0.0.id)\t\($0.0.source)" }
        for table in ParityTables.all {
            for (probe, probeAnswers) in perProbe {
                if let answer = probeAnswers[table.name] { lines.append("\(table.name)\t\(probe.id)\t\(answer)") }
            }
        }
        let expected = ExpectedFile(url: SafetyNetPaths.fixture("bundle-kinds/parity-expected.tsv"))
        try expected.check(lines.joined(separator: "\n") + "\n", isUpdating: isUpdating)
    }

    func testViewerRoutesMatchTheFrozenAnswers() async throws {
        let root = try TestTempDirectory.make(prefix: "BundleKindParityRoutes").resolvingSymlinksInPath()
        defer { TestTempDirectory.cleanup(root) }
        try XCTSkipUnless(Self.isCaseInsensitive(root), "The uppercase rows need a volume that ignores case")
        let expected = ExpectedFile(url: SafetyNetPaths.fixture("bundle-kinds/viewer-expected.tsv"))
        let committed = isUpdating ? [:] : expected.committedAnswers()
        var lines = [
            "# Viewer route answers, Phase 2.6 lane B1. Recorded from the real code, never written by hand.",
            "# Lines are tab separated: group, row id, answer. Rewrite and review as in parity-expected.tsv.",
            "# referenceWithTracks and rawGenotypeBAM are the settled state of the sidebar router.",
            "# rawGenotypeBAMSibling is MainSplitViewController.ontGenotypingViewerBundleURL(forRawBAM:).",
            "# viralReconLocator is ViralReconAnalysisBundleLocator.viewableBundleURL(in:).",
            "# documentLoaderPackageGate is DocumentLoader.scanFolder(at:).",
        ]
        for row in ViewerRoutes.rows {
            let rowRoot = root.appendingPathComponent("\(row.group)-\(row.id)", isDirectory: true)
            let text = try await row.run(rowRoot, committed["\(row.group)\t\(row.id)"])
            lines.append("\(row.group)\t\(row.id)\t\(text)")
        }
        try expected.check(lines.joined(separator: "\n") + "\n", isUpdating: isUpdating)
    }

    private static func isCaseInsensitive(_ directory: URL) -> Bool {
        let probe = directory.appendingPathComponent("case-probe")
        FileManager.default.createFile(atPath: probe.path, contents: Data())
        return FileManager.default.fileExists(atPath: directory.appendingPathComponent("CASE-PROBE").path)
    }
}
