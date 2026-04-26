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
            mappingProvenance: nil
        )
    }

    static func mappingResult(
        result: MappingResult,
        resultDirectoryURL: URL?,
        provenance: MappingProvenance?
    ) -> ReferenceBundleViewportInput {
        ReferenceBundleViewportInput(
            kind: .mappingResult,
            renderedBundleURL: result.viewerBundleURL?.standardizedFileURL,
            manifest: nil,
            mappingResult: result,
            mappingResultDirectoryURL: resultDirectoryURL?.standardizedFileURL,
            mappingProvenance: provenance
        )
    }
}
