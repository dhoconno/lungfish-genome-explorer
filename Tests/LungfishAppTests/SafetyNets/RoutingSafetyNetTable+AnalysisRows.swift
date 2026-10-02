// RoutingSafetyNetTable+AnalysisRows.swift - Analysis result rows
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Rows for the analysis results the Analyses folder lists. See RoutingSafetyNetTable.swift.

import AppKit
import Foundation
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow

extension RoutingSafetyNetTable {
    // MARK: Analysis results

    static var analysisRows: [RoutingRow] {
        [
            RoutingRow(family: .analyses, name: "SPAdes assembly", type: .analysisResult) { context in
                let (result, contigs) = try RoutingSafetyNetFixtures.assemblyAnalysis(
                    in: context.url("Analyses", isDirectory: true)
                )
                let path = context.render(result)
                return RoutingRowFixture(
                    item: try RoutingSafetyNetItems.scannedAnalysis(result),
                    expected: RoutingObservation(
                        viewports: ["AssemblyResultViewController"],
                        mode: .assembly,
                        native: ["assembly tool=spades output=\(path) contigs=\(context.render(contigs))"],
                        inspector: ["assembly"],
                        provenance: "analysisResult \(path)"
                    )
                )
            },
            RoutingRow(family: .analyses, name: "SPAdes seed whose sidecar the loader rejects", type: .analysisResult) { context in
                let result = try RoutingSafetyNetFixtures.assemblySeedAnalysis(in: context.url("Analyses", isDirectory: true))
                return RoutingRowFixture(
                    item: try RoutingSafetyNetItems.scannedAnalysis(result),
                    expected: nothing(status: "Unable to load assembly result.")
                )
            },
            RoutingRow(family: .analyses, name: "minimap2 mapping with a viewer bundle", type: .analysisResult) { context in
                let (result, viewerBundle, bam) = try RoutingSafetyNetFixtures.mappingAnalysis(
                    in: context.url("Analyses", isDirectory: true)
                )
                let path = context.render(result)
                return RoutingRowFixture(
                    item: try RoutingSafetyNetItems.scannedAnalysis(result),
                    expected: RoutingObservation(
                        viewports: ["ReferenceBundleViewportController"],
                        mode: .mapping,
                        reference: "mappingResult bundle=\(context.render(viewerBundle)) result=\(path) bam=\(context.render(bam)) \(publishedSARSTracks)",
                        bamContext: "\(path) samples=[sample]",
                        inspector: ["bundle=\(context.render(viewerBundle))", "mapping"],
                        provenance: "analysisResult \(path)"
                    )
                )
            },
            RoutingRow(family: .analyses, name: "legacy minimap2 result without a viewer bundle", type: .analysisResult) { context in
                let (result, bam) = try RoutingSafetyNetFixtures.legacyMappingAnalysis(
                    in: context.url("Analyses", isDirectory: true)
                )
                let path = context.render(result)
                return RoutingRowFixture(
                    item: try RoutingSafetyNetItems.scannedAnalysis(result),
                    expected: RoutingObservation(
                        viewports: ["ReferenceBundleViewportController"],
                        mode: .mapping,
                        reference: "mappingResult bundle=- result=\(path) bam=\(context.render(bam)) manifest=none",
                        inspector: ["mapping"],
                        provenance: "analysisResult \(path)"
                    )
                )
            },
            RoutingRow(family: .analyses, name: "minimap2 seed whose sidecar the loader rejects", type: .analysisResult) { context in
                let result = try RoutingSafetyNetFixtures.mappingSeedAnalysis(in: context.url("Analyses", isDirectory: true))
                return RoutingRowFixture(
                    item: try RoutingSafetyNetItems.scannedAnalysis(result),
                    expected: nothing(status: "Unable to load mapping result.")
                )
            },
            RoutingRow(family: .analyses, name: "Viral Recon run binds its .lungfishref, never a loose BAM", type: .analysisResult) { context in
                let ingested = try RoutingSafetyNetFixtures.viralReconAnalyses(
                    projectURL: context.url("Project", isDirectory: true),
                    scratch: context.url("viralrecon-scratch", isDirectory: true),
                    sampleNames: ["SRR36291587"]
                )
                let analysis = ingested[0].bundleDirectory
                let bundle = ingested[0].referenceBundleURL
                return RoutingRowFixture(
                    item: try RoutingSafetyNetItems.scannedAnalysis(analysis),
                    expected: RoutingObservation(
                        viewports: ["ReferenceBundleViewportController"],
                        mode: .mapping,
                        reference: "directBundle bundle=\(context.render(bundle)) \(publishedSARSTracks)",
                        bamContext: "\(context.render(bundle)) samples=[sample]",
                        inspector: ["bundle=\(context.render(bundle))", "viralRecon"],
                        provenance: "analysisResult \(context.render(analysis))"
                    )
                )
            },
            RoutingRow(family: .analyses, name: "Viral Recon batch sample binds that sample's .lungfishref", type: .analysisResult) { context in
                let ingested = try RoutingSafetyNetFixtures.viralReconAnalyses(
                    projectURL: context.url("Project", isDirectory: true),
                    scratch: context.url("viralrecon-scratch", isDirectory: true),
                    sampleNames: ["SRR36291587", "SRR36291588"]
                )
                let sample = ingested[1]
                let batch = sample.bundleDirectory.deletingLastPathComponent()
                return RoutingRowFixture(
                    item: try RoutingSafetyNetItems.scannedBatchChild(batch: batch, child: sample.bundleDirectory),
                    expected: RoutingObservation(
                        viewports: ["ReferenceBundleViewportController"],
                        mode: .mapping,
                        reference: "directBundle bundle=\(context.render(sample.referenceBundleURL)) \(publishedSARSTracks)",
                        bamContext: "\(context.render(sample.referenceBundleURL)) samples=[sample]",
                        inspector: ["bundle=\(context.render(sample.referenceBundleURL))", "viralRecon"],
                        provenance: "analysisResult \(context.render(sample.bundleDirectory))"
                    )
                )
            },
            RoutingRow(family: .analyses, name: "reviewed primer order", type: .analysisResult) { context in
                let order = try RoutingSafetyNetFixtures.primerOrderAnalysis(in: context.url("Analyses", isDirectory: true))
                return RoutingRowFixture(
                    item: try RoutingSafetyNetItems.scannedAnalysis(order),
                    expected: RoutingObservation(
                        viewports: ["PrimerOrderHostingController"],
                        inspector: ["primerAnalysis=\(context.render(order)) order"]
                    )
                )
            },
            RoutingRow(family: .analyses, name: "Savont sample FASTA", type: .analysisResult) { context in
                let (batch, fasta) = try RoutingSafetyNetFixtures.savontBatch(in: context.url("Analyses", isDirectory: true))
                return RoutingRowFixture(
                    item: try RoutingSafetyNetItems.scannedBatchChild(batch: batch, child: fasta),
                    expected: RoutingObservation(
                        mode: .genomics,
                        document: context.render(fasta),
                        loaded: [context.render(fasta)]
                    )
                )
            },
            RoutingRow(family: .analyses, name: "classifier folder reached as an analysis row", type: .analysisResult) { context in
                // The scanner gives classifier folders their own types. The
                // analysis route still checks the classifier router first, so
                // this row and the three tool ID rows below are built by hand.
                let result = try RoutingSafetyNetFixtures.kraken2Result(
                    named: "kraken2-2026-01-15T11-30-00",
                    in: context.url("Analyses", isDirectory: true),
                    samples: ["HG002"]
                )
                try metadata("kraken2", isBatch: false, in: result)
                let path = context.render(result)
                let item = SidebarItem(title: result.lastPathComponent, type: .analysisResult, url: result)
                item.userInfo["analysisTool"] = "kraken2"
                return RoutingRowFixture(
                    item: item,
                    expected: RoutingObservation(
                        viewports: ["TaxonomyViewController"],
                        mode: .metagenomics,
                        classifierContext: "\(path) samples=[HG002]",
                        native: ["taxonomy batch=\(path) selected=[HG002]"],
                        provenance: "classificationResult \(path)"
                    )
                )
            },
            RoutingRow(family: .analyses, name: "NAO-MGS by tool ID", type: .analysisResult) { context in
                let (bundle, samples) = try await RoutingSafetyNetFixtures.naoMgsResult(
                    named: "Wastewater surveillance",
                    in: context.url("Analyses", isDirectory: true)
                )
                let path = context.render(bundle)
                let item = SidebarItem(title: bundle.lastPathComponent, type: .analysisResult, url: bundle)
                item.userInfo["analysisTool"] = "naomgs"
                return RoutingRowFixture(
                    item: item,
                    expected: RoutingObservation(
                        viewports: ["NaoMgsResultViewController"],
                        mode: .metagenomics,
                        classifierContext: "\(path) samples=[\(naoMgsCanonicalSamples)]",
                        inspector: ["naoMgs=\(samples.sorted().first ?? "-")"],
                        provenance: "naoMgsResult \(path)"
                    )
                )
            },
            RoutingRow(family: .analyses, name: "NVD by tool ID", type: .analysisResult) { context in
                let (bundle, samples) = try await RoutingSafetyNetFixtures.nvdResult(
                    named: "Novel virus screen",
                    in: context.url("Analyses", isDirectory: true)
                )
                let path = context.render(bundle)
                let item = SidebarItem(title: bundle.lastPathComponent, type: .analysisResult, url: bundle)
                item.userInfo["analysisTool"] = "nvd"
                return RoutingRowFixture(
                    item: item,
                    expected: RoutingObservation(
                        viewports: ["NvdResultViewController"],
                        mode: .metagenomics,
                        classifierContext: "\(path) samples=[\(samples.sorted().joined(separator: ","))]",
                        inspector: ["nvd=\(nvdExperiment)"],
                        provenance: "nvdResult \(path)"
                    )
                )
            },
            RoutingRow(family: .analyses, name: "CZ ID by tool ID", type: .analysisResult) { context in
                let bundle = try RoutingSafetyNetFixtures.czIdResult(
                    named: "Cornea CZ ID import",
                    in: context.url("Analyses", isDirectory: true)
                )
                let item = SidebarItem(title: bundle.lastPathComponent, type: .analysisResult, url: bundle)
                item.userInfo["analysisTool"] = "cz-id"
                return RoutingRowFixture(
                    item: item,
                    expected: RoutingObservation(
                        viewports: ["CzIdResultViewController"],
                        mode: .metagenomics,
                        provenance: "czIdResult \(context.render(bundle))"
                    )
                )
            },
            RoutingRow(family: .analyses, name: "pbAA, a known tool with no viewer", type: .analysisResult) { context in
                let result = try RoutingSafetyNetFixtures.viewerlessAnalysis(
                    tool: "pbaa",
                    in: context.url("Analyses", isDirectory: true)
                )
                return RoutingRowFixture(
                    item: try RoutingSafetyNetItems.scannedAnalysis(result),
                    expected: RoutingObservation(
                        status: "Unsupported analysis: pbaa. Inspect or reveal pbaa-2026-01-15T20-00-00 from the sidebar.",
                        provenance: "analysisResult \(context.render(result))"
                    )
                )
            },
        ]
    }
}
