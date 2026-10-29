// ViewSwitchKinds.swift - The viewport kinds of the view-switch matrix, one routing row each
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// A kind is one outcome of the routing table: one installed child class of
// the viewer, or for a viewer with no child one way of showing nothing (a
// Quick Look preview, a genomics document or a status line), in its content
// mode. Each kind names one representative row of RoutingSafetyNetTable, and
// the view-switch matrix builds that row's fixture once and switches between
// every ordered pair of kinds in one window.
//
// The routing table checks that every row's outcome is a kind here, so a row
// that opens a new viewport fails until its kind joins the matrix (ARCH reading
// of 2026-10-28, change 14). Lane SMOKE copies this list for the packaged
// view-switch test in Tests/LungfishXCUITests.

import Foundation
@testable import LungfishApp

/// One viewport kind and the routing row that opens it.
struct ViewSwitchKind: Hashable, Sendable, CustomStringConvertible {
    /// A short name for failure messages and the declared-leak table.
    let name: String
    /// The outcome every row of this kind settles on, as ``ViewSwitchKinds/outcome(of:)`` writes it.
    let outcome: String
    /// The `family/name` label of the representative routing row.
    let row: String
    /// The folder the fixture is built in under the matrix's scratch root.
    let folder: String
    /// The Provenance target a window records for this kind and its window-less
    /// routing row does not, which ``ViewSwitchReading/alone(_:kind:)`` copies.
    /// The primer routes set their own target in a window
    /// (`InspectorViewController+PrimerAnalysis.swift:30`, `:63`, `:96`).
    var windowProvenance: String?

    var description: String { name }
}

@MainActor
enum ViewSwitchKinds {
    /// Every kind, in the order the switch walk starts from.
    static let all: [ViewSwitchKind] = [
        kind("Kraken2", "TaxonomyViewController in metagenomics", "classifiers/Kraken2 result", "k01-kraken2"),
        kind("EsViritu", "EsVirituResultViewController in metagenomics", "classifiers/EsViritu result", "k02-esviritu"),
        kind("TaxTriage", "TaxTriageResultViewController in metagenomics", "classifiers/TaxTriage result", "k03-taxtriage"),
        kind("NAO-MGS", "NaoMgsResultViewController in metagenomics", "classifiers/NAO-MGS result bundle", "k04-naomgs"),
        kind("NVD", "NvdResultViewController in metagenomics", "classifiers/NVD result bundle", "k05-nvd"),
        kind("CZ ID", "CzIdResultViewController in metagenomics", "classifiers/CZ ID taxonomy bundle", "k06-czid"),
        kind("12S", "TwelveSAmpliconResultViewController in metagenomics", "bundles/12S amplicon result", "k07-twelves"),
        kind(
            "Reference", "ReferenceBundleViewportController in mapping",
            "bundles/SARS-CoV-2 reference bundle with published tracks", "k08-reference"
        ),
        kind("Assembly", "AssemblyResultViewController in assembly", "analyses/SPAdes assembly", "k09-assembly"),
        kind("FASTQ", "FASTQDatasetViewController in fastq", "bundles/FASTQ bundle with cached statistics", "k10-fastq"),
        kind("Genotype", "GenotypeResultViewController in genotype", "bundles/genotype result with calls", "k11-genotype"),
        kind(
            "MHC reference", "NSHostingController<MHCReferenceBundleViewport> in genomics",
            "bundles/MHC amplicon reference bundle", "k12-mhc"
        ),
        kind(
            "MSA", "MultipleSequenceAlignmentViewController in genomics",
            "bundles/multiple sequence alignment bundle", "k13-msa"
        ),
        kind("Tree", "PhylogeneticTreeViewController in genomics", "bundles/phylogenetic tree bundle", "k14-tree"),
        kind(
            "Primer analysis", "PrimerAnalysisHostingController in empty", "bundles/saved primer analysis", "k15-primer",
            windowProvenance: "primerAnalysisBundle Primer Designs/Mamu-A1 assay.lungfishprimeranalysis"
        ),
        kind(
            "Primer order", "PrimerOrderHostingController in empty", "analyses/reviewed primer order", "k16-order",
            windowProvenance: "primerAnalysisBundle Analyses/primer-order-2026-01-15T18-00-00"
        ),
        kind("FASTA document", "document in genomics", "files/FASTA file", "k17-fasta"),
        // A recorded preview draws no view, so the next route never clears its
        // URL. The text preview is drawn for real and removed as in the app.
        kind("Quick Look", "Quick Look in empty", "files/Nextflow script previews as text", "k18-quicklook"),
        kind("Status only", "status in empty", "bundles/primer scheme, metadata only", "k19-status"),
    ]

    private static func kind(
        _ name: String, _ outcome: String, _ row: String, _ folder: String, windowProvenance: String? = nil
    ) -> ViewSwitchKind {
        ViewSwitchKind(name: name, outcome: outcome, row: row, folder: folder, windowProvenance: windowProvenance)
    }

    /// The kind of a routed outcome: the installed child classes, or how a
    /// viewer with no child shows nothing, and the content mode.
    static func outcome(of observation: RoutingObservation) -> String {
        let shown: String
        if !observation.viewports.isEmpty {
            shown = observation.viewports.joined(separator: " + ")
        } else if observation.quickLook != nil {
            shown = "Quick Look"
        } else if observation.document != nil {
            shown = "document"
        } else {
            shown = "status"
        }
        return "\(shown) in \(observation.mode.rawValue)"
    }

    /// The kind whose outcome this is, or nil when the matrix has no entry for it.
    static func kind(of observation: RoutingObservation) -> ViewSwitchKind? {
        let outcome = outcome(of: observation)
        return all.first { $0.outcome == outcome }
    }

    /// The `family/name` label a routing row is known by.
    static func label(of row: RoutingRow) -> String {
        "\(row.family.rawValue)/\(row.name)"
    }

    /// The representative routing row of a kind.
    static func row(of kind: ViewSwitchKind) -> RoutingRow? {
        RoutingSafetyNetTable.rows.first { label(of: $0) == kind.row }
    }

    /// A walk of kind indices that starts at 0 and takes every ordered pair of
    /// two different kinds exactly once, an Euler circuit of the complete
    /// directed graph (Hierholzer's algorithm). Each kind has as many ways in
    /// as out, so the circuit exists, and it holds n(n-1) switches.
    static func eulerCircuit(count: Int) -> [Int] {
        guard count > 1 else { return Array(0..<count) }
        var used = Array(repeating: 0, count: count)
        var stack = [0]
        var circuit: [Int] = []
        while let vertex = stack.last {
            if used[vertex] < count - 1 {
                let next = (vertex + 1 + used[vertex]) % count
                used[vertex] += 1
                stack.append(next)
            } else {
                circuit.append(stack.removeLast())
            }
        }
        return circuit.reversed()
    }
}
