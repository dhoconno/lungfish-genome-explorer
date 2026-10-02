// RoutingSafetyNetTable+BundleAndClassifierRows.swift - Bundle and classifier result rows
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Rows for native bundles and classifier results. See RoutingSafetyNetTable.swift.

import AppKit
import Foundation
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow

extension RoutingSafetyNetTable {
    // MARK: Bundles

    static var bundleRows: [RoutingRow] {
        [
            RoutingRow(family: .bundles, name: "TestGenome reference bundle", type: .referenceBundle) { context in
                let bundle = try RoutingSafetyNetFixtures.testGenomeReferenceBundle(
                    in: context.url("Reference Sequences", isDirectory: true)
                )
                return RoutingRowFixture(
                    item: RoutingSafetyNetItems.scanned(bundle),
                    expected: RoutingObservation(
                        viewports: ["ReferenceBundleViewportController"],
                        mode: .mapping,
                        reference: "directBundle bundle=Reference Sequences/TestGenome.lungfishref genome=genome/sequence.fa[chr1,chr2,chrM] alignments=[] variants=[testsnps:variants/snps.bcf] annotations=[genes:annotations/genes.bb] signals=[gc_content:tracks/gc_content.bw]",
                        inspector: ["bundle=Reference Sequences/TestGenome.lungfishref"],
                        provenance: "referenceBundle Reference Sequences/TestGenome.lungfishref"
                    )
                )
            },
            RoutingRow(family: .bundles, name: "SARS-CoV-2 reference bundle with published tracks", type: .referenceBundle) { context in
                let bundle = try RoutingSafetyNetFixtures.sarsCoV2ReferenceBundle(
                    named: "MT192765.1",
                    in: context.url("Reference Sequences", isDirectory: true),
                    publishTracks: true
                )
                return RoutingRowFixture(
                    item: RoutingSafetyNetItems.scanned(bundle),
                    expected: RoutingObservation(
                        viewports: ["ReferenceBundleViewportController"],
                        mode: .mapping,
                        reference: "directBundle bundle=Reference Sequences/MT192765.1.lungfishref \(publishedSARSTracks)",
                        bamContext: "Reference Sequences/MT192765.1.lungfishref samples=[sample]",
                        inspector: ["bundle=Reference Sequences/MT192765.1.lungfishref"],
                        provenance: "referenceBundle Reference Sequences/MT192765.1.lungfishref"
                    )
                )
            },
            RoutingRow(family: .bundles, name: "MHC amplicon reference bundle", type: .mhcReferenceBundle) { context in
                let bundle = try RoutingSafetyNetFixtures.mhcReferenceBundle(
                    in: context.url("Reference allele databases", isDirectory: true)
                )
                let path = context.render(bundle)
                return RoutingRowFixture(
                    item: RoutingSafetyNetItems.scanned(bundle),
                    expected: RoutingObservation(
                        viewports: ["NSHostingController<MHCReferenceBundleViewport>"],
                        mode: .genomics,
                        native: ["mhc bundle=\(path) references=3 definitions=[mhc-simulated-mcm-teaching]"],
                        inspector: ["mhcReference=\(path)"],
                        provenance: "mhcReferenceBundle \(path)"
                    )
                )
            },
            RoutingRow(family: .bundles, name: "multiple sequence alignment bundle", type: .multipleSequenceAlignmentBundle) { context in
                let bundle = try RoutingSafetyNetFixtures.multipleSequenceAlignmentBundle(
                    in: context.url("Multiple Sequence Alignments", isDirectory: true)
                )
                let path = context.render(bundle)
                return RoutingRowFixture(
                    item: RoutingSafetyNetItems.scanned(bundle),
                    expected: RoutingObservation(
                        viewports: ["MultipleSequenceAlignmentViewController"],
                        mode: .genomics,
                        native: ["msa bundle=\(path)"],
                        inspector: ["multipleSequenceAlignment"],
                        provenance: "multipleSequenceAlignmentBundle \(path)"
                    )
                )
            },
            RoutingRow(family: .bundles, name: "phylogenetic tree bundle", type: .phylogeneticTreeBundle) { context in
                let bundle = try RoutingSafetyNetFixtures.phylogeneticTreeBundle(
                    in: context.url("Phylogenetic Trees", isDirectory: true)
                )
                let path = context.render(bundle)
                return RoutingRowFixture(
                    item: RoutingSafetyNetItems.scanned(bundle),
                    expected: RoutingObservation(
                        viewports: ["PhylogeneticTreeViewController"],
                        mode: .genomics,
                        native: ["tree bundle=\(path)"],
                        inspector: ["phylogeneticTree"],
                        provenance: "phylogeneticTreeBundle \(path)"
                    )
                )
            },
            RoutingRow(family: .bundles, name: "FASTQ bundle with cached statistics", type: .fastqBundle) { context in
                let (bundle, fastq) = try await RoutingSafetyNetFixtures.fastqBundle(
                    in: context.url("Reads", isDirectory: true)
                )
                return RoutingRowFixture(
                    item: RoutingSafetyNetItems.scanned(bundle),
                    expected: RoutingObservation(
                        viewports: ["FASTQDatasetViewController"],
                        mode: .fastq,
                        fastq: "dataset=\(context.render(fastq)) source=\(context.render(bundle))",
                        inspector: ["fastqStatistics"],
                        provenance: "fastqBundle \(context.render(bundle))"
                    )
                )
            },
            RoutingRow(family: .bundles, name: "saved primer analysis", type: .primerAnalysisBundle) { context in
                let bundle = try RoutingSafetyNetFixtures.primerAnalysisBundle(
                    in: context.url("Primer Designs", isDirectory: true)
                )
                return RoutingRowFixture(
                    item: RoutingSafetyNetItems.scanned(bundle),
                    expected: RoutingObservation(
                        viewports: ["PrimerAnalysisHostingController"],
                        inspector: ["primerAnalysis=\(context.render(bundle))"]
                    )
                )
            },
            RoutingRow(family: .bundles, name: "primer scheme, metadata only", type: .primerSchemeBundle) { context in
                let bundle = try RoutingSafetyNetFixtures.primerSchemeBundle(
                    in: context.url("Primer Schemes", isDirectory: true)
                )
                return RoutingRowFixture(
                    item: RoutingSafetyNetItems.scanned(bundle),
                    expected: RoutingObservation(
                        status: "Primer scheme QIAseq Direct SARS-CoV-2 with Booster A. Details are in the Inspector.",
                        inspector: ["primerScheme=QIASeqDIRECT-SARS2"]
                    )
                )
            },
            RoutingRow(family: .bundles, name: "genotype result with calls", type: .genotypeResultBundle) { context in
                let bundle = try RoutingSafetyNetFixtures.genotypeResultBundle(
                    in: context.url("Genotyping", isDirectory: true),
                    withCalls: true
                )
                let path = context.render(bundle)
                return RoutingRowFixture(
                    item: RoutingSafetyNetItems.scanned(bundle),
                    expected: RoutingObservation(
                        viewports: ["GenotypeResultViewController"],
                        mode: .genotype,
                        native: ["genotype bundle=\(path)"],
                        inspector: ["genotype=\(path)"],
                        provenance: "genotypeResultBundle \(path)"
                    )
                )
            },
            RoutingRow(family: .bundles, name: "genotype result without calls previews its workbook", type: .genotypeResultBundle) { context in
                let bundle = try RoutingSafetyNetFixtures.genotypeResultBundle(
                    in: context.url("Genotyping", isDirectory: true),
                    withCalls: false
                )
                let path = context.render(bundle)
                return RoutingRowFixture(
                    item: RoutingSafetyNetItems.scanned(bundle),
                    expected: RoutingObservation(
                        status: "Previewing: DW472-mhc-workbook.xlsx",
                        quickLook: "\(path)/DW472-mhc-workbook.xlsx",
                        inspector: ["genotype=\(path)"],
                        provenance: "genotypeResultBundle \(path)"
                    )
                )
            },
            RoutingRow(family: .bundles, name: "12S amplicon result", type: .twelveSAmpliconResultBundle) { context in
                let (bundle, sampleIDs) = try RoutingSafetyNetFixtures.twelveSResultBundle(
                    in: context.url("12S", isDirectory: true)
                )
                return RoutingRowFixture(
                    item: RoutingSafetyNetItems.scanned(bundle),
                    expected: RoutingObservation(
                        viewports: ["TwelveSAmpliconResultViewController"],
                        mode: .metagenomics,
                        native: ["twelveS samples=[\(sampleIDs.joined(separator: ","))]"],
                        inspector: ["twelveS"],
                        provenance: "twelveSAmpliconResultBundle \(context.render(bundle))"
                    )
                )
            },
        ]
    }

    // MARK: Classifier results

    static var classifierRows: [RoutingRow] {
        [
            RoutingRow(family: .classifiers, name: "Kraken2 result", type: .classificationResult) { context in
                let result = try RoutingSafetyNetFixtures.kraken2Result(
                    named: "kraken2-2026-01-15T11-00-00",
                    in: context.url("Analyses", isDirectory: true),
                    samples: ["HG002"]
                )
                try metadata("kraken2", isBatch: false, in: result)
                let path = context.render(result)
                return RoutingRowFixture(
                    item: try RoutingSafetyNetItems.scannedAnalysis(result),
                    expected: RoutingObservation(
                        viewports: ["TaxonomyViewController"],
                        mode: .metagenomics,
                        classifierContext: "\(path) samples=[HG002]",
                        native: ["taxonomy batch=\(path) selected=[HG002]"],
                        provenance: "classificationResult \(path)"
                    )
                )
            },
            RoutingRow(family: .classifiers, name: "Kraken2 per-sample folder narrows the picker", type: .classificationResult) { context in
                // Classifier batches are leaf rows today, so no scanned row points
                // at a sample folder. The router still handles one, so the row is
                // built by hand.
                let batch = try RoutingSafetyNetFixtures.kraken2Result(
                    named: "kraken2-batch-2026-01-15T12-00-00",
                    in: context.url("Analyses", isDirectory: true),
                    samples: ["HG002", "MMU-17"],
                    sampleSubdirectories: true
                )
                try metadata("kraken2", isBatch: true, in: batch)
                let sample = batch.appendingPathComponent("MMU-17", isDirectory: true)
                let path = context.render(batch)
                return RoutingRowFixture(
                    item: SidebarItem(title: "MMU-17", type: .classificationResult, url: sample),
                    expected: RoutingObservation(
                        viewports: ["TaxonomyViewController"],
                        mode: .metagenomics,
                        classifierContext: "\(path) samples=[HG002,MMU-17]",
                        native: ["taxonomy batch=\(path) selected=[MMU-17]"],
                        provenance: "classificationResult \(path)"
                    )
                )
            },
            RoutingRow(family: .classifiers, name: "legacy classification folder name", type: .classificationResult) { context in
                // Before the tool name became the prefix, Kraken2 results were
                // written as classification-<timestamp> with no metadata sidecar.
                // The scanner recognises them by classification-result.json.
                let result = try RoutingSafetyNetFixtures.kraken2Result(
                    named: "classification-2026-01-15T09-00-00",
                    in: context.url("Analyses", isDirectory: true),
                    samples: ["HG002"]
                )
                try SafetyNetFiles.write(
                    #"{"config":{"databaseName":"Viral"}}"#,
                    to: result.appendingPathComponent("classification-result.json")
                )
                let path = context.render(result)
                return RoutingRowFixture(
                    item: try RoutingSafetyNetItems.scannedAnalysis(result),
                    expected: RoutingObservation(
                        viewports: ["TaxonomyViewController"],
                        mode: .metagenomics,
                        classifierContext: "\(path) samples=[HG002]",
                        native: ["taxonomy batch=\(path) selected=[HG002]"],
                        inspector: ["batchOperation=Kraken2"],
                        provenance: "classificationResult \(path)"
                    )
                )
            },
            RoutingRow(family: .classifiers, name: "EsViritu result", type: .esvirituResult) { context in
                let result = try RoutingSafetyNetFixtures.esVirituResult(
                    named: "esviritu-2026-01-15T10-00-00",
                    in: context.url("Analyses", isDirectory: true),
                    samples: ["HG002"]
                )
                try metadata("esviritu", isBatch: false, in: result)
                let path = context.render(result)
                return RoutingRowFixture(
                    item: try RoutingSafetyNetItems.scannedAnalysis(result),
                    expected: RoutingObservation(
                        viewports: ["EsVirituResultViewController"],
                        mode: .metagenomics,
                        classifierContext: "\(path) samples=[HG002]",
                        native: ["esViritu batch=\(path) selected=[HG002]"],
                        provenance: "esvirituResult \(path)"
                    )
                )
            },
            RoutingRow(family: .classifiers, name: "TaxTriage result", type: .taxTriageResult) { context in
                let result = try RoutingSafetyNetFixtures.taxTriageResult(
                    named: "taxtriage-2026-01-15T12-30-00",
                    in: context.url("Analyses", isDirectory: true),
                    samples: ["HG002"]
                )
                try metadata("taxtriage", isBatch: false, in: result)
                let path = context.render(result)
                return RoutingRowFixture(
                    item: try RoutingSafetyNetItems.scannedAnalysis(result),
                    expected: RoutingObservation(
                        viewports: ["TaxTriageResultViewController"],
                        mode: .metagenomics,
                        classifierContext: "\(path) samples=[HG002]",
                        native: ["taxTriage batch=\(path) selected=[HG002]"],
                        inspector: ["batchOperation=TaxTriage"],
                        provenance: "taxTriageResult \(path)"
                    )
                )
            },
            RoutingRow(family: .classifiers, name: "NAO-MGS result bundle", type: .naoMgsResult) { context in
                let (bundle, samples) = try await RoutingSafetyNetFixtures.naoMgsResult(
                    named: "naomgs-wastewater",
                    in: context.url("Imports", isDirectory: true)
                )
                let path = context.render(bundle)
                let item = try unwrapped(
                    SidebarProjectScanner.collectNaoMgsResults(in: bundle.deletingLastPathComponent()).first
                )
                return RoutingRowFixture(
                    item: RoutingSafetyNetItems.materialize(item),
                    expected: RoutingObservation(
                        viewports: ["NaoMgsResultViewController"],
                        mode: .metagenomics,
                        classifierContext: "\(path) samples=[\(naoMgsCanonicalSamples)]",
                        inspector: ["naoMgs=\(samples.sorted().first ?? "-")"],
                        provenance: "naoMgsResult \(path)"
                    )
                )
            },
            RoutingRow(family: .classifiers, name: "NVD result bundle", type: .nvdResult) { context in
                let (bundle, samples) = try await RoutingSafetyNetFixtures.nvdResult(
                    named: "nvd-demo",
                    in: context.url("Imports", isDirectory: true)
                )
                let path = context.render(bundle)
                let item = try unwrapped(
                    SidebarProjectScanner.collectNvdResults(in: bundle.deletingLastPathComponent()).first
                )
                return RoutingRowFixture(
                    item: RoutingSafetyNetItems.materialize(item),
                    expected: RoutingObservation(
                        viewports: ["NvdResultViewController"],
                        mode: .metagenomics,
                        classifierContext: "\(path) samples=[\(samples.sorted().joined(separator: ","))]",
                        inspector: ["nvd=\(RoutingSafetyNetTable.nvdExperiment)"],
                        provenance: "nvdResult \(path)"
                    )
                )
            },
            RoutingRow(family: .classifiers, name: "CZ ID taxonomy bundle", type: .czIdResult) { context in
                let bundle = try RoutingSafetyNetFixtures.czIdResult(
                    named: "cornea-czid.lungfishtax",
                    in: context.url("Imports", isDirectory: true)
                )
                return RoutingRowFixture(
                    item: RoutingSafetyNetItems.scanned(bundle),
                    expected: RoutingObservation(
                        viewports: ["CzIdResultViewController"],
                        mode: .metagenomics,
                        provenance: "czIdResult \(context.render(bundle))"
                    )
                )
            },
        ]
    }
}
