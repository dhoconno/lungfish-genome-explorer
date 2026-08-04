import XCTest
import AppKit
import SwiftUI
import LungfishCore
import LungfishIO
import LungfishKit
@testable import LungfishGenotypeUI

@MainActor
final class GenotypeCallEvidenceViewTests: XCTestCase {
    func testContentTypographyModelUpdatesEvidenceMetricsWithoutChangingEvidenceOrActions() {
        let notifications = NotificationCenter()
        let preference = MutableEvidenceTextSizePreference(.system)
        let provider = MutableEvidencePreferredFonts(pointSize: 13)
        let model = ContentTypographyModel(
            notificationCenter: notifications,
            preferenceProvider: { preference.value },
            preferredFontProvider: provider
        )
        let evidence = GenotypeCallEvidenceView.Evidence(
            sample: "DW472",
            locus: "MHC-DP",
            slot: .h1,
            callName: "M4DP",
            status: .called,
            observedGenotypeCount: 0,
            observedGenotypes: [],
            diagnosticAlleles: [],
            locusReadTotal: 100,
            neighborsBefore: [],
            neighborsAfter: []
        )
        let view = GenotypeCallEvidenceView(evidence: evidence, typographyModel: model)
        let baselineActions = GenotypeCallEvidenceView.unresolvedOverrideActions(for: evidence)

        for (sizePreference, expectedBodySize) in [
            (ContentTextSizePreference.system, CGFloat(13)),
            (.custom(90), CGFloat(11.7)),
            (.custom(150), CGFloat(19.5)),
            (.custom(200), CGFloat(26)),
        ] {
            preference.value = sizePreference
            notifications.post(name: .contentTextSizeDidChange, object: nil)

            XCTAssertEqual(
                view.testingContentTypographyPointSizes.body,
                expectedBodySize,
                accuracy: 0.01
            )
            XCTAssertEqual(
                view.testingContentTypographyPointSizes.caption,
                expectedBodySize,
                accuracy: 0.01
            )
            XCTAssertEqual(view.evidence, evidence)
            XCTAssertEqual(
                GenotypeCallEvidenceView.unresolvedOverrideActions(for: evidence),
                baselineActions
            )
        }
    }

    func testEvidenceUsesAdaptiveCardLayoutAndSharedContentTypography() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishGenotypeUI/GenotypeCallEvidenceView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("ViewThatFits(in: .horizontal)"))
        XCTAssertTrue(source.contains("typographyModel.font(for:"))
    }

    func testRendersEmptyState() {
        let view = GenotypeCallEvidenceView(evidence: nil)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 600)
        XCTAssertGreaterThan(host.frame.width, 0)
    }

    func testRendersFullEvidence() {
        let evidence = GenotypeCallEvidenceView.Evidence(
            sample: "H22C112",
            locus: "MHC-A",
            slot: .h2,
            callName: "M2A",
            status: .tooManyHaplotypes,
            observedGenotypeCount: 5,
            observedGenotypes: [
                "05_M1M2M3_A1_063g",
                "07_M1M2_70_156bp",
                "02_M2_G_02_06_156bp",
                "07_M3_70_156bp",
            ],
            diagnosticAlleles: [
                .init(allele: "05_M1M2M3_A1_063g", reads: 312, percentOfLocus: 0.41, isLowSupport: false),
                .init(allele: "07_M1M2_70_156bp", reads: 28, percentOfLocus: 0.036, isLowSupport: true),
                .init(allele: "02_M2_G_02_06_156bp", reads: 198, percentOfLocus: 0.26, isLowSupport: false),
            ],
            locusReadTotal: 757,
            neighborsBefore: [.init(animalId: "H22C115", summary: "M1A / M3A")],
            neighborsAfter: [.init(animalId: "H22C82", summary: "M1A / M1A")]
        )
        let view = GenotypeCallEvidenceView(evidence: evidence)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 800)
        XCTAssertGreaterThan(host.frame.width, 0)
    }

    func testNotAssayedEvidenceIsNotHomozygous() {
        let evidence = GenotypeCallEvidenceView.Evidence(
            sample: "DW474",
            locus: "MHC-DPB",
            slot: .h1,
            callName: "Not assayed",
            status: .notAssayed,
            observedGenotypeCount: 0,
            observedGenotypes: [],
            diagnosticAlleles: [],
            locusReadTotal: 0,
            neighborsBefore: [],
            neighborsAfter: [],
            errorExplanation: "MHC-DPB was not observed for this cohort.",
            h1Name: "Not assayed",
            h2Name: "Not assayed"
        )

        XCTAssertFalse(evidence.isHomozygous)
    }

    func testCandidateOverrideActionsShowWhichDiploidSlotWillChange() {
        let evidence = GenotypeCallEvidenceView.Evidence(
            sample: "DW472",
            locus: "MHC-DP",
            slot: .h1,
            callName: "M4DP",
            status: .tooManyHaplotypes,
            observedGenotypeCount: 3,
            observedGenotypes: [],
            diagnosticAlleles: [],
            locusReadTotal: 500,
            neighborsBefore: [],
            neighborsAfter: [],
            h1Name: "M4DP",
            h2Name: "M7DP"
        )
        let candidate = GenotypeCallEvidenceView.CandidateHaplotype(
            name: "M3DP",
            observed: ["15_M3_DPA1_01"],
            missing: ["15_M3_DPB1_01"]
        )

        let actions = GenotypeCallEvidenceView.overrideActions(for: candidate, evidence: evidence)

        XCTAssertEqual(actions.map(\.slot), [.h1, .h2])
        XCTAssertEqual(actions.map(\.label), ["H1: M4DP -> M3DP", "H2: M7DP -> M3DP"])
        XCTAssertTrue(actions.first?.help.contains("H2 remains M7DP") ?? false)
        XCTAssertTrue(actions.last?.help.contains("H1 remains M4DP") ?? false)
    }

    func testGroupedCandidateOverrideActionsExpandToConcreteHaplotypes() {
        let evidence = GenotypeCallEvidenceView.Evidence(
            sample: "DW472",
            locus: "MHC-DP",
            slot: .h1,
            callName: "M4DP / M7DP",
            status: .tooManyHaplotypes,
            observedGenotypeCount: 3,
            observedGenotypes: [],
            diagnosticAlleles: [],
            locusReadTotal: 500,
            neighborsBefore: [],
            neighborsAfter: [],
            h1Name: "M4DP",
            h2Name: "M7DP"
        )
        let candidate = GenotypeCallEvidenceView.CandidateHaplotype(
            name: "M5/M6DP",
            observed: ["15_M5M6_DPA1_01"],
            missing: ["15_M5M6_DPB1_01"]
        )

        let actions = GenotypeCallEvidenceView.overrideActions(for: candidate, evidence: evidence)

        XCTAssertEqual(actions.map(\.haplotypeName), ["M5DP", "M5DP", "M6DP", "M6DP"])
        XCTAssertEqual(actions.map(\.label), [
            "H1: M4DP -> M5DP",
            "H2: M7DP -> M5DP",
            "H1: M4DP -> M6DP",
            "H2: M7DP -> M6DP",
        ])
        XCTAssertFalse(actions.contains { $0.haplotypeName == "M5/M6DP" })
    }

    func testUnresolvedOverrideActionsAllowQuestionMarkAssignments() {
        let evidence = GenotypeCallEvidenceView.Evidence(
            sample: "DW472",
            locus: "MHC-DP",
            slot: .h1,
            callName: "M4DP / M7DP",
            status: .tooManyHaplotypes,
            observedGenotypeCount: 3,
            observedGenotypes: [],
            diagnosticAlleles: [],
            locusReadTotal: 500,
            neighborsBefore: [],
            neighborsAfter: [],
            h1Name: "M4DP",
            h2Name: "M7DP"
        )

        let actions = GenotypeCallEvidenceView.unresolvedOverrideActions(for: evidence)

        XCTAssertEqual(actions.map(\.haplotypeName), ["?", "?"])
        XCTAssertEqual(actions.map(\.label), ["H1: M4DP -> ?", "H2: M7DP -> ?"])
        XCTAssertTrue(actions.first?.help.contains("Leave H1 unresolved") ?? false)
    }

    func testSlotOverrideMenuSeparatesRecommendedAndUnsupportedHaplotypes() throws {
        let evidence = GenotypeCallEvidenceView.Evidence(
            sample: "DW472",
            locus: "MHC-DP",
            slot: .h1,
            callName: "M4DP / M7DP",
            status: .tooManyHaplotypes,
            observedGenotypeCount: 3,
            observedGenotypes: [],
            diagnosticAlleles: [],
            locusReadTotal: 500,
            neighborsBefore: [],
            neighborsAfter: [],
            candidateHaplotypes: [
                .init(
                    name: "M3DP",
                    observed: ["15_M3_DPA1_01"],
                    missing: ["15_M3_DPB1_01"]
                )
            ],
            h1Name: "M4DP",
            h2Name: "M7DP",
            availableHaplotypeNames: ["M3DP", "M4DP", "M5DP", "M6DP", "M7DP"]
        )

        let sections = GenotypeCallEvidenceView.overrideActionSections(for: .h1, evidence: evidence)

        XCTAssertEqual(sections.recommended.map(\.label), ["H1: M4DP -> M3DP"])
        XCTAssertEqual(sections.unsupported.map(\.label), [
            "H1: M4DP -> M5DP (no genotype support)",
            "H1: M4DP -> M6DP (no genotype support)",
            "H1: M4DP -> M7DP (no genotype support)",
        ])
        XCTAssertTrue(sections.unsupported.allSatisfy { $0.help.contains("linked-locus evidence") })

        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishGenotypeUI/GenotypeCallEvidenceView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("Divider()"))
    }

    func testAlleleDisplayPrefersConventionalMetadataAndKeepsFullHeader() {
        let header = "MCM_MHC_MiSeq_0068|source_loci=MHC-A1|haplotypes=M1,M2,M3|alleles=Mamu-A1_063:01:01:01,Mamu-A1_063:02:01:01|evidence_classes=primary_expressed"

        let label = GenotypeCallEvidenceView.AlleleLabel(header)

        XCTAssertEqual(label.primary, "Mamu-A1*063:01:01:01/Mamu-A1*063:02:01:01")
        XCTAssertEqual(label.secondary, "")
        XCTAssertEqual(label.badge, "primary")
        XCTAssertEqual(label.associatedHaplotypes, ["M1", "M2", "M3"])
        XCTAssertEqual(label.fullHeader, header)
    }

    func testGenotypeEvidenceSectionsUseExcelOrderAndCanBeHidden() throws {
        let sections = [
            GenotypeCallEvidenceView.GenotypeEvidenceSection(
                GenotypeCallEvidenceView.AnimalGenotype(
                    genotype: "13_Mafa_DQB1_06g1|source_loci=MHC-DQB1|haplotypes=M1|alleles=Mafa-DQB1_06:01",
                    locus: "MHC-DQ",
                    reads: 40,
                    isDiagnosticForCall: false,
                    associatedHaplotypes: ["M1"]
                )
            ),
            GenotypeCallEvidenceView.GenotypeEvidenceSection(
                GenotypeCallEvidenceView.AnimalGenotype(
                    genotype: "MCM_MHC_MiSeq_0073|source_loci=MHC-B|haplotypes=M1B|alleles=Mafa-B_073:01",
                    locus: "MHC-B",
                    reads: 66,
                    isDiagnosticForCall: true,
                    associatedHaplotypes: ["M1B"]
                )
            ),
            GenotypeCallEvidenceView.GenotypeEvidenceSection(
                GenotypeCallEvidenceView.AnimalGenotype(
                    genotype: "04_Mafa_AG_05_3mis_156bp|source_loci=MHC-AG|haplotypes=M1",
                    locus: "MHC-A",
                    reads: 30,
                    isDiagnosticForCall: false,
                    associatedHaplotypes: ["M1"]
                )
            ),
            GenotypeCallEvidenceView.GenotypeEvidenceSection(
                GenotypeCallEvidenceView.AnimalGenotype(
                    genotype: "01_Mafa_F_01_06|source_loci=MHC-F|haplotypes=M1",
                    locus: "MHC-A",
                    reads: 20,
                    isDiagnosticForCall: false,
                    associatedHaplotypes: ["M1"]
                )
            ),
        ]

        XCTAssertEqual(sections.map(\.title), ["Mafa-DQA/DQB", "Mafa-B", "Mafa-AG", "Mafa-F"])
        XCTAssertEqual(sections.sorted().map(\.title), ["Mafa-F", "Mafa-AG", "Mafa-B", "Mafa-DQA/DQB"])

        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishGenotypeUI/GenotypeCallEvidenceView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertTrue(source.contains("@State private var hiddenGenotypeSections"))
        XCTAssertTrue(source.contains("genotypeSectionVisibilityMenu"))
        XCTAssertTrue(source.contains("Diagnostic"))
        XCTAssertTrue(source.contains("Associated"))
        XCTAssertTrue(source.contains("Other"))
    }

    func testClassIIGenotypeSubsectionsSortAlphaChainsBeforeBetaChains() {
        let dqb = GenotypeCallEvidenceView.AnimalGenotype(
            genotype: "MCM_MHC_MiSeq_0173|source_loci=MHC-DQB1|haplotypes=M1DQ|alleles=Mafa-DQB1_06:01",
            locus: "MHC-DQ",
            reads: 200,
            isDiagnosticForCall: true,
            associatedHaplotypes: ["M1DQ"]
        )
        let dqa = GenotypeCallEvidenceView.AnimalGenotype(
            genotype: "MCM_MHC_MiSeq_0025|source_loci=MHC-DQA1|haplotypes=M1DQ|alleles=Mafa-DQA1_01:01",
            locus: "MHC-DQ",
            reads: 10,
            isDiagnosticForCall: false,
            associatedHaplotypes: ["M1DQ"]
        )
        let dpb = GenotypeCallEvidenceView.AnimalGenotype(
            genotype: "MCM_MHC_MiSeq_0154|source_loci=MHC-DPB1|haplotypes=M1DP|alleles=Mafa-DPB1_01:01",
            locus: "MHC-DP",
            reads: 200,
            isDiagnosticForCall: true,
            associatedHaplotypes: ["M1DP"]
        )
        let dpa = GenotypeCallEvidenceView.AnimalGenotype(
            genotype: "MCM_MHC_MiSeq_0007|source_loci=MHC-DPA1|haplotypes=M1DP|alleles=Mafa-DPA1_01:01",
            locus: "MHC-DP",
            reads: 10,
            isDiagnosticForCall: false,
            associatedHaplotypes: ["M1DP"]
        )

        XCTAssertLessThan(
            GenotypeCallEvidenceView.GenotypeEvidenceSection.subsectionRank(for: dqa),
            GenotypeCallEvidenceView.GenotypeEvidenceSection.subsectionRank(for: dqb)
        )
        XCTAssertLessThan(
            GenotypeCallEvidenceView.GenotypeEvidenceSection.subsectionRank(for: dpa),
            GenotypeCallEvidenceView.GenotypeEvidenceSection.subsectionRank(for: dpb)
        )
    }

    func testGenotypeAgreementClassificationUsesCalledHaplotypes() {
        let evidence = GenotypeCallEvidenceView.Evidence(
            sample: "LF2830",
            locus: "MHC-B",
            slot: .h1,
            callName: "M1B / M4B",
            status: .called,
            observedGenotypeCount: 2,
            observedGenotypes: [],
            diagnosticAlleles: [],
            locusReadTotal: 100,
            neighborsBefore: [],
            neighborsAfter: [],
            h1Name: "M1B",
            h2Name: "M4B"
        )
        let agreeing = GenotypeCallEvidenceView.AnimalGenotype(
            genotype: "MCM_MHC_MiSeq_0073|source_loci=MHC-B|haplotypes=M1B|alleles=Mafa-B_073:01",
            locus: "MHC-B",
            reads: 66,
            isDiagnosticForCall: false,
            associatedHaplotypes: ["M1B"]
        )
        let discordant = GenotypeCallEvidenceView.AnimalGenotype(
            genotype: "MCM_MHC_MiSeq_0125|source_loci=MHC-B17|haplotypes=M6B|alleles=Mafa-B_125:01",
            locus: "MHC-B",
            reads: 3,
            isDiagnosticForCall: false,
            associatedHaplotypes: ["M6B"]
        )

        XCTAssertEqual(GenotypeCallEvidenceView.genotypeAgreement(agreeing, evidence: evidence), .agreesWithCalledHaplotype)
        XCTAssertEqual(GenotypeCallEvidenceView.genotypeAgreement(discordant, evidence: evidence), .outsideCalledHaplotypes)
    }

    func testCandidateSelectionReasonExplainsAlternatives() {
        let evidence = GenotypeCallEvidenceView.Evidence(
            sample: "DW472",
            locus: "MHC-DP",
            slot: .h1,
            callName: "M4DP / M7DP",
            status: .tooManyHaplotypes,
            observedGenotypeCount: 3,
            observedGenotypes: [],
            diagnosticAlleles: [],
            locusReadTotal: 500,
            neighborsBefore: [],
            neighborsAfter: [],
            h1Name: "M4DP",
            h2Name: "M7DP"
        )

        XCTAssertEqual(
            GenotypeCallEvidenceView.selectionReason(
                for: .init(name: "M4DP", observed: ["15_M4_DPA1_01"], missing: []),
                evidence: evidence
            ),
            "Selected for H1"
        )
        XCTAssertEqual(
            GenotypeCallEvidenceView.selectionReason(
                for: .init(name: "M3DP", observed: ["15_M3_DPA1_01"], missing: ["15_M3_DPB1_01"]),
                evidence: evidence
            ),
            "Not selected: missing 1 diagnostic allele"
        )
    }

    func testPendingOverridesCanStageBothSlotsBeforeApply() {
        var pending = GenotypeCallEvidenceView.PendingOverrides()

        pending.stage(.init(slot: .h1, haplotypeName: "M3DP"))
        pending.stage(.init(slot: .h2, haplotypeName: "M5DP"))

        XCTAssertEqual(pending.requests, [
            .init(slot: .h1, haplotypeName: "M3DP"),
            .init(slot: .h2, haplotypeName: "M5DP"),
        ])
        XCTAssertFalse(pending.isEmpty)
    }

    func testRenderedPendingOverrideClearsOnlyAfterChangedCallback() throws {
        for outcome in [
            GenotypeHaplotypeMutationOutcome.unchanged,
            .failure,
            .changed,
        ] {
            var callbackRequests: [[
                GenotypeCallEvidenceView.HaplotypeOverrideRequest
            ]] = []
            let mounted = mountEvidenceView(
                onOverridesRequested: {
                    callbackRequests.append($0)
                    return outcome
                }
            )
            defer { mounted.window.close() }
            let stage = try XCTUnwrap(
                button(
                    "genotype-call-evidence-stage-h1-M3DP",
                    in: mounted.host
                )
            )
            stage.performClick(nil)
            flush(mounted.host)
            let apply = try XCTUnwrap(
                button(
                    "genotype-call-evidence-apply-pending",
                    in: mounted.host
                )
            )
            XCTAssertTrue(mounted.window.makeFirstResponder(apply))

            apply.performClick(nil)
            flush(mounted.host)

            XCTAssertEqual(callbackRequests, [[
                .init(slot: .h1, haplotypeName: "M3DP"),
            ]])
            let retainedApply = button(
                "genotype-call-evidence-apply-pending",
                in: mounted.host
            )
            if outcome == .changed {
                XCTAssertNil(retainedApply)
            } else {
                XCTAssertTrue(retainedApply === apply)
                XCTAssertTrue(mounted.window.firstResponder === apply)
            }
        }
    }

    func testCandidateRowsUseSlotExplicitSetHaplotypeButtonsAndNotObservedMarkers() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishGenotypeUI/GenotypeCallEvidenceView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(source.contains("Menu(\"Override"))
        XCTAssertFalse(source.contains("Button(\"Set haplotype"))
        XCTAssertTrue(source.contains("overrideActions(for: candidate, evidence: evidence)"))
        XCTAssertTrue(source.contains("@State private var pendingOverrides"))
        XCTAssertTrue(source.contains("outcome = onOverridesRequested(requests)"))
        XCTAssertTrue(source.contains("GenotypeMutationActionButton("))
        XCTAssertTrue(source.contains("[not observed]"))
        XCTAssertTrue(source.contains("haplotypeSlotCards(evidence)"))
        XCTAssertTrue(source.contains("slotCard("))
        XCTAssertTrue(source.contains("candidateAlternativesCard(evidence)"))
        XCTAssertTrue(source.contains("animalGenotypesColumn(evidence)"))
        XCTAssertTrue(source.contains("Menu"))
        XCTAssertFalse(source.contains("diagnosticAlleles(evidence)"))
        XCTAssertFalse(source.contains("coverageBar(evidence)"))
        XCTAssertFalse(source.contains("neighbors(evidence)"))
    }

    private typealias MountedEvidence = (
        window: NSWindow,
        host: NSHostingView<GenotypeCallEvidenceView>
    )

    private func mountEvidenceView(
        onOverridesRequested: @escaping (
            [GenotypeCallEvidenceView.HaplotypeOverrideRequest]
        ) -> GenotypeHaplotypeMutationOutcome
    ) -> MountedEvidence {
        let evidence = GenotypeCallEvidenceView.Evidence(
            sample: "DW472",
            locus: "MHC-DP",
            slot: .h1,
            callName: "M4DP / M7DP",
            status: .tooManyHaplotypes,
            observedGenotypeCount: 3,
            observedGenotypes: [],
            diagnosticAlleles: [],
            locusReadTotal: 500,
            neighborsBefore: [],
            neighborsAfter: [],
            candidateHaplotypes: [
                .init(
                    name: "M3DP",
                    observed: ["15_M3_DPA1_01"],
                    missing: ["15_M3_DPB1_01"]
                ),
            ],
            h1Name: "M4DP",
            h2Name: "M7DP",
            availableHaplotypeNames: ["M3DP", "M4DP", "M7DP"]
        )
        var view = GenotypeCallEvidenceView(evidence: evidence)
        view.onOverridesRequested = onOverridesRequested
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 1_200, height: 1_600)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        flush(host)
        return (window, host)
    }

    private func flush(_ host: NSView) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.08))
        host.layoutSubtreeIfNeeded()
    }

    private func button(_ identifier: String, in root: NSView) -> NSButton? {
        let buttons = descendants(of: root).compactMap { $0 as? NSButton }
        let match = buttons.first {
            $0.accessibilityIdentifier() == identifier
        }
        return match
    }

    private func descendants(of root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    func testCandidateAlleleLinesUseDisplayLabelForMissingAlleles() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishGenotypeUI/GenotypeCallEvidenceView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("compactAlleleLine(Self.displayAlleleLabel(allele), marker: \"missing\")"))
        XCTAssertTrue(source.contains("static func displayAlleleLabel"))
    }

    func testOutlineDoesNotRenderTrailingExclamationNoteColumn() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishGenotypeUI/GenotypeOutlineView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(source.contains("makeNoteGlyph"))
        XCTAssertFalse(source.contains("labelWithString: \"!\""))
        XCTAssertFalse(source.contains("\\u{26A0}"))
        XCTAssertFalse(source.contains("trailingGutter"))
        XCTAssertFalse(source.contains("handleDisclosureToggle"))
        XCTAssertFalse(source.contains("makeDisclosedDetail"))
        XCTAssertFalse(source.contains("\\u{25B6}"))
    }

    func testReviewInspectorDoesNotUseTransientCellPopover() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishGenotypeUI/GenotypeResultViewController.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(source.contains("NSPopover"))
        XCTAssertFalse(source.contains("presentCellEvidencePopover"))
        XCTAssertTrue(source.contains("selectCellEvidence"))
    }

    func testResultViewportShowsRunThresholdSummaryInsteadOfDropoutEditor() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishGenotypeUI/GenotypeResultViewController.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(source.contains("Dropout Thresholds"))
        XCTAssertFalse(source.contains("makeDropoutThresholdHost"))
        XCTAssertFalse(source.contains("applyDropoutThresholds"))
        XCTAssertTrue(source.contains("Haplotype Thresholds"))
        XCTAssertTrue(source.contains("Rerun miSeq amplicon MHC genotyping"))
    }
}

@MainActor
private final class MutableEvidenceTextSizePreference {
    var value: ContentTextSizePreference

    init(_ value: ContentTextSizePreference) {
        self.value = value
    }
}

@MainActor
private final class MutableEvidencePreferredFonts: ContentPreferredFontProviding {
    var pointSize: CGFloat

    init(pointSize: CGFloat) {
        self.pointSize = pointSize
    }

    func preferredFont(for role: ContentTypography.Role) -> NSFont {
        switch role {
        case .monospaced:
            return .monospacedSystemFont(ofSize: pointSize, weight: .regular)
        case .emphasizedBody, .tableHeader:
            return .systemFont(ofSize: pointSize, weight: .semibold)
        default:
            return .systemFont(ofSize: pointSize)
        }
    }

    func canonicalUnscaledPointSize(for role: ContentTypography.Role) -> CGFloat {
        13
    }
}
