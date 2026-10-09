import AppKit
import LungfishCore
import LungfishIO

/// Value-semantic geometry for the ordinary and manual regions of a native
/// matrix table header.
struct GenotypeManualHaplotypeHeaderLayout: Equatable {
    let isEligible: Bool
    let isExpanded: Bool
    let ordinaryHeight: CGFloat
    let disclosureHeight: CGFloat
    let rowHeight: CGFloat
    let locusCount: Int

    init(
        isEligible: Bool,
        isExpanded: Bool,
        ordinaryHeight: CGFloat,
        disclosureHeight: CGFloat,
        rowHeight: CGFloat,
        locusCount: Int = 7
    ) {
        self.isEligible = isEligible
        self.isExpanded = isExpanded
        self.ordinaryHeight = ordinaryHeight
        self.disclosureHeight = disclosureHeight
        self.rowHeight = rowHeight
        self.locusCount = locusCount
    }

    var manualHeight: CGFloat {
        guard isEligible else { return 0 }
        return disclosureHeight
            + rowHeight * CGFloat(isExpanded ? locusCount : 0)
    }

    var totalHeight: CGFloat {
        ordinaryHeight + manualHeight
    }

    func ordinaryRect(in bounds: NSRect, isFlipped: Bool) -> NSRect {
        NSRect(
            x: bounds.minX,
            y: isFlipped
                ? bounds.minY
                : bounds.maxY - ordinaryHeight,
            width: bounds.width,
            height: min(max(ordinaryHeight, 0), bounds.height)
        )
    }

    func manualRect(in bounds: NSRect, isFlipped: Bool) -> NSRect {
        guard manualHeight > 0 else { return .zero }
        return NSRect(
            x: bounds.minX,
            y: isFlipped
                ? bounds.minY + ordinaryHeight
                : bounds.minY,
            width: bounds.width,
            height: min(manualHeight, max(0, bounds.height - ordinaryHeight))
        )
    }
}
