import Foundation
import LungfishCore
import LungfishWorkflow

struct ReferenceBundleViewportInput: Equatable {
    enum Kind: Equatable {
        case directBundle
        case mappingResult
    }

    let kind: Kind
    let renderedBundleURL: URL?
    let manifest: BundleManifest?
    let mappingResult: MappingResult?
    let mappingResultDirectoryURL: URL?
    let mappingProvenance: MappingProvenance?
    /// The viewer bundle's manifest for `.mappingResult` inputs, used ONLY to
    /// derive display strings (selector-cell bundle name, track header
    /// label) — never populates `manifest` above, which drives
    /// `documentTitle` and is deliberately left `nil` for mapping results
    /// (that summary-bar decision is out of scope for Item 2; see
    /// `docs/superpowers/specs/2026-08-09-mapping-viewer-fixes-spec.md` at commit ba9d983f9).
    let viewerBundleManifest: BundleManifest?
    /// When the saved mapping result last changed on disk, the version of
    /// `mappingResult` that identity compares instead of its contigs.
    let mappingResultModificationDate: Date?

    var documentTitle: String {
        manifest?.name
            ?? mappingResultDirectoryURL?.lastPathComponent
            ?? renderedBundleURL?.deletingPathExtension().lastPathComponent
            ?? "Reference Bundle"
    }

    var hasMappingRunContext: Bool {
        mappingResult != nil
    }

    /// Two inputs show the same document when they name the same files at the
    /// same versions. A large reference has hundreds of thousands of sequences
    /// in its manifest and in its mapping result, and comparing those arrays
    /// on the main actor on each display request cost seconds.
    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.kind == rhs.kind,
              lhs.renderedBundleURL == rhs.renderedBundleURL,
              lhs.mappingResultDirectoryURL == rhs.mappingResultDirectoryURL,
              sameVersion(lhs.manifest, rhs.manifest),
              sameVersion(lhs.viewerBundleManifest, rhs.viewerBundleManifest)
        else { return false }
        if lhs.mappingResultModificationDate != nil || rhs.mappingResultModificationDate != nil {
            return lhs.mappingResultModificationDate == rhs.mappingResultModificationDate
        }
        // A result built in memory has no saved version, and it is small.
        return lhs.mappingResult == rhs.mappingResult
    }

    /// A manifest's version without its per-sequence arrays: its identifier,
    /// modification date, sequence count and track declarations.
    private static func sameVersion(_ lhs: BundleManifest?, _ rhs: BundleManifest?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return lhs.identifier == rhs.identifier
            && lhs.modifiedDate == rhs.modifiedDate
            && lhs.genome?.chromosomes.count == rhs.genome?.chromosomes.count
            && lhs.alignments == rhs.alignments
            && lhs.variants == rhs.variants
            && lhs.annotations == rhs.annotations
    }

    static func directBundle(
        bundleURL: URL,
        manifest: BundleManifest
    ) -> ReferenceBundleViewportInput {
        ReferenceBundleViewportInput(
            kind: .directBundle,
            renderedBundleURL: bundleURL.standardizedFileURL,
            manifest: manifest,
            mappingResult: nil,
            mappingResultDirectoryURL: nil,
            mappingProvenance: nil,
            viewerBundleManifest: nil,
            mappingResultModificationDate: nil
        )
    }

    static func mappingResult(
        result: MappingResult,
        resultDirectoryURL: URL?,
        provenance: MappingProvenance?,
        viewerBundleManifest: BundleManifest? = nil,
        resultModificationDate: Date? = nil
    ) -> ReferenceBundleViewportInput {
        ReferenceBundleViewportInput(
            kind: .mappingResult,
            renderedBundleURL: result.viewerBundleURL?.standardizedFileURL,
            manifest: nil,
            mappingResult: result,
            mappingResultDirectoryURL: resultDirectoryURL?.standardizedFileURL,
            mappingProvenance: provenance,
            viewerBundleManifest: viewerBundleManifest,
            mappingResultModificationDate: resultModificationDate
        )
    }
}
