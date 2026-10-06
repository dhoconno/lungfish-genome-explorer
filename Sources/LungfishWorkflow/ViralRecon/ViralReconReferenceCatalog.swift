import Foundation

/// The reference Viral Recon always uses.
///
/// Viral Recon is a SARS-CoV-2 tool. Every bundled primer scheme declares that
/// organism and names MN908947.3 as canonical, so a primer scheme cannot apply
/// to any other genome. The reference is therefore fixed here rather than
/// chosen by the user. A project bundle is reused only when it holds exactly
/// MN908947.3; an equivalent accession is never substituted.
public enum ViralReconReferenceCatalog {
    /// The only accession Viral Recon runs against.
    public static let canonicalAccession = "MN908947.3"

    /// Bundle directory name for the canonical accession.
    public static var bundleFilename: String { "\(canonicalAccession).lungfishref" }

    /// Where a downloaded canonical bundle is written inside a project.
    public static func bundleURL(inProject projectURL: URL) -> URL {
        projectURL
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent(bundleFilename, isDirectory: true)
    }

    /// The canonical bundle the project already holds, if any.
    ///
    /// Checked in order: the download location, then the project's
    /// `Reference Sequences` folder. A bundle named for the canonical
    /// accession is used unless its index names another sequence; any other
    /// bundle there is used only when its index names MN908947.3 exactly.
    /// Without this, a project that imported the reference into
    /// `Reference Sequences` got a second, duplicate copy in `Downloads`.
    public static func existingBundleURL(
        inProject projectURL: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        // The download is checked too: one fetched while `fetch genome` still
        // substituted NC_045512.2 carries the canonical name but not the
        // canonical sequence, and every primer BED line would fail to match.
        let downloaded = bundleURL(inProject: projectURL)
        if fileManager.fileExists(atPath: downloaded.path) {
            let found = ViralReconReferenceAcquisition.sequenceIdentifier(
                inBundleAt: downloaded, fileManager: fileManager)
            if found == nil || found == canonicalAccession { return downloaded }
        }

        let folder = projectURL.appendingPathComponent("Reference Sequences", isDirectory: true)
        let named = folder.appendingPathComponent(bundleFilename, isDirectory: true)
        if fileManager.fileExists(atPath: named.path) {
            let found = ViralReconReferenceAcquisition.sequenceIdentifier(
                inBundleAt: named, fileManager: fileManager)
            if found == nil || found == canonicalAccession { return named }
        }
        // Names only, rebuilt against the project URL: a directory listing can
        // resolve symlinks (/var to /private/var), so the returned URL would
        // not match the project path it came from.
        let others = ((try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasSuffix(".lungfishref") && !$0.hasPrefix(".") && $0 != bundleFilename }
            .sorted()
            .map { folder.appendingPathComponent($0, isDirectory: true) }
        return others.first {
            ViralReconReferenceAcquisition.sequenceIdentifier(
                inBundleAt: $0, fileManager: fileManager) == canonicalAccession
        }
    }

    /// Accessions that are the same genome but carry a different sequence
    /// identifier. Recorded so a caller can explain why one is refused. These
    /// are never substituted for the canonical accession: the primer BED is
    /// written against MN908947.3, so an alignment against another identifier
    /// leaves the trimming step with nothing to match.
    public static let equivalentAccessions: Set<String> = ["NC_045512.2", "NC_045512"]
}
