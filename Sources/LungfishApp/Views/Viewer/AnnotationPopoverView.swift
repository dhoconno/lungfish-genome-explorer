// AnnotationPopoverView.swift - SwiftUI popover for annotation details
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI
import LungfishCore

// MARK: - Annotation Popover View

/// SwiftUI view for displaying annotation details in a popover.
struct AnnotationPopoverView: View {
    let annotation: SequenceAnnotation

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header with name and type
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(annotation.name)
                        .font(.headline)

                    Text(annotationTypeName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Type color indicator
                Circle()
                    .fill(colorForAnnotation)
                    .frame(width: 16, height: 16)
            }

            Divider()

            // Location info
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("Location", value: "\(annotation.start)–\(annotation.end)")
                LabeledContent("Length", value: "\(annotation.totalLength) bp")

                if annotation.isDiscontinuous {
                    LabeledContent("Intervals", value: "\(annotation.intervals.count) segments")
                }

                if annotation.strand != .unknown {
                    LabeledContent("Strand", value: annotation.strand == .forward ? "Forward (+)" : "Reverse (−)")
                }
            }
            .font(.callout)

            // Notes if present
            if let note = annotation.note, !note.isEmpty {
                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text("Notes")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(note)
                        .font(.caption)
                        .lineLimit(4)
                }
            }
        }
        .padding()
        .frame(width: 260)
    }

    private var colorForAnnotation: Color {
        let annotationColor = annotation.color ?? annotation.type.defaultColor
        return Color(
            red: annotationColor.red,
            green: annotationColor.green,
            blue: annotationColor.blue,
            opacity: annotationColor.alpha
        )
    }

    /// Human-readable name for annotation type
    private var annotationTypeName: String {
        switch annotation.type {
        case .gene: return "Gene"
        case .mRNA: return "mRNA"
        case .transcript: return "Transcript"
        case .exon: return "Exon"
        case .intron: return "Intron"
        case .cds: return "CDS"
        case .utr5: return "5' UTR"
        case .utr3: return "3' UTR"
        case .promoter: return "Promoter"
        case .enhancer: return "Enhancer"
        case .silencer: return "Silencer"
        case .terminator: return "Terminator"
        case .polyASignal: return "PolyA Signal"
        case .regulatory: return "Regulatory"
        case .ncRNA: return "ncRNA"
        case .tRNA: return "tRNA"
        case .rRNA: return "rRNA"
        case .pseudogene: return "Pseudogene"
        case .mobileElement: return "Mobile Element"
        case .primer: return "Primer"
        case .primerPair: return "Primer Pair"
        case .amplicon: return "Amplicon"
        case .restrictionSite: return "Restriction Site"
        case .snp: return "SNP"
        case .variation: return "Variation"
        case .insertion: return "Insertion"
        case .deletion: return "Deletion"
        case .repeatRegion: return "Repeat Region"
        case .stem_loop: return "Stem Loop"
        case .misc_feature: return "Misc Feature"
        case .mat_peptide: return "Mature Peptide"
        case .sig_peptide: return "Signal Peptide"
        case .transit_peptide: return "Transit Peptide"
        case .misc_binding: return "Misc Binding"
        case .protein_bind: return "Protein Binding"
        case .contig: return "Contig"
        case .gap: return "Gap"
        case .scaffold: return "Scaffold"
        case .region: return "Region"
        case .source: return "Source"
        case .custom: return "Custom"
        case .barcode5p: return "Barcode (5')"
        case .barcode3p: return "Barcode (3')"
        case .adapter5p: return "Adapter (5')"
        case .adapter3p: return "Adapter (3')"
        case .primer5p: return "Primer (5')"
        case .primer3p: return "Primer (3')"
        case .trimQuality: return "Quality Trim"
        case .trimFixed: return "Fixed Trim"
        case .orientMarker: return "Orientation"
        case .umiRegion: return "UMI"
        case .contaminantMatch: return "Contaminant"
        }
    }
}
