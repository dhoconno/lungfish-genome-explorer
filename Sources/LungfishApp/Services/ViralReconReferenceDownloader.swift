import Foundation
import LungfishKit
import LungfishWorkflow

/// Downloads the canonical Viral Recon reference through the CLI.
///
/// `lungfish-cli fetch genome` already retrieves the sequence and its GFF3
/// annotations and builds an indexed `.lungfishref`, so this wraps that rather
/// than reimplementing bundle construction.
enum ViralReconReferenceDownloader {
    /// The accession is positional, matching `fetch genome <accession>`. The
    /// bundle name is pinned to the accession because the CLI otherwise derives
    /// the directory name from the organism, which the acquisition step would
    /// not find.
    static func arguments(accession: String, destinationDirectory: URL) -> [String] {
        [
            "fetch", "genome", accession,
            "--output-dir", destinationDirectory.path,
            "--name", accession,
        ]
    }

    static func live() -> ViralReconReferenceAcquisition.Downloader {
        { accession, destinationDirectory in
            _ = try LungfishCLIRunner.run(
                arguments: arguments(accession: accession,
                                     destinationDirectory: destinationDirectory))
        }
    }
}
