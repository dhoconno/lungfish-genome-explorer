// MainSplitViewController+ClassifierDisplay.swift - Classifier result display routing
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishKit
import LungfishCore
import LungfishEsVirituUI
import LungfishIO
import LungfishNaoMgsUI
import LungfishNvdUI
import LungfishTaxTriageUI
import LungfishWorkflow
import os.log

extension MainSplitViewController {
    private struct BAMInspectorSampleEntry: ClassifierSampleEntry {
        let id: String
        var displayName: String { id }
        let metricLabel = ""
        let metricValue = ""
    }

    func clearBAMMetadataPresentation() {
        if let context = bamMetadataPresentationContext,
           let token = bamMetadataPresentationConsumerToken {
            context.removeObserver(token)
        }
        bamMetadataPresentationContext = nil
        bamMetadataPresentationConsumerToken = nil
    }

    /// Installs a result-scoped metadata context for a mapping BAM.  Identity
    /// comes only from each persisted alignment metadata database; filenames
    /// are intentionally absent from this path.
    func installMappingBAMMetadataPresentation(resultURL: URL, result: MappingResult) {
        guard let bundleURL = result.viewerBundleURL else { return }
        installBAMMetadataPresentation(
            resultURL: resultURL, bundleURL: bundleURL, workflowName: "Mapping"
        )
    }

    /// Shared direct-reference and mapping route installation.  Every track
    /// is resolved through BAMSampleIdentityResolver before identities from
    /// separate tracks are merged, keeping one canonical policy for all BAM
    /// viewports.
    func installBAMMetadataPresentation(
        resultURL: URL,
        bundleURL: URL,
        workflowName: String,
        persistedSampleAliases: [String: [String]] = [:]
    ) {
        clearBAMMetadataPresentation()
        guard let consumer = viewerController.referenceBundleViewportController,
              let manifest = try? BundleManifest.load(from: bundleURL)
        else { return }
        var collectedIdentities: [SampleIdentity] = []
        var manifestAliases: [String: [String]] = [:]
        for track in manifest.alignments {
            guard let metadataDBPath = track.metadataDBPath,
                  let database = try? AlignmentMetadataDatabase(url: bundleMemberURL(metadataDBPath, in: bundleURL)),
                  let resolution = try? BAMSampleIdentityResolver.resolve(
                    readGroups: database.readGroups(),
                    trackIDs: [track.id],
                    explicitResultSampleID: track.sampleNames.count == 1 ? track.sampleNames[0] : nil,
                    trackSampleIDs: track.sampleNames.count == 1 ? [track.id: track.sampleNames[0]] : [:]
                  )
            else { continue }
            if track.sampleNames.count == 1,
               let declared = track.sampleNames.first,
               resolution.identities.count == 1,
               let resolved = resolution.identities.first,
               BAMSampleIdentityResolver.normalized(resolved.canonicalID)
                    != BAMSampleIdentityResolver.normalized(declared) {
                // A single persisted track-level sample name is an explicit
                // alias for its one resolved RG sample.  Do not attach it to
                // multi-sample tracks: that would make imported metadata
                // ambiguous rather than helpful.
                manifestAliases[resolved.canonicalID, default: []].append(declared)
            }
            collectedIdentities.append(contentsOf: resolution.identities)
        }
        let aliases = manifestAliases.merging(persistedSampleAliases) { current, supplied in
            Array(Set(current).union(supplied)).sorted()
        }
        let identities = BAMSampleIdentityResolver.merge(
            collectedIdentities,
            aliases: aliases
        )
        guard !identities.isEmpty,
              let index = try? SampleIdentityIndex(samples: identities),
              let identityInputURLs = alignmentIdentityInputURLs(
                  manifest: manifest,
                  bundleURL: bundleURL
              )
        else { return }
        let metadataIdentifiers = index.canonicalSampleIDs.union(
            Set(identities.flatMap(\.aliases))
        )
        let store = SampleMetadataStore.load(from: resultURL, knownSampleIds: metadataIdentifiers)
        if let store {
            rekeyBAMMetadataRecords(store, using: index)
        }
        if let store {
            SampleMetadataEditPersistenceService().wire(store: store, bundleURL: resultURL)
        }
        let context = SampleMetadataPresentationContext(
            finalResultURL: resultURL,
            identityIndex: index,
            identityInputURLs: identityInputURLs,
            sampleMetadataStore: store,
            importContext: .init(
                resultID: resultURL.lastPathComponent,
                provenanceID: "\(workflowName.lowercased()):\(resultURL.lastPathComponent)",
                workflowName: workflowName,
                workflowVersion: LungfishAppVersion.short
            )
        )
        bamMetadataPresentationContext = context
        bamMetadataPresentationConsumerToken = context.observe(consumer)
        inspectorController?.updateClassifierSampleState(
            pickerState: .init(allSamples: index.canonicalSampleIDs),
            entries: index.canonicalSampleIDs.sorted().map(BAMInspectorSampleEntry.init(id:)),
            strippedPrefix: "",
            presentationContext: context,
            attachments: BundleAttachmentStore(bundleURL: resultURL)
        )
    }

    private func bundleMemberURL(_ path: String, in bundleURL: URL) -> URL {
        if path.hasPrefix("@/") { return bundleURL.appendingPathComponent(String(path.dropFirst(2))) }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        return bundleURL.appendingPathComponent(path)
    }

    /// Resolves only final, contained manifest members used to establish BAM
    /// identity. Unsafe, external, or missing members make the presentation
    /// context unavailable instead of producing incomplete provenance later.
    private func alignmentIdentityInputURLs(
        manifest: BundleManifest,
        bundleURL rawBundleURL: URL
    ) -> [URL]? {
        let bundleURL = rawBundleURL.standardizedFileURL
        let resolvedBundleURL = bundleURL.resolvingSymlinksInPath()
        var urls = [bundleURL.appendingPathComponent(BundleManifest.filename)]
        for track in manifest.alignments {
            var paths = [track.sourcePath, track.indexPath]
            if let metadataDBPath = track.metadataDBPath {
                paths.append(metadataDBPath)
            }
            for path in paths where !path.isEmpty {
                let candidate = bundleMemberURL(path, in: bundleURL)
                    .standardizedFileURL
                    .resolvingSymlinksInPath()
                guard candidate.pathComponents.count > resolvedBundleURL.pathComponents.count,
                      candidate.pathComponents.starts(with: resolvedBundleURL.pathComponents),
                      FileManager.default.fileExists(atPath: candidate.path)
                else { return nil }
                urls.append(candidate)
            }
        }
        var seen = Set<String>()
        return urls.map { $0.resolvingSymlinksInPath() }.filter { seen.insert($0.path).inserted }
    }

    /// The metadata store persists records keyed by whichever header value was
    /// imported.  BAM viewports use canonical RG identities, so fold any
    /// persisted manifest aliases back to the canonical key before observers
    /// receive the store.  A canonical record wins if both it and an alias are
    /// present, keeping a duplicate metadata import deterministic.
    private func rekeyBAMMetadataRecords(
        _ store: SampleMetadataStore,
        using identityIndex: SampleIdentityIndex
    ) {
        var rekeyed: [String: [String: String]] = [:]
        for canonicalID in identityIndex.canonicalSampleIDs.sorted() {
            if let record = store.records[canonicalID] {
                rekeyed[canonicalID] = record
            }
        }
        for identifier in store.records.keys.sorted() {
            guard let canonicalID = identityIndex.canonicalSampleID(forMetadataIdentifier: identifier),
                  rekeyed[canonicalID] == nil,
                  let record = store.records[identifier]
            else { continue }
            rekeyed[canonicalID] = record
        }
        store.records = rekeyed
        store.matchedSampleIds = Set(rekeyed.keys)
    }

    func clearClassifierMetadataPresentation() {
        if let context = classifierMetadataPresentationContext,
           let token = classifierMetadataPresentationConsumerToken {
            context.removeObserver(token)
        }
        classifierMetadataPresentationContext = nil
        classifierMetadataPresentationConsumerToken = nil
        classifierAlignmentEvidenceViewport?.bindSampleMetadataPresentation(nil)
        inspectorController?.clearClassifierSampleMetadataState()
    }

    /// Loads persisted metadata once, creates the result-scoped source of truth,
    /// and connects the active viewport through the shared consumer protocol.
    /// No classifier-specific import callback is retained by the Inspector.
    func installClassifierMetadataPresentation(
        resultURL: URL,
        pickerState: ClassifierSamplePickerState,
        entries: [any ClassifierSampleEntry],
        strippedPrefix: String,
        workflowName: String,
        consumer: any SampleMetadataPresentationConsumer
    ) {
        clearClassifierMetadataPresentation()

        let sampleIDs = entries.map(\.id)
        let metadataStore = SampleMetadataStore.load(
            from: resultURL,
            knownSampleIds: Set(sampleIDs)
        )
        if let metadataStore {
            SampleMetadataEditPersistenceService().wire(store: metadataStore, bundleURL: resultURL)
        }
        guard let identityIndex = try? SampleIdentityIndex(samples: sampleIDs.map {
            SampleIdentity(canonicalID: $0, aliases: [], alignmentTrackIDs: [], readGroupIDs: [])
        }) else {
            classifierMetadataPresentationContext = nil
            classifierMetadataPresentationConsumerToken = nil
            consumer.applySampleMetadata(metadataStore)
            inspectorController?.updateClassifierSampleState(
                pickerState: pickerState,
                entries: entries,
                strippedPrefix: strippedPrefix,
                metadata: metadataStore,
                attachments: BundleAttachmentStore(bundleURL: resultURL)
            )
            return
        }

        let context = SampleMetadataPresentationContext(
            finalResultURL: resultURL,
            identityIndex: identityIndex,
            sampleMetadataStore: metadataStore,
            importContext: SampleMetadataImportContext(
                resultID: resultURL.lastPathComponent,
                provenanceID: "\(workflowName.lowercased()):\(resultURL.lastPathComponent)",
                workflowName: workflowName,
                workflowVersion: LungfishAppVersion.short
            )
        )
        classifierMetadataPresentationContext = context
        classifierMetadataPresentationConsumerToken = context.observe(consumer)
        classifierAlignmentEvidenceViewport?.bindSampleMetadataPresentation(context)
        inspectorController?.updateClassifierSampleState(
            pickerState: pickerState,
            entries: entries,
            strippedPrefix: strippedPrefix,
            presentationContext: context,
            attachments: BundleAttachmentStore(bundleURL: resultURL)
        )
    }

    func routeClassifierDisplay(url: URL) {
        guard let route = ClassifierDatabaseRouter.route(for: url) else {
            mainSplitLogger.warning("routeClassifierDisplay: Not a classifier directory: \(url.lastPathComponent, privacy: .public)")
            return
        }

        if route.databaseURL != nil {
            displayBatchGroup(at: route.resultURL)
            if let sampleId = route.sampleId {
                filterBatchViewToSingleSample(sampleId: sampleId)
            }
        } else {
            showDatabaseBuildPlaceholder(tool: route.displayName, resultURL: route.resultURL)
        }
    }

    /// After a batch view loads, constrain the sample picker to a single sample.
    /// Fires the metagenomicsSampleSelectionChanged notification which each VC
    /// observes to reload the filtered view.
    func filterBatchViewToSingleSample(sampleId: String) {
        if let taxTriageVC = viewerController.taxTriageViewController {
            taxTriageVC.samplePickerState?.selectedSamples = [sampleId]
            NotificationCenter.default.post(name: .metagenomicsSampleSelectionChanged, object: nil)
            return
        }
        if let esVirituVC = viewerController.esVirituViewController {
            esVirituVC.samplePickerState?.selectedSamples = [sampleId]
            NotificationCenter.default.post(name: .metagenomicsSampleSelectionChanged, object: nil)
            return
        }
        if let taxonomyVC = viewerController.taxonomyViewController {
            taxonomyVC.samplePickerState?.selectedSamples = [sampleId]
            NotificationCenter.default.post(name: .metagenomicsSampleSelectionChanged, object: nil)
            return
        }
    }

    /// Displays a batch aggregated viewer for a `.batchGroup` sidebar item.
    ///
    /// Detects the tool type from the batch directory name prefix, loads the
    /// appropriate manifest (for Kraken2 and EsViritu) or scans subdirectories
    /// (for TaxTriage), creates the viewer VC, and wires the Inspector.
    ///
    /// - Parameter batchURL: The batch result directory (e.g. `kraken2-batch-2024-06-02T14-20-15/`).
    func displayBatchGroup(at batchURL: URL) {
        let dirName = batchURL.lastPathComponent
        mainSplitLogger.info("displayBatchGroup: Opening '\(dirName, privacy: .public)'")

        let projectURL = sidebarController.currentProjectURL ?? DocumentManager.shared.activeProject?.url
        let toolId = AnalysesFolder.readAnalysisMetadata(from: batchURL)?.tool ?? dirName
        inspectorController?.updateProvenanceTarget(
            url: batchURL,
            sidebarType: provenanceSidebarType(forMetagenomicsToolId: toolId, directoryName: dirName),
            displayName: dirName
        )

        switch AnalysisResultDisplayRoute.route(forToolID: toolId) {
        case .assembly:
            displayAssemblyAnalysisFromSidebar(at: batchURL)
            return
        case .mapping:
            displayMappingAnalysisFromSidebar(at: batchURL)
            return
        case .naoMgs, .nvd, .czId, .unknown:
            break
        }

        if dirName.hasPrefix("kraken2") || dirName.hasPrefix("classification") {
            // Check for SQLite database first -- faster than parsing per-sample kreport files.
            let dbURL = batchURL.appendingPathComponent("kraken2.sqlite")
            if FileManager.default.fileExists(atPath: dbURL.path),
               let db = try? Kraken2Database(at: dbURL) {
                viewerController.displayTaxonomyFromDatabase(db: db, resultURL: batchURL)
                if let taxonomyVC = viewerController.taxonomyViewController {
                    // Load sample metadata from the bundle if available
                    self.installClassifierMetadataPresentation(
                        resultURL: batchURL,
                        pickerState: taxonomyVC.samplePickerState,
                        entries: taxonomyVC.sampleEntries,
                        strippedPrefix: taxonomyVC.strippedPrefix,
                        workflowName: "Kraken2",
                        consumer: taxonomyVC
                    )
                }
            } else {
                // No SQLite DB — show placeholder and auto-build.
                showDatabaseBuildPlaceholder(tool: "Kraken2", resultURL: batchURL)
                return
            }
            // Build params starting from the manifest-level fields (if available).
            if let manifest = MetagenomicsBatchResultStore.loadClassification(from: batchURL) {
                var params: [String: String] = [
                    "Database": "\(manifest.databaseName) \(manifest.databaseVersion)".trimmingCharacters(in: .whitespaces),
                    "Goal": manifest.goal,
                ]
                // Augment with per-sample config from the first sample's result sidecar.
                if let firstSample = manifest.samples.first {
                    let sampleResultDir = batchURL.appendingPathComponent(firstSample.resultDirectory)
                    if let sampleResult = try? ClassificationResult.load(from: sampleResultDir) {
                        let cfg = sampleResult.config
                        if !sampleResult.toolVersion.isEmpty {
                            params["Tool Version"] = "Kraken2 \(sampleResult.toolVersion)"
                        }
                        params["Confidence"] = String(format: "%.2f", cfg.confidence)
                        params["Min Hit Groups"] = "\(cfg.minimumHitGroups)"
                        params["Threads"] = "\(cfg.threads)"
                        if cfg.memoryMapping { params["Memory Mapping"] = "Yes" }
                        if cfg.quickMode { params["Quick Mode"] = "Yes" }
                        let runtimeStr = formatInspectorRuntime(sampleResult.runtime)
                        if !runtimeStr.isEmpty { params["Runtime (first sample)"] = runtimeStr }
                    }
                }
                let sourceSamples = resolveBatchSourceSamples(manifest.samples, projectURL: projectURL)
                self.inspectorController?.updateBatchOperationDetails(
                    tool: "Kraken2",
                    parameters: params,
                    timestamp: manifest.header.createdAt,
                    sourceSamples: sourceSamples
                )
            }
            // Kraken2 batch always reads from its own per-result sidecars; no separate
            // aggregated manifest is built, so this status is not applicable.
            self.inspectorController?.viewModel.documentSectionViewModel.batchManifestStatus = .notCached

        } else if dirName.hasPrefix("esviritu") {
            // Check for SQLite database first — faster than parsing per-sample files.
            let dbURL = batchURL.appendingPathComponent("esviritu.sqlite")
            if FileManager.default.fileExists(atPath: dbURL.path),
               let db = try? EsVirituDatabase(at: dbURL) {
                viewerController.displayEsVirituFromDatabase(db: db, resultURL: batchURL)
                if let evVC = viewerController.esVirituViewController {
                    self.installClassifierMetadataPresentation(
                        resultURL: batchURL,
                        pickerState: evVC.samplePickerState,
                        entries: evVC.sampleEntries,
                        strippedPrefix: evVC.strippedPrefix,
                        workflowName: "EsViritu",
                        consumer: evVC
                    )
                }
            } else {
                // No SQLite DB — show placeholder and auto-build.
                showDatabaseBuildPlaceholder(tool: "EsViritu", resultURL: batchURL)
                return
            }
            // Build params from the first sample's EsViritu result sidecar.
            var esVirituParams: [String: String] = [:]
            if let firstSample = MetagenomicsBatchResultStore.loadEsViritu(from: batchURL)?.samples.first {
                let sampleResultDir = batchURL.appendingPathComponent(firstSample.resultDirectory)
                if let sampleResult = try? LungfishWorkflow.EsVirituResult.load(from: sampleResultDir) {
                    let cfg = sampleResult.config
                    if !sampleResult.toolVersion.isEmpty {
                        esVirituParams["Tool Version"] = "EsViritu \(sampleResult.toolVersion)"
                    }
                    esVirituParams["Threads"] = "\(cfg.threads)"
                    esVirituParams["Quality Filter"] = cfg.qualityFilter ? "Yes" : "No"
                    esVirituParams["Min Read Length"] = "\(cfg.minReadLength)"
                    esVirituParams["Paired-End"] = cfg.isPairedEnd ? "Yes" : "No"
                    let runtimeStr = formatInspectorRuntime(sampleResult.runtime)
                    if !runtimeStr.isEmpty { esVirituParams["Runtime (first sample)"] = runtimeStr }
                }
            }
            if let manifest = MetagenomicsBatchResultStore.loadEsViritu(from: batchURL) {
                let sourceSamples = resolveBatchSourceSamples(manifest.samples, projectURL: projectURL)
                self.inspectorController?.updateBatchOperationDetails(
                    tool: "EsViritu",
                    parameters: esVirituParams,
                    timestamp: manifest.header.createdAt,
                    sourceSamples: sourceSamples
                )
            }
            if let esVirituVC = viewerController.esVirituViewController {
                self.inspectorController?.viewModel.documentSectionViewModel.batchManifestStatus =
                    esVirituVC.didLoadFromManifestCache ? .cached : .building
            }

        } else if dirName.hasPrefix("taxtriage") {
            // Check for SQLite database first — faster than parsing per-sample files.
            let dbURL = batchURL.appendingPathComponent("taxtriage.sqlite")
            if FileManager.default.fileExists(atPath: dbURL.path),
               let db = try? TaxTriageDatabase(at: dbURL) {
                viewerController.displayTaxTriageFromDatabase(db: db, resultURL: batchURL)
                if let ttVC = viewerController.taxTriageViewController {
                    self.installClassifierMetadataPresentation(
                        resultURL: batchURL,
                        pickerState: ttVC.samplePickerState,
                        entries: ttVC.sampleEntries,
                        strippedPrefix: ttVC.strippedPrefix,
                        workflowName: "TaxTriage",
                        consumer: ttVC
                    )
                }
            } else {
                // No SQLite DB — show placeholder and auto-build.
                showDatabaseBuildPlaceholder(tool: "TaxTriage", resultURL: batchURL)
                return
            }

            // Load TaxTriage result sidecar for provenance.
            var taxTriageParams: [String: String] = [:]
            let taxTriageTimestamp: Date? = nil  // TaxTriageResult does not store a createdAt timestamp
            var taxTriageSamples: [(sampleId: String, bundleURL: URL?)] = []

            if let ttResult = try? TaxTriageResult.load(from: batchURL) {
                let cfg = ttResult.config

                // Pipeline parameters
                taxTriageParams["Platform"] = cfg.platform.displayName
                taxTriageParams["Classifiers"] = cfg.classifiers.joined(separator: ", ")
                taxTriageParams["Confidence"] = String(format: "%.2f", cfg.k2Confidence)
                taxTriageParams["Top Hits"] = "\(cfg.topHitsCount)"
                taxTriageParams["Rank"] = cfg.rank
                taxTriageParams["Max CPUs"] = "\(cfg.maxCpus)"
                taxTriageParams["Max Memory"] = cfg.maxMemory
                if let dbPath = cfg.kraken2DatabasePath {
                    taxTriageParams["Database Path"] = dbPath.lastPathComponent
                }
                let runtimeStr = formatInspectorRuntime(ttResult.runtime)
                if !runtimeStr.isEmpty { taxTriageParams["Runtime"] = runtimeStr }
                if ttResult.hasIgnoredFailures {
                    let sampleCount = Set(ttResult.ignoredFailures.compactMap(\.sampleID)).count
                    if sampleCount > 0 {
                        taxTriageParams["Warnings"] = "\(ttResult.ignoredFailures.count) ignored failures across \(sampleCount) samples"
                    } else {
                        taxTriageParams["Warnings"] = "\(ttResult.ignoredFailures.count) ignored failures"
                    }
                }

                // Resolve source sample URLs from config samples and project search.
                taxTriageSamples = cfg.samples.map { sample in
                    let bundleURL = cfg.sourceBundleURLs?.first { url in
                        url.deletingPathExtension().lastPathComponent
                            .localizedCaseInsensitiveContains(sample.sampleId)
                    } ?? projectURL.flatMap { findBundleInProject($0, matchingSampleId: sample.sampleId) }
                    return (sampleId: sample.sampleId, bundleURL: bundleURL)
                }
            } else if let taxTriageVC = viewerController.taxTriageViewController {
                // No sidecar available — use sample entries from the VC to at least resolve source URLs.
                taxTriageSamples = taxTriageVC.sampleEntries.map { entry in
                    let bundleURL = projectURL.flatMap { findBundleInProject($0, matchingSampleId: entry.id) }
                    return (sampleId: entry.id, bundleURL: bundleURL)
                }
            }

            self.inspectorController?.clearBatchOperationDetails()
            self.inspectorController?.updateBatchOperationDetails(
                tool: "TaxTriage",
                parameters: taxTriageParams,
                timestamp: taxTriageTimestamp,
                sourceSamples: taxTriageSamples
            )
            if let taxTriageVC = viewerController.taxTriageViewController {
                self.inspectorController?.viewModel.documentSectionViewModel.batchManifestStatus =
                    taxTriageVC.didLoadFromManifestCache ? .cached : .building
            }

        } else if dirName.hasPrefix("naomgs") || AnalysesFolder.readAnalysisMetadata(from: batchURL)?.tool == "naomgs" {
            displayNaoMgsResultFromSidebar(at: batchURL)
            self.inspectorController?.clearBatchOperationDetails()

        } else if dirName.hasPrefix("nvd") || AnalysesFolder.readAnalysisMetadata(from: batchURL)?.tool == "nvd" {
            displayNvdResultFromSidebar(at: batchURL)
            self.inspectorController?.clearBatchOperationDetails()

        } else {
            mainSplitLogger.warning("displayBatchGroup: Unrecognized batch prefix in '\(dirName, privacy: .public)'")
        }
    }

    func provenanceSidebarType(
        forMetagenomicsToolId toolId: String,
        directoryName: String
    ) -> SidebarItemType {
        if directoryName.hasPrefix("kraken2")
            || directoryName.hasPrefix("classification")
            || toolId.hasPrefix("kraken2")
            || toolId.hasPrefix("classification") {
            return .classificationResult
        }
        if directoryName.hasPrefix("esviritu") || toolId.hasPrefix("esviritu") {
            return .esvirituResult
        }
        if directoryName.hasPrefix("taxtriage") || toolId.hasPrefix("taxtriage") {
            return .taxTriageResult
        }
        if directoryName.hasPrefix("naomgs") || toolId == "naomgs" {
            return .naoMgsResult
        }
        if directoryName.hasPrefix("nvd") || toolId == "nvd" {
            return .nvdResult
        }
        if directoryName.hasPrefix("cz-id") || toolId.hasPrefix("cz-id") {
            return .czIdResult
        }
        return .analysisResult
    }

    /// Shows a ``DatabaseBuildPlaceholderView`` in the viewport area and
    /// automatically triggers a background `lungfish build-db` subprocess.
    ///
    /// On success the placeholder is removed and ``displayBatchGroup(at:)`` is
    /// called again so the newly-built SQLite database is picked up.  On failure
    /// the placeholder switches to an error state with a Retry button.
    ///
    /// - Parameters:
    ///   - tool: Human-readable tool name (e.g. "TaxTriage").
    ///   - resultURL: The batch result directory URL.
    func showDatabaseBuildPlaceholder(tool: String, resultURL: URL) {
        let databaseBuildRequest = beginDatabaseBuildRequest(tool: tool, resultURL: resultURL)

        // Clear any existing viewport content so the placeholder is the only thing shown.
        viewerController.clearViewport(statusMessage: "")

        let placeholder = DatabaseBuildPlaceholderView()

        let contentView = viewerController.view
        contentView.addSubview(placeholder)
        registerTransientViewportOverlay(placeholder)
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            placeholder.topAnchor.constraint(equalTo: contentView.topAnchor),
            placeholder.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            placeholder.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            placeholder.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        let dirName = resultURL.lastPathComponent
        mainSplitLogger.info(
            "showDatabaseBuildPlaceholder: Shown for tool='\(tool, privacy: .public)' result='\(dirName, privacy: .public)'"
        )

        // Auto-trigger the database build.
        triggerDatabaseBuild(
            tool: tool,
            resultURL: resultURL,
            placeholder: placeholder,
            request: databaseBuildRequest
        )
    }

    func beginDatabaseBuildRequest(
        tool: String,
        resultURL: URL
    ) -> (identity: ContentSelectionIdentity, token: AsyncRequestToken<ContentSelectionIdentity>) {
        let identity = ContentSelectionIdentity(
            url: resultURL,
            kind: "databaseBuild:\(tool.lowercased())",
            resultID: resultURL.lastPathComponent,
            windowID: windowStateScope.id
        )
        return (identity, beginDisplayRequest(identity: identity))
    }

    func commitDatabaseBuildCompletion(
        _ request: (identity: ContentSelectionIdentity, token: AsyncRequestToken<ContentSelectionIdentity>),
        commit: () -> Void
    ) {
        guard canCommitDisplayRequest(request.token, identity: request.identity) else { return }
        commit()
    }

    /// Runs `lungfish-cli build-db <tool> <resultDir>` via ``LungfishCLIRunner``.
    ///
    /// Updates the placeholder view with progress/error states and, on success,
    /// removes it and re-triggers ``displayBatchGroup(at:)`` so the newly-built
    /// database is loaded.
    ///
    /// Most batch pipelines now build the database in-process before the user
    /// ever reaches this placeholder (see ``runEsVirituBatch`` and
    /// ``runClassificationBatch``). This path exists as a fallback for
    /// legacy/imported batches that were created without an attached SQLite DB.
    func triggerDatabaseBuild(
        tool: String,
        resultURL: URL,
        placeholder: DatabaseBuildPlaceholderView,
        request: (identity: ContentSelectionIdentity, token: AsyncRequestToken<ContentSelectionIdentity>)
    ) {
        let cliTool = tool.lowercased()
        let requestIdentity = request.identity
        let requestGeneration = request.token.generation

        // Show the "building" spinner state immediately so the user sees feedback.
        placeholder.showBuilding(tool: tool)

        Task.detached { [weak self] in
            do {
                let sampleDirectories = try Self.classifierDatabaseBuildSampleDirectories(
                    tool: cliTool,
                    resultURL: resultURL
                )
                try LungfishCLIRunner.buildClassifierDatabase(
                    tool: cliTool,
                    resultURL: resultURL,
                    force: true,
                    sampleDirectories: sampleDirectories
                )

                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        let completionRequest = (
                            identity: requestIdentity,
                            token: AsyncRequestToken(generation: requestGeneration, identity: requestIdentity)
                        )
                        self.commitDatabaseBuildCompletion(completionRequest) {
                            placeholder.removeFromSuperview()
                            // Re-display — the DB should now exist.
                            self.displayBatchGroup(at: resultURL)
                        }
                    }
                }
            } catch {
                let errorDescription = error.localizedDescription
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        let completionRequest = (
                            identity: requestIdentity,
                            token: AsyncRequestToken(generation: requestGeneration, identity: requestIdentity)
                        )
                        self.commitDatabaseBuildCompletion(completionRequest) {
                            placeholder.showError("Build failed: \(errorDescription)")
                            // Ensure the placeholder is still in the viewport hierarchy so the error is visible.
                            if placeholder.superview == nil {
                                let contentView = self.viewerController.view
                                contentView.addSubview(placeholder)
                                self.registerTransientViewportOverlay(placeholder)
                                placeholder.translatesAutoresizingMaskIntoConstraints = false
                                NSLayoutConstraint.activate([
                                    placeholder.topAnchor.constraint(equalTo: contentView.topAnchor),
                                    placeholder.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                                    placeholder.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                                    placeholder.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
                                ])
                            }
                            placeholder.onRetry = { [weak self] in
                                placeholder.removeFromSuperview()
                                self?.showDatabaseBuildPlaceholder(tool: tool, resultURL: resultURL)
                            }
                        }
                    }
                }
            }
        }
    }

    nonisolated static func classifierDatabaseBuildSampleDirectories(tool: String, resultURL: URL) throws -> [URL] {
        guard tool.lowercased() == "kraken2" else {
            return []
        }
        guard let manifest = MetagenomicsBatchResultStore.loadClassification(from: resultURL) else {
            return []
        }

        let directories = manifest.samples
            .map { resultURL.appendingPathComponent($0.resultDirectory, isDirectory: true).standardizedFileURL }
        guard !directories.isEmpty else {
            throw LungfishCLIRunner.RunError.invalidInvocation(
                "Cannot build Kraken2 database: batch manifest has no successful sample directories."
            )
        }
        return directories
    }

    /// Formats a pipeline runtime duration as a human-readable string for the Inspector.
    ///
    /// Returns strings like "34s", "2m 14s", or "1h 3m" depending on magnitude.
    /// Returns an empty string for zero or negative durations.
    func formatInspectorRuntime(_ seconds: TimeInterval) -> String {
        guard seconds > 0 else { return "" }
        let total = Int(seconds.rounded())
        if total < 60 {
            return "\(total)s"
        } else if total < 3600 {
            let m = total / 60
            let s = total % 60
            return s > 0 ? "\(m)m \(s)s" : "\(m)m"
        } else {
            let h = total / 3600
            let m = (total % 3600) / 60
            return m > 0 ? "\(h)h \(m)m" : "\(h)h"
        }
    }

    /// Resolves each sample record's originating `.lungfishfastq` bundle URL.
    ///
    /// First attempts to walk up the input file path to find a `.lungfishfastq` ancestor.
    /// If that fails (e.g. when materialized temp files have been cleaned up), falls back
    /// to searching the project directory for a bundle whose name contains the sample ID.
    ///
    /// - Parameters:
    ///   - samples: Records from a batch manifest.
    ///   - projectURL: The project root to search as a fallback (optional).
    /// - Returns: Tuples of sample ID and bundle URL (nil when the bundle cannot be located).
    func resolveBatchSourceSamples(
        _ samples: [MetagenomicsBatchSampleRecord],
        projectURL: URL? = nil
    ) -> [(sampleId: String, bundleURL: URL?)] {
        samples.map { record in
            // Primary: walk up each input file path looking for a .lungfishfastq ancestor.
            var bundleURL = record.inputFiles.first.flatMap { path in
                resolveBundleURL(fromInputFilePath: path)
            }

            // Fallback: search the project directory for a .lungfishfastq bundle whose
            // filename (without extension) contains the sample ID.
            // This handles the common case where inputFiles pointed to materialized temp files
            // that have since been cleaned up.
            if bundleURL == nil, let projectURL {
                bundleURL = findBundleInProject(projectURL, matchingSampleId: record.sampleId)
            }

            return (sampleId: record.sampleId, bundleURL: bundleURL)
        }
    }

    /// Searches a project directory tree for a `.lungfishfastq` bundle whose filename
    /// (without extension) contains the given sample ID (case-insensitive).
    ///
    /// Only searches two levels deep to stay fast: `<project>/` and `<project>/Imports/`.
    ///
    /// - Parameters:
    ///   - projectURL: The project root directory.
    ///   - sampleId: The sample ID to match against bundle filenames.
    /// - Returns: The first matching `.lungfishfastq` bundle URL, or nil.
    func findBundleInProject(_ projectURL: URL, matchingSampleId sampleId: String) -> URL? {
        let fm = FileManager.default
        let lowerSampleId = sampleId.lowercased()

        func searchDirectory(_ dir: URL) -> URL? {
            guard let entries = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { return nil }

            return entries.first { entry in
                guard entry.pathExtension.lowercased() == "lungfishfastq" else { return false }
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else { return false }
                let bundleName = entry.deletingPathExtension().lastPathComponent.lowercased()
                return bundleName.contains(lowerSampleId) || lowerSampleId.contains(bundleName)
            }
        }

        // Search project root.
        if let found = searchDirectory(projectURL) { return found }

        // Search project/Imports/.
        let importsDir = projectURL.appendingPathComponent("Imports")
        if let found = searchDirectory(importsDir) { return found }

        return nil
    }

    /// Walks up a file path to find the enclosing `.lungfishfastq` bundle directory.
    ///
    /// Input files inside FASTQ bundles live at paths like:
    /// `.../SampleA.lungfishfastq/reads.fastq.gz`
    /// This helper climbs ancestors until it finds a directory with the `.lungfishfastq` extension.
    ///
    /// - Parameter path: Absolute file path to start from.
    /// - Returns: The `.lungfishfastq` directory URL, or nil if none is found.
    func resolveBundleURL(fromInputFilePath path: String) -> URL? {
        var url = URL(fileURLWithPath: path)
        // Walk up until we hit the root or find a .lungfishfastq directory.
        while url.pathComponents.count > 1 {
            url = url.deletingLastPathComponent()
            if url.pathExtension.lowercased() == "lungfishfastq" {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                    return url
                }
            }
        }
        return nil
    }

    /// Displays a NAO-MGS surveillance result from its bundle directory.
    ///
    /// Reads the manifest and virus hits JSON from the bundle, then
    /// displays the NAO-MGS result viewer. Falls back to re-parsing the
    /// original TSV if the cached JSON is missing.
    ///
    /// - Parameter url: The `naomgs-*` bundle directory.
    func displayNaoMgsResultFromSidebar(
        at url: URL,
        identity: ContentSelectionIdentity? = nil,
        token: AsyncRequestToken<ContentSelectionIdentity>? = nil
    ) {
        mainSplitLogger.info("displayNaoMgsResult: Opening '\(url.lastPathComponent, privacy: .public)'")
        let displayIdentity = identity ?? contentSelectionIdentity(url: url, kind: "naoMgsResult")
        let displayToken = token ?? beginDisplayRequest(identity: displayIdentity)
        inspectorController?.updateProvenanceTarget(
            url: url,
            sidebarType: .naoMgsResult,
            displayName: url.lastPathComponent
        )

        // Show a placeholder immediately so the user gets feedback while we load.
        let placeholderVC = NaoMgsResultViewController()
        viewerController.displayNaoMgsResult(placeholderVC)

        // Two-phase load: manifest first (fast) for instant taxon list,
        // then SQLite database (slow) for detail queries.
        let bundleURL = url
        Task {
            do {
                let fm = FileManager.default
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601

                // Phase 1: Read manifest (fast — small JSON file).
                let manifestURL = bundleURL.appendingPathComponent("manifest.json")
                guard fm.fileExists(atPath: manifestURL.path) else {
                    throw NSError(domain: "NaoMgsDisplay", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "manifest.json not found in NAO-MGS bundle"])
                }
                // Read the manifest off the main actor; the commit below is
                // already gated by `canCommitDisplayRequest`, which dominates
                // the (await-free) UI mutation so a stale read commits nothing.
                let manifestData = try await AsyncFileReader.readData(manifestURL)
                let manifest = try decoder.decode(NaoMgsManifest.self, from: manifestData)

                guard canCommitDisplayRequest(displayToken, identity: displayIdentity) else { return }

                // If manifest has cached taxon rows, show them immediately.
                if let cachedRows = manifest.cachedTaxonRows, !cachedRows.isEmpty {
                    placeholderVC.configureWithCachedRows(cachedRows, manifest: manifest, bundleURL: bundleURL)
                    inspectorController?.updateNaoMgsManifest(manifest)
                    mainSplitLogger.info("displayNaoMgsResult: Showing \(cachedRows.count) cached taxon rows instantly")
                }

                // Phase 2: Open SQLite database (slow — full file I/O + SQLite init).
                let dbURL = bundleURL.appendingPathComponent("hits.sqlite")
                guard fm.fileExists(atPath: dbURL.path) else {
                    throw NSError(domain: "NaoMgsDisplay", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "hits.sqlite not found — bundle may need re-import"])
                }
                if try naomgsBundleNeedsUpgrade(dbURL: dbURL) {
                    throw NSError(
                        domain: "NaoMgsDisplay",
                        code: 3,
                        userInfo: [
                            NSLocalizedDescriptionKey: "This NAO-MGS bundle uses an older derived database layout and needs explicit repair or re-import before viewing. Viewing no longer rewrites scientific bundle data automatically."
                        ]
                    )
                }
                let database = try NaoMgsDatabase(at: dbURL)

                guard canCommitDisplayRequest(displayToken, identity: displayIdentity) else { return }
                // Full configure with database — enables detail queries, filtering, BLAST.
                placeholderVC.configure(database: database, manifest: manifest, bundleURL: bundleURL)

                // Update inspector with NAO-MGS manifest info
                inspectorController?.updateNaoMgsManifest(manifest)

                // Wire sample picker state to Inspector for embedded sample selector
                installClassifierMetadataPresentation(
                    resultURL: bundleURL,
                    pickerState: placeholderVC.samplePickerState,
                    entries: placeholderVC.sampleEntries,
                    strippedPrefix: placeholderVC.strippedPrefix,
                    workflowName: "NAO-MGS",
                    consumer: placeholderVC
                )

                let totalHits = (try? database.totalHitCount()) ?? manifest.hitCount
                mainSplitLogger.info("displayNaoMgsResult: Configured with database, \(totalHits) hits")
            } catch {
                guard canCommitDisplayRequest(displayToken, identity: displayIdentity) else { return }
                mainSplitLogger.error("displayNaoMgsResult: Failed - \(error.localizedDescription, privacy: .public)")
                let alert = NSAlert()
                alert.messageText = "Failed to Load NAO-MGS Result"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                if let window = view.window ?? NSApp.keyWindow {
                    await alert.beginSheetModal(for: window)
                }
            }
        }
    }

    func naomgsBundleNeedsUpgrade(dbURL: URL) throws -> Bool {
        let database = try NaoMgsDatabase(at: dbURL)
        let rows = try database.fetchTaxonSummaryRows()
        guard let first = rows.first else { return false }
        let readNames = try database.fetchReadNames(sample: first.sample, taxId: first.taxId)
        return readNames.isEmpty
    }

    /// Displays an NVD result from its bundle directory.
    ///
    /// Two-phase loading: manifest first (fast) for instant contig list,
    /// then SQLite database (slower) for full detail queries.
    ///
    /// - Parameter url: The `nvd-*` bundle directory.
    func displayNvdResultFromSidebar(
        at url: URL,
        identity: ContentSelectionIdentity? = nil,
        token: AsyncRequestToken<ContentSelectionIdentity>? = nil
    ) {
        mainSplitLogger.info("displayNvdResult: Opening '\(url.lastPathComponent, privacy: .public)'")
        let displayIdentity = identity ?? contentSelectionIdentity(url: url, kind: "nvdResult")
        let displayToken = token ?? beginDisplayRequest(identity: displayIdentity)
        inspectorController?.updateProvenanceTarget(
            url: url,
            sidebarType: .nvdResult,
            displayName: url.lastPathComponent
        )

        // Show a placeholder immediately so the user gets feedback while we load.
        let placeholderVC = NvdResultViewController()
        viewerController.displayNvdResult(placeholderVC)

        // Two-phase load: manifest first (fast) for instant contig list,
        // then SQLite database (slower) for detail queries.
        let bundleURL = url
        Task {
            do {
                let fm = FileManager.default
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601

                // Phase 1: Read manifest (fast — small JSON file).
                let manifestURL = bundleURL.appendingPathComponent("manifest.json")
                guard fm.fileExists(atPath: manifestURL.path) else {
                    throw NSError(domain: "NvdDisplay", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "manifest.json not found in NVD bundle"])
                }
                // Read the manifest off the main actor; the commit below is
                // already gated by `canCommitDisplayRequest`, which dominates
                // the (await-free) UI mutation so a stale read commits nothing.
                let manifestData = try await AsyncFileReader.readData(manifestURL)
                let manifest = try decoder.decode(NvdManifest.self, from: manifestData)

                // If manifest has cached contig rows, show them immediately.
                if let cachedRows = manifest.cachedTopContigs, !cachedRows.isEmpty {
                    guard canCommitDisplayRequest(displayToken, identity: displayIdentity) else { return }
                    placeholderVC.configureWithCachedRows(cachedRows, manifest: manifest, bundleURL: bundleURL)
                    inspectorController?.updateNvdManifest(manifest)
                    mainSplitLogger.info("displayNvdResult: Showing \(cachedRows.count) cached contig rows instantly")
                }

                // Phase 2: Open SQLite database (slower — full file I/O + SQLite init).
                let dbURL = bundleURL.appendingPathComponent("hits.sqlite")
                guard fm.fileExists(atPath: dbURL.path) else {
                    throw NSError(domain: "NvdDisplay", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "hits.sqlite not found — bundle may need re-import"])
                }
                let database = try NvdDatabase(at: dbURL)

                guard canCommitDisplayRequest(displayToken, identity: displayIdentity) else { return }
                // Full configure with database — enables detail queries, filtering, BLAST.
                placeholderVC.configure(database: database, manifest: manifest, bundleURL: bundleURL)

                // Update inspector with NVD manifest info
                inspectorController?.updateNvdManifest(manifest)

                // Wire sample picker state to Inspector for embedded sample selector
                installClassifierMetadataPresentation(
                    resultURL: bundleURL,
                    pickerState: placeholderVC.samplePickerState,
                    entries: placeholderVC.sampleEntries,
                    strippedPrefix: placeholderVC.strippedPrefix,
                    workflowName: "NVD",
                    consumer: placeholderVC
                )

                let totalHits = (try? database.totalHitCount()) ?? manifest.hitCount
                mainSplitLogger.info("displayNvdResult: Configured with database, \(totalHits) hits")
            } catch {
                guard canCommitDisplayRequest(displayToken, identity: displayIdentity) else { return }
                mainSplitLogger.error("displayNvdResult: Failed - \(error.localizedDescription, privacy: .public)")
                let alert = NSAlert()
                alert.messageText = "Failed to Load NVD Result"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                if let window = view.window ?? NSApp.keyWindow {
                    await alert.beginSheetModal(for: window)
                }
            }
        }
    }

    func displayCzIdResultFromSidebar(
        at url: URL,
        identity: ContentSelectionIdentity? = nil,
        token: AsyncRequestToken<ContentSelectionIdentity>? = nil
    ) {
        mainSplitLogger.info("displayCzIdResult: Opening '\(url.lastPathComponent, privacy: .public)'")
        let displayIdentity = identity ?? contentSelectionIdentity(url: url, kind: "czIdResult")
        let displayToken = token ?? beginDisplayRequest(identity: displayIdentity)
        inspectorController?.updateProvenanceTarget(
            url: url,
            sidebarType: .czIdResult,
            displayName: url.lastPathComponent
        )

        let bundleURL = url
        Task {
            do {
                let manifestURL = bundleURL.appendingPathComponent("cz-id-manifest.json")
                // Read the manifest off the main actor; the commit below is
                // already gated by `canCommitDisplayRequest`, which dominates
                // the (await-free) UI mutation so a stale read commits nothing.
                let manifestData = try await AsyncFileReader.readData(manifestURL)
                let manifest = try JSONDecoder().decode(CzIdImportManifest.self, from: manifestData)
                let result = try ClassificationResult.load(from: bundleURL)

                guard canCommitDisplayRequest(displayToken, identity: displayIdentity) else { return }
                let controller = CzIdResultViewController()
                controller.configure(result: result, manifest: manifest, bundleURL: bundleURL)
                viewerController.displayCzIdResult(controller)
                inspectorController?.clearBatchOperationDetails()
                mainSplitLogger.info("displayCzIdResult: Configured with \(manifest.rowCount, privacy: .public) taxa")
            } catch {
                guard canCommitDisplayRequest(displayToken, identity: displayIdentity) else { return }
                mainSplitLogger.error("displayCzIdResult: Failed - \(error.localizedDescription, privacy: .public)")
                let alert = NSAlert()
                alert.messageText = "Failed to Load CZ-ID Result"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                if let window = view.window ?? NSApp.keyWindow {
                    await alert.beginSheetModal(for: window)
                }
            }
        }
    }

    /// Reads the first line of each FASTA file in `referencesDirectory` to build
    /// an accession → organism name dictionary.
    ///
    /// FASTA headers have the form: `>{accession} {organism description}`.
    /// Only the first line of each file is read (fast — no full parse needed).
    static func buildAccessionNameMap(referencesDirectory: URL) -> [String: String] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: referencesDirectory.path),
              let enumerator = fm.enumerator(
                at: referencesDirectory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
              ) else { return [:] }

        var map: [String: String] = [:]
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension.lowercased() == "fasta",
                  let handle = try? FileHandle(forReadingFrom: fileURL) else { continue }
            // Read just the first 512 bytes — enough for any FASTA header line.
            let headerData = handle.readData(ofLength: 512)
            try? handle.close()
            guard let headerStr = String(data: headerData, encoding: .utf8) else { continue }
            let firstLine = headerStr.components(separatedBy: "\n").first ?? ""
            guard firstLine.hasPrefix(">") else { continue }
            let withoutCaret = firstLine.dropFirst() // remove ">"
            let parts = withoutCaret.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let accession = String(parts[0])
            var organism = String(parts[1])
            // Trim trailing whitespace / carriage return
            organism = organism.trimmingCharacters(in: .whitespacesAndNewlines)
            if !organism.isEmpty {
                map[accession] = organism
            }
        }
        return map
    }

    /// Derives a best-fit organism name for each taxon by finding the most common
    /// accession for that taxon and looking it up in `accessionToName`.
    static func deriveTaxonNames(
        hits: [NaoMgsVirusHit],
        accessionToName: [String: String]
    ) -> [Int: String] {
        // Count how many times each accession appears per taxId.
        var taxIdAccCounts: [Int: [String: Int]] = [:]
        for hit in hits where !hit.subjectSeqId.isEmpty {
            taxIdAccCounts[hit.taxId, default: [:]][hit.subjectSeqId, default: 0] += 1
        }

        // Also collect subjectTitle from hits (v1 format has these).
        var taxIdTitleCounts: [Int: [String: Int]] = [:]
        for hit in hits where !hit.subjectTitle.isEmpty {
            taxIdTitleCounts[hit.taxId, default: [:]][hit.subjectTitle, default: 0] += 1
        }

        var result: [Int: String] = [:]
        for (taxId, accCounts) in taxIdAccCounts {
            // Pick the accession with the most hits.
            guard let topAcc = accCounts.max(by: { $0.value < $1.value })?.key else { continue }
            // Try exact accession first, then version-stripped (e.g. "KU162869" from "KU162869.1").
            if let name = accessionToName[topAcc] {
                result[taxId] = name
            } else {
                let versionless = String(topAcc.prefix(while: { $0 != "." }))
                if let name = accessionToName.first(where: { $0.key.hasPrefix(versionless) })?.value {
                    result[taxId] = name
                }
            }
        }

        // Fallback: for taxa without FASTA-derived names, use subjectTitle from the hits.
        for (taxId, titleCounts) in taxIdTitleCounts where result[taxId] == nil {
            if let topTitle = titleCounts.max(by: { $0.value < $1.value })?.key {
                // Clean up the title: sometimes it includes accession prefix
                var cleanTitle = topTitle
                // Remove "complete genome" / "complete genome, monopartite" suffixes for cleaner display
                cleanTitle = cleanTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleanTitle.isEmpty {
                    result[taxId] = cleanTitle
                }
            }
        }

        return result
    }
}
