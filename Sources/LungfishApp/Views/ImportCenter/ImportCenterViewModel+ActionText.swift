// ImportCenterViewModel+ActionText.swift - The Import Center's Linux cards and the words of each import action
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import UniformTypeIdentifiers

extension ImportCenterViewModel {
    /// The cards of a run on a Linux machine or cluster, on the Sequencing Reads tab (CHTC C4 lane U): the plan sheet
    /// and the adopt of a returned plan folder.
    static let linuxRunCards: [ImportCardInfo] = [
        ImportCardInfo(
            id: "fastq-linux-plan",
            title: "Plan for a Linux Machine",
            description: "Write the files that pre-process FASTQ reads on a Linux machine or cluster, with HTCondor's sample.sub and run.dag. Nothing is imported.",
            sfSymbol: "doc.badge.gearshape",
            fileHint: ".fastq.gz, .fq.gz, .fastq, .fq (files or one folder)",
            tab: .sequencingReads,
            importKind: .openPanel(
                configuration: .init(
                    allowedTypes: [
                        UTType(filenameExtension: "gz") ?? .data,
                        UTType(filenameExtension: "fastq") ?? .data,
                        UTType(filenameExtension: "fq") ?? .data,
                        .folder,
                    ],
                    canChooseFiles: true,
                    canChooseDirectories: true,
                    allowsMultipleSelection: true
                ),
                action: .fastqLinuxPlan
            )
        ),
        ImportCardInfo(
            id: "linux-run-result",
            title: "Linux Run Result",
            description: "Import a plan folder that a run on a Linux machine or cluster returned, as one FASTQ bundle with the run's record.",
            sfSymbol: "arrow.down.doc",
            fileHint: "a returned plan folder with plan.json and run-record.json",
            tab: .sequencingReads,
            importKind: .openPanel(
                configuration: .init(
                    allowedTypes: [.folder],
                    canChooseFiles: false,
                    canChooseDirectories: true,
                    allowsMultipleSelection: false
                ),
                action: .linuxRunResult
            )
        ),
    ]

    func panelMessage(for action: ImportCardInfo.ImportAction) -> String {
        switch action {
        case .fastq:    return "Select FASTQ files or folders to import"
        case .fastqSampleSheet: return "Select a FASTQ sample sheet CSV to import"
        case .fastqLinuxPlan: return "Select the FASTQ files, or one folder of them, to plan for a Linux machine"
        case .linuxRunResult: return "Select a plan folder that a Linux run returned"
        case .ontRun:   return "Select an ONT output directory to import"
        case .bam:      return "Select BAM or CRAM alignment files to import"
        case .vcf:      return "Select VCF variant files to import"
        case .fasta:    return "Select standalone reference sequence files (.fa/.fasta/.gb/.embl, optionally .gz) to import"
        case .annotationTrack: return "Select GTF, GFF, GFF3, or BED annotation files to attach to a reference bundle"
        case .multipleSequenceAlignment: return "Select multiple sequence alignment files to import"
        case .phylogeneticTree: return "Select phylogenetic tree files to import"
        case .geneiousExport: return "Select a Geneious archive or export folder to import"
        case .clcWorkbenchExport: return "Select a CLC Workbench export folder, archive, or native project file"
        case .dnastarLasergeneExport: return "Select a DNASTAR Lasergene or GenVision export folder or file"
        case .benchlingBulkExport: return "Select a Benchling bulk export archive, folder, or standard exported file"
        case .sequenceDesignLibraryExport: return "Select a sequence design library export folder, archive, or file"
        case .alignmentTreeExport: return "Select an alignment or phylogenetic tree export"
        case .sequencingPlatformRunFolder: return "Select a sequencing platform run folder or downloaded analysis export"
        case .phylogeneticsResultSet: return "Select a phylogenetics result folder, archive, or file"
        case .qiime2Archive: return "Select a QIIME 2 archive or exported folder"
        case .igvSessionTrackSet: return "Select an IGV session file or local track-set folder"
        case .kraken2:  return "Select Kraken2 report files to import"
        case .esViritu: return "Select EsViritu result files or directory"
        case .taxTriage: return "Select TaxTriage result files or directory"
        case .naoMgs:   return "Select NAO-MGS results"
        case .nvd:      return "Select NVD results directory"
        case .czId:     return "Select CZ-ID report, ZIP archive, or extracted folder"
        case .primerScheme: return "Primer scheme import runs via the wizard sheet"
        }
    }

    /// Returns the human-readable label stored in ``ImportHistoryEntry/importAction``
    /// for a given ``ImportCardInfo/ImportAction``.
    func historyLabel(for action: ImportCardInfo.ImportAction) -> String {
        switch action {
        case .fastq:    return "FASTQ"
        case .fastqSampleSheet: return "FASTQ Sample Sheet"
        case .fastqLinuxPlan: return "Linux Plan"
        case .linuxRunResult: return "Linux Run Result"
        case .ontRun:   return "ONT Run"
        case .bam:      return "BAM"
        case .vcf:      return "VCF"
        case .fasta:    return "FASTA"
        case .annotationTrack: return "Annotation Track"
        case .multipleSequenceAlignment: return "MSA"
        case .phylogeneticTree: return "Phylogenetic Tree"
        case .geneiousExport: return "Geneious"
        case .clcWorkbenchExport: return "CLC Workbench"
        case .dnastarLasergeneExport: return "DNASTAR Lasergene"
        case .benchlingBulkExport: return "Benchling Bulk"
        case .sequenceDesignLibraryExport: return "Sequence Library"
        case .alignmentTreeExport: return "Alignment Tree"
        case .sequencingPlatformRunFolder: return "Sequencing Run"
        case .phylogeneticsResultSet: return "Phylogenetics"
        case .qiime2Archive: return "QIIME 2"
        case .igvSessionTrackSet: return "IGV Session"
        case .naoMgs:   return "NAO-MGS"
        case .kraken2:  return "Kraken2"
        case .esViritu: return "EsViritu"
        case .taxTriage: return "TaxTriage"
        case .nvd:      return "NVD"
        case .czId:     return "CZ-ID"
        case .primerScheme: return "Primer Scheme"
        }
    }
}
