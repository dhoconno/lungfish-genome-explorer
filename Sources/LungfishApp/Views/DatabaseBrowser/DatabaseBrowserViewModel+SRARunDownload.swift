// DatabaseBrowserViewModel+SRARunDownload.swift - How the SRA window downloads and imports one run
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

extension DatabaseBrowserViewModel {
    /// The defaults the window's "Download source" popup writes and its
    /// downloads read, the suite `sraDownloadSuiteName` names or the
    /// standard defaults.
    nonisolated var sraDownloadDefaults: UserDefaults {
        sraDownloadSuiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    /// The window's "Download source" setting as stored now.
    nonisolated func sraDownloadPreference() -> SRADownloadSourcePreference {
        .stored(in: sraDownloadDefaults)
    }

    /// Downloads one run of the window's SRA batch into its own folder of
    /// `batchDir`. `preference` is the batch's snapshot of the "Download
    /// source" setting, so a change mid-batch does not split the batch. Nil
    /// reads the setting now.
    ///
    /// `startENADownloadTask` calls this for every run. `mirrorFile` also
    /// gets the bytes ENA lists for the whole run, for the row's progress.
    nonisolated func stageSRARun(
        accession: String,
        preference: SRADownloadSourcePreference? = nil,
        ncbiRun: SRARunInfo?,
        in batchDir: URL,
        lookUpRoute: @escaping @Sendable () async throws -> SRAFASTQDownloadRoute,
        enaRecordWait: Duration = SRAWindowRunDownload.enaRecordWait,
        mirrorFile: (_ url: URL, _ expectedBytes: Int64?, _ priorBytes: Int64, _ runBytes: Int64?) async throws -> Data,
        toolkit: (_ status: SRAWindowToolkitStatus, _ folder: URL) async throws -> [URL],
        log: (_ line: String) -> Void
    ) async throws -> SRAWindowStagedRun {
        let answered = SRAWindowRouteBox()
        return try await SRAWindowRunDownload.stage(
            accession: accession,
            preference: preference ?? sraDownloadPreference(),
            ncbiRun: ncbiRun,
            in: batchDir,
            lookUpRoute: {
                let route = try await lookUpRoute()
                await answered.set(route)
                return route
            },
            enaRecordWait: enaRecordWait,
            mirrorFile: { url, expectedBytes, priorBytes in
                // ENA's mirror runs only after the lookup answered.
                let runBytes = await answered.route?.enaRecord?.totalFileSizeBytes.map { Int64($0) }
                return try await mirrorFile(url, expectedBytes, priorBytes, runBytes)
            },
            toolkit: toolkit,
            log: log
        )
    }

    /// NCBI's run info from an SRA search, by run accession, which the
    /// window keeps for runs whose ENA record does not arrive at download.
    nonisolated static func ncbiRunsByAccession(in lookup: SRARunMetadataLookup.Outcome) -> [String: SRARunInfo] {
        Dictionary(
            lookup.runs.compactMap { run in run.ncbiRun.map { (run.accession, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// The `lungfish-cli import fastq` argv for one downloaded SRA/ENA run.
    ///
    /// Built from the same sheet configuration the file-drop import uses, so
    /// the Compression Tool popup (`clumpingTool`) and the Pairing popup are
    /// honoured here too. Before 2026-09-24 this path dropped the clumping
    /// tool and always ran the platform default. The pairing choice applies
    /// when the run downloaded a single file (single-end versus interleaved).
    /// A run that arrived as R1/R2 imports as one paired sample, with the
    /// file of reads whose mate is missing when the run has one.
    nonisolated static func sraImportCLIArguments(
        importConfig: FASTQImportConfiguration,
        r1: URL,
        r2: URL?,
        unpaired: URL? = nil,
        projectDirectory: URL
    ) -> [String] {
        CLIImportRunner.buildCLIArguments(
            r1: r1,
            r2: r2,
            unpaired: unpaired,
            projectDirectory: projectDirectory,
            platform: importConfig.cliPlatformValue,
            recipeName: FASTQIngestionService.resolvedRecipeName(for: importConfig),
            qualityBinning: importConfig.qualityBinning.rawValue,
            optimizeStorage: !importConfig.skipClumpify,
            clumpingTool: importConfig.clumpingTool,
            pairingMode: r2 == nil ? importConfig.cliPairingMode : .pairedEnd,
            compressionLevel: importConfig.compressionLevel?.rawValue ?? "balanced"
        )
    }
}

/// The route ENA's lookup answered for one run, once it answered.
private actor SRAWindowRouteBox {
    private(set) var route: SRAFASTQDownloadRoute?
    func set(_ route: SRAFASTQDownloadRoute) { self.route = route }
}
