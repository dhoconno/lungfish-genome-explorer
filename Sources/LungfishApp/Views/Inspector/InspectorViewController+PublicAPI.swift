// InspectorViewController.swift - Selection details inspector
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishTwelveSUI
import SwiftUI
import LungfishCore
import LungfishIO
import LungfishGenotypeUI
import LungfishPhylogeneticsUI
import LungfishWorkflow
import os.log

extension InspectorViewController {
    // MARK: - Public API

    /// Updates the document tab with bundle metadata from a loaded reference bundle.
    ///
    /// - Parameters:
    ///   - manifest: The bundle manifest to display, or nil to clear
    ///   - bundleURL: The URL of the loaded bundle
    public func updateBundleMetadata(manifest: BundleManifest?, bundleURL: URL?) {
        viewModel.documentSectionViewModel.update(manifest: manifest, bundleURL: bundleURL)
        if let bundleURL {
            updateProvenanceTarget(
                url: bundleURL,
                sidebarType: .referenceBundle,
                displayName: manifest?.name ?? bundleURL.deletingPathExtension().lastPathComponent
            )
        }
    }

    func updateReferenceBundleDocumentState(
        manifest: BundleManifest?,
        bundleURL: URL?,
        bundle: ReferenceBundle?
    ) {
        updateBundleMetadata(manifest: manifest, bundleURL: bundleURL)

        if let bundle {
            viewModel.selectionSectionViewModel.referenceBundle = bundle
            viewModel.documentSectionViewModel.referenceTrackCapabilities =
                ReferenceBundleTrackCapabilities(bundle: bundle)
            updateSampleSection(from: bundle)
        }

        // Auto-select the first chromosome so the Chromosome section is visible immediately.
        if let chromosomes = manifest?.genome?.chromosomes, !chromosomes.isEmpty {
            let sorted = naturalChromosomeSort(chromosomes)
            updateSelectedChromosome(sorted.first)
        }
    }

    /// Updates the Document inspector with assembly provenance, source inputs, and artifact links.
    public func updateAssemblyDocument(
        result: AssemblyResult,
        provenance: AssemblyProvenance?,
        projectURL: URL?
    ) {
        let sourceRows = provenance.map {
            AssemblyInspectorSourceResolver.resolve(provenanceInputs: $0.inputs, projectURL: projectURL)
        } ?? []

        let state = AssemblyDocumentState(
            title: result.outputDirectory.lastPathComponent,
            subtitle: "\(result.tool.displayName) • \(result.readType.displayName)",
            sourceData: sourceRows,
            contextRows: assemblyContextRows(result: result, provenance: provenance),
            artifactRows: assemblyArtifactRows(result: result)
        )

        viewModel.documentSectionViewModel.navigateToSourceData = { [weak self] url in
            NotificationCenter.default.post(
                name: .navigateToSidebarItem,
                object: nil,
                userInfo: self?.windowScopedUserInfo(["url": url])
            )
        }
        viewModel.documentSectionViewModel.updateAssemblyDocument(state)
        updateProvenanceTarget(
            url: result.outputDirectory,
            sidebarType: .analysisResult,
            displayName: result.outputDirectory.lastPathComponent
        )
        viewModel.selectedTab = .bundle
    }

    /// Updates the Document inspector with a prebuilt mapping document state.
    func updateMappingDocument(_ state: MappingDocumentState?) {
        if state != nil {
            viewModel.documentSectionViewModel.navigateToSourceData = { [weak self] url in
                NotificationCenter.default.post(
                    name: .navigateToSidebarItem,
                    object: nil,
                    userInfo: self?.windowScopedUserInfo(["url": url])
                )
            }
        } else {
            viewModel.documentSectionViewModel.navigateToSourceData = nil
        }
        viewModel.documentSectionViewModel.updateMappingDocument(state)
        if state != nil {
            viewModel.selectedTab = .bundle
        }
    }

    /// Updates the Document inspector with multiple-sequence-alignment bundle statistics.
    func updateMultipleSequenceAlignmentDocument(_ bundle: MultipleSequenceAlignmentBundle) {
        let manifest = bundle.manifest
        viewModel.readStyleSectionViewModel.clear()
        viewModel.readStyleSectionViewModel.hasMultipleSequenceAlignmentBundle = true
        viewModel.readStyleSectionViewModel.msaReferenceRowOptions = bundle.rows.map {
            MSAReferenceRowOption(id: $0.id, name: $0.displayName)
        }
        viewModel.readStyleSectionViewModel.selectedMSAReferenceRowID =
            manifest.referenceRowID
            ?? bundle.rows.first?.id
        viewModel.readStyleSectionViewModel.onSettingsChanged = { [weak self] in
            guard let self else { return }
            NotificationCenter.default.post(
                name: .readDisplaySettingsChanged,
                object: self,
                userInfo: self.windowScopedUserInfo(
                    self.makeReadDisplaySettingsPayload(from: self.viewModel.readStyleSectionViewModel)
                )
            )
        }
        let state = MultipleSequenceAlignmentDocumentState(
            title: manifest.name,
            subtitle: "\(manifest.sourceFormat.rawValue) • \(manifest.alphabet)",
            summary: "\(manifest.rowCount) sequences • \(manifest.alignedLength) aligned columns",
            contextRows: [
                ("Sequences", "\(manifest.rowCount)"),
                ("Aligned Columns", "\(manifest.alignedLength)"),
                ("Alphabet", manifest.alphabet),
                ("Variable Sites", "\(manifest.variableSiteCount)"),
                ("Parsimony Informative", "\(manifest.parsimonyInformativeSiteCount)"),
                ("Source Format", manifest.sourceFormat.rawValue),
                ("Source File", manifest.sourceFileName),
            ],
            warningRows: manifest.warnings,
            artifactRows: [
                MultipleSequenceAlignmentDocumentArtifactRow(
                    label: "Aligned FASTA",
                    fileURL: bundle.url.appendingPathComponent("alignment/primary.aligned.fasta")
                ),
                MultipleSequenceAlignmentDocumentArtifactRow(
                    label: "Row Metadata",
                    fileURL: bundle.url.appendingPathComponent("metadata/rows.json")
                ),
                MultipleSequenceAlignmentDocumentArtifactRow(
                    label: "Alignment Index",
                    fileURL: bundle.url.appendingPathComponent("cache/alignment-index.sqlite")
                ),
                MultipleSequenceAlignmentDocumentArtifactRow(
                    label: "Provenance",
                    fileURL: bundle.url.appendingPathComponent(".lungfish-provenance.json")
                ),
            ],
            consensusPreview: String(manifest.consensus.prefix(160))
        )
        viewModel.documentSectionViewModel.updateMultipleSequenceAlignmentDocument(state)
        updateProvenanceTarget(
            url: bundle.url,
            sidebarType: .multipleSequenceAlignmentBundle,
            displayName: manifest.name
        )
        viewModel.selectedTab = .bundle
    }

    /// Updates the Document inspector with MHC amplicon reference bundle metadata.
    ///
    /// The bundle (`.lungfishmhcref`) is metadata-only: it has no viewport, so this
    /// loads its manifest plus any embedded haplotype definitions and surfaces them
    /// in the Bundle inspector tab.
    func updateMHCReferenceBundleDocument(_ bundleURL: URL) {
        viewModel.readStyleSectionViewModel.clear()

        guard let manifest = try? MHCAmpliconReferenceBundle.loadManifest(from: bundleURL) else {
            viewModel.documentSectionViewModel.updateMHCReferenceBundleDocument(nil)
            return
        }

        let definitions = (try? MHCAmpliconReferenceBundle.haplotypeDefinitions(in: bundleURL)) ?? []
        let definitionRows = definitions.map { definition -> MHCReferenceBundleDefinitionRow in
            let loci = definition.locusDefinitions.map(\.locus).joined(separator: ", ")
            return MHCReferenceBundleDefinitionRow(
                displayName: "\(definition.displayName) (\(definition.speciesName))",
                loci: loci.isEmpty ? "No loci" : loci
            )
        }
        let warningRows = manifest.warnings.map { warning in
            let context = [
                warning.recordIdentifier.map { "Record: \($0)" },
                warning.featureType.map { "Feature: \($0)" },
                warning.sourceLocation.map { "Location: \($0)" },
            ].compactMap { $0 }.joined(separator: " • ")
            return MHCReferenceBundleWarningRow(message: warning.message, context: context)
        }

        var artifactRows: [MHCReferenceBundleArtifactRow] = [
            MHCReferenceBundleArtifactRow(label: "Bundle Folder", fileURL: bundleURL),
        ]
        if let referenceURL = MHCAmpliconReferenceBundle.referenceFASTAURL(in: bundleURL) {
            artifactRows.append(
                MHCReferenceBundleArtifactRow(label: "Reference FASTA", fileURL: referenceURL)
            )
        }
        if let referenceBundleURL = MHCAmpliconReferenceBundle.referenceBundleURL(in: bundleURL) {
            artifactRows.append(
                MHCReferenceBundleArtifactRow(label: "Annotated Reference Bundle", fileURL: referenceBundleURL)
            )
            if let embeddedManifest = try? BundleManifest.load(from: referenceBundleURL) {
                for annotation in embeddedManifest.annotations {
                    guard let databasePath = annotation.databasePath,
                          let databaseURL = try? BundleManifest.validatedBundleMemberURL(
                            for: databasePath,
                            in: referenceBundleURL,
                            field: "annotations[\(annotation.id)].databasePath"
                          ) else { continue }
                    artifactRows.append(
                        MHCReferenceBundleArtifactRow(
                            label: "Annotation Database — \(annotation.name)",
                            fileURL: databaseURL
                        )
                    )
                }
            }
        }
        for url in MHCAmpliconReferenceBundle.haplotypeDefinitionURLs(in: bundleURL) {
            artifactRows.append(
                MHCReferenceBundleArtifactRow(
                    label: "Haplotype Definitions",
                    fileURL: url
                )
            )
        }
        if let provenanceURL = MHCAmpliconReferenceBundle.provenanceURL(in: bundleURL) {
            artifactRows.append(
                MHCReferenceBundleArtifactRow(
                    label: "Provenance",
                    fileURL: provenanceURL
                )
            )
        }

        let state = MHCReferenceBundleDocumentState(
            name: manifest.name,
            schemaVersion: manifest.schemaVersion,
            kind: manifest.kind,
            referenceCount: manifest.metrics.referenceCount,
            haplotypeDefinitionCount: manifest.metrics.haplotypeDefinitionCount,
            defaultDefinitionID: manifest.defaultHaplotypeDefinitionID,
            createdAt: manifest.createdAt,
            definitionRows: definitionRows,
            warningRows: warningRows,
            artifactRows: artifactRows,
            bundleURL: bundleURL,
            provenancePath: manifest.provenancePath
        )
        viewModel.documentSectionViewModel.updateMHCReferenceBundleDocument(state)
        updateProvenanceTarget(
            url: bundleURL,
            sidebarType: .mhcReferenceBundle,
            displayName: manifest.name
        )
        viewModel.selectedTab = .bundle
    }

    /// Updates the Document inspector with phylogenetic-tree bundle statistics.
    func updatePhylogeneticTreeDocument(_ bundle: PhylogeneticTreeBundle) {
        let manifest = bundle.manifest
        let rootedText = manifest.isRooted ? "rooted" : "unrooted"
        viewModel.readStyleSectionViewModel.clear()
        let state = PhylogeneticTreeDocumentState(
            title: manifest.name,
            subtitle: "\(manifest.sourceFormat) • \(rootedText)",
            summary: "\(manifest.tipCount) tips • \(manifest.internalNodeCount) internal nodes",
            contextRows: [
                ("Tips", "\(manifest.tipCount)"),
                ("Internal Nodes", "\(manifest.internalNodeCount)"),
                ("Rooting", manifest.isRooted ? "Rooted" : "Unrooted"),
                ("Source Format", manifest.sourceFormat),
                ("Primary Tree", manifest.primaryTreeID),
                ("Branch Unit", manifest.branchLengthUnit ?? "unspecified"),
                ("Source File", manifest.sourceFileName),
                ("Capabilities", manifest.capabilities.joined(separator: ", ")),
            ],
            warningRows: manifest.warnings,
            artifactRows: [
                PhylogeneticTreeDocumentArtifactRow(
                    label: "Primary Newick",
                    fileURL: bundle.url.appendingPathComponent("tree/primary.nwk")
                ),
                PhylogeneticTreeDocumentArtifactRow(
                    label: "Normalized Tree",
                    fileURL: bundle.url.appendingPathComponent("tree/primary.normalized.json")
                ),
                PhylogeneticTreeDocumentArtifactRow(
                    label: "Tree Index",
                    fileURL: bundle.url.appendingPathComponent("cache/tree-index.sqlite")
                ),
                PhylogeneticTreeDocumentArtifactRow(
                    label: "Provenance",
                    fileURL: bundle.url.appendingPathComponent(".lungfish-provenance.json")
                ),
            ]
        )
        viewModel.documentSectionViewModel.updatePhylogeneticTreeDocument(state)
        updateProvenanceTarget(
            url: bundle.url,
            sidebarType: .phylogeneticTreeBundle,
            displayName: manifest.name
        )
        viewModel.selectedTab = .bundle
    }

    /// Updates the Document inspector with genotype-result bundle statistics.
    func updateGenotypeResultDocument(_ result: ONTGenotypeResultBundleData) {
        loadedGenotypeResult = result
        let sampleIds = genotypeSampleIds(result)
        let metadataStore = SampleMetadataStore.load(
            from: result.bundleURL,
            knownSampleIds: Set(sampleIds)
        )
        metadataStore?.wireAutosave(bundleURL: result.bundleURL)
        // Loading via the store triggers default-cohort seeding the first
        // time a bundle is opened so the inspector lists Needs review et al.
        let sidecar: GenotypeAnnotationSidecar = {
            if let store = try? GenotypeAnnotationStore(bundleURL: result.bundleURL, author: NSUserName()) {
                return store.sidecar
            }
            return GenotypeAnnotationSidecar.empty(generatedAt: "")
        }()
        let subjects = GenotypeCohortSubjectBuilder.buildSubjects(
            result: result,
            sidecar: sidecar,
            metadataBySample: metadataStore?.records ?? [:]
        )
        let smartCohorts: [GenotypeSmartCohortSection.DisplayedCohort] = sidecar.smartCohorts.map { cohort in
            let count = subjects.filter { cohort.predicate.evaluate($0) }.count
            return GenotypeSmartCohortSection.DisplayedCohort(filter: cohort, count: count)
        }
        let workbookArtifactRows: [GenotypeResultArtifactRow] = {
            var rows = [
                GenotypeResultArtifactRow(label: "Workbook", fileURL: result.artifacts.workbookURL),
            ]
            if result.artifacts.primaryWorkbookURL != result.artifacts.workbookURL {
                rows.append(GenotypeResultArtifactRow(
                    label: "Original Workbook",
                    fileURL: result.artifacts.primaryWorkbookURL
                ))
            }
            return rows
        }()
        let candidateGenBankURLs = result.mhcCandidateGenBankArtifactURLs
        var state = GenotypeResultDocumentState(
            title: result.manifest.analysisName,
            subtitle: "\(result.manifest.kind) • \(result.manifest.outputName)",
            bundleURL: result.bundleURL,
            sampleIds: sampleIds,
            sampleMetadataStore: metadataStore,
            windowStateScope: windowStateScope,
            summaryRows: genotypeSummaryRows(result),
            qcRows: genotypeQCRows(subjects: subjects),
            artifactRows: workbookArtifactRows + [
                GenotypeResultArtifactRow(label: "Long Summary CSV", fileURL: result.artifacts.longSummaryCSVURL),
                GenotypeResultArtifactRow(label: "Sample Summary CSV", fileURL: result.artifacts.sampleSummaryCSVURL),
                GenotypeResultArtifactRow(label: "Run Stats JSON", fileURL: result.artifacts.statsJSONURL),
                result.artifacts.deduplicatedUnmatchedClustersFASTAURL.map {
                    GenotypeResultArtifactRow(label: "Deduplicated Unmatched FASTA", fileURL: $0)
                },
                candidateGenBankURLs.candidateAlleles.map {
                    GenotypeResultArtifactRow(label: "Candidate Alleles GenBank", fileURL: $0)
                },
                candidateGenBankURLs.unnameableClusters.map {
                    GenotypeResultArtifactRow(label: "Un-nameable Clusters GenBank", fileURL: $0)
                },
                GenotypeResultArtifactRow(label: "Provenance", fileURL: result.artifacts.provenanceURL),
                GenotypeResultArtifactRow(
                    label: "Annotations & Audit",
                    fileURL: ONTGenotypeResultBundleData.annotationSidecarURL(forBundleAt: result.bundleURL)
                ),
            ].compactMap { $0 },
            smartCohorts: smartCohorts,
            auditEntries: sidecar.auditLog,
            haplotypeDefinitionRows: genotypeHaplotypeDefinitionRows(result, sidecar: sidecar),
            haplotypeDefinitionsFolderURL: genotypeHaplotypeDefinitionsFolderURL(result),
            currentWorkbookUpdate: genotypeCurrentWorkbookUpdateState(result: result, sidecar: sidecar)
        )
        // Mirror the current display-state knobs into the document state so
        // Inspector controls render with the right values when the section appears.
        var currentDisplay = viewModel.genotypeResultDisplaySectionViewModel.displayState
        if result.manifest.kind == "full-length-ont-mhc-genotype", result.mhcCandidates != nil {
            currentDisplay.mhcCandidateDisplaySettings = sidecar.settings.mhcCandidateDisplay
        } else {
            currentDisplay.mhcCandidateDisplaySettings = nil
        }
        let availableLoci = genotypeHaplotypeLoci(result)
        let defaultIncludedLoci = genotypeDefaultIncludedHaplotypeLoci(
            availableLoci,
            result: result
        )
        let selectedIncludedLoci = currentDisplay.includedLoci.map {
            Set($0.filter { availableLoci.contains($0) })
        } ?? defaultIncludedLoci
        state.summaryViewMode = currentDisplay.summaryViewMode
        state.showsAncillaryLoci = currentDisplay.showsAncillaryLoci
        state.availableHaplotypeLoci = availableLoci
        state.defaultIncludedHaplotypeLoci = defaultIncludedLoci
        state.includedHaplotypeLoci = selectedIncludedLoci
        viewModel.documentSectionViewModel.updateGenotypeResultDocument(state)
        let isGenotypeOnlyResult = result.haplotypeAnalysis == nil && !result.calls.isEmpty
        viewModel.genotypeResultDisplaySectionViewModel.update(
            isAvailable: true,
            state: currentDisplay,
            hasHaplotypingResult: result.haplotypeAnalysis != nil,
            isGenotypeOnlyResult: isGenotypeOnlyResult
        )
        viewModel.genotypeResultDisplaySectionViewModel.updateMHCCandidatePresentation(from: result)
        updateProvenanceTarget(
            url: result.bundleURL,
            sidebarType: .genotypeResultBundle,
            displayName: result.manifest.analysisName
        )
        viewModel.selectedTab = .bundle
    }

    func updateGenotypeResultDisplaySummary(visibleRows: Int, totalRows: Int, hiddenCells: Int) {
        viewModel.genotypeResultDisplaySectionViewModel.updateSummary(
            visibleRows: visibleRows,
            totalRows: totalRows,
            hiddenCells: hiddenCells
        )
    }

    func updateGenotypeResultDisplayState(_ state: GenotypeResultDisplayState) {
        viewModel.genotypeResultDisplaySectionViewModel.updateDisplayState(state)
        if let documentState = viewModel.documentSectionViewModel.genotypeResultDocument {
            viewModel.documentSectionViewModel.updateGenotypeResultDocument(
                documentState
                    .replacing(summaryViewMode: state.summaryViewMode)
                    .replacing(showsAncillaryLoci: state.showsAncillaryLoci)
                    .replacing(
                        includedHaplotypeLoci: state.includedLoci
                            ?? documentState.defaultIncludedHaplotypeLoci
                    )
            )
        }
    }

    func updateTwelveSAmpliconResultDocument(_ result: TwelveSAmpliconResultBundleData) {
        viewModel.readStyleSectionViewModel.clear()
        let knownSampleIDs = Set(result.samples.map(\.sampleID))
        let importedMetadataStore = SampleMetadataStore.load(from: result.bundleURL, knownSampleIds: knownSampleIDs)
        importedMetadataStore?.wireAutosave(bundleURL: result.bundleURL)
        let currentDisplay = viewModel.twelveSResultDisplaySectionViewModel.displayState
        let scientificNameRows = result.scientificNameRows
        let targetRowCount = scientificNameRows.reduce(0) { count, row in
            count + row.sampleCounts.values.filter { $0 > 0 }.count
        }
        viewModel.twelveSResultDisplaySectionViewModel.update(isAvailable: true, state: currentDisplay)
        viewModel.twelveSResultDisplaySectionViewModel.updateSummary(
            TwelveSResultDisplaySummary(
                rowLabel: "Target Rows",
                visibleRows: targetRowCount,
                totalRows: targetRowCount
            )
        )
        viewModel.twelveSResultDisplaySectionViewModel.updateSamples(
            count: result.samples.count,
            metadata: result.sampleMetadata,
            manifest: result.sampleMetadataManifest
        )
        if let importedMetadataStore {
            viewModel.twelveSResultDisplaySectionViewModel.sampleMetadataStore = importedMetadataStore
        }
        viewModel.twelveSResultDisplaySectionViewModel.updateTaxonGroupOptions(
            scientificNameRows
                .filter { $0.sampleCounts.values.contains { $0 > 0 } }
                .flatMap(\.displayTaxonGroups)
        )
        viewModel.twelveSDetailSectionViewModel.isAvailable = true
        viewModel.twelveSDetailSectionViewModel.clear()
        updateProvenanceTarget(
            url: result.bundleURL,
            sidebarType: .twelveSAmpliconResultBundle,
            displayName: result.manifest.analysisName
        )
        viewModel.selectedTab = .resultSummary
    }

    func updateTwelveSImportedSampleMetadata(_ metadataStore: SampleMetadataStore?) {
        viewModel.twelveSResultDisplaySectionViewModel.sampleMetadataStore = metadataStore
    }

    /// Updates the 12S Detail tab with the currently-selected row's payload, or
    /// clears it for a multi/empty selection. Auto-selects the Detail tab the
    /// first time a single row is selected, without stealing it thereafter.
    func updateTwelveSDetail(_ payload: TwelveSDetailPayload?) {
        let hadDetail = viewModel.twelveSDetailSectionViewModel.hasDetail
        viewModel.twelveSDetailSectionViewModel.apply(payload)
        if payload != nil, !hadDetail, viewModel.selectedTab == .resultSummary {
            viewModel.selectedTab = .twelveSDetail
        }
    }

    /// Clears the 12S Detail tab and marks it unavailable (12S viewport closed).
    func clearTwelveSDetail() {
        viewModel.twelveSDetailSectionViewModel.reset()
    }

    func updateTwelveSResultDisplaySummary(_ summary: TwelveSResultDisplaySummary) {
        viewModel.twelveSResultDisplaySectionViewModel.updateSummary(summary)
    }

    func updateTwelveSResultDisplayState(_ state: TwelveSResultDisplayState) {
        viewModel.twelveSResultDisplaySectionViewModel.updateDisplayState(state)
    }

    func updateGenotypeAnnotationSidecar(_ sidecar: GenotypeAnnotationSidecar) {
        guard let state = viewModel.documentSectionViewModel.genotypeResultDocument else { return }
        var nextState = state.replacing(auditEntries: sidecar.auditLog)
        let cachedResult = loadedGenotypeResult.flatMap { result -> ONTGenotypeResultBundleData? in
            guard result.bundleURL.standardizedFileURL == state.bundleURL?.standardizedFileURL else { return nil }
            return result
        }
        if let result = cachedResult {
            loadedGenotypeResult = result
            let subjects = GenotypeCohortSubjectBuilder.buildSubjects(
                result: result,
                sidecar: sidecar,
                metadataBySample: state.sampleMetadataStore?.records ?? [:]
            )
            nextState.smartCohorts = sidecar.smartCohorts.map { cohort in
                GenotypeSmartCohortSection.DisplayedCohort(
                    filter: cohort,
                    count: subjects.filter { cohort.predicate.evaluate($0) }.count
                )
            }
            nextState.qcRows = genotypeQCRows(subjects: subjects)
            nextState.haplotypeDefinitionRows = genotypeHaplotypeDefinitionRows(result, sidecar: sidecar)
            nextState.currentWorkbookUpdate = genotypeCurrentWorkbookUpdateState(result: result, sidecar: sidecar)
            var displayState = viewModel.genotypeResultDisplaySectionViewModel.displayState
            if viewModel.genotypeResultDisplaySectionViewModel.mhcCandidateControlsAvailable {
                displayState.mhcCandidateDisplaySettings = sidecar.settings.mhcCandidateDisplay
            }
            viewModel.genotypeResultDisplaySectionViewModel.updateDisplayState(displayState)
        }
        viewModel.documentSectionViewModel.updateGenotypeResultDocument(
            nextState
        )
        if let bundleURL = state.bundleURL {
            let annotationURL = ONTGenotypeResultBundleData.annotationSidecarURL(forBundleAt: bundleURL)
            if FileManager.default.fileExists(atPath: annotationURL.path) {
                updateProvenanceTarget(
                    url: annotationURL,
                    sidebarType: .genotypeResultBundle,
                    displayName: "Annotations & Audit"
                )
            }
        }
    }

    private func genotypeSummaryRows(_ result: ONTGenotypeResultBundleData) -> [(String, String)] {
        [
            ("Samples", "\(result.sampleCount)"),
            ("Calls", "\(result.callCount)"),
            ("Total Reads", formatInteger(result.stats.totalInputReads)),
            ("Retained Reads", formatInteger(result.stats.retainedUniqueReads)),
            ("Assigned Retained", formatInteger(result.stats.assignedUniqueRetainedReads)),
            ("Unassigned Retained", formatInteger(result.stats.unassignedUniqueRetainedReads)),
            ("Retained %", formatPercent(result.stats.retainedUniquePercentOfTotalReads)),
            ("Created", result.manifest.createdAt ?? "Unknown"),
        ]
    }

    private func genotypeQCRows(subjects: [GenotypeCohortSubject]) -> [(String, String)] {
        let qcCounts = Dictionary(grouping: subjects, by: \.qcStatus).mapValues(\.count)
        let incomplete = subjects.filter { SmartCohortPredicate.needsHaplotypeReview.evaluate($0) }.count
        let noHaplotypeCalls = subjects.filter(\.calls.isEmpty).count
        return [
            ("OK", "\(qcCounts[.ok, default: 0])"),
            ("Low Support", "\(qcCounts[.lowSupport, default: 0])"),
            ("Review", "\(qcCounts[.review, default: 0])"),
            ("Incomplete Haplotypes", "\(incomplete)"),
            ("No Haplotype Calls", "\(noHaplotypeCalls)"),
        ]
    }

    private func genotypeCurrentWorkbookUpdateState(
        result: ONTGenotypeResultBundleData,
        sidecar: GenotypeAnnotationSidecar
    ) -> GenotypeResultCurrentWorkbookUpdateState {
        let workbookChangeCount = sidecar.callOverrides.count
            + sidecar.manualHaplotypeAssignments.count
            + sidecar.matrixStyles.count
            + sidecar.matrixComments.count
        let hasMatrixAnnotations = !sidecar.matrixStyles.isEmpty || !sidecar.matrixComments.isEmpty
        let changeLabel: String
        if hasMatrixAnnotations {
            changeLabel = workbookChangeCount == 1 ? "workbook annotation change" : "workbook annotation changes"
        } else {
            changeLabel = workbookChangeCount == 1 ? "manual haplotype change" : "manual haplotype changes"
        }
        let isWritable = FileManager.default.isWritableFile(atPath: result.bundleURL.path)
        let statusText: String
        if workbookChangeCount == 0 {
            statusText = "current.xlsx has no workbook annotation edits to apply."
        } else if !isWritable {
            statusText = "current.xlsx cannot be updated because this bundle is read-only."
        } else {
            statusText = "current.xlsx can be refreshed from \(workbookChangeCount) \(changeLabel)."
        }
        return GenotypeResultCurrentWorkbookUpdateState(
            manualChangeCount: workbookChangeCount,
            statusText: statusText,
            isEnabled: workbookChangeCount > 0 && isWritable
        )
    }

    private func genotypeSampleIds(_ result: ONTGenotypeResultBundleData) -> [String] {
        var seen: Set<String> = []
        var sampleIds: [String] = []
        for sample in result.samples.map(\.sample) + result.calls.map(\.sample) where seen.insert(sample).inserted {
            sampleIds.append(sample)
        }
        return sampleIds
    }

    private func genotypeHaplotypeLoci(_ result: ONTGenotypeResultBundleData) -> [String] {
        guard let analysis = result.haplotypeAnalysis else { return [] }
        var seen: Set<String> = []
        var loci: [String] = []
        for sample in analysis.samples {
            for call in sample.calls where seen.insert(call.locus).inserted {
                loci.append(call.locus)
            }
        }
        return loci
    }

    private func genotypeDefaultIncludedHaplotypeLoci(
        _ loci: [String],
        result: ONTGenotypeResultBundleData
    ) -> Set<String> {
        var included = Set(loci)
        if genotypeResultLooksLikeMCM(result, loci: loci) {
            included.remove("MHC-E")
        }
        return included
    }

    private func genotypeResultLooksLikeMCM(
        _ result: ONTGenotypeResultBundleData,
        loci: [String]
    ) -> Bool {
        let analysis = result.haplotypeAnalysis
        let metadata = [
            analysis?.definitionSetID,
            analysis?.definitionSetName,
            analysis?.assayID,
            result.manifest.haplotypeDefinitionSetID,
            result.manifest.haplotypeAssayID,
        ]
        if metadata.contains(where: { $0?.localizedCaseInsensitiveContains("mcm") == true }) {
            return true
        }
        return Set(loci).isSuperset(of: ["MHC-A", "MHC-B", "MHC-DR"])
    }

    private func genotypeHaplotypeDefinitionsFolderURL(_ result: ONTGenotypeResultBundleData) -> URL {
        genotypeProjectRoot(for: result)
            .appendingPathComponent("Haplotype Definitions", isDirectory: true)
    }

    private func genotypeHaplotypeDefinitionRows(
        _ result: ONTGenotypeResultBundleData,
        sidecar: GenotypeAnnotationSidecar?
    ) -> [(String, String)] {
        let store = HaplotypeDefinitionStore(projectRoot: genotypeProjectRoot(for: result))
        let definitionID = sidecar?.settings.activeHaplotypeDefinitionSetID
            ?? result.haplotypeAnalysis?.definitionSetID
            ?? result.manifest.haplotypeDefinitionSetID
        let assayID = sidecar?.settings.activeHaplotypeDefinitionSetID == nil
            ? result.haplotypeAnalysis?.assayID ?? result.manifest.haplotypeAssayID
            : sidecar?.settings.activeHaplotypeAssayID
        guard let definitionID else { return [] }
        let definition = store.mergedRegistry().definitionSet(id: definitionID, assayID: assayID)
        let locusCount = definition?.locusDefinitions.count ?? result.haplotypeAnalysis?.samples.first?.calls.count ?? 0
        let haplotypeCount = definition?.locusDefinitions.reduce(0) { $0 + $1.haplotypes.count } ?? 0
        var rows = [
            ("Active", definition?.displayName ?? result.haplotypeAnalysis?.definitionSetName ?? definitionID),
            ("Definition ID", definitionID),
            ("Loci", "\(locusCount)"),
            ("Haplotypes", "\(haplotypeCount)"),
        ]
        if let assayID = definition?.assayID ?? assayID {
            rows.insert(("Assay", assayID), at: 2)
        }
        return rows
    }

    private func genotypeProjectRoot(for result: ONTGenotypeResultBundleData) -> URL {
        result.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// Updates the Selected Item inspector with MSA row/site/range metadata.
    func updateMultipleSequenceAlignmentSelection(_ state: MultipleSequenceAlignmentSelectionState?) {
        viewModel.selectedAnnotation = nil
        viewModel.selectionSectionViewModel.select(multipleSequenceAlignmentSelection: state)
        if state != nil {
            viewModel.selectedTab = .selectedItem
        }
    }

    /// Updates the Selected Item inspector with phylogenetic-tree node metadata.
    func updatePhylogeneticTreeSelection(_ state: PhylogeneticTreeSelectionState?) {
        viewModel.selectedAnnotation = nil
        viewModel.selectionSectionViewModel.select(phylogeneticTreeSelection: state)
        if state != nil {
            viewModel.selectedTab = .selectedItem
        }
    }

    /// Updates the Selected Item inspector with sequence/reference range metadata.
    func updateSequenceRegionSelection(_ state: SequenceRegionSelectionState?) {
        viewModel.selectedAnnotation = nil
        viewModel.selectionSectionViewModel.select(sequenceRegionSelection: state)
        if state != nil {
            viewModel.selectedTab = .selectedItem
        }
    }

    /// Updates the Selected Item inspector with genotype result sample/call metadata.
    ///
    /// Auto-switches to the `.selectedItem` tab only when the analyst has
    /// already focused on per-call metadata (current tab `.selectedItem`).
    /// Switching away from the user's current `.bundle` or `.view` tab in
    /// response to incidental selection events (auto-select-first-row when
    /// the view mode changes, etc.) is treated as a regression.
    func updateGenotypeResultSelection(_ state: GenotypeResultSelectionState?) {
        viewModel.selectedAnnotation = nil
        viewModel.selectionSectionViewModel.select(genotypeResultSelection: state)
        viewModel.genotypeResultDisplaySectionViewModel.updateSelection(state)
        // Do not flip the user's tab choice automatically; the analyst opens
        // the Selected Item tab explicitly when they want to inspect a call.
    }

    private func formatInteger(_ value: Int?) -> String {
        value.map { $0.formatted(.number) } ?? "Unavailable"
    }

    private func formatPercent(_ value: Double?) -> String {
        guard let value else { return "Unavailable" }
        return "\(String(format: "%.2f", value))%"
    }

    private func formatNumber(_ value: Double?) -> String {
        guard let value else { return "Unavailable" }
        return String(format: "%.2f", value)
    }

    /// Updates the chromosome selection in the Document tab.
    ///
    /// - Parameter chromosome: The chromosome to display details for, or nil to clear
    public func updateSelectedChromosome(_ chromosome: ChromosomeInfo?) {
        viewModel.documentSectionViewModel.selectChromosome(chromosome)
    }

    /// Updates the NAO-MGS manifest in the Document section.
    ///
    /// - Parameter manifest: The NAO-MGS manifest, or nil to clear
    public func updateNaoMgsManifest(_ manifest: NaoMgsManifest?) {
        viewModel.documentSectionViewModel.updateNaoMgsManifest(manifest)
    }

    /// Wires the shared classifier sample picker state for the Inspector-embedded sample selector.
    func updateClassifierSampleState(
        pickerState: ClassifierSamplePickerState,
        entries: [any ClassifierSampleEntry],
        strippedPrefix: String,
        metadata: SampleMetadataStore? = nil,
        attachments: BundleAttachmentStore? = nil
    ) {
        viewModel.documentSectionViewModel.classifierPickerState = pickerState
        viewModel.documentSectionViewModel.classifierSampleEntries = entries
        viewModel.documentSectionViewModel.classifierStrippedPrefix = strippedPrefix
        viewModel.documentSectionViewModel.sampleMetadataStore = metadata
        viewModel.documentSectionViewModel.bundleAttachmentStore = attachments
    }

    /// Updates the Inspector with batch operation details for display in the Result Summary tab.
    ///
    /// - Parameters:
    ///   - tool: Human-readable tool name (e.g. "Kraken2").
    ///   - parameters: Key-value pairs from the batch manifest (database, confidence, etc.).
    ///   - timestamp: Batch creation timestamp from the manifest header.
    ///   - sourceSamples: Pairs of sample IDs and their resolved bundle URLs (nil when not resolvable).
    func updateBatchOperationDetails(
        tool: String,
        parameters: [String: String],
        timestamp: Date?,
        sourceSamples: [(sampleId: String, bundleURL: URL?)]
    ) {
        viewModel.documentSectionViewModel.batchOperationTool = tool
        viewModel.documentSectionViewModel.batchOperationParameters = parameters
        viewModel.documentSectionViewModel.batchOperationTimestamp = timestamp
        viewModel.documentSectionViewModel.batchSourceSampleURLs = sourceSamples
    }

    /// Clears batch operation details from the Inspector.
    func clearBatchOperationDetails() {
        viewModel.documentSectionViewModel.batchOperationTool = nil
        viewModel.documentSectionViewModel.batchOperationParameters = [:]
        viewModel.documentSectionViewModel.batchOperationTimestamp = nil
        viewModel.documentSectionViewModel.batchSourceSampleURLs = []
    }

}
