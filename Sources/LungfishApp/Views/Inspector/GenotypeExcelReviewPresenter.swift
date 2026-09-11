import AppKit
import LungfishGenotypeUI
import LungfishIO
import LungfishWorkflow

struct GenotypeExcelReviewRow: Equatable {
    let kind: String
    let identity: String
    let before: String
    let after: String

    init(kind: String, identity: String, before: String, after: String) {
        self.kind = kind
        self.identity = identity
        self.before = before
        self.after = after
    }

    init(change: GenotypeEditableWorkbookService.Change) {
        kind = change.kind.rawValue.capitalized
        identity = Self.identity(for: change)
        before = change.before ?? "None"
        after = change.value ?? "Clear"
    }

    private static func identity(
        for change: GenotypeEditableWorkbookService.Change
    ) -> String {
        if change.kind == .call {
            return [change.sample, change.locus, change.slot?.rawValue.uppercased()]
                .compactMap { $0 }.joined(separator: " • ")
        }
        guard let target = change.target else {
            return [change.sample, change.locus].filter { !$0.isEmpty }.joined(separator: " • ")
        }
        switch target {
        case .row(let locus, let genotype, let stableClusterID):
            return ["Matrix row", locus, genotype, stableClusterID].compactMap { $0 }.joined(separator: " • ")
        case .column(let sample):
            return "Matrix column • \(sample)"
        case .cell(let locus, let genotype, let sample, let stableClusterID):
            return ["Matrix cell", sample, locus, genotype, stableClusterID].compactMap { $0 }.joined(separator: " • ")
        }
    }
}

@MainActor
enum GenotypeExcelReviewPresenter {
    static func makeScrollView(rows: [GenotypeExcelReviewRow]) -> NSScrollView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        for row in rows {
            let label = NSTextField(
                wrappingLabelWithString: "\(row.kind) — \(row.identity)\n\(row.before) → \(row.after)"
            )
            label.isSelectable = true
            label.maximumNumberOfLines = 0
            label.preferredMaxLayoutWidth = 484
            stack.addArrangedSubview(label)
        }
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        stack.frame.size = NSSize(width: 500, height: stack.fittingSize.height)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 320))
        scroll.hasVerticalScroller = true
        scroll.documentView = stack
        return scroll
    }
}
