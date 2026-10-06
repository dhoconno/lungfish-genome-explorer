import AppKit
import SwiftUI
import XCTest
import LungfishWorkflow
@testable import LungfishApp

@MainActor
final class WorkflowLibraryTests: XCTestCase {
    func testBuiltInCatalogRegistersEveryFASTQOperationAndKeepsONTGenotypingSpecialized() throws {
        let catalogToolIDs = Set(WorkflowLibraryCatalog.builtIn.compactMap(\.toolID))
        XCTAssertEqual(catalogToolIDs, Set(FASTQOperationToolID.allCases))

        let ont = try XCTUnwrap(WorkflowLibraryCatalog.item(for: .ontGenotyping))
        XCTAssertEqual(ont.maturity, .specialized)
        XCTAssertEqual(ont.requiredPluginPackIDs, ["lungfish-tools", "read-mapping"])
        XCTAssertEqual(ont.title, "MiSeq Amplicon MHC Genotyping")

        XCTAssertEqual(WorkflowLibraryCatalog.item(for: .minimap2)?.requiredPluginPackIDs, ["read-mapping"])
        XCTAssertEqual(WorkflowLibraryCatalog.item(for: .mafft)?.requiredPluginPackIDs, ["multiple-sequence-alignment"])
        XCTAssertEqual(
            WorkflowLibraryCatalog.item(for: .savont)?.requiredPluginPackIDs,
            ["full-length-mhc-genotyping"]
        )

        let coreItems = WorkflowLibraryCatalog.builtIn.filter { $0.maturity == .core }
        XCTAssertFalse(coreItems.isEmpty)
        XCTAssertTrue(coreItems.allSatisfy { $0.maturity == .core })
    }

    func testBuiltInCatalogIncludesTwelveSAmpliconMatchingAsSpecializedWorkflow() throws {
        let twelveS = try XCTUnwrap(WorkflowLibraryCatalog.item(id: WorkflowLibraryCatalog.twelveSAmpliconMatchingID))

        XCTAssertNil(twelveS.toolID)
        XCTAssertEqual(twelveS.title, "12S Amplicon Matching")
        XCTAssertEqual(twelveS.maturity, .specialized)
        XCTAssertEqual(twelveS.categoryID, .classification, "12S identifies species, so it is classification")
        XCTAssertEqual(twelveS.requiredPluginPackIDs, ["lungfish-tools"])
    }

    func testSavontIsCoreAndRetainsItsManagedRuntimeRequirement() throws {
        let savont = try XCTUnwrap(WorkflowLibraryCatalog.item(for: .savont))
        XCTAssertEqual(savont.maturity, .core)
        XCTAssertEqual(savont.requiredPluginPackIDs, ["full-length-mhc-genotyping"])
        XCTAssertTrue(WorkflowLibraryEnablementStore(userDefaults: try makeDefaults()).isWorkflowEnabled(.savont))
    }

    func testStandaloneSavontRemainsVisibleWithExistingWorkflowPreferences() throws {
        let defaults = try makeDefaults()
        defaults.set(
            [FASTQOperationToolID.ontGenotyping.rawValue],
            forKey: "WorkflowLibrary.enabledWorkflowIDs"
        )
        let store = WorkflowLibraryEnablementStore(userDefaults: defaults)
        let state = FASTQOperationDialogState(
            initialCategory: .clustering,
            selectedInputURLs: [URL(fileURLWithPath: "/tmp/barcode12.lungfishfastq")],
            workflowLibrary: store
        )

        XCTAssertEqual(state.visibleToolIDs, [.savont, .pbaa])
    }

    func testBuiltInCatalogIncludesFullLengthONTMHCGenotypingAsSpecializedWorkflow() throws {
        let workflow = try XCTUnwrap(
            WorkflowLibraryCatalog.item(id: WorkflowLibraryCatalog.fullLengthONTMHCGenotypingID)
        )

        XCTAssertNil(workflow.toolID)
        XCTAssertEqual(workflow.title, "Full-Length ONT MHC Genotyping")
        XCTAssertEqual(workflow.maturity, .specialized)
        XCTAssertEqual(workflow.categoryID, .genotyping)
        XCTAssertEqual(workflow.requiredPluginPackIDs, [
            "lungfish-tools",
            "read-mapping",
            "full-length-mhc-genotyping",
        ])
        XCTAssertTrue(workflow.capabilities.contains(.workflowOperations))
        XCTAssertTrue(workflow.capabilities.contains(.haplotypeDefinitions))
    }

    func testBuiltInSectionsGroupCoreWorkflowsBeforeSpecializedWorkflows() throws {
        let sections = WorkflowLibraryCatalog.builtInSections

        XCTAssertEqual(sections.first?.kind, .core)
        XCTAssertEqual(sections.first?.title, "Core Tools")
        XCTAssertTrue(sections.first?.items.allSatisfy { $0.maturity == .core } == true)

        let specialized = try XCTUnwrap(sections.first { $0.kind == .specialized })
        XCTAssertEqual(specialized.title, "Specialized Workflows")
        XCTAssertTrue(specialized.items.contains { $0.toolID == .ontGenotyping })
        XCTAssertTrue(specialized.items.contains { $0.id == WorkflowLibraryCatalog.fullLengthONTMHCGenotypingID })
        XCTAssertTrue(specialized.items.contains { $0.id == WorkflowLibraryCatalog.twelveSAmpliconMatchingID })
        XCTAssertTrue(sections.firstIndex { $0.kind == .core }! < sections.firstIndex { $0.kind == .specialized }!)
    }

    func testCoreSectionGroupsBuiltInToolsByLogicalCategory() throws {
        let core = try XCTUnwrap(WorkflowLibraryCatalog.builtInSections.first { $0.kind == .core })

        XCTAssertTrue(core.groups.contains { $0.title == "Mapping" && $0.items.contains { $0.toolID == .minimap2 } })
        XCTAssertFalse(core.groups.first { $0.title == "Mapping" }?.items.contains { $0.toolID == .viralRecon } ?? true)
        XCTAssertTrue(core.groups.contains { $0.title == "Variant Calling" && $0.items.contains { $0.toolID == .viralRecon } })
        XCTAssertTrue(core.groups.contains { $0.title == "Alignment & Phylogenetics" && $0.items.contains { $0.toolID == .mafft } })
        XCTAssertTrue(core.groups.contains { $0.title == "Trimming & Filtering" && $0.items.contains { $0.toolID == .removeDuplicates } })
        XCTAssertTrue(core.groups.contains { $0.title == "Trimming & Filtering" && $0.items.contains { $0.toolID == .removeLowComplexityReads } })
        XCTAssertEqual(
            core.groups.map(\.title),
            core.groups.map(\.title).sorted { $0.localizedStandardCompare($1) == .orderedAscending },
            "the library lists its groups alphabetically"
        )
        for group in core.groups {
            XCTAssertTrue(
                FASTQOperationCategoryID.allCases.contains { $0.displayName == group.title },
                "\(group.title) is a category display name"
            )
        }
        XCTAssertFalse(core.groups.flatMap(\.items).contains { $0.toolID == .ontGenotyping })
        XCTAssertFalse(core.groups.flatMap(\.items).contains { $0.id == WorkflowLibraryCatalog.twelveSAmpliconMatchingID })
    }

    func testFreshInstallKeepsNicheWorkflowsOptInAndPersistsExplicitChanges() throws {
        let defaults = try makeDefaults()
        let store = WorkflowLibraryEnablementStore(userDefaults: defaults)
        let twelveS = try XCTUnwrap(WorkflowLibraryCatalog.item(id: WorkflowLibraryCatalog.twelveSAmpliconMatchingID))

        // A fresh install enables ONT genotyping (an enhancement to an existing
        // workflow) but leaves 12S amplicon matching opt-in/disabled.
        XCTAssertTrue(store.isWorkflowEnabled(.minimap2))
        XCTAssertTrue(store.isWorkflowEnabled(.ontGenotyping))
        XCTAssertFalse(
            store.isWorkflowEnabled(twelveS),
            "12S is a niche opt-in workflow; it must be DISABLED on fresh install"
        )

        // Explicitly enabling the niche workflow persists across reloads.
        store.setWorkflow(twelveS, enabled: true)
        XCTAssertTrue(store.isWorkflowEnabled(twelveS))

        let enabledReload = WorkflowLibraryEnablementStore(userDefaults: defaults)
        XCTAssertTrue(enabledReload.isWorkflowEnabled(twelveS))
        XCTAssertTrue(enabledReload.isWorkflowEnabled(.ontGenotyping))

        // Disabling ONT genotyping and the niche workflow also persists.
        enabledReload.setWorkflow(.ontGenotyping, enabled: false)
        enabledReload.setWorkflow(twelveS, enabled: false)
        XCTAssertFalse(enabledReload.isWorkflowEnabled(.ontGenotyping))
        XCTAssertFalse(enabledReload.isWorkflowEnabled(twelveS))

        let disabledReload = WorkflowLibraryEnablementStore(userDefaults: defaults)
        XCTAssertFalse(disabledReload.isWorkflowEnabled(.ontGenotyping))
        XCTAssertFalse(disabledReload.isWorkflowEnabled(twelveS))
    }

    func testEnablementStorePostsChangeNotificationWhenWorkflowAvailabilityChanges() throws {
        let defaults = try makeDefaults()
        let store = WorkflowLibraryEnablementStore(userDefaults: defaults)
        let expectation = expectation(description: "workflow enablement changed")
        let observer = NotificationCenter.default.addObserver(
            forName: .workflowLibraryEnablementDidChange,
            object: nil,
            queue: nil
        ) { notification in
            XCTAssertEqual(notification.userInfo?["workflowID"] as? String, FASTQOperationToolID.ontGenotyping.rawValue)
            expectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        store.setWorkflow(.ontGenotyping, enabled: false)

        wait(for: [expectation], timeout: 1)
    }

    func testWorkflowFeatureAvailabilityFollowsEnabledSpecializedAndUserWorkflows() throws {
        let defaults = try makeDefaults()
        let store = WorkflowLibraryEnablementStore(userDefaults: defaults)
        let packageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)

        var availability = WorkflowFeatureAvailability.current(enablementStore: store, packageStore: packageStore)
        XCTAssertTrue(availability.hasWorkflowOperations)
        XCTAssertTrue(availability.hasHaplotypeDefinitions)

        store.setWorkflow(.ontGenotyping, enabled: false)
        availability = WorkflowFeatureAvailability.current(enablementStore: store, packageStore: packageStore)
        XCTAssertFalse(availability.hasWorkflowOperations)
        XCTAssertFalse(availability.hasHaplotypeDefinitions)

        store.setUserWorkflow("org.example.custom", enabled: true)
        availability = WorkflowFeatureAvailability.current(enablementStore: store, packageStore: packageStore)
        XCTAssertFalse(
            availability.hasWorkflowOperations,
            "Stale ID-only user workflow state must not unlock Workflow Operations"
        )

        let package = try makeUserWorkflowPackageOnDisk(id: "org.example.custom", runnerKind: .nextflow)
        packageStore.addValidatedPackage(package)
        store.setUserWorkflow(package, enabled: true)
        availability = WorkflowFeatureAvailability.current(enablementStore: store, packageStore: packageStore)
        XCTAssertTrue(availability.hasWorkflowOperations)
        XCTAssertFalse(availability.hasHaplotypeDefinitions)
    }

    func testWorkflowFeatureAvailabilityIgnoresCatalogOnlyUserWorkflowPackages() throws {
        let defaults = try makeDefaults()
        let store = WorkflowLibraryEnablementStore(userDefaults: defaults)
        let packageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        store.setWorkflow(.ontGenotyping, enabled: false)
        let commandPackage = try makeUserWorkflowPackageOnDisk(
            id: "org.example.command-workflow",
            runnerKind: .command,
            entrypoint: "run.sh"
        )
        let unsupportedContractPackage = try makeUserWorkflowPackageOnDisk(
            id: "org.example.fastq-only-workflow",
            runnerKind: .nextflow,
            inputs: [
                WorkflowPackageInput(id: "reads", name: "Reads", bundleTypes: [.lungfishfastq]),
            ]
        )
        packageStore.addValidatedPackage(commandPackage)
        packageStore.addValidatedPackage(unsupportedContractPackage)

        store.setUserWorkflow(commandPackage.manifest.id, enabled: true)
        store.setUserWorkflow(unsupportedContractPackage.manifest.id, enabled: true)
        let availability = WorkflowFeatureAvailability.current(enablementStore: store, packageStore: packageStore)

        XCTAssertFalse(availability.hasWorkflowOperations)
        XCTAssertFalse(availability.hasHaplotypeDefinitions)
        XCTAssertFalse(unsupportedContractPackage.supportsWorkflowLibraryExecution)
        XCTAssertTrue(
            unsupportedContractPackage.workflowLibraryExecutionUnavailableReason?.contains(".lungfishref") == true
        )
    }

    func testEnablingSpecializedWorkflowIsBlockedUntilRequiredPluginPacksAreReady() async throws {
        let defaults = try makeDefaults()
        let store = WorkflowLibraryEnablementStore(userDefaults: defaults)
        let ont = try XCTUnwrap(WorkflowLibraryCatalog.item(for: .ontGenotyping))
        store.setWorkflow(.ontGenotyping, enabled: false)

        let blockedProvider = StubWorkflowLibraryPluginStatusProvider(states: [
            "lungfish-tools": .ready,
            "read-mapping": .needsInstall,
        ])
        let blocked = await store.enableWorkflow(ont, using: blockedProvider)
        XCTAssertEqual(blocked, .blocked(missingPackIDs: ["read-mapping"]))
        XCTAssertFalse(store.isWorkflowEnabled(.ontGenotyping))

        let readyProvider = StubWorkflowLibraryPluginStatusProvider(states: [
            "lungfish-tools": .ready,
            "read-mapping": .ready,
        ])
        let enabled = await store.enableWorkflow(ont, using: readyProvider)
        XCTAssertEqual(enabled, .enabled)
        XCTAssertTrue(store.isWorkflowEnabled(.ontGenotyping))
    }

    /// U4. Moving 12S into Classification must not change what gates it. The
    /// category's own pack list (the metagenomics pack) seeds only the core
    /// tools built from a tool ID. A catalog workflow carries its own list, and
    /// both `enableWorkflow(_:using:)` and the library view model read that
    /// list from the item.
    func testTwelveSEnablementIsGatedByItsOwnPackListAndNotByTheClassificationCategory() async throws {
        let twelveS = WorkflowLibraryCatalog.twelveSAmpliconMatchingItem
        XCTAssertEqual(twelveS.categoryID, .classification)
        XCTAssertEqual(FASTQOperationCategoryID.classification.requiredPackIDs, ["metagenomics"])
        XCTAssertEqual(twelveS.requiredPluginPackIDs, ["lungfish-tools"])
        XCTAssertFalse(twelveS.requiredPluginPackIDs.contains("metagenomics"))

        let defaults = try makeDefaults()
        let store = WorkflowLibraryEnablementStore(userDefaults: defaults)
        store.setWorkflow(twelveS, enabled: false)

        // Its own pack is missing and the metagenomics pack is ready, so it stays blocked on its own pack.
        let ownPackMissing = StubWorkflowLibraryPluginStatusProvider(states: [
            "lungfish-tools": .needsInstall,
            "metagenomics": .ready,
        ])
        let blocked = await store.enableWorkflow(twelveS, using: ownPackMissing)
        XCTAssertEqual(blocked, .blocked(missingPackIDs: ["lungfish-tools"]))
        XCTAssertFalse(store.isWorkflowEnabled(twelveS))

        // Its own pack is ready and the metagenomics pack is missing, so it enables and that pack plays no part.
        let ownPackReady = StubWorkflowLibraryPluginStatusProvider(states: [
            "lungfish-tools": .ready,
            "metagenomics": .needsInstall,
        ])
        let enabled = await store.enableWorkflow(twelveS, using: ownPackReady)
        XCTAssertEqual(enabled, .enabled)
        XCTAssertTrue(store.isWorkflowEnabled(twelveS))
    }

    func testEnablingFullLengthMHCWorkflowRequiresSpecializedSavontBlastPack() async throws {
        let defaults = try makeDefaults()
        let store = WorkflowLibraryEnablementStore(userDefaults: defaults)
        let workflow = try XCTUnwrap(
            WorkflowLibraryCatalog.item(id: WorkflowLibraryCatalog.fullLengthONTMHCGenotypingID)
        )
        store.setWorkflow(workflow, enabled: false)

        let blockedProvider = StubWorkflowLibraryPluginStatusProvider(states: [
            "lungfish-tools": .ready,
            "read-mapping": .ready,
            "full-length-mhc-genotyping": .needsInstall,
        ])
        let blocked = await store.enableWorkflow(workflow, using: blockedProvider)
        XCTAssertEqual(blocked, .blocked(missingPackIDs: ["full-length-mhc-genotyping"]))
        XCTAssertFalse(store.isWorkflowEnabled(workflow))

        let readyProvider = StubWorkflowLibraryPluginStatusProvider(states: [
            "lungfish-tools": .ready,
            "read-mapping": .ready,
            "full-length-mhc-genotyping": .ready,
        ])
        let enabled = await store.enableWorkflow(workflow, using: readyProvider)
        XCTAssertEqual(enabled, .enabled)
        XCTAssertTrue(store.isWorkflowEnabled(workflow))
    }

    func testViewModelInstallsMissingDependenciesBeforeEnablingSpecializedWorkflow() async throws {
        let defaults = try makeDefaults()
        let store = WorkflowLibraryEnablementStore(userDefaults: defaults)
        let statusProvider = InstallingWorkflowLibraryPluginStatusProvider(states: [
            "lungfish-tools": .ready,
            "read-mapping": .needsInstall,
        ])
        let packageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        let viewModel = WorkflowLibraryViewModel(
            store: store,
            packageStore: packageStore,
            statusProvider: statusProvider
        )
        let ont = try XCTUnwrap(WorkflowLibraryCatalog.item(for: .ontGenotyping))

        await viewModel.refreshDependencyStatuses()
        XCTAssertEqual(viewModel.missingRequiredPluginPackIDs(for: ont), ["read-mapping"])

        await viewModel.installDependenciesAndEnable(ont)

        XCTAssertEqual(statusProvider.installedPackIDs, ["read-mapping"])
        XCTAssertTrue(store.isWorkflowEnabled(.ontGenotyping))
        XCTAssertTrue(viewModel.missingRequiredPluginPackIDs(for: ont).isEmpty)
    }

    func testViewModelInstallsFullLengthMHCPluginPackBeforeEnablingWorkflow() async throws {
        let defaults = try makeDefaults()
        let store = WorkflowLibraryEnablementStore(userDefaults: defaults)
        let workflow = try XCTUnwrap(
            WorkflowLibraryCatalog.item(id: WorkflowLibraryCatalog.fullLengthONTMHCGenotypingID)
        )
        store.setWorkflow(workflow, enabled: false)
        let statusProvider = InstallingWorkflowLibraryPluginStatusProvider(states: [
            "lungfish-tools": .ready,
            "read-mapping": .ready,
            "full-length-mhc-genotyping": .needsInstall,
        ])
        let packageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        let viewModel = WorkflowLibraryViewModel(
            store: store,
            packageStore: packageStore,
            statusProvider: statusProvider
        )

        await viewModel.refreshDependencyStatuses()
        XCTAssertEqual(viewModel.missingRequiredPluginPackIDs(for: workflow), ["full-length-mhc-genotyping"])

        await viewModel.installDependenciesAndEnable(workflow)

        XCTAssertEqual(statusProvider.installedPackIDs, ["full-length-mhc-genotyping"])
        XCTAssertTrue(store.isWorkflowEnabled(workflow))
        XCTAssertTrue(viewModel.missingRequiredPluginPackIDs(for: workflow).isEmpty)
    }

    func testViewModelImportsValidatedUserWorkflowPackages() async throws {
        let defaults = try makeDefaults()
        let store = WorkflowLibraryEnablementStore(userDefaults: defaults)
        let packageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        let viewModel = WorkflowLibraryViewModel(
            store: store,
            packageStore: packageStore,
            statusProvider: StubWorkflowLibraryPluginStatusProvider(states: [:])
        )
        let packageURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Examples/WorkflowPackages/hello-world-nextflow.lungfishflowpkg", isDirectory: true)

        try await viewModel.importWorkflowPackage(at: packageURL)

        XCTAssertEqual(viewModel.userWorkflowPackages.map(\.manifest.id), ["org.lungfish.templates.hello-world-nextflow"])
        XCTAssertEqual(viewModel.userWorkflowSections.map(\.title), ["User Workflows"])
        XCTAssertEqual(viewModel.userWorkflowSections.first?.groups.first?.title, "Examples")
    }

    func testCachedPackageStopsBeingRunnableWhenEntrypointDisappears() throws {
        let defaults = try makeDefaults()
        let package = try makeUserWorkflowPackageOnDisk(id: "missing-entrypoint", runnerKind: .nextflow)
        defer { try? FileManager.default.removeItem(at: package.packageURL.deletingLastPathComponent()) }
        let store = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        store.addValidatedPackage(package)
        XCTAssertEqual(store.cachedValidatedPackages().map(\.manifest.id), [package.manifest.id])
        try FileManager.default.removeItem(at: package.packageURL.appendingPathComponent(package.manifest.runner.entrypoint))
        XCTAssertTrue(store.cachedValidatedPackages().isEmpty)
        XCTAssertTrue(store.validatedPackages().isEmpty)
        XCTAssertEqual(store.registrationSnapshot.first?.status, .invalid)
    }

    func testViewModelLoadsColdImportedWorkflowPackagesAsynchronously() async throws {
        let defaults = try makeDefaults()
        let store = WorkflowLibraryEnablementStore(userDefaults: defaults)
        let packageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        packageStore.addPackage(at: helloWorldNextflowPackageURL())
        let viewModel = WorkflowLibraryViewModel(
            store: store,
            packageStore: packageStore,
            statusProvider: StubWorkflowLibraryPluginStatusProvider(states: [:]),
            automaticallyRefreshUserWorkflowPackages: false
        )

        XCTAssertTrue(viewModel.userWorkflowPackages.isEmpty)

        await viewModel.refreshUserWorkflowPackages()

        XCTAssertEqual(
            viewModel.userWorkflowPackages.map(\.manifest.id),
            ["org.lungfish.templates.hello-world-nextflow"]
        )
    }

    func testWorkflowLibraryWindowUsesSinglePaneWithoutPlaceholderToolbar() throws {
        let _ = NSApplication.shared
        closeWorkflowLibraryWindows()
        addTeardownBlock { @MainActor in
            self.closeWorkflowLibraryWindows()
        }

        WorkflowLibraryWindowController.show()

        let window = try XCTUnwrap(workflowLibraryWindow())
        XCTAssertEqual(window.accessibilityIdentifier(), WorkflowLibraryAccessibilityID.window)
        XCTAssertNil(window.toolbar)
        XCTAssertNotNil(window.contentView)
    }

    /// Regression for the 2026.9.53 hang: after the library was scrolled part way
    /// down, flipping the 12S Amplicon Matching switch left SwiftUI re-placing
    /// lazy-stack items on every run-loop pass (100% CPU, main thread in
    /// LazyLayoutViewCache / LazyStack.initialPlacement). The panel must settle.
    func testLibraryPanelSettlesAfterTogglingWorkflowWhileScrolledPartWay() throws {
        let _ = NSApplication.shared
        let defaults = try makeDefaults()
        let store = WorkflowLibraryEnablementStore(userDefaults: defaults)
        let packIDs = Set(WorkflowLibraryCatalog.builtIn.flatMap(\.requiredPluginPackIDs))
        let provider = StubWorkflowLibraryPluginStatusProvider(
            states: Dictionary(uniqueKeysWithValues: packIDs.map { ($0, PluginPackState.ready) })
        )
        let viewModel = WorkflowLibraryViewModel(
            store: store,
            packageStore: WorkflowLibraryImportedPackageStore(userDefaults: defaults),
            statusProvider: provider,
            automaticallyRefreshUserWorkflowPackages: false
        )
        let twelveS = WorkflowLibraryCatalog.twelveSAmpliconMatchingItem
        XCTAssertFalse(viewModel.isEnabled(twelveS))

        let host = LayoutCountingHostingView(rootView: WorkflowLibraryPanelView(viewModel: viewModel))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        addTeardownBlock { @MainActor in window.close() }
        spinMainRunLoop(seconds: 0.5)

        // Scroll to the middle, as the AX scrollbar value 0.5 did.
        let scrollView = try XCTUnwrap(firstScrollView(in: host))
        let documentHeight = scrollView.documentView?.frame.height ?? 0
        let clipHeight = scrollView.contentView.bounds.height
        XCTAssertGreaterThan(documentHeight, clipHeight * 2, "the catalog should need scrolling")
        if let scroller = scrollView.verticalScroller, scroller.isAccessibilityElement() {
            scroller.setAccessibilityValue(NSNumber(value: 0.5))
        } else {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: (documentHeight - clipHeight) * 0.5))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        spinMainRunLoop(seconds: 0.5)

        // Resize, as the user did before clicking.
        window.setContentSize(NSSize(width: 820, height: 600))
        spinMainRunLoop(seconds: 0.5)

        for enabled in [true, false, true] {
            let toggled = expectation(description: "12S enabled=\(enabled)")
            Task { @MainActor in
                await viewModel.setWorkflow(twelveS, enabled: enabled)
                toggled.fulfill()
            }
            wait(for: [toggled], timeout: 10)
            XCTAssertEqual(viewModel.isEnabled(twelveS), enabled)
            spinMainRunLoop(seconds: 0.2)
        }

        spinMainRunLoop(seconds: 0.5)
        host.layoutCount = 0
        let cpuBefore = currentThreadCPUSeconds()
        spinMainRunLoop(seconds: 1.0)
        let idleCPU = currentThreadCPUSeconds() - cpuBefore
        print("WorkflowLibrary settle: layouts=\(host.layoutCount) idleCPU=\(idleCPU)")
        XCTAssertLessThan(host.layoutCount, 5, "the library kept re-laying out after it should have settled")
        XCTAssertLessThan(idleCPU, 0.25, "the main thread kept working after the library should have settled")
    }

    func testViewModelSummarizesUserWorkflowPackageExecutionAndDependencies() async throws {
        let defaults = try makeDefaults()
        let package = makeUserWorkflowPackage(
            id: "org.example.command-workflow",
            runnerKind: .command,
            entrypoint: "run.sh",
            requiredPluginPackIDs: ["lungfish-tools"]
        )
        let viewModel = WorkflowLibraryViewModel(
            store: WorkflowLibraryEnablementStore(userDefaults: defaults),
            packageStore: WorkflowLibraryImportedPackageStore(userDefaults: defaults),
            statusProvider: StubWorkflowLibraryPluginStatusProvider(states: [
                "lungfish-tools": .needsInstall,
            ])
        )
        viewModel.userWorkflowPackages = [package]

        await viewModel.refreshDependencyStatuses()

        XCTAssertEqual(package.workflowLibraryExecutionUnavailableReason, "Command-runner packages can be imported and reviewed, but beta builds do not execute them.")
        XCTAssertEqual(viewModel.dependencyStatusRows(for: package), [
            WorkflowLibraryPackageStatusRow(
                id: "dependency.lungfish-tools",
                label: "Dependency",
                value: "\(viewModel.pluginPackName(for: "lungfish-tools")) - Needs install",
                isReady: false
            ),
        ])
    }

    func testImportCancelsStartupPackageRefreshAndClearsLoadingState() async throws {
        let defaults = try makeDefaults()
        let store = WorkflowLibraryEnablementStore(userDefaults: defaults)
        let packageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        packageStore.addPackage(at: helloWorldNextflowPackageURL())
        let viewModel = WorkflowLibraryViewModel(
            store: store,
            packageStore: packageStore,
            statusProvider: StubWorkflowLibraryPluginStatusProvider(states: [:])
        )

        try await viewModel.importWorkflowPackage(at: helloWorldNextflowPackageURL())

        XCTAssertFalse(viewModel.isLoadingUserWorkflowPackages)
        XCTAssertEqual(
            viewModel.userWorkflowPackages.map(\.manifest.id),
            ["org.lungfish.templates.hello-world-nextflow"]
        )
    }

    func testWorkflowPackageValidationCacheInvalidatesManifestContentChanges() throws {
        let defaults = try makeDefaults()
        let packageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        let temp = try temporaryDirectory()
        let packageURL = temp.appendingPathComponent("cached.lungfishflowpkg", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.copyItem(at: helloWorldNextflowPackageURL(), to: packageURL)
        packageStore.addPackage(at: packageURL)

        XCTAssertEqual(
            packageStore.validatedPackages().map(\.manifest.id),
            ["org.lungfish.templates.hello-world-nextflow"]
        )

        let manifestURL = packageURL.appendingPathComponent(WorkflowPackageValidator.manifestFilename)
        let originalManifest = try String(contentsOf: manifestURL, encoding: .utf8)
        let updatedManifest = originalManifest.replacingOccurrences(
            of: "Hello World Nextflow",
            with: "Hello World Nextflaw"
        )
        XCTAssertEqual(originalManifest.utf8.count, updatedManifest.utf8.count)
        try updatedManifest.write(to: manifestURL, atomically: true, encoding: .utf8)

        XCTAssertEqual(
            packageStore.validatedPackages().map(\.manifest.name),
            ["Hello World Nextflaw"]
        )
    }

    func testImportedWorkflowPackagesPersistAcrossViewModels() async throws {
        let defaults = try makeDefaults()
        let store = WorkflowLibraryEnablementStore(userDefaults: defaults)
        let packageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        let firstViewModel = WorkflowLibraryViewModel(
            store: store,
            packageStore: packageStore,
            statusProvider: StubWorkflowLibraryPluginStatusProvider(states: [:])
        )

        try await firstViewModel.importWorkflowPackage(at: helloWorldNextflowPackageURL())

        let reloadedPackageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        let reloadedViewModel = WorkflowLibraryViewModel(
            store: WorkflowLibraryEnablementStore(userDefaults: defaults),
            packageStore: reloadedPackageStore,
            statusProvider: StubWorkflowLibraryPluginStatusProvider(states: [:])
        )
        await reloadedViewModel.refreshUserWorkflowPackages()

        XCTAssertEqual(
            reloadedViewModel.userWorkflowPackages.map(\.manifest.id),
            ["org.lungfish.templates.hello-world-nextflow"]
        )
    }

    func testViewModelEnablesImportedUserWorkflowPackageWhenDependenciesAreReady() async throws {
        let defaults = try makeDefaults()
        let store = WorkflowLibraryEnablementStore(userDefaults: defaults)
        let packageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        let viewModel = WorkflowLibraryViewModel(
            store: store,
            packageStore: packageStore,
            statusProvider: StubWorkflowLibraryPluginStatusProvider(states: [
                "lungfish-tools": .ready,
            ])
        )

        try await viewModel.importWorkflowPackage(at: helloWorldNextflowPackageURL())
        let package = try XCTUnwrap(viewModel.userWorkflowPackages.first)

        XCTAssertFalse(viewModel.enabledUserWorkflowIDs.contains(package.manifest.id))
        XCTAssertFalse(viewModel.isEnabled(package))

        await viewModel.setWorkflow(package, enabled: true)

        XCTAssertTrue(viewModel.enabledUserWorkflowIDs.contains(package.manifest.id))
        XCTAssertTrue(viewModel.isEnabled(package))

        let reloadedStore = WorkflowLibraryEnablementStore(userDefaults: defaults)
        XCTAssertTrue(reloadedStore.isUserWorkflowEnabled(package.manifest.id))
    }

    func testCommandRunnerUserWorkflowPackagesRemainCatalogOnly() async throws {
        let defaults = try makeDefaults()
        let store = WorkflowLibraryEnablementStore(userDefaults: defaults)
        let packageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        let statusProvider = InstallingWorkflowLibraryPluginStatusProvider(states: [
            "lungfish-tools": .needsInstall,
        ])
        let package = try makeUserWorkflowPackageOnDisk(
            id: "org.example.command-workflow",
            runnerKind: .command,
            entrypoint: "run.sh",
            requiredPluginPackIDs: ["lungfish-tools"]
        )

        defer { try? FileManager.default.removeItem(at: package.packageURL.deletingLastPathComponent()) }
        packageStore.addValidatedPackage(package)
        let viewModel = WorkflowLibraryViewModel(
            store: store,
            packageStore: packageStore,
            statusProvider: statusProvider,
            automaticallyRefreshUserWorkflowPackages: false
        )
        XCTAssertFalse(package.supportsWorkflowLibraryExecution)
        let enablementResult = await store.enableUserWorkflow(package, using: statusProvider)
        XCTAssertEqual(enablementResult, .unsupportedRunner(kind: .command))
        XCTAssertFalse(store.isUserWorkflowEnabled(package))

        store.setUserWorkflow(package, enabled: true)
        XCTAssertFalse(
            store.isUserWorkflowEnabled(package),
            "Package-aware enablement must not mark command-runner packages runnable"
        )

        await viewModel.setWorkflow(package, enabled: true)

        XCTAssertFalse(viewModel.isEnabled(package))
        XCTAssertTrue(viewModel.showingError)
        XCTAssertTrue(viewModel.errorMessage?.contains("catalog-only") == true)

        viewModel.showingError = false
        viewModel.errorMessage = nil
        await viewModel.installDependenciesAndEnable(package)

        XCTAssertEqual(statusProvider.installedPackIDs, [])
        XCTAssertFalse(viewModel.isEnabled(package))
        XCTAssertTrue(viewModel.showingError)
        XCTAssertTrue(viewModel.errorMessage?.contains("beta builds do not execute") == true)
    }

    func testViewModelInstallsMissingDependenciesBeforeEnablingUserWorkflowPackage() async throws {
        let defaults = try makeDefaults()
        let store = WorkflowLibraryEnablementStore(userDefaults: defaults)
        let packageStore = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        let statusProvider = InstallingWorkflowLibraryPluginStatusProvider(states: [
            "lungfish-tools": .needsInstall,
        ])
        let viewModel = WorkflowLibraryViewModel(
            store: store,
            packageStore: packageStore,
            statusProvider: statusProvider
        )

        try await viewModel.importWorkflowPackage(at: helloWorldNextflowPackageURL())
        let package = try XCTUnwrap(viewModel.userWorkflowPackages.first)

        XCTAssertEqual(viewModel.missingRequiredPluginPackIDs(for: package), ["lungfish-tools"])

        await viewModel.installDependenciesAndEnable(package)

        XCTAssertEqual(statusProvider.installedPackIDs, ["lungfish-tools"])
        XCTAssertTrue(viewModel.isEnabled(package))
        XCTAssertTrue(viewModel.missingRequiredPluginPackIDs(for: package).isEmpty)
    }

    func testReplacingManifestIdentityPersistsOnlyLatestLinkedSource() throws {
        let defaults = try makeDefaults()
        let first = try makeUserWorkflowPackageOnDisk(id: "replacement", runnerKind: .nextflow)
        let second = try makeUserWorkflowPackageOnDisk(id: "replacement", runnerKind: .nextflow)
        defer {
            try? FileManager.default.removeItem(at: first.packageURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: second.packageURL.deletingLastPathComponent())
        }
        let store = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        store.addValidatedPackage(first)
        store.addValidatedPackage(second)
        let reloaded = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        XCTAssertEqual(reloaded.packageURLSnapshot, [second.packageURL])
        XCTAssertEqual(reloaded.validatedPackages().map(\.manifest.id), ["replacement"])
    }

    func testMissingOrMalformedRegistrationRemainsRemovableAfterReload() throws {
        for removeManifest in [true, false] {
            let defaults = try makeDefaults()
            let package = try makeUserWorkflowPackageOnDisk(id: "unavailable", runnerKind: .nextflow)
            defer { try? FileManager.default.removeItem(at: package.packageURL.deletingLastPathComponent()) }
            WorkflowLibraryImportedPackageStore(userDefaults: defaults).addValidatedPackage(package)
            if removeManifest {
                try FileManager.default.removeItem(at: package.manifestURL)
            } else {
                try Data("invalid json".utf8).write(to: package.manifestURL)
            }
            let reloaded = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
            XCTAssertEqual(reloaded.packageURLSnapshot, [package.packageURL])
            reloaded.removePackage(withManifestID: package.manifest.id)
            XCTAssertTrue(reloaded.packageURLSnapshot.isEmpty)
            XCTAssertTrue(WorkflowLibraryImportedPackageStore(userDefaults: defaults).packageURLSnapshot.isEmpty)
        }
    }

    func testUnavailableRegistrationRetainsMetadataIdentityAndCanBeRelocated() throws {
        let defaults = try makeDefaults()
        let package = try makeUserWorkflowPackageOnDisk(id: "relocated", runnerKind: .nextflow)
        let relocated = try makeUserWorkflowPackageOnDisk(id: "relocated", runnerKind: .nextflow)
        defer {
            try? FileManager.default.removeItem(at: package.packageURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: relocated.packageURL.deletingLastPathComponent())
        }
        let store = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        store.addValidatedPackage(package)
        let id = try XCTUnwrap(store.registrationSnapshot.first?.id)
        try FileManager.default.removeItem(at: package.packageURL)
        let reloaded = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        XCTAssertTrue(reloaded.validatedPackages().isEmpty)
        let unavailable = try XCTUnwrap(reloaded.registrationSnapshot.first)
        XCTAssertEqual(unavailable.id, id)
        XCTAssertEqual(unavailable.status, .missing)
        XCTAssertEqual(unavailable.lastKnownManifest?.version, "1.0.0")
        XCTAssertNotNil(unavailable.diagnostic)
        try reloaded.relocateRegistration(id: id, to: relocated)
        XCTAssertEqual(reloaded.registrationSnapshot.first?.id, id)
        XCTAssertEqual(reloaded.validatedPackages().map(\.packageURL), [relocated.packageURL])
    }

    func testLegacyDisconnectedPathHasStableRemovableRegistrationID() throws {
        let defaults = try makeDefaults()
        let missing = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).lungfishflowpkg")
        defaults.set([missing.path], forKey: "WorkflowLibrary.importedWorkflowPackagePaths")
        let store = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        let id = try XCTUnwrap(store.registrationSnapshot.first?.id)
        let reloaded = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        XCTAssertEqual(reloaded.registrationSnapshot.first?.id, id)
        reloaded.removeRegistration(id: id)
        XCTAssertTrue(WorkflowLibraryImportedPackageStore(userDefaults: defaults).registrationSnapshot.isEmpty)
    }

    func testRelinkingChangedIdentityReconcilesVisiblePackagesWithStore() async throws {
        let defaults = try makeDefaults()
        let package = try makeUserWorkflowPackageOnDisk(id: "before", runnerKind: .nextflow)
        defer { try? FileManager.default.removeItem(at: package.packageURL.deletingLastPathComponent()) }
        let store = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        let model = WorkflowLibraryViewModel(packageStore: store,
            statusProvider: StubWorkflowLibraryPluginStatusProvider(states: [:]), automaticallyRefreshUserWorkflowPackages: false)
        try await model.importWorkflowPackage(at: package.packageURL)
        let text = try String(contentsOf: package.manifestURL, encoding: .utf8)
        try text.replacingOccurrences(of: "before", with: "after").write(to: package.manifestURL, atomically: true, encoding: .utf8)
        try await model.importWorkflowPackage(at: package.packageURL)
        XCTAssertEqual(model.userWorkflowPackages.map(\.manifest.id), ["after"])
        XCTAssertEqual(store.registrationSnapshot.compactMap { $0.lastKnownManifest?.id }, ["after"])
    }

    func testLateLinkValidationCannotReplaceNewerLinkedSource() async throws {
        let defaults = try makeDefaults()
        let first = try makeUserWorkflowPackageOnDisk(id: "ordered", runnerKind: .nextflow)
        let second = try makeUserWorkflowPackageOnDisk(id: "ordered", runnerKind: .nextflow)
        defer {
            try? FileManager.default.removeItem(at: first.packageURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: second.packageURL.deletingLastPathComponent())
        }
        let barrier = WorkflowLibraryTestBarrier()
        let store = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        let model = WorkflowLibraryViewModel(packageStore: store,
            statusProvider: StubWorkflowLibraryPluginStatusProvider(states: [:]), automaticallyRefreshUserWorkflowPackages: false,
            packageValidator: { url in
                if url == first.packageURL { await barrier.pause(); return first }
                return second
            })
        let firstTask = Task { try await model.importWorkflowPackage(at: first.packageURL) }
        await barrier.waitUntilEntered()
        try await model.importWorkflowPackage(at: second.packageURL)
        await barrier.release()
        try await firstTask.value
        XCTAssertEqual(store.packageURLSnapshot, [second.packageURL])
        XCTAssertEqual(model.userWorkflowPackages.map(\.packageURL), [second.packageURL])
    }

    func testNewerLinkWinsWhenOlderValidationCompletesFirst() async throws {
        let defaults = try makeDefaults()
        let first = try makeUserWorkflowPackageOnDisk(id: "ordered", runnerKind: .nextflow)
        let second = try makeUserWorkflowPackageOnDisk(id: "ordered", runnerKind: .nextflow)
        defer {
            try? FileManager.default.removeItem(at: first.packageURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: second.packageURL.deletingLastPathComponent())
        }
        let barrier = WorkflowLibraryTestBarrier()
        let secondBarrier = WorkflowLibraryTestBarrier()
        let store = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        let model = WorkflowLibraryViewModel(packageStore: store,
            statusProvider: StubWorkflowLibraryPluginStatusProvider(states: [:]), automaticallyRefreshUserWorkflowPackages: false,
            packageValidator: { url in
                if url == first.packageURL { await barrier.pause(); return first }
                await secondBarrier.pause()
                return second
            })
        let firstTask = Task { try await model.importWorkflowPackage(at: first.packageURL) }
        await barrier.waitUntilEntered()
        let secondTask = Task { try await model.importWorkflowPackage(at: second.packageURL) }
        await secondBarrier.waitUntilEntered()
        await barrier.release()
        try await firstTask.value
        await secondBarrier.release()
        try await secondTask.value
        XCTAssertEqual(store.packageURLSnapshot, [second.packageURL])
        XCTAssertEqual(model.userWorkflowPackages.map(\.packageURL), [second.packageURL])
    }

    func testConcurrentLinksForIndependentIdentitiesAreBothRetained() async throws {
        let defaults = try makeDefaults()
        let first = try makeUserWorkflowPackageOnDisk(id: "first-independent", runnerKind: .nextflow)
        let second = try makeUserWorkflowPackageOnDisk(id: "second-independent", runnerKind: .nextflow)
        defer {
            try? FileManager.default.removeItem(at: first.packageURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: second.packageURL.deletingLastPathComponent())
        }
        let barrier = WorkflowLibraryTestBarrier()
        let store = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        let model = WorkflowLibraryViewModel(packageStore: store,
            statusProvider: StubWorkflowLibraryPluginStatusProvider(states: [:]), automaticallyRefreshUserWorkflowPackages: false,
            packageValidator: { url in
                if url == first.packageURL { await barrier.pause(); return first }
                return second
            })
        let firstTask = Task { try await model.importWorkflowPackage(at: first.packageURL) }
        await barrier.waitUntilEntered()
        try await model.importWorkflowPackage(at: second.packageURL)
        await barrier.release()
        try await firstTask.value
        XCTAssertEqual(Set(store.packageURLSnapshot), Set([first.packageURL, second.packageURL]))
        XCTAssertEqual(Set(model.userWorkflowPackages.map(\.packageURL)), Set([first.packageURL, second.packageURL]))
    }

    func testPendingEnableCannotResurrectRemovedRegistration() async throws {
        let defaults = try makeDefaults()
        let package = try makeUserWorkflowPackageOnDisk(id: "removed", runnerKind: .nextflow,
            requiredPluginPackIDs: ["read-mapping"])
        defer { try? FileManager.default.removeItem(at: package.packageURL.deletingLastPathComponent()) }
        let store = WorkflowLibraryImportedPackageStore(userDefaults: defaults)
        store.addValidatedPackage(package)
        let enablement = WorkflowLibraryEnablementStore(userDefaults: defaults)
        let barrier = WorkflowLibraryTestBarrier()
        let provider = StubWorkflowLibraryPluginStatusProvider(states: ["read-mapping": .ready])
        provider.statusBarrier = { await barrier.pause() }
        let model = WorkflowLibraryViewModel(store: enablement, packageStore: store,
            statusProvider: provider, automaticallyRefreshUserWorkflowPackages: false)
        let task = Task { await model.setWorkflow(package, enabled: true) }
        await barrier.waitUntilEntered()
        model.removeRegistration(try XCTUnwrap(store.registrationSnapshot.first))
        await barrier.release()
        await task.value
        XCTAssertFalse(enablement.enabledUserWorkflowIDSnapshot.contains(package.manifest.id))
        XCTAssertTrue(store.registrationSnapshot.isEmpty)
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "WorkflowLibraryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func helloWorldNextflowPackageURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Examples/WorkflowPackages/hello-world-nextflow.lungfishflowpkg", isDirectory: true)
    }

    private func makeUserWorkflowPackage(
        id: String,
        runnerKind: WorkflowPackageRunnerKind,
        entrypoint: String,
        inputs: [WorkflowPackageInput]? = nil,
        outputs: [WorkflowPackageOutput]? = nil,
        requiredPluginPackIDs: [String] = []
    ) -> WorkflowPackageValidationResult {
        let packageURL = URL(fileURLWithPath: "/tmp/\(id).lungfishflowpkg", isDirectory: true)
        let manifest = WorkflowPackageManifest(
            id: id,
            name: "User Workflow",
            version: "1.0.0",
            category: "Examples",
            runner: WorkflowPackageRunner(kind: runnerKind, entrypoint: entrypoint),
            inputs: inputs ?? [
                WorkflowPackageInput(id: "reference", name: "Reference", bundleTypes: [.lungfishref]),
                WorkflowPackageInput(id: "reads", name: "Reads", bundleTypes: [.lungfishfastq]),
            ],
            outputs: outputs ?? [
                WorkflowPackageOutput(
                    id: "output",
                    name: "Output",
                    bundleType: .lungfishref,
                    pathTemplate: "out.lungfishref"
                ),
            ],
            requiredPluginPackIDs: requiredPluginPackIDs
        )
        return WorkflowPackageValidationResult(
            packageURL: packageURL,
            manifestURL: packageURL.appendingPathComponent("manifest.json"),
            manifest: manifest,
            warnings: []
        )
    }

    private func makeUserWorkflowPackageOnDisk(
        id: String,
        runnerKind: WorkflowPackageRunnerKind,
        entrypoint: String = "main.nf",
        inputs: [WorkflowPackageInput]? = nil,
        outputs: [WorkflowPackageOutput]? = nil,
        requiredPluginPackIDs: [String] = []
    ) throws -> WorkflowPackageValidationResult {
        let packageURL = try temporaryDirectory()
            .appendingPathComponent("\(id).lungfishflowpkg", isDirectory: true)
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        try "exit 0\n".write(
            to: packageURL.appendingPathComponent(entrypoint),
            atomically: true,
            encoding: .utf8
        )

        let manifest = makeUserWorkflowPackage(
            id: id,
            runnerKind: runnerKind,
            entrypoint: entrypoint,
            inputs: inputs,
            outputs: outputs,
            requiredPluginPackIDs: requiredPluginPackIDs
        ).manifest
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(
            to: packageURL.appendingPathComponent(WorkflowPackageValidator.manifestFilename),
            options: .atomic
        )
        return try WorkflowPackageValidator.validatePackage(at: packageURL)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkflowLibraryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func spinMainRunLoop(seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func currentThreadCPUSeconds() -> Double {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let thread = mach_thread_self()
        defer { mach_port_deallocate(mach_task_self_, thread) }
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1_000_000
            + Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1_000_000
    }

    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        for subview in view.subviews {
            if let found = firstScrollView(in: subview) { return found }
        }
        return nil
    }

    private func workflowLibraryWindow() -> NSWindow? {
        NSApp.windows.first { $0.accessibilityIdentifier() == WorkflowLibraryAccessibilityID.window }
    }

    private func closeWorkflowLibraryWindows() {
        for window in NSApp.windows where window.accessibilityIdentifier() == WorkflowLibraryAccessibilityID.window {
            window.close()
        }
    }
}

private final class LayoutCountingHostingView: NSHostingView<WorkflowLibraryPanelView> {
    var layoutCount = 0

    override func layout() {
        layoutCount += 1
        super.layout()
    }
}

private final class StubWorkflowLibraryPluginStatusProvider: PluginPackStatusProviding, @unchecked Sendable {
    let states: [String: PluginPackState]
    var statusBarrier: (@Sendable () async -> Void)?

    init(states: [String: PluginPackState]) {
        self.states = states
    }

    func visibleStatuses() async -> [PluginPackStatus] {
        await visibleStatuses(includeExperimental: true)
    }

    func visibleStatuses(includeExperimental: Bool) async -> [PluginPackStatus] {
        states.compactMap { packID, state in
            guard let pack = PluginPack.builtInPack(id: packID) else { return nil }
            return PluginPackStatus(pack: pack, state: state, toolStatuses: [], failureMessage: nil)
        }
    }

    func status(for pack: PluginPack) async -> PluginPackStatus {
        PluginPackStatus(pack: pack, state: states[pack.id] ?? .needsInstall, toolStatuses: [], failureMessage: nil)
    }

    func status(forPackID packID: String) async -> PluginPackStatus? {
        await statusBarrier?()
        guard let pack = PluginPack.builtInPack(id: packID) else { return nil }
        return PluginPackStatus(pack: pack, state: states[packID] ?? .needsInstall, toolStatuses: [], failureMessage: nil)
    }

    func invalidateVisibleStatusesCache() async {}

    func install(
        pack: PluginPack,
        reinstall: Bool,
        progress: (@Sendable (PluginPackInstallProgress) -> Void)?
    ) async throws {}
}

@MainActor
private final class InstallingWorkflowLibraryPluginStatusProvider: PluginPackStatusProviding, @unchecked Sendable {
    private(set) var states: [String: PluginPackState]
    private(set) var installedPackIDs: [String] = []

    init(states: [String: PluginPackState]) {
        self.states = states
    }

    func visibleStatuses() async -> [PluginPackStatus] {
        await visibleStatuses(includeExperimental: true)
    }

    func visibleStatuses(includeExperimental: Bool) async -> [PluginPackStatus] {
        states.compactMap { packID, state in
            guard let pack = PluginPack.builtInPack(id: packID) else { return nil }
            return PluginPackStatus(pack: pack, state: state, toolStatuses: [], failureMessage: nil)
        }
    }

    func status(for pack: PluginPack) async -> PluginPackStatus {
        PluginPackStatus(pack: pack, state: states[pack.id] ?? .needsInstall, toolStatuses: [], failureMessage: nil)
    }

    func status(forPackID packID: String) async -> PluginPackStatus? {
        guard let pack = PluginPack.builtInPack(id: packID) else { return nil }
        return PluginPackStatus(pack: pack, state: states[packID] ?? .needsInstall, toolStatuses: [], failureMessage: nil)
    }

    func invalidateVisibleStatusesCache() async {}

    func install(
        pack: PluginPack,
        reinstall: Bool,
        progress: (@Sendable (PluginPackInstallProgress) -> Void)?
    ) async throws {
        installedPackIDs.append(pack.id)
        states[pack.id] = .ready
    }
}

private actor WorkflowLibraryTestBarrier {
    private var entered = false
    private var released = false
    private var blocked: [CheckedContinuation<Void, Never>] = []
    private var observers: [CheckedContinuation<Void, Never>] = []
    func pause() async {
        guard !released else { return }
        entered = true
        observers.forEach { $0.resume() }
        observers.removeAll()
        await withCheckedContinuation { blocked.append($0) }
    }
    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func release() {
        released = true
        blocked.forEach { $0.resume() }
        blocked.removeAll()
    }
}
