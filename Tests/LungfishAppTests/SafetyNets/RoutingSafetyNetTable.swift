// RoutingSafetyNetTable.swift - One row per routed sidebar kind
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Each row builds a fixture under its own scratch root, names the sidebar row
// the app would show for it and states the full settled outcome of selecting
// that row. Rows build their sidebar items with the real scanner wherever the
// scanner produces the row, so the item type and the routing keys in
// `userInfo` are the ones the app hands to `displayContent(for:)`.
//
// Expected paths are relative to the row's scratch root. A row whose outcome
// changes on purpose is updated in the same commit as the change. The rows
// live in three extension files named after their families.

import AppKit
import Foundation
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow

/// A scratch root and its path renderer, handed to every row builder.
struct RoutingRowContext {
    let root: URL
    let paths: SafetyNetPathRenderer

    func url(_ relativePath: String, isDirectory: Bool = false) -> URL {
        root.appendingPathComponent(relativePath, isDirectory: isDirectory)
    }

    func render(_ url: URL?) -> String {
        paths.render(url) ?? "-"
    }
}

/// What a row hands to the router, and what the router must leave behind.
struct RoutingRowFixture {
    let item: SidebarItem
    let expected: RoutingObservation
}

/// One routed sidebar kind with the family it runs in, a name for failure
/// messages, the `SidebarItemType` it covers and its fixture builder.
struct RoutingRow {
    enum Family: String, CaseIterable {
        case containers
        case files
        case bundles
        case classifiers
        case analyses
    }

    let family: Family
    let name: String
    let type: SidebarItemType
    let build: @MainActor (RoutingRowContext) async throws -> RoutingRowFixture
}

// MARK: - Sidebar items

/// Sidebar rows the way the sidebar shows them.
@MainActor
enum RoutingSafetyNetItems {
    struct MissingNode: Error, CustomStringConvertible {
        let url: URL
        var description: String { "The sidebar scanner builds no row for \(url.path)" }
    }

    /// The row the scanner builds for one file or directory.
    static func scanned(_ url: URL, isRoot: Bool = false) -> SidebarItem {
        materialize(SidebarProjectScanner.scanTree(from: url, isRoot: isRoot))
    }

    /// The row the scanner builds for an analysis directory under `Analyses/`.
    static func scannedAnalysis(_ url: URL) throws -> SidebarItem {
        guard let info = AnalysesFolder.analysisInfo(for: url),
              let node = SidebarProjectScanner.buildAnalysisNode(info: info) else {
            throw MissingNode(url: url)
        }
        return materialize(node)
    }

    /// The per-sample child of a batch analysis row, found by its URL.
    static func scannedBatchChild(batch: URL, child: URL) throws -> SidebarItem {
        let group = try scannedAnalysis(batch)
        guard let item = group.children.first(where: {
            $0.url?.standardizedFileURL == child.standardizedFileURL
        }) else {
            throw MissingNode(url: child)
        }
        return item
    }

    /// Turns a scan node into a sidebar row with the fields routing reads.
    ///
    /// `SidebarViewController` does the same and also renders text badges as
    /// images, which routing never reads.
    static func materialize(_ node: SidebarScanNode) -> SidebarItem {
        let icon: String?
        switch node.badge {
        case .symbol(let name): icon = name
        case .text, nil: icon = nil
        }
        let item = SidebarItem(
            title: node.title,
            type: node.type,
            icon: icon,
            children: node.children.map { materialize($0) },
            url: node.url,
            subtitle: node.subtitle
        )
        item.userInfo = node.userInfo
        return item
    }
}

// MARK: - Table

@MainActor
enum RoutingSafetyNetTable {
    /// An empty viewport that binds nothing and shows only a status line.
    /// "No sequence loaded" is the status of a viewer nothing has touched.
    static func nothing(status: String = "No sequence loaded") -> RoutingObservation {
        RoutingObservation(status: status)
    }

    /// Writes the `analysis-metadata.json` sidecar an analysis run writes when
    /// it creates its folder.
    static func metadata(_ tool: String, isBatch: Bool, in directory: URL) throws {
        try AnalysesFolder.writeAnalysisMetadata(.init(tool: tool, isBatch: isBatch), to: directory)
    }

    static var rows: [RoutingRow] {
        containerRows + fileRows + bundleRows + classifierRows + analysisRows
    }

    /// The genome and track set of a SARS-CoV-2 bundle with published tracks.
    static let publishedSARSTracks = "genome=genome/sequence.fa[MT192765.1] alignments=[sample-alignment:alignments/sample.sorted.bam] variants=[sample-variants:variants/sample.vcf.gz] annotations=[] signals=[]"

    /// The experiment name the committed NVD BLAST table carries.
    static let nvdExperiment = "100"

    /// The canonical samples of the committed NAO-MGS virus hits table.
    ///
    /// The table names seven sequencing lanes. The sample identity index
    /// strips the `_S<n>_L<lane>` suffixes, so the two Stickney lanes and
    /// the two PLC lanes each become one sample.
    static let naoMgsCanonicalSamples = [
        "MU-CASPER-2026-03-31-a-CA_LosAngeles_County_20260304",
        "MU-CASPER-2026-03-31-a-IL_CHI_StickneyWS_20260308",
        "MU-CASPER-2026-03-31-a-MA_Boston_DITPN_20260311",
        "MU-CASPER-2026-03-31-a-NY_PLC_009_20260318",
        "MU-CASPER-2026-03-31-a-Water_20260323",
    ].joined(separator: ",")

    /// Writes an empty result sidecar into each sample folder of a batch, the
    /// file the scanner counts samples by.
    static func writeSampleSidecars(_ filename: String, in batch: URL, samples: [String]) throws {
        for sample in samples {
            try SafetyNetFiles.write("{}", to: batch.appendingPathComponent(sample).appendingPathComponent(filename))
        }
    }

    struct MissingRowItem: Error {}

    static func unwrapped<T>(_ value: T?) throws -> T {
        guard let value else { throw MissingRowItem() }
        return value
    }
}
