import AppKit
@testable import LungfishCore
import LungfishGenotypeUI
import LungfishIO
import LungfishKit
import SwiftUI
import XCTest
import ViewInspector
@testable import LungfishApp

@MainActor
final class GenotypeInspectorPresentationTests: XCTestCase {
    func testGenotypeInspectorRoutesExactlyFiveTabsToTheirSections() throws {
        let model = makePopulatedModel()

        XCTAssertEqual(
            model.availableTabs,
            [.bundle, .selectedItem, .annotations, .view, .provenance]
        )

        for tab in model.availableTabs {
            model.selectedTab = tab
            let inspected = try InspectorView(viewModel: model).inspect()
            switch tab {
            case .bundle:
                _ = try inspected.find(ViewType.View<GenotypeResultDocumentSection>.self)
            case .selectedItem:
                _ = try inspected.find(ViewType.View<SelectionSection>.self)
            case .annotations:
                _ = try inspected.find(ViewType.View<GenotypeMatrixAnnotationSection>.self)
            case .view:
                _ = try inspected.find(ViewType.View<GenotypeResultDisplaySection>.self)
            case .provenance:
                _ = try inspected.find(ViewType.View<ProvenanceSection>.self)
            default:
                XCTFail("Unexpected genotype Inspector tab: \(tab)")
            }
        }
    }

    func testMountedAnnotationColorControlsExposeNativeNamesAndValues() async throws {
        let model = makePopulatedModel()
        model.selectedTab = .annotations
        let mounted = mount(model: model, width: 420, height: 1_400)
        defer { mounted.window.close() }
        try await settle(mounted.host)

        let colorWells = descendantViews(of: mounted.host).compactMap { $0 as? NSColorWell }
        XCTAssertEqual(colorWells.count, 3)
        XCTAssertEqual(Set(colorWells.compactMap { $0.accessibilityLabel() }), [
            "Fill color", "Text color", "Border color",
        ])
        XCTAssertTrue(colorWells.allSatisfy {
            !($0.accessibilityValueDescription() ?? "").isEmpty
        })
    }

    func testRenderPopulatedFiveTabInspectorAtNativeWidthsAndEnlargedText() async throws {
        guard let path = ProcessInfo.processInfo.environment[
            "LUNGFISH_GENOTYPE_INSPECTOR_QA_DIR"
        ] else {
            throw XCTSkip("Set LUNGFISH_GENOTYPE_INSPECTOR_QA_DIR for visual verification")
        }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let suiteName = "GenotypeInspectorPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let restoreSettings = AppSettings.isolateForTesting(defaults: defaults)
        defer {
            restoreSettings()
            defaults.removePersistentDomain(forName: suiteName)
        }

        for percentage in [100, 200] {
            AppSettings.shared.contentTextSizePreference = .custom(percentage)
            AppSettings.shared.save()
            for width in [CGFloat(300), 420] {
                let model = makePopulatedModel()
                for tab in model.availableTabs {
                    model.selectedTab = tab
                    let mounted = mount(
                        model: model,
                        width: width,
                        height: percentage == 200 ? 3_600 : 2_200,
                        expandProvenanceDetails: true
                    )
                    try await settle(mounted.host)
                    let bitmap = try XCTUnwrap(
                        mounted.host.bitmapImageRepForCachingDisplay(in: mounted.host.bounds)
                    )
                    mounted.host.cacheDisplay(in: mounted.host.bounds, to: bitmap)
                    let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    let filename = "genotype-inspector-\(tab.rawValue)-w\(Int(width))-p\(percentage).png"
                    try data.write(to: output.appendingPathComponent(filename))
                    mounted.window.close()
                }
            }
        }
    }

    private func makePopulatedModel() -> InspectorViewModel {
        let model = InspectorViewModel()
        model.contentMode = .genotype
        model.documentSectionViewModel.updateGenotypeResultDocument(.init(
            title: "Paired MiSeq MHC genotyping — September validation cohort",
            subtitle: "Haplotyped run with retained review context and one-way workbook export",
            bundleURL: URL(fileURLWithPath: "/synthetic/validation cohort/result.lungfishgenotype"),
            sampleIds: ["Animal-A-long-identity", "Animal-B"],
            summaryRows: [
                ("Workflow", "Paired haplotyped MiSeq MHC genotyping"),
                ("Reference", "Mauritian cynomolgus macaque definition set 2026.09"),
                ("Run identifier", "run-2026-09-13-long-reproducible-identifier"),
            ],
            qcRows: [
                ("Overall", "Passed with one analyst-reviewed false-positive cell"),
                ("Retained reads", "184,203 of 190,551"),
            ],
            artifactRows: [
                .init(
                    label: "Editable Excel workbook snapshot",
                    fileURL: URL(fileURLWithPath: "/synthetic/validation cohort/result.xlsx")
                ),
            ],
            availableHaplotypeLoci: ["MHC-A", "MHC-B", "MHC-DRB"],
            includedHaplotypeLoci: ["MHC-A", "MHC-B", "MHC-DRB"],
            defaultIncludedHaplotypeLoci: ["MHC-A", "MHC-B"],
            hasHaplotypingResult: true,
            haplotypeDefinitionRows: [
                ("Active", "Mauritian cynomolgus macaques — validated production definitions"),
                ("Definition ID", "MHC-exon2-miSeq.mauritian-cynomolgus-macaques"),
            ],
            haplotypeDefinitionsFolderURL: URL(fileURLWithPath: "/synthetic/definitions")
        ))

        let target = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A",
            genotype: "01_Mafa_A1_001_01/01_Mafa_A1_001_02",
            sample: "Animal-A-long-identity"
        )
        let selection = GenotypeResultSelectionState(
            title: "Animal-A-long-identity",
            subtitle: "Selected sample · paired haplotyped MiSeq result",
            detailRows: [
                ("Animal identity", "Animal-A-long-identity-associated-with-validation-cohort-2026"),
                ("Alleles", "01_Mafa_A1_001_01 / 01_Mafa_A1_001_02 / unresolved shared support"),
                ("Status", "Reviewed — false-positive annotation retained in audit history"),
            ],
            highlightTarget: .init(
                genotype: "01_Mafa_A1_001_01/01_Mafa_A1_001_02",
                locus: "MHC-A",
                sample: "Animal-A-long-identity"
            ),
            matrixTargets: [target],
            animalId: "Animal-A-long-identity"
        )
        model.selectionSectionViewModel.select(genotypeResultSelection: selection)

        let display = model.genotypeResultDisplaySectionViewModel
        display.update(
            isAvailable: true,
            state: .init(
                summaryViewMode: .matrix,
                cellColorMode: .haplotype,
                diagnosticAllelesOnly: true,
                matrixMinimumReads: 12,
                matrixMinimumPercent: 2.5,
                matrixPercentDenominator: .sampleRetained,
                matrixRowFilterText: "MHC-A shared allele",
                matrixSampleFilterText: "Animal-A"
            ),
            hasHaplotypingResult: true
        )
        display.updateSummary(visibleRows: 17, totalRows: 24, hiddenCells: 6)
        display.updateSelection(selection)
        display.isMatrixAppearanceExpanded = true
        display.updateMatrixReviewCapability(GenotypeMatrixReviewCapability.evaluate(
            selection: [target],
            evidence: .init([target: 42]),
            reviews: [
                .init(
                    target: target,
                    disposition: .falsePositive,
                    author: "Analyst Example",
                    timestamp: "2026-09-13T15:30:00Z"
                ),
            ],
            comments: [
                .init(
                    target: target,
                    body: "Reviewed against the paired read evidence; retain this note with the cell.",
                    author: "Analyst Example",
                    timestamp: "2026-09-13T15:31:00Z"
                ),
            ],
            isWritable: true
        ))

        let provenance = model.provenanceSectionViewModel
        provenance.summary = .init(
            workflowName: "Paired MiSeq MHC genotyping",
            workflowVersion: "6.4.0",
            toolName: "lungfish-genotype",
            toolVersion: "6.4.0",
            createdAt: Date(timeIntervalSince1970: 1_789_312_200),
            schemaVersion: 3,
            runID: UUID(uuidString: "11111111-2222-3333-4444-555555555555"),
            sidecarPath: "/synthetic/validation cohort/result.lungfishgenotype/provenance/run.json",
            statusLabel: "Verified reproducibility record",
            exitStatus: 0,
            wallTimeSeconds: 128.4,
            stepCount: 1,
            inputCount: 2,
            outputCount: 3,
            signatureCount: 1
        )
        provenance.warnings = [
            .init(
                title: "Review annotation present",
                message: "The exported snapshot includes analyst-authored cell review context."
            ),
        ]
        provenance.lineageRuns = [
            .init(
                id: UUID(),
                title: "Genotyping workflow",
                subtitle: "Completed with captured invocation and runtime identity",
                steps: [
                    .init(
                        id: UUID(), ordinal: 1, toolName: "lungfish-genotype",
                        toolVersion: "6.4.0",
                        command: "lungfish-genotype call --assay MHC-exon2-miSeq --paired reads_R1.fastq reads_R2.fastq",
                        inputPaths: ["/synthetic/reads_R1.fastq", "/synthetic/reads_R2.fastq"],
                        outputPaths: ["/synthetic/validation cohort/result.lungfishgenotype"],
                        exitStatus: 0, wallTimeSeconds: 128.4, stderr: "", dependsOn: []
                    ),
                ]
            ),
        ]
        provenance.fileRows = [
            .init(
                role: "Final output",
                path: "/synthetic/validation cohort/result.lungfishgenotype/matrix/genotypes.tsv",
                displayPath: "matrix/genotypes-with-long-stable-identities.tsv",
                checksumSHA256: String(repeating: "a1", count: 32),
                fileSize: 184_203,
                fileSizeLabel: "179.9 KB",
                format: "TSV"
            ),
        ]
        provenance.optionRows = [
            .init(kind: "resolved", name: "assay", value: "MHC-exon2-miSeq"),
        ]
        provenance.runtimeRows = [
            .init(label: "Runtime", value: "macOS arm64 · Swift 6 · conda env genotype-2026.09"),
        ]
        provenance.rawJSON = "{\"workflow\":\"Paired MiSeq MHC genotyping\",\"exitStatus\":0}"
        provenance.copyableText = "Paired MiSeq MHC genotyping provenance"
        return model
    }

    private func mount(
        model: InspectorViewModel,
        width: CGFloat,
        height: CGFloat,
        expandProvenanceDetails: Bool = false
    ) -> (window: NSWindow, host: NSHostingView<InspectorView>) {
        let host = NSHostingView(rootView: InspectorView(
            viewModel: model,
            provenanceDetailsInitiallyExpanded: expandProvenanceDetails
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.appearance = NSAppearance(named: .aqua)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()
        return (window, host)
    }

    private func settle(_ host: NSView) async throws {
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(180))
        host.layoutSubtreeIfNeeded()
    }

    private func descendantViews(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendantViews(of: $0) }
    }

}
