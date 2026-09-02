import Foundation

/// Finds the viewable reference bundle inside a Viral Recon analysis directory.
///
/// A Viral Recon analysis is not itself a viewport document. The alignment and
/// variant tracks are registered into the `.lungfishref` bundle the run was
/// aligned against, which the ingest step copies into the analysis directory,
/// so selecting the analysis means opening that bundle.
enum ViralReconAnalysisBundleLocator {
    /// The `.lungfishref` inside `analysisDirectory`, or nil when there is none.
    ///
    /// A batch directory holds no bundle of its own; its per-sample children do,
    /// which is why this deliberately does not recurse. Recursing would make a
    /// batch open one arbitrary sample and present it as the whole run.
    static func viewableBundleURL(
        in analysisDirectory: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        let contents = (try? fileManager.contentsOfDirectory(
            at: analysisDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return contents
            .filter { $0.pathExtension == "lungfishref" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first
    }
}
