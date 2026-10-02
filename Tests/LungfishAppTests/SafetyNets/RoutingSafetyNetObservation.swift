// RoutingSafetyNetObservation.swift - What a routed sidebar selection installed
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The routing safety net compares one observation per row. An observation
// records what the window shows and binds once `displayContent(for:)`
// settles. That is the viewer's child controllers, its content mode, the
// Quick Look target, the loaded document, the status text of an empty
// viewport, the documents handed to the loader, the reference viewport input,
// the sample metadata contexts, the native viewport bindings, the Inspector
// documents and the provenance target. Paths are written relative to the
// row's scratch root so the expected values read like the fixture layout.

import AppKit
import Foundation
import SwiftUI
@testable import LungfishApp
@testable import LungfishAssemblyUI
@testable import LungfishEsVirituUI
@testable import LungfishTaxTriageUI
import LungfishCore
import LungfishGenotypeUI
import LungfishIO
import LungfishKit
import LungfishPhylogeneticsUI
import LungfishTwelveSUI

// MARK: - Paths

/// Writes URLs relative to a scratch root.
///
/// The temporary directory sits behind the `/var` to `/private/var` link, and
/// some routes hand back resolved URLs while others do not, so both spellings
/// of the root are accepted. A URL outside the root keeps its absolute path.
struct SafetyNetPathRenderer: Sendable {
    private let roots: [String]

    init(root: URL) {
        let spellings = Set([
            root.standardizedFileURL.path,
            root.resolvingSymlinksInPath().standardizedFileURL.path,
        ])
        roots = spellings.sorted { $0.count > $1.count }
    }

    func render(_ url: URL?) -> String? {
        guard let url else { return nil }
        let candidates = [
            url.standardizedFileURL.path,
            url.resolvingSymlinksInPath().standardizedFileURL.path,
        ]
        for candidate in candidates {
            for root in roots {
                if candidate == root { return "." }
                if candidate.hasPrefix(root + "/") {
                    return String(candidate.dropFirst(root.count + 1))
                }
            }
        }
        return url.standardizedFileURL.path
    }

    func render(_ urls: [URL]) -> [String] {
        urls.compactMap { render($0) }
    }
}

// MARK: - Observation

/// The settled outcome of one routed selection.
///
/// Every field has a fixed meaning, so a row's expected value is the full
/// outcome and any new, missing or different binding fails the row.
struct RoutingObservation: Equatable, Sendable, CustomStringConvertible {
    /// Class names of the viewer's child controllers, in installation order.
    var viewports: [String] = []
    /// The viewer's content mode.
    var mode: ViewportContentMode = .empty
    /// The status text, recorded only when no viewport and no document is shown.
    var status: String?
    /// The Quick Look target, with " as text" when the plain-text preview is used.
    var quickLook: String?
    /// The URL of the document the genomics viewer shows.
    var document: String?
    /// Every URL handed to the external document loader.
    var loaded: [String] = []
    /// The shared reference viewport input.
    var reference: String?
    /// The result URL and canonical sample IDs of the BAM sample metadata context.
    var bamContext: String?
    /// The result URL and canonical sample IDs of the classifier sample metadata context.
    var classifierContext: String?
    /// The dataset file and selected source of the FASTQ dashboard.
    var fastq: String?
    /// Native viewport bindings, one entry per installed native controller.
    var native: [String] = []
    /// Inspector document sections that hold content.
    var inspector: [String] = []
    /// The sidebar type and URL of the Inspector provenance target.
    var provenance: String?

    var description: String {
        var lines = [
            "viewports: \(viewports.isEmpty ? "none" : viewports.joined(separator: ", "))",
            "mode: \(mode.rawValue)",
        ]
        if let status { lines.append("status: \(status)") }
        if let quickLook { lines.append("quickLook: \(quickLook)") }
        if let document { lines.append("document: \(document)") }
        if !loaded.isEmpty { lines.append("loaded: \(loaded.joined(separator: ", "))") }
        if let reference { lines.append("reference: \(reference)") }
        if let bamContext { lines.append("bamContext: \(bamContext)") }
        if let classifierContext { lines.append("classifierContext: \(classifierContext)") }
        if let fastq { lines.append("fastq: \(fastq)") }
        for entry in native { lines.append("native: \(entry)") }
        for entry in inspector { lines.append("inspector: \(entry)") }
        if let provenance { lines.append("provenance: \(provenance)") }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Observer

@MainActor
enum RoutingObserver {
    static func observe(
        _ split: MainSplitViewController,
        paths: SafetyNetPathRenderer,
        loaded: [URL]
    ) -> RoutingObservation {
        let viewer: ViewerViewController = split.viewerController
        var observation = RoutingObservation()
        observation.viewports = viewer.children.map { String(describing: type(of: $0)) }
        observation.mode = viewer.contentMode
        if let quickLookURL = viewer.testQuickLookURL {
            let suffix = viewer.testPlainTextPreviewString == nil ? "" : " as text"
            observation.quickLook = (paths.render(quickLookURL) ?? "-") + suffix
        }
        observation.document = paths.render(viewer.currentDocument?.url)
        if observation.viewports.isEmpty, observation.document == nil {
            observation.status = viewer.testPreviewStatusText
        }
        observation.loaded = paths.render(loaded)
        if let input = viewer.referenceBundleViewportController?.currentInput {
            observation.reference = describe(input, paths: paths)
        }
        if let context = split.bamMetadataPresentationContext {
            observation.bamContext = describe(context, paths: paths)
        }
        if let context = split.classifierMetadataPresentationContext {
            observation.classifierContext = describe(context, paths: paths)
        }
        if let datasetURL = viewer.currentFASTQDatasetURL {
            observation.fastq = "dataset=\(paths.render(datasetURL) ?? "-") source=\(paths.render(split.activeFASTQSourceURL) ?? "-")"
        }
        observation.native = nativeBindings(viewer, paths: paths)
        observation.inspector = inspectorDocuments(split.inspectorController, paths: paths)
        if let item = split.inspectorController.viewModel.provenanceSectionViewModel.currentItem {
            let type = item.sidebarType.map(SidebarItemTypeCatalog.caseName) ?? "none"
            observation.provenance = "\(type) \(paths.render(item.url) ?? "-")"
        }
        return observation
    }

    static func describe(_ input: ReferenceBundleViewportInput, paths: SafetyNetPathRenderer) -> String {
        var parts: [String] = []
        switch input.kind {
        case .directBundle: parts.append("directBundle")
        case .mappingResult: parts.append("mappingResult")
        }
        parts.append("bundle=\(paths.render(input.renderedBundleURL) ?? "-")")
        if let result = input.mappingResult {
            parts.append("result=\(paths.render(input.mappingResultDirectoryURL) ?? "-")")
            parts.append("bam=\(paths.render(result.bamURL) ?? "-")")
        }
        if let manifest = input.manifest ?? input.viewerBundleManifest {
            if let genome = manifest.genome {
                parts.append("genome=\(genome.path)[\(genome.chromosomes.map(\.name).joined(separator: ","))]")
            } else {
                parts.append("genome=none")
            }
            parts.append("alignments=[\(manifest.alignments.map { "\($0.id):\($0.sourcePath)" }.joined(separator: ","))]")
            parts.append("variants=[\(manifest.variants.map { "\($0.id):\($0.path)" }.joined(separator: ","))]")
            parts.append("annotations=[\(manifest.annotations.map { "\($0.id):\($0.path)" }.joined(separator: ","))]")
            parts.append("signals=[\(manifest.tracks.map { "\($0.id):\($0.path)" }.joined(separator: ","))]")
        } else {
            parts.append("manifest=none")
        }
        return parts.joined(separator: " ")
    }

    static func describe(_ context: SampleMetadataPresentationContext, paths: SafetyNetPathRenderer) -> String {
        let samples = context.identityIndex.canonicalSampleIDs.sorted().joined(separator: ",")
        return "\(paths.render(context.finalResultURL) ?? "-") samples=[\(samples)]"
    }

    static func nativeBindings(_ viewer: ViewerViewController, paths: SafetyNetPathRenderer) -> [String] {
        var bindings: [String] = []
        if let controller = viewer.mhcReferenceBundleViewController {
            let model = controller.rootView.model
            let definitions = model.definitionSummaries.map(\.id).joined(separator: ",")
            bindings.append("mhc bundle=\(paths.render(model.bundleURL) ?? "-") references=\(model.referenceCount) definitions=[\(definitions)]")
        }
        if let controller = viewer.multipleSequenceAlignmentViewController {
            bindings.append("msa bundle=\(paths.render(controller.bundleURL) ?? "-")")
        }
        if let controller = viewer.phylogeneticTreeViewController {
            bindings.append("tree bundle=\(paths.render(controller.bundleURL) ?? "-")")
        }
        if let controller = viewer.genotypeResultViewController {
            bindings.append("genotype bundle=\(paths.render(controller.currentResultBundleURL) ?? "-")")
        }
        if let controller = viewer.twelveSAmpliconResultViewController {
            let samples = controller.inspectorSampleEntries.map(\.id).joined(separator: ",")
            bindings.append("twelveS samples=[\(samples)]")
        }
        if let controller = viewer.assemblyResultController {
            let result = controller.currentResult
            bindings.append(
                "assembly tool=\(result?.tool.rawValue ?? "-") output=\(paths.render(result?.outputDirectory) ?? "-") contigs=\(paths.render(result?.contigsPath) ?? "-")"
            )
        }
        if let controller = viewer.taxonomyViewController {
            bindings.append("taxonomy batch=\(paths.render(controller.batchURL) ?? "-") selected=\(selection(controller.samplePickerState?.selectedSamples))")
        }
        if let controller = viewer.esVirituViewController {
            bindings.append("esViritu batch=\(paths.render(controller.batchURL) ?? "-") selected=\(selection(controller.samplePickerState?.selectedSamples))")
        }
        if let controller = viewer.taxTriageViewController {
            bindings.append("taxTriage batch=\(paths.render(controller.batchGroupURL) ?? "-") selected=\(selection(controller.samplePickerState?.selectedSamples))")
        }
        return bindings
    }

    private static func selection(_ samples: Set<String>?) -> String {
        guard let samples else { return "none" }
        return "[\(samples.sorted().joined(separator: ","))]"
    }

    static func inspectorDocuments(_ inspector: InspectorViewController, paths: SafetyNetPathRenderer) -> [String] {
        let document = inspector.viewModel.documentSectionViewModel
        var entries: [String] = []
        if let bundleURL = document.bundleURL {
            entries.append("bundle=\(paths.render(bundleURL) ?? "-")")
        }
        if document.mappingDocument != nil { entries.append("mapping") }
        if document.assemblyDocument != nil { entries.append("assembly") }
        if document.multipleSequenceAlignmentDocument != nil { entries.append("multipleSequenceAlignment") }
        if document.phylogeneticTreeDocument != nil { entries.append("phylogeneticTree") }
        if let genotype = document.genotypeResultDocument {
            entries.append("genotype=\(paths.render(genotype.bundleURL) ?? "-")")
        }
        if document.viralReconDocument != nil { entries.append("viralRecon") }
        if let mhc = document.mhcReferenceBundleDocument {
            entries.append("mhcReference=\(paths.render(mhc.bundleURL) ?? "-")")
        }
        if let scheme = document.primerSchemeDocument {
            entries.append("primerScheme=\(scheme.manifest.name)")
        }
        if let manifest = document.naoMgsManifest {
            entries.append("naoMgs=\(manifest.sampleName)")
        }
        if let manifest = document.nvdManifest {
            entries.append("nvd=\(manifest.experiment)")
        }
        if document.fastqStatistics != nil { entries.append("fastqStatistics") }
        if let tool = document.batchOperationTool { entries.append("batchOperation=\(tool)") }
        if inspector.viewModel.twelveSResultDisplaySectionViewModel.isAvailable { entries.append("twelveS") }
        if let primer = inspector.viewModel.primerAnalysisDocument {
            entries.append("primerAnalysis=\(paths.render(primer.bundleURL) ?? "-")\(primer.isOrder ? " order" : "")")
        }
        return entries
    }
}
