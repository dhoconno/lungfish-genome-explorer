// RoutingSafetyNetTable+ContainerAndFileRows.swift - Container, batch group and file rows
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Rows for containers, batch groups and loose files. See RoutingSafetyNetTable.swift.

import AppKit
import Foundation
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow

extension RoutingSafetyNetTable {
    // MARK: Containers and batch groups

    static var containerRows: [RoutingRow] {
        [
            RoutingRow(family: .containers, name: "group header", type: .group) { _ in
                // A container opens no viewport. It is only a heading.
                RoutingRowFixture(item: SidebarItem(title: "Analyses", type: .group), expected: nothing())
            },
            RoutingRow(family: .containers, name: "folder", type: .folder) { context in
                let folder = try SafetyNetFiles.makeDirectory(context.url("Imports", isDirectory: true))
                return RoutingRowFixture(item: RoutingSafetyNetItems.scanned(folder), expected: nothing())
            },
            RoutingRow(family: .containers, name: "project root", type: .project) { context in
                let project = try SafetyNetFiles.makeDirectory(context.url("Safety.lungfish", isDirectory: true))
                return RoutingRowFixture(
                    item: RoutingSafetyNetItems.scanned(project, isRoot: true),
                    expected: nothing()
                )
            },
            RoutingRow(family: .containers, name: "FASTQ batch operation without a folder", type: .batchGroup) { _ in
                // Batch operation rows built from batch-operations.json carry no
                // URL, so there is nothing to route.
                let item = SidebarItem(title: "Quality trim", type: .batchGroup, subtitle: "2 processed")
                return RoutingRowFixture(item: item, expected: nothing())
            },
            RoutingRow(family: .containers, name: "Kraken2 batch", type: .batchGroup) { context in
                let batch = try RoutingSafetyNetFixtures.kraken2Result(
                    named: "kraken2-batch-2026-01-15T15-00-00",
                    in: context.url("Analyses", isDirectory: true),
                    samples: ["HG002", "MMU-17"],
                    sampleSubdirectories: true
                )
                try metadata("kraken2", isBatch: true, in: batch)
                try writeSampleSidecars("classification-result.json", in: batch, samples: ["HG002", "MMU-17"])
                let path = context.render(batch)
                return RoutingRowFixture(
                    item: try RoutingSafetyNetItems.scannedAnalysis(batch),
                    expected: RoutingObservation(
                        viewports: ["TaxonomyViewController"],
                        mode: .metagenomics,
                        classifierContext: "\(path) samples=[HG002,MMU-17]",
                        native: ["taxonomy batch=\(path) selected=[HG002,MMU-17]"],
                        provenance: "classificationResult \(path)"
                    )
                )
            },
            RoutingRow(family: .containers, name: "EsViritu batch", type: .batchGroup) { context in
                let batch = try RoutingSafetyNetFixtures.esVirituResult(
                    named: "esviritu-batch-2026-01-15T15-10-00",
                    in: context.url("Analyses", isDirectory: true),
                    samples: ["HG002", "MMU-17"]
                )
                try metadata("esviritu", isBatch: true, in: batch)
                try writeSampleSidecars("esviritu-result.json", in: batch, samples: ["HG002", "MMU-17"])
                let path = context.render(batch)
                return RoutingRowFixture(
                    item: try RoutingSafetyNetItems.scannedAnalysis(batch),
                    expected: RoutingObservation(
                        viewports: ["EsVirituResultViewController"],
                        mode: .metagenomics,
                        classifierContext: "\(path) samples=[HG002,MMU-17]",
                        native: ["esViritu batch=\(path) selected=[HG002,MMU-17]"],
                        provenance: "esvirituResult \(path)"
                    )
                )
            },
            RoutingRow(family: .containers, name: "TaxTriage batch", type: .batchGroup) { context in
                let batch = try RoutingSafetyNetFixtures.taxTriageResult(
                    named: "taxtriage-batch-2026-01-15T15-20-00",
                    in: context.url("Analyses", isDirectory: true),
                    samples: ["HG002", "MMU-17"]
                )
                try metadata("taxtriage", isBatch: true, in: batch)
                try writeSampleSidecars("taxtriage-result.json", in: batch, samples: ["HG002", "MMU-17"])
                let path = context.render(batch)
                return RoutingRowFixture(
                    item: try RoutingSafetyNetItems.scannedAnalysis(batch),
                    expected: RoutingObservation(
                        viewports: ["TaxTriageResultViewController"],
                        mode: .metagenomics,
                        classifierContext: "\(path) samples=[HG002,MMU-17]",
                        native: ["taxTriage batch=\(path) selected=[HG002,MMU-17]"],
                        inspector: ["batchOperation=TaxTriage"],
                        provenance: "taxTriageResult \(path)"
                    )
                )
            },
            RoutingRow(family: .containers, name: "NAO-MGS batch", type: .batchGroup) { context in
                let (batch, samples) = try await RoutingSafetyNetFixtures.naoMgsResult(
                    named: "naomgs-batch-2026-01-15T15-30-00",
                    in: context.url("Analyses", isDirectory: true)
                )
                try metadata("naomgs", isBatch: true, in: batch)
                let path = context.render(batch)
                return RoutingRowFixture(
                    item: try RoutingSafetyNetItems.scannedAnalysis(batch),
                    expected: RoutingObservation(
                        viewports: ["NaoMgsResultViewController"],
                        mode: .metagenomics,
                        classifierContext: "\(path) samples=[\(naoMgsCanonicalSamples)]",
                        inspector: ["naoMgs=\(samples.sorted().first ?? "-")"],
                        provenance: "naoMgsResult \(path)"
                    )
                )
            },
            RoutingRow(family: .containers, name: "minimap2 batch root", type: .batchGroup) { context in
                let batch = try SafetyNetFiles.makeDirectory(
                    context.url("Analyses/minimap2-batch-2026-01-15T16-30-00", isDirectory: true)
                )
                try metadata("minimap2", isBatch: true, in: batch)
                try SafetyNetFiles.makeDirectory(batch.appendingPathComponent("HG002", isDirectory: true))
                let path = context.render(batch)
                return RoutingRowFixture(
                    item: try RoutingSafetyNetItems.scannedAnalysis(batch),
                    expected: RoutingObservation(
                        status: "Unable to load mapping result.",
                        provenance: "analysisResult \(path)"
                    )
                )
            },
            RoutingRow(family: .containers, name: "SPAdes batch root", type: .batchGroup) { context in
                let batch = try SafetyNetFiles.makeDirectory(
                    context.url("Analyses/spades-batch-2026-01-15T16-40-00", isDirectory: true)
                )
                try metadata("spades", isBatch: true, in: batch)
                try SafetyNetFiles.makeDirectory(batch.appendingPathComponent("HG002", isDirectory: true))
                let path = context.render(batch)
                return RoutingRowFixture(
                    item: try RoutingSafetyNetItems.scannedAnalysis(batch),
                    expected: RoutingObservation(
                        status: "Unable to load assembly result.",
                        provenance: "analysisResult \(path)"
                    )
                )
            },
            RoutingRow(family: .containers, name: "Viral Recon batch root", type: .batchGroup) { context in
                let ingested = try RoutingSafetyNetFixtures.viralReconAnalyses(
                    projectURL: context.url("Project", isDirectory: true),
                    scratch: context.url("viralrecon-scratch", isDirectory: true),
                    sampleNames: ["SRR36291587", "SRR36291588"]
                )
                let batch = ingested[0].bundleDirectory.deletingLastPathComponent()
                let item = try RoutingSafetyNetItems.scannedAnalysis(batch)
                return RoutingRowFixture(
                    item: item,
                    expected: RoutingObservation(
                        status: "Select a sample to view its Viral Recon results.",
                        provenance: "analysisResult \(context.render(batch))"
                    )
                )
            },
            RoutingRow(family: .containers, name: "Savont batch root", type: .batchGroup) { context in
                let (batch, fasta) = try RoutingSafetyNetFixtures.savontBatch(
                    in: context.url("Analyses", isDirectory: true)
                )
                let item = try RoutingSafetyNetItems.scannedAnalysis(batch)
                return RoutingRowFixture(
                    item: item,
                    expected: RoutingObservation(
                        mode: .genomics,
                        document: context.render(fasta),
                        loaded: [context.render(fasta)],
                        provenance: "sequence \(context.render(fasta))"
                    )
                )
            },
            RoutingRow(family: .containers, name: "pbAA batch root, a tool with no viewer", type: .batchGroup) { context in
                let batch = try SafetyNetFiles.makeDirectory(
                    context.url("Analyses/pbaa-batch-2026-01-15T20-30-00", isDirectory: true)
                )
                try metadata("pbaa", isBatch: true, in: batch)
                try SafetyNetFiles.makeDirectory(batch.appendingPathComponent("HG002", isDirectory: true))
                let item = try RoutingSafetyNetItems.scannedAnalysis(batch)
                return RoutingRowFixture(
                    item: item,
                    expected: RoutingObservation(
                        status: "No sequence loaded",
                        provenance: "analysisResult \(context.render(batch))"
                    )
                )
            },
        ]
    }

    // MARK: Files

    static var fileRows: [RoutingRow] {
        [
            RoutingRow(family: .files, name: "FASTA file", type: .sequence) { context in
                let fasta = try SafetyNetFiles.copy(
                    RoutingSafetyNetFixtures.sarsCoV2.appendingPathComponent("genome.fasta"),
                    to: context.url("Inputs/MT192765.1.fasta")
                )
                return RoutingRowFixture(
                    item: RoutingSafetyNetItems.scanned(fasta),
                    expected: RoutingObservation(
                        mode: .genomics,
                        document: "Inputs/MT192765.1.fasta",
                        loaded: ["Inputs/MT192765.1.fasta"],
                        provenance: "sequence Inputs/MT192765.1.fasta"
                    )
                )
            },
            RoutingRow(family: .files, name: "sequence row whose document left the window", type: .sequence) { _ in
                RoutingRowFixture(
                    item: SidebarItem(title: "MT192765.1", type: .sequence),
                    expected: nothing(status: "This document is no longer available in this window.")
                )
            },
            RoutingRow(family: .files, name: "GFF3 file", type: .annotation) { context in
                let gff = try SafetyNetFiles.copy(
                    RoutingSafetyNetFixtures.sarsCoV2.appendingPathComponent("genome.gff3"),
                    to: context.url("Inputs/genome.gff3")
                )
                return RoutingRowFixture(
                    item: RoutingSafetyNetItems.scanned(gff),
                    expected: RoutingObservation(
                        mode: .genomics,
                        document: "Inputs/genome.gff3",
                        loaded: ["Inputs/genome.gff3"],
                        provenance: "annotation Inputs/genome.gff3"
                    )
                )
            },
            RoutingRow(family: .files, name: "VCF file goes to the VCF import, never the loader", type: .annotation) { context in
                // Without an open project the VCF import stops before its naming
                // prompt, so the row shows that a VCF never reaches the loader.
                let vcf = try SafetyNetFiles.copy(
                    RoutingSafetyNetFixtures.sarsCoV2.appendingPathComponent("test.vcf"),
                    to: context.url("Inputs/test.vcf")
                )
                return RoutingRowFixture(item: RoutingSafetyNetItems.scanned(vcf), expected: nothing())
            },
            RoutingRow(family: .files, name: "loose BAM is refused", type: .alignment) { context in
                let bam = try SafetyNetFiles.copy(
                    RoutingSafetyNetFixtures.sarsCoV2.appendingPathComponent("test.paired_end.sorted.bam"),
                    to: context.url("Inputs/test.paired_end.sorted.bam")
                )
                try SafetyNetFiles.copy(
                    RoutingSafetyNetFixtures.sarsCoV2.appendingPathComponent("test.paired_end.sorted.bam.bai"),
                    to: context.url("Inputs/test.paired_end.sorted.bam.bai")
                )
                return RoutingRowFixture(
                    item: RoutingSafetyNetItems.scanned(bam),
                    expected: RoutingObservation(
                        status: "Unable to load test.paired_end.sorted.bam: Unsupported file format: BAM/CRAM files are imported as alignment tracks. Use File › Import Center… with a bundle open.",
                        loaded: ["Inputs/test.paired_end.sorted.bam"]
                    )
                )
            },
            RoutingRow(family: .files, name: "ONT genotyping BAM opens its prepared bundle", type: .alignment) { context in
                let directory = context.url("Genotyping", isDirectory: true)
                let bam = try SafetyNetFiles.copy(
                    RoutingSafetyNetFixtures.sarsCoV2.appendingPathComponent("test.paired_end.sorted.bam"),
                    to: directory.appendingPathComponent("DW472.md.sorted.bam")
                )
                try RoutingSafetyNetFixtures.sarsCoV2ReferenceBundle(
                    named: "DW472.mapped",
                    in: directory,
                    publishTracks: true
                )
                return RoutingRowFixture(
                    item: RoutingSafetyNetItems.scanned(bam),
                    expected: RoutingObservation(
                        viewports: ["ReferenceBundleViewportController"],
                        mode: .mapping,
                        reference: "directBundle bundle=Genotyping/DW472.mapped.lungfishref \(RoutingSafetyNetTable.publishedSARSTracks)",
                        bamContext: "Genotyping/DW472.mapped.lungfishref samples=[sample]",
                        inspector: ["bundle=Genotyping/DW472.mapped.lungfishref"],
                        provenance: "referenceBundle Genotyping/DW472.mapped.lungfishref"
                    )
                )
            },
            RoutingRow(family: .files, name: "bigWig coverage file is refused", type: .coverage) { context in
                let bigWig = try SafetyNetFiles.copy(
                    SafetyNetPaths.testData("TestGenome.lungfishref/tracks/gc_content.bw"),
                    to: context.url("Inputs/gc_content.bw")
                )
                return RoutingRowFixture(
                    item: RoutingSafetyNetItems.scanned(bigWig),
                    expected: RoutingObservation(
                        status: "Unable to load gc_content.bw: Unsupported file format: bw",
                        loaded: ["Inputs/gc_content.bw"]
                    )
                )
            },
            RoutingRow(family: .files, name: "Markdown notes", type: .document) { context in
                let notes = try SafetyNetFiles.write(
                    "# Sample sheet notes\n\nHG002 and MMU-17 were sequenced together.\n",
                    to: context.url("Inputs/notes.md")
                )
                return RoutingRowFixture(
                    item: RoutingSafetyNetItems.scanned(notes),
                    expected: RoutingObservation(status: "Previewing: notes.md", quickLook: "Inputs/notes.md")
                )
            },
            RoutingRow(family: .files, name: "PNG image", type: .image) { context in
                let image = try RoutingSafetyNetFixtures.pngImage(
                    named: "coverage.png",
                    in: context.url("Inputs", isDirectory: true)
                )
                return RoutingRowFixture(
                    item: RoutingSafetyNetItems.scanned(image),
                    expected: RoutingObservation(status: "Previewing: coverage.png", quickLook: "Inputs/coverage.png")
                )
            },
            RoutingRow(family: .files, name: "file of unknown type", type: .unknown) { context in
                let log = try SafetyNetFiles.write(
                    "spades finished\n",
                    to: context.url("Inputs/spades.log")
                )
                return RoutingRowFixture(
                    item: RoutingSafetyNetItems.scanned(log),
                    expected: RoutingObservation(status: "Previewing: spades.log", quickLook: "Inputs/spades.log")
                )
            },
            RoutingRow(family: .files, name: "Lungfish package with no viewer", type: .document) { context in
                // A .lungfishtax folder without its CZ ID manifest is shown as an
                // opaque package and previewed, never walked as a folder.
                let package = try SafetyNetFiles.makeDirectory(
                    context.url("Inputs/legacy-import.lungfishtax", isDirectory: true)
                )
                try SafetyNetFiles.write("taxon\treads\n", to: package.appendingPathComponent("report.tsv"))
                return RoutingRowFixture(
                    item: RoutingSafetyNetItems.scanned(package),
                    expected: RoutingObservation(
                        status: "Previewing: legacy-import.lungfishtax",
                        quickLook: "Inputs/legacy-import.lungfishtax"
                    )
                )
            },
        ]
    }
}
