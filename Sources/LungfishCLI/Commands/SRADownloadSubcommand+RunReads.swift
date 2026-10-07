// SRADownloadSubcommand+RunReads.swift - fetch sra download takes one run and keeps it whole
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore

extension SRADownloadSubcommand {
    /// Refuses anything but one run accession. ENA answers an experiment or
    /// study accession with all of its runs, and the download fetched only
    /// the first of them under the other run's name (finding F5-N6).
    func validateRunAccession() throws {
        guard SRAAccessionParser.accessionType(accession) == .run,
              accession == accession.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw ValidationError(
                "fetch sra download takes one run accession, SRR, ERR or DRR followed by digits, so it cannot download \(accession)."
            )
        }
    }

    /// Applies the lone-mate rule the window applies before it imports a run.
    ///
    /// The run's layout is ENA's when ENA answered with a record, else NCBI's
    /// LibraryLayout, which is looked up only when no mate 2 arrived. A lone
    /// mate of a paired run fails the download, and the files this run wrote
    /// are removed so no half pair stays. A run listed as paired that arrived
    /// as one file of single reads is kept with a warning, as is a lone mate
    /// 1 of a run neither archive gives a layout for, and the warning names
    /// any read file beyond mates 1 and 2. A cancellation while NCBI is asked
    /// cancels the download and removes the run's files too.
    ///
    /// - Returns: The warning line to print and record under `layoutWarning`,
    ///   or nil.
    /// - Throws: `SRARunRefusal` with the one-line reason, or a cancellation.
    func checkRunReads(_ files: [URL], service: SRAService, enaRecord: ENAReadRecord?) async throws -> String? {
        let accession = accession
        do {
            return try await SRARunReads.sorting(
                files,
                accession: accession,
                enaLayout: enaRecord?.libraryLayout,
                ncbiLayout: { await service.ncbiRunInfo(forRun: accession)?.libraryLayout }
            ).layoutWarning
        } catch let failure as SRARunReads.Failure {
            Self.remove(files)
            throw SRARunRefusal(failure: failure)
        } catch {
            Self.remove(files)
            throw error
        }
    }

    private static func remove(_ files: [URL]) {
        for file in files {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

/// A run whose files arrived but are not one whole run, which `fetch sra
/// download` refuses. The command reports it as a refusal in one line, never
/// as a network error (review B-N6).
struct SRARunRefusal: Error {
    let failure: SRARunReads.Failure

    /// The one-line reason the command fails with.
    var reason: String {
        "\(failure.message), so the run was refused and its files were removed"
    }
}
