import AppKit
import SwiftUI
import LungfishCore
import LungfishIO

public struct GenotypeCandidateEvidenceSection: View {
    public static let visibilityLabels = [
        "Known",
        "Shared candidates (2+ samples)",
        "Singleton candidates (1 sample)",
    ]

    public static let tintLabels = [
        "Shared novel",
        "Singleton novel",
        "Shared extension",
        "Singleton extension",
    ]

    @Bindable private var viewModel: GenotypeResultDisplaySectionViewModel

    public init(viewModel: GenotypeResultDisplaySectionViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("Full-length MHC candidates")
                .font(.caption)
                .foregroundStyle(.secondary)

            if viewModel.mhcCandidateControlsAvailable {
                visibilityControls
                tintControls
            }

            ForEach(Array(viewModel.mhcCandidateIntegrityWarnings.enumerated()), id: \.offset) { _, warning in
                warningLabel(warning)
            }
            if let warning = viewModel.mhcCandidatePersistenceWarning {
                warningLabel(warning)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Full-length MHC candidate display controls")
    }

    private var visibilityControls: some View {
        VStack(alignment: .leading, spacing: 5) {
            Toggle(Self.visibilityLabels[0], isOn: Binding(
                get: { viewModel.mhcCandidateDisplaySettings.showKnown },
                set: { viewModel.setMHCCandidateVisibility(showKnown: $0) }
            ))
            Toggle(Self.visibilityLabels[1], isOn: Binding(
                get: { viewModel.mhcCandidateDisplaySettings.showSharedCandidates },
                set: { viewModel.setMHCCandidateVisibility(showSharedCandidates: $0) }
            ))
            Toggle(Self.visibilityLabels[2], isOn: Binding(
                get: { viewModel.mhcCandidateDisplaySettings.showSingletonCandidates },
                set: { viewModel.setMHCCandidateVisibility(showSingletonCandidates: $0) }
            ))
        }
        .toggleStyle(.checkbox)
        .controlSize(.small)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Candidate visibility")
    }

    private var tintControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            tintControl(.sharedNovel, label: Self.tintLabels[0])
            tintControl(.singletonNovel, label: Self.tintLabels[1])
            tintControl(.sharedExtension, label: Self.tintLabels[2])
            tintControl(.singletonExtension, label: Self.tintLabels[3])
            Button("Reset all candidate tints") {
                viewModel.resetAllMHCCandidateTints()
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Candidate allele-name tints")
    }

    private func tintControl(
        _ category: ONTMHCCandidateTintCategory,
        label: String
    ) -> some View {
        HStack(spacing: 6) {
            ColorPicker(label, selection: Binding(
                get: { swiftUIColor(viewModel.mhcCandidateDisplaySettings.tints[category]) },
                set: { color in
                    if let annotationColor = annotationColor(color) {
                        viewModel.setMHCCandidateTint(annotationColor, category: category)
                    }
                }
            ), supportsOpacity: true)
            Button("Reset") {
                viewModel.resetMHCCandidateTint(category)
            }
            .help("Reset \(label) to default")
            .accessibilityLabel("Reset \(label) to default")
        }
        .controlSize(.small)
    }

    private func warningLabel(_ warning: String) -> some View {
        Label(warning, systemImage: "exclamationmark.triangle")
            .font(.caption2)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("Candidate artifact warning: \(warning)")
    }

    private func swiftUIColor(_ color: AnnotationColor?) -> Color {
        let color = color ?? ONTMHCCandidateDisplaySettings.defaultTints[.sharedNovel]!
        return Color(red: color.red, green: color.green, blue: color.blue, opacity: color.alpha)
    }

    private func annotationColor(_ color: Color) -> AnnotationColor? {
        guard let converted = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        return AnnotationColor(
            red: converted.redComponent,
            green: converted.greenComponent,
            blue: converted.blueComponent,
            alpha: converted.alphaComponent
        )
    }
}

enum GenotypeCandidateEvidenceProjection {
    struct IndexedPresentation {
        let baseDetailRows: [(String, String)]
        let selectedSampleReadCounts: [String: Int]

        func detailRows(selectedSample: String?) -> [(String, String)] {
            guard let selectedSample,
                  let readCount = selectedSampleReadCounts[selectedSample] else {
                return baseDetailRows
            }
            return baseDetailRows + [
                ("Selected Sample", selectedSample),
                ("Selected Sample Reads", "\(readCount)"),
            ]
        }
    }

    static func indexedPresentations(
        document: ONTMHCCandidateAllelesDocument,
        artifacts: ONTMHCCandidateArtifactManifest
    ) -> [String: IndexedPresentation] {
        var sampleReadCountsByStableClusterID: [String: [String: Int]] = [:]
        var evidenceCountsByStableClusterID: [String: Int] = [:]
        sampleReadCountsByStableClusterID.reserveCapacity(document.candidates.count)
        evidenceCountsByStableClusterID.reserveCapacity(document.candidates.count)
        for observation in document.observations {
            sampleReadCountsByStableClusterID[observation.stableClusterID, default: [:]][observation.sampleID, default: 0]
                += observation.aggregatedSampleReadCount
            evidenceCountsByStableClusterID[observation.stableClusterID, default: 0]
                += observation.genotypingHitSummaries.isEmpty
                    ? observation.evidence.count
                    : observation.genotypingAlignmentCount
        }

        var presentations: [String: IndexedPresentation] = [:]
        presentations.reserveCapacity(document.candidates.count)
        for candidate in document.candidates {
            presentations[candidate.stableClusterID] = IndexedPresentation(
                baseDetailRows: detailRows(
                    candidate: candidate,
                    artifacts: artifacts,
                    genotypingEvidenceCount: evidenceCountsByStableClusterID[candidate.stableClusterID] ?? 0
                ),
                selectedSampleReadCounts: sampleReadCountsByStableClusterID[candidate.stableClusterID] ?? [:]
            )
        }
        return presentations
    }

    private static func detailRows(
        candidate: ONTMHCCandidateRecord,
        artifacts: ONTMHCCandidateArtifactManifest,
        genotypingEvidenceCount: Int
    ) -> [(String, String)] {
        var rows: [(String, String)] = [
            ("Stable Cluster ID", candidate.stableClusterID),
            ("Provisional Name", candidate.provisionalName),
            ("Locus", candidate.locus),
            ("Classification", candidate.classification == .novel ? "Novel" : "Extension"),
            ("Support Class", candidate.supportClass == .shared ? "Shared (2+ samples)" : "Singleton (1 sample)"),
            ("Independent Samples", "\(candidate.independentSampleCount)"),
            ("Occurrence Count", "\(candidate.occurrenceCount)"),
            ("Total Cluster Reads", "\(candidate.totalClusterReads)"),
            ("Supporting Sample IDs", candidate.supportingSampleIDs.sorted().joined(separator: ", ")),
        ]
        rows += [
            ("Closest Reference", candidate.closestReferenceName),
            ("Closest Reference Class", candidate.closestReferenceClass == .cDNA ? "cDNA" : "Genomic DNA"),
            ("SNP Substitutions", "\(candidate.snpCount)"),
            ("Inserted Bases", "\(candidate.insertedBases)"),
            ("Deleted Bases", "\(candidate.deletedBases)"),
            ("Long-gap Bases", "\(candidate.longGapBases)"),
            ("Comparable Bases", "\(candidate.comparableBases)"),
            ("Shorter-sequence Coverage", decimal(candidate.shorterCoverage)),
            ("Identity", decimal(candidate.identity)),
            ("MAPQ", "\(candidate.mappingQuality)"),
            ("Alignment Score (AS)", "\(candidate.alignmentScore)"),
            ("FASTA Record ID", candidate.fastaRecordID),
            ("Sequence SHA-256", candidate.sequenceSHA256),
        ]
        appendArtifact("Candidate FASTA", artifacts.candidateFASTA, to: &rows)
        appendArtifact("Un-nameable FASTA", artifacts.unnameableFASTA, to: &rows)
        appendArtifact("Genotyping BAM", artifacts.genotypingEvidence?.bam, to: &rows)
        appendArtifact("Genotyping BAI", artifacts.genotypingEvidence?.bai, to: &rows)
        appendArtifact("Reciprocal BAM", artifacts.reciprocalEvidence?.bam, to: &rows)
        appendArtifact("Reciprocal BAI", artifacts.reciprocalEvidence?.bai, to: &rows)
        appendAlignment("Selected Alignment", candidate.selectedEvidence, to: &rows)
        if genotypingEvidenceCount > 0 {
            let noun = genotypingEvidenceCount == 1 ? "alignment" : "alignments"
            rows.append((
                "Genotyping Evidence",
                "\(genotypingEvidenceCount.formatted(.number)) \(noun) in indexed BAM"
            ))
        }
        return rows
    }

    static func warningText(_ warnings: [ONTGenotypeIntegrityWarning]) -> String {
        warnings.map { warning in
            let path = warning.path.map { " [\($0)]" } ?? ""
            return "\(warning.code.rawValue): \(warning.detail)\(path)"
        }.joined(separator: "\n")
    }

    private static func appendArtifact(
        _ label: String,
        _ artifact: ONTMHCArtifactReference?,
        to rows: inout [(String, String)]
    ) {
        guard let artifact else { return }
        rows.append(("\(label) Path", artifact.path))
        rows.append(("\(label) SHA-256", artifact.sha256))
    }

    private static func appendAlignment(
        _ label: String,
        _ evidence: ONTMHCEvidenceLocator,
        to rows: inout [(String, String)]
    ) {
        rows.append(("\(label) BAM", evidence.bamPath))
        rows.append(("\(label) Query", evidence.queryName))
        rows.append(("\(label) Reference", evidence.referenceName))
        rows.append(("\(label) Read Group", evidence.readGroupID ?? "Unavailable"))
        rows.append(("\(label) Start", "\(evidence.referenceStart)"))
        rows.append(("\(label) CIGAR", evidence.cigar))
    }

    private static func decimal(_ value: Double) -> String {
        String(format: "%.6f", value)
    }
}
