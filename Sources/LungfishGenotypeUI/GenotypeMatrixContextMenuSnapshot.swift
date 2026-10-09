import Foundation
import LungfishCore
import LungfishIO
import LungfishKit

struct GenotypeMatrixContextMenuSnapshot: Equatable, Sendable {
    let selectionTargets: [GenotypeAnnotationSidecar.MatrixTarget]
    let capability: GenotypeMatrixReviewCapabilityState
    let visibilityCapability: GenotypeMatrixVisibilityCapabilitySnapshot
    let keyModifierRawValue: UInt
    let manualHaplotypeEditSample: String?
    let selectedRowCallSampleCount: Int?

    init(
        selectionTargets: [GenotypeAnnotationSidecar.MatrixTarget],
        capability: GenotypeMatrixReviewCapabilityState,
        visibilityCapability: GenotypeMatrixVisibilityCapabilitySnapshot,
        keyModifierRawValue: UInt,
        manualHaplotypeEditSample: String? = nil,
        selectedRowCallSampleCount: Int? = nil
    ) {
        self.selectionTargets = selectionTargets
        self.capability = capability
        self.visibilityCapability = visibilityCapability
        self.keyModifierRawValue = keyModifierRawValue
        self.manualHaplotypeEditSample = manualHaplotypeEditSample
        self.selectedRowCallSampleCount = selectedRowCallSampleCount
    }
}
