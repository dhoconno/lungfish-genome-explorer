# Sample Curation Workbench Implementation Plan — Phase 2

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the narrow trailing manual-haplotype card with a responsive, full-width selected-sample workbench that keeps compact H1/H2 assignments, sample metrics, supported alleles, and comments visible together in eligible genotype-only ONT and miSeq analyses.

**Architecture:** A stable AppKit workbench owns full-width and side-by-side/stacked geometry inside the existing outer detail scroll view. The existing SwiftUI editor model remains the single live source for draft, completeness, Copy, and Save state; a custom SwiftUI `Layout` reflows the same controls at narrow widths. Supported alleles use a bounded inline SwiftUI preview and an on-demand popover for the full virtualized list.

**Tech Stack:** Swift 6, AppKit, SwiftUI, XCTest, macOS accessibility APIs

---

**Design:** `docs/superpowers/specs/2026-07-28-manual-haplotype-save-refresh-and-sample-workbench-design.md`

**Prerequisite Phase 1:** `docs/superpowers/plans/2026-07-28-manual-haplotype-save-refresh.md`

### Task 1: Add a stable responsive AppKit workbench

**Files:**
- Create: `Sources/LungfishGenotypeUI/GenotypeSampleCurationWorkbenchView.swift`
- Modify: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`

- [ ] **Step 1: Write failing standalone layout tests**

Create a workbench with fixed-height header, assignment, and evidence fixtures.
Assert:

```swift
let assignmentIdentity = ObjectIdentifier(assignment)
let evidenceIdentity = ObjectIdentifier(evidence)

workbench.frame.size.width = 779
workbench.layoutSubtreeIfNeeded()
XCTAssertEqual(workbench.layoutMode, .stacked)

workbench.frame.size.width = 841
workbench.layoutSubtreeIfNeeded()
XCTAssertEqual(workbench.layoutMode, .sideBySide)

workbench.frame.size.width = 800
workbench.layoutSubtreeIfNeeded()
XCTAssertEqual(workbench.layoutMode, .sideBySide)

workbench.frame.size.width = 779
workbench.layoutSubtreeIfNeeded()
XCTAssertEqual(workbench.layoutMode, .stacked)
XCTAssertEqual(ObjectIdentifier(workbench.assignmentView), assignmentIdentity)
XCTAssertEqual(ObjectIdentifier(workbench.evidenceView), evidenceIdentity)
XCTAssertFalse(
    descendants(of: workbench).contains { $0 is NSScrollView }
)
```

Repeat after setting typography scale to 2.0 and assert that an 841-point
workbench stays stacked. Assert the editor width never exceeds 640 points in
side-by-side mode.

- [ ] **Step 2: Run the test and verify RED**

```bash
swift test --filter GenotypeResultViewportTests/testSampleCurationWorkbench
```

Expected: compile failure because the workbench type does not exist.

- [ ] **Step 3: Implement the responsive container**

Create:

```swift
import AppKit

@MainActor
final class GenotypeSampleCurationWorkbenchView: NSView {
    enum LayoutMode: Equatable {
        case sideBySide
        case stacked
    }

    let headerView: NSView
    let assignmentView: NSView
    let evidenceView: NSView

    private let rootStack = NSStackView()
    private let bodyStack = NSStackView()
    private var wideConstraints: [NSLayoutConstraint] = []
    private var stackedConstraints: [NSLayoutConstraint] = []
    private var contentTypographyScale: CGFloat

    private(set) var layoutMode: LayoutMode = .stacked

    init(
        headerView: NSView,
        assignmentView: NSView,
        evidenceView: NSView,
        contentTypographyScale: CGFloat
    ) {
        self.headerView = headerView
        self.assignmentView = assignmentView
        self.evidenceView = evidenceView
        self.contentTypographyScale = max(1, contentTypographyScale)
        super.init(frame: .zero)
        configure()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        updateLayoutModeIfNeeded()
    }

    func updateContentTypographyScale(_ scale: CGFloat) {
        let normalized = max(1, scale)
        guard normalized != contentTypographyScale else { return }
        contentTypographyScale = normalized
        updateLayoutModeIfNeeded()
        needsLayout = true
    }

    private func configure() {
        translatesAutoresizingMaskIntoConstraints = false
        [headerView, assignmentView, evidenceView].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        rootStack.translatesAutoresizingMaskIntoConstraints = false
        rootStack.orientation = .vertical
        rootStack.alignment = .width
        rootStack.spacing = 12

        bodyStack.translatesAutoresizingMaskIntoConstraints = false
        bodyStack.spacing = 16
        bodyStack.distribution = .fill
        bodyStack.addArrangedSubview(assignmentView)
        bodyStack.addArrangedSubview(evidenceView)

        rootStack.addArrangedSubview(headerView)
        rootStack.addArrangedSubview(bodyStack)
        addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: topAnchor),
            rootStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            rootStack.bottomAnchor.constraint(equalTo: bottomAnchor),
            headerView.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            bodyStack.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
        ])

        let preferredAssignmentWidth = assignmentView.widthAnchor.constraint(
            equalTo: bodyStack.widthAnchor,
            multiplier: 0.62,
            constant: -8
        )
        preferredAssignmentWidth.priority = .defaultHigh
        wideConstraints = [
            assignmentView.widthAnchor.constraint(
                greaterThanOrEqualToConstant: 420
            ),
            assignmentView.widthAnchor.constraint(
                lessThanOrEqualToConstant: 640
            ),
            evidenceView.widthAnchor.constraint(
                greaterThanOrEqualToConstant: 300
            ),
            preferredAssignmentWidth,
        ]
        stackedConstraints = [
            assignmentView.widthAnchor.constraint(
                equalTo: bodyStack.widthAnchor
            ),
            evidenceView.widthAnchor.constraint(
                equalTo: bodyStack.widthAnchor
            ),
        ]
        apply(.stacked)
    }

    private func updateLayoutModeIfNeeded() {
        let adjustment = min(
            240,
            max(0, contentTypographyScale - 1) * 240
        )
        let enterWide = 840 + adjustment
        let leaveWide = 780 + adjustment
        let next: LayoutMode
        switch layoutMode {
        case .stacked:
            next = bounds.width >= enterWide ? .sideBySide : .stacked
        case .sideBySide:
            next = bounds.width < leaveWide ? .stacked : .sideBySide
        }
        guard next != layoutMode else { return }
        apply(next)
    }

    private func apply(_ mode: LayoutMode) {
        NSLayoutConstraint.deactivate(wideConstraints + stackedConstraints)
        layoutMode = mode
        switch mode {
        case .sideBySide:
            bodyStack.orientation = .horizontal
            bodyStack.alignment = .top
            NSLayoutConstraint.activate(wideConstraints)
        case .stacked:
            bodyStack.orientation = .vertical
            bodyStack.alignment = .width
            NSLayoutConstraint.activate(stackedConstraints)
        }
    }
}
```

Do not override `intrinsicContentSize` and do not invalidate intrinsic size from
`layout()`. The stack's top/bottom child constraints determine height.

- [ ] **Step 4: Run layout tests**

```bash
swift test --filter GenotypeResultViewportTests/testSampleCurationWorkbench
```

Expected: PASS with hysteresis, stable child identities, no nested scroll view,
and a 640-point editor maximum.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishGenotypeUI/GenotypeSampleCurationWorkbenchView.swift Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift
git commit -m "feat: add responsive sample curation workbench"
```

### Task 2: Reflow the same assignment controls at narrow widths

**Files:**
- Modify: `Sources/LungfishGenotypeUI/GenotypeManualHaplotypeEditor.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift:5514-5605`
- Modify: `Tests/LungfishGenotypeUITests/GenotypeManualHaplotypeEditorTests.swift`
- Modify: `Tests/LungfishGenotypeUITests/GenotypeManualHaplotypeAccessibilityTests.swift`

- [ ] **Step 1: Write failing responsive-control tests**

Assert:

- all fourteen combo boxes retain their current identifiers and row-major
  accessibility order;
- at 520 points, each locus places H1 and H2 beside the locus;
- at 280 and 420 points, H1 and H2 stack below the locus without horizontal
  overflow;
- the same `NSComboBox` object identities survive 520 → 280 → 520;
- draft text and first responder survive the transition;
- the host has no `height >= 590` constraint; and
- the same assertions pass at 200% content text size.

Add DEBUG helpers for the host identity, combo identities, and minimum height
constraints:

```swift
var testingManualHaplotypeEditorHostIdentity: ObjectIdentifier? {
    manualHaplotypeEditorHostView.map(ObjectIdentifier.init)
}

var testingManualHaplotypeComboIdentities: [ObjectIdentifier] {
    guard let host = manualHaplotypeEditorHostView else { return [] }
    return GenotypeManualHaplotypeLocus.allCases.flatMap { locus in
        HaplotypeSlot.allCases.compactMap { slot in
            descendantComboBox(
                in: host,
                accessibilityIdentifier:
                    "manual-haplotype-\(locus.rawValue)-"
                    + slot.rawValue
            )
        }
    }.map(ObjectIdentifier.init)
}

var testingManualHaplotypeEditorMinimumHeightConstraints: [CGFloat] {
    manualHaplotypeEditorHostView?.constraints.compactMap {
        $0.firstAttribute == .height
            && $0.relation == .greaterThanOrEqual
            ? $0.constant
            : nil
    } ?? []
}
```

- [ ] **Step 2: Run the tests and verify RED**

```bash
swift test --filter 'GenotypeManualHaplotype(Editor|Accessibility)Tests'
```

Expected: FAIL because the current editor always stacks loci vertically and the
host has a fixed 590-point minimum.

- [ ] **Step 3: Add a custom SwiftUI layout that moves, rather than recreates, controls**

Add:

```swift
private struct HaplotypeLocusRowLayout: Layout {
    let wideThreshold: CGFloat
    let spacing: CGFloat = 8

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let width = max(0, proposal.width ?? 0)
        let isWide = width >= wideThreshold
        if isWide {
            let locusWidth = min(
                88,
                subviews[0].sizeThatFits(.unspecified).width
            )
            let slotWidth = max(
                0,
                (width - locusWidth - spacing * 2) / 2
            )
            let slotProposal = ProposedViewSize(
                width: slotWidth,
                height: nil
            )
            return CGSize(
                width: width,
                height: max(
                    subviews[0].sizeThatFits(.unspecified).height,
                    subviews[1].sizeThatFits(slotProposal).height,
                    subviews[2].sizeThatFits(slotProposal).height
                )
            )
        }
        let childProposal = ProposedViewSize(width: width, height: nil)
        return CGSize(
            width: width,
            height:
                subviews[0].sizeThatFits(childProposal).height
                + subviews[1].sizeThatFits(childProposal).height
                + subviews[2].sizeThatFits(childProposal).height
                + spacing * 2
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let isWide = bounds.width >= wideThreshold
        if isWide {
            let locusWidth = min(
                88,
                subviews[0].sizeThatFits(.unspecified).width
            )
            let slotWidth = max(
                0,
                (bounds.width - locusWidth - spacing * 2) / 2
            )
            subviews[0].place(
                at: bounds.origin,
                anchor: .topLeading,
                proposal: ProposedViewSize(
                    width: locusWidth,
                    height: nil
                )
            )
            subviews[1].place(
                at: CGPoint(
                    x: bounds.minX + locusWidth + spacing,
                    y: bounds.minY
                ),
                anchor: .topLeading,
                proposal: ProposedViewSize(
                    width: slotWidth,
                    height: nil
                )
            )
            subviews[2].place(
                at: CGPoint(
                    x: bounds.maxX - slotWidth,
                    y: bounds.minY
                ),
                anchor: .topLeading,
                proposal: ProposedViewSize(
                    width: slotWidth,
                    height: nil
                )
            )
            return
        }

        var y = bounds.minY
        for subview in subviews {
            let childProposal = ProposedViewSize(
                width: bounds.width,
                height: nil
            )
            subview.place(
                at: CGPoint(x: bounds.minX, y: y),
                anchor: .topLeading,
                proposal: childProposal
            )
            y += subview.sizeThatFits(childProposal).height + spacing
        }
    }
}
```

Render every locus once:

```swift
let canonicalBody = max(NSFont.systemFontSize, 1)
let typographyScale = comboFieldFont.pointSize / canonicalBody
ForEach(model.rows) { row in
    HaplotypeLocusRowLayout(
        wideThreshold: 430 * typographyScale
    ) {
        Text(row.locus.workbookLabel)
            .font(headingFont)
        slotEditor(row.h1)
        slotEditor(row.h2)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(
        "\(row.locus.workbookLabel) haplotype assignments"
    )
    Divider()
}
```

Keep the visible H1/H2 labels in `slotEditor`; mark each label as a header for
accessibility. End the editor root with:

```swift
.frame(maxWidth: .infinity, alignment: .leading)
.fixedSize(horizontal: false, vertical: true)
```

Pass `slot.validationDescription` into `ManualHaplotypeComboBox` as
`accessibilityHelp`. Store it on the representable and apply it to the actual
`NSComboBox`:

```swift
comboBox.setAccessibilityHelp(accessibilityHelp)
```

Add a test that creates an invalid label and asserts the corresponding combo's
accessibility help equals the model's validation description. The adjacent
warning icon remains supplemental.

- [ ] **Step 4: Remove the fixed host height and make hosting width-driven**

Delete the 590-point minimum. Configure:

```swift
container.sizingOptions = [.intrinsicContentSize]
container.setContentHuggingPriority(.defaultLow, for: .horizontal)
container.setContentCompressionResistancePriority(
    .defaultLow,
    for: .horizontal
)
```

The workbench wrapper added in Task 4 supplies the required external width.

- [ ] **Step 5: Run responsive editor tests**

```bash
swift test --filter 'GenotypeManualHaplotype(Editor|Accessibility)Tests'
```

Expected: PASS with stable controls, no overflow at 280/420 points, correct
large-text reflow, and no fixed host height.

- [ ] **Step 6: Commit**

```bash
git add Sources/LungfishGenotypeUI/GenotypeManualHaplotypeEditor.swift Sources/LungfishGenotypeUI/GenotypeResultViewController.swift Tests/LungfishGenotypeUITests
git commit -m "feat: reflow manual haplotype assignments responsively"
```

### Task 3: Add a bounded responsive supported-allele panel

**Files:**
- Create: `Sources/LungfishGenotypeUI/GenotypeSupportedAllelesPanel.swift`
- Modify: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`

- [ ] **Step 1: Write failing snapshot and panel tests**

Test a 1,001-row snapshot:

```swift
let snapshot = GenotypeSupportedAllelesSnapshot(rows: rows)
XCTAssertEqual(snapshot.rows.count, 1_001)
XCTAssertEqual(snapshot.previewRows.count, 12)
XCTAssertEqual(snapshot.omittedRowCount, 989)
XCTAssertEqual(snapshot.layoutMode(forWidth: 519), .compact)
XCTAssertEqual(snapshot.layoutMode(forWidth: 520), .columns)
XCTAssertTrue(
    snapshot.rows[0].accessibilityLabel.contains("unique reads")
)
```

Mount the panel and assert its inline accessibility children are bounded to the
heading, twelve rows, and **Show All 1,001 Alleles…** button. Activate the
button and assert the separate popover list contains all rows without changing
the outer detail document height.

- [ ] **Step 2: Run the test and verify RED**

```bash
swift test --filter GenotypeResultViewportTests/testSupportedAllelesPanel
```

Expected: compile failure because the panel does not exist.

- [ ] **Step 3: Implement the value-semantic snapshot**

Create:

```swift
import SwiftUI
import LungfishKit

struct GenotypeSupportedAllelePresentation: Identifiable, Equatable {
    let id: String
    let allele: String
    let locus: String
    let uniqueReads: String
    let alignments: String
    let support: String

    var accessibilityLabel: String {
        "\(allele), locus \(locus), \(uniqueReads) unique reads, "
            + "\(alignments) alignments, \(support) support"
    }
}

struct GenotypeSupportedAllelesSnapshot: Equatable {
    enum LayoutMode: Equatable {
        case columns
        case compact
    }

    static let previewLimit = 12
    let rows: [GenotypeSupportedAllelePresentation]

    var previewRows: ArraySlice<GenotypeSupportedAllelePresentation> {
        rows.prefix(Self.previewLimit)
    }

    var omittedRowCount: Int {
        max(0, rows.count - Self.previewLimit)
    }

    func layoutMode(forWidth width: CGFloat) -> LayoutMode {
        width >= 520 ? .columns : .compact
    }
}
```

- [ ] **Step 4: Implement the bounded inline preview and full-list popover**

Add `GenotypeSupportedAllelesPanel`, using the same plain injected
`ContentTypographyModel` reference pattern as
`GenotypeManualHaplotypeEditor`—the model uses Observation, not
`ObservableObject`—plus `@State private var showsAll`. The inline body displays
only `snapshot.previewRows`.

For wide rows use:

```swift
GridRow {
    Text(row.allele).lineLimit(1)
    Text(row.locus)
    Text(row.uniqueReads).monospacedDigit()
    Text(row.alignments).monospacedDigit()
    Text(row.support).monospacedDigit()
}
.accessibilityElement(children: .ignore)
.accessibilityLabel(row.accessibilityLabel)
```

For compact rows use:

```swift
VStack(alignment: .leading, spacing: 2) {
    Text(row.allele).lineLimit(2)
    Text(
        "\(row.locus) • \(row.uniqueReads) unique • "
            + "\(row.alignments) alignments • \(row.support)"
    )
    .font(typographyModel.font(for: .caption))
    .foregroundStyle(.secondary)
}
.accessibilityElement(children: .ignore)
.accessibilityLabel(row.accessibilityLabel)
```

Choose between those non-editable presentations with `ViewThatFits`. When
`omittedRowCount > 0`, add:

```swift
Button("Show All \(snapshot.rows.count) Alleles\u{2026}") {
    showsAll = true
}
.popover(isPresented: $showsAll) {
    List(snapshot.rows) { row in
        compactRow(row)
    }
    .frame(minWidth: 520, minHeight: 360)
}
```

The popover owns the only full-list scroller; it is not nested in the detail
document.

- [ ] **Step 5: Run supported-allele tests**

```bash
swift test --filter GenotypeResultViewportTests/testSupportedAllelesPanel
```

Expected: PASS with a twelve-row inline bound, compact rows below 520 points,
native accessibility labels, and an on-demand virtualized full list.

- [ ] **Step 6: Commit**

```bash
git add Sources/LungfishGenotypeUI/GenotypeSupportedAllelesPanel.swift Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift
git commit -m "feat: add bounded supported allele evidence panel"
```

### Task 4: Integrate the full-width selected-sample workbench

**Files:**
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift:4025-4184,5514-5635`
- Modify: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`

- [ ] **Step 1: Write failing integration geometry tests**

For `.listTop`, `.listLeading`, and `.listTrailing`, select one eligible sample
and assert at 280, 420, 779, 841, 1,200, and 2,300 points:

```swift
XCTAssertNotNil(controller.testingSampleWorkbenchLayoutMode)
XCTAssertEqual(
    controller.testingSampleWorkbenchFrame?.width,
    controller.testingDetailStackWidth,
    accuracy: 1
)
XCTAssertGreaterThanOrEqual(
    controller.testingSampleWorkbenchFrame?.minX ?? -1,
    controller.testingDetailStackFrame.minX - 1
)
XCTAssertLessThanOrEqual(
    controller.testingSampleWorkbenchFrame?.maxX ?? .greatestFiniteMagnitude,
    controller.testingDetailStackFrame.maxX + 1
)
```

Cross 841 → 779 → 841 with a dirty draft and first responder. Assert workbench,
editor host, editor model, and combo-box identities do not change.

- [ ] **Step 2: Run geometry tests and verify RED**

```bash
swift test --filter GenotypeResultViewportTests/testSelectedSampleWorkbench
```

Expected: FAIL because the editor is still a narrow trailing arranged subview.

- [ ] **Step 3: Build one static header and two stable body columns**

For a single sample only:

1. Build a full-width header with selected sample name, retained unique reads,
   alignments, and QC.
2. Create the editor host once and pin it on all four edges in an assignment
   wrapper.
3. Convert the already sorted
   `comparisonMatrix.visibleSampleAlleleDetails(sample:)` array to
   `GenotypeSupportedAllelesSnapshot`.
4. Host `GenotypeSupportedAllelesPanel` in the evidence column above the
   existing sample comment section.
5. Create `GenotypeSampleCurationWorkbenchView`.
6. Add only the workbench to `detailStack`.

Track:

```swift
private var sampleCurationWorkbench:
    GenotypeSampleCurationWorkbenchView?
private var sampleWorkbenchWidthConstraint: NSLayoutConstraint?
private var sampleSupportedAllelesSnapshot:
    GenotypeSupportedAllelesSnapshot?
```

At the start of every detail replacement and result configuration, deactivate
`sampleWorkbenchWidthConstraint` and set all three properties to `nil`:

```swift
sampleWorkbenchWidthConstraint?.isActive = false
sampleWorkbenchWidthConstraint = nil
sampleCurationWorkbench = nil
sampleSupportedAllelesSnapshot = nil
```

The multi-sample, row, cell, haplotyped, and empty-selection paths must all pass
through this teardown.

Pin the host inside the assignment wrapper:

```swift
NSLayoutConstraint.activate([
    editor.topAnchor.constraint(equalTo: wrapper.topAnchor),
    editor.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
    editor.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
    editor.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
])
```

Pin only the workbench width to the existing detail stack:

```swift
sampleWorkbenchWidthConstraint =
    workbench.widthAnchor.constraint(equalTo: detailStack.widthAnchor)
sampleWorkbenchWidthConstraint?.isActive = true
```

Do not change generic detail-stack alignment, other detail surfaces, or the
document bottom constraint.

- [ ] **Step 4: Keep live state in the SwiftUI editor**

Inside the editor's existing card header, display:

```swift
HStack {
    VStack(alignment: .leading, spacing: 2) {
        Text("Haplotype Assignments")
            .font(headingFont)
        Text("\(model.draft.assignedSlotCount) of 14 assigned")
            .font(captionFont)
            .foregroundStyle(.secondary)
    }
    Spacer()
    if model.draft.isDirty {
        Text("Unsaved")
            .font(captionFont)
            .foregroundStyle(.secondary)
    }
    Button("Save Assignments") {
        model.save()
    }
    .disabled(!model.canSave)
}
```

This keeps completeness, dirty state, and Save live without duplicating editor
state in AppKit. The sample header remains static read/QC context.

- [ ] **Step 5: Wire live content typography to the AppKit breakpoint**

Extend `makeGeneratedContentTypographyObservation`'s `afterApply` closure:

```swift
let canonical = max(NSFont.systemFontSize, 1)
let scale =
    manualHaplotypeEditorTypographyModel.scaledPointSize(
        fromCanonicalPointSize: canonical
    ) / canonical
sampleCurationWorkbench?.updateContentTypographyScale(scale)
sampleCurationWorkbench?.layoutSubtreeIfNeeded()
```

SwiftUI editor and evidence fonts continue updating through their observed
`ContentTypographyModel`. Add a live 100% → 200% test, not only a
construct-at-200% test.

- [ ] **Step 6: Run integration and existing detail tests**

```bash
swift test --filter 'GenotypeResultViewportTests/test(SelectedSampleWorkbench|SelectedColumn|SelectedLargeColumn|SharedGenotypeDetailContentIsAnchored)'
```

Expected: PASS. The workbench fills the detail stack, other detail surfaces are
unchanged, the inline evidence preview remains bounded, and selection state
still publishes all supported alleles.

- [ ] **Step 7: Commit**

```bash
git add Sources/LungfishGenotypeUI/GenotypeResultViewController.swift Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift
git commit -m "feat: present selected sample curation workbench"
```

### Task 5: Compact Copy/Export actions and preserve actual focus

**Files:**
- Modify: `Sources/LungfishGenotypeUI/GenotypeManualHaplotypeEditor.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift:5607-5635`
- Modify: `Tests/LungfishGenotypeUITests/GenotypeManualHaplotypeAccessibilityTests.swift`
- Modify: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`

- [ ] **Step 1: Write failing action and focus tests**

Assert:

- **Copy from Sample…** opens a searchable popover without increasing the
  workbench document height;
- **Export All Manual Definitions…** is in an overflow menu, not adjacent to
  Save;
- autocomplete and copy still mutate the same local draft;
- the actual `window.firstResponder` becomes MHC-A H1 after invoking
  **Edit Haplotype Assignments…**; and
- the focused combo frame intersects the detail clip view.

- [ ] **Step 2: Run tests and verify RED**

```bash
swift test --filter 'GenotypeManualHaplotypeAccessibilityTests|GenotypeResultViewportTests/testManualHaplotype.*Focus'
```

Expected: action placement and actual focus FAIL.

- [ ] **Step 3: Replace the height-expanding Copy disclosure**

Use:

```swift
@State private var showsCopyPopover = false

Button("Copy from Sample\u{2026}") {
    showsCopyPopover = true
}
.popover(isPresented: $showsCopyPopover) {
    copyPickerContents
        .frame(minWidth: 360, minHeight: 280)
        .padding(12)
}
```

Move the current disclosure body unchanged into `copyPickerContents`, retaining
search, completeness previews, and `model.copyAssignments(from:)`.

- [ ] **Step 4: Separate analysis-wide export from sample Save**

Place beside Copy:

```swift
Menu {
    Button("Export All Manual Definitions\u{2026}") {
        model.export()
    }
    .disabled(!model.canExport)
} label: {
    Image(systemName: "ellipsis.circle")
}
.accessibilityLabel("More haplotype assignment actions")
```

Remove the old footer export button. Keep the existing `model.export()` path so
provenance behavior is unchanged.

- [ ] **Step 5: Focus the real combo after layout**

In `focusManualHaplotypeEditor(sample:)`, lay out the mounted workbench and
defer combo discovery until SwiftUI has materialized its representable:

```swift
view.layoutSubtreeIfNeeded()
DispatchQueue.main.async { [weak self] in
    guard let self,
          let host = self.manualHaplotypeEditorHostView else {
        return
    }
    self.view.layoutSubtreeIfNeeded()
    guard let combo = self.descendantComboBox(
        in: host,
        accessibilityIdentifier: "manual-haplotype-MHC-A-h1"
    ) else {
        return
    }
    let fieldRect = combo.convert(
        combo.bounds,
        to: self.detailDocumentView
    )
    self.detailScrollView.contentView.scrollToVisible(fieldRect)
    self.detailScrollView.reflectScrolledClipView(
        self.detailScrollView.contentView
    )
    guard self.view.window?.makeFirstResponder(combo) == true else {
        return
    }
#if DEBUG
    self.testingLastManualHaplotypeFocusIdentifier =
        "manual-haplotype-MHC-A-h1"
#endif
}
```

- [ ] **Step 6: Run action, draft, focus, and accessibility tests**

```bash
swift test --filter 'GenotypeManualHaplotype(Editor|Accessibility)Tests|GenotypeResultViewportTests/testManualHaplotype'
```

Expected: PASS with bounded popovers, unchanged copy/autocomplete behavior,
separated action scope, and an actual visible first responder.

- [ ] **Step 7: Commit**

```bash
git add Sources/LungfishGenotypeUI/GenotypeManualHaplotypeEditor.swift Sources/LungfishGenotypeUI/GenotypeResultViewController.swift Tests/LungfishGenotypeUITests
git commit -m "fix: streamline manual haplotype actions and focus"
```

### Task 6: Lock ONT/miSeq genotype-only parity

**Files:**
- Modify: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`
- Modify: `Tests/LungfishGenotypeUITests/GenotypeManualHaplotypeAccessibilityTests.swift`

- [ ] **Step 1: Extend the explicit shared-renderer test**

For `.fullLengthONTMHCGenotype` and `.miSeqAmpliconMHCGenotype` genotype-only
manifests, seed Animal B with MHC-A H1 `Shared-H1`, then assert:

```swift
XCTAssertNotNil(controller.testingSampleWorkbenchLayoutMode, kind)
XCTAssertEqual(
    controller.testingManualHaplotypeEditorSample,
    "AnimalA",
    kind
)
XCTAssertEqual(
    controller.testingManualHaplotypeAutocompleteSuggestions(
        matching: "Shared"
    ),
    ["Shared-H1"],
    kind
)
controller.testingCopyManualHaplotypes(from: "AnimalB")
XCTAssertTrue(controller.testingManualHaplotypeEditorIsDirty, kind)
controller.testingSaveManualHaplotypeDraft()
XCTAssertFalse(controller.testingManualHaplotypeEditorIsDirty, kind)
XCTAssertEqual(
    controller.testingComparisonMatrix
        .testingManualHaplotypeBandValues(sample: "AnimalA").first,
    "Shared-H1 · —",
    kind
)
```

Use existing model methods in DEBUG helpers; do not duplicate production copy
or autocomplete logic. Assert the persisted sidecar contains Animal A's copied
assignments and that the workbook callback is exactly `[.markDirty]` for each
workflow kind.

- [ ] **Step 2: Preserve miSeq provisional `_nov` presentation**

Add a miSeq genotype-only fixture containing an `_nov` row and
`provisionalExon2SequencesByGenotype`. Save a manual assignment, then assert the
row remains visible and its provisional exon 2 detail still opens.

- [ ] **Step 3: Retain the named haplotyped-miSeq exclusion test**

Run the Phase 1 test that proves an explicit haplotyped miSeq result is
ineligible, mounts no editor/workbench, and offers no context command.

- [ ] **Step 4: Run parity tests**

```bash
swift test --filter 'GenotypeResultViewportTests/test(ManualHaplotypeSampleRenderer|GenotypeOnlyMiSeqPresentsProvisional|HaplotypedMiSeqExcludes)|GenotypeManualHaplotypeEligibilityTests'
```

Expected: the workbench, copy, autocomplete, save propagation, and `_nov`
presentation work in both genotype-only assay kinds; haplotyped miSeq remains
unchanged.

- [ ] **Step 5: Commit**

```bash
git add Tests/LungfishGenotypeUITests
git commit -m "test: verify manual curation across genotype-only MHC assays"
```

### Task 7: Final verification

**Files:**
- Modify only if verification exposes a regression:
  - `Sources/LungfishGenotypeUI/GenotypeSampleCurationWorkbenchView.swift`
  - `Sources/LungfishGenotypeUI/GenotypeSupportedAllelesPanel.swift`
  - `Sources/LungfishGenotypeUI/GenotypeManualHaplotypeEditor.swift`
  - `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift`
  - `Tests/LungfishGenotypeUITests`

- [ ] **Step 1: Run focused UI suites**

```bash
swift test --filter 'GenotypeResultViewportTests|GenotypeManualHaplotypeEditorTests|GenotypeManualHaplotypeAccessibilityTests|GenotypeManualHaplotypeEligibilityTests'
```

Expected: all selected tests PASS.

- [ ] **Step 2: Run the complete test suite**

```bash
swift test
```

Expected: PASS. If known sandbox-only filesystem watcher, Trash, or AppKit XPC
failures recur, save the full log and separately prove all changed-surface
suites pass.

- [ ] **Step 3: Build the debug app**

```bash
swift build --disable-sandbox --arch arm64
./scripts/build-app.sh --configuration debug --skip-build
```

Expected: both commands exit 0 and produce a signed debug app.

- [ ] **Step 4: Check formatting and scope**

```bash
git diff --check
git status --short
```

Expected: no whitespace errors and only planned source, test, and documentation
changes.

- [ ] **Step 5: Commit verification adjustments only if needed**

```bash
git add Sources/LungfishGenotypeUI Tests/LungfishGenotypeUITests
git commit -m "test: verify sample curation workbench"
```

Skip this commit when verification requires no changes.
