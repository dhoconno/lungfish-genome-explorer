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
    /// `docs/superpowers/specs/2026-08-09-mapping-viewer-fixes-spec.md`).
    let viewerBundleManifest: BundleManifest?

    var documentTitle: String {
        manifest?.name
            ?? mappingResultDirectoryURL?.lastPathComponent
            ?? renderedBundleURL?.deletingPathExtension().lastPathComponent
            ?? "Reference Bundle"
    }

    var hasMappingRunContext: Bool {
        mappingResult != nil
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
            viewerBundleManifest: nil
        )
    }

    static func mappingResult(
        result: MappingResult,
        resultDirectoryURL: URL?,
        provenance: MappingProvenance?,
        viewerBundleManifest: BundleManifest? = nil
    ) -> ReferenceBundleViewportInput {
        ReferenceBundleViewportInput(
            kind: .mappingResult,
            renderedBundleURL: result.viewerBundleURL?.standardizedFileURL,
            manifest: nil,
            mappingResult: result,
            mappingResultDirectoryURL: resultDirectoryURL?.standardizedFileURL,
            mappingProvenance: provenance,
            viewerBundleManifest: viewerBundleManifest
        )
    }
}
