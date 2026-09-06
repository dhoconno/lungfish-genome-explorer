// AppKitConcurrencyModalSafetyTests.swift - source regressions for modal/concurrency safety
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishTestSupport

final class AppKitConcurrencyModalSafetyTests: XCTestCase {
    func testProductionSourcesDoNotCallRunModal() throws {
        let root = repositoryRoot()
        let appSourcesRoot = root.appendingPathComponent("Sources/LungfishApp", isDirectory: true)
        let swiftFiles = try swiftSourceFiles(under: appSourcesRoot)
        var violations: [String] = []

        for file in swiftFiles {
            let source = try String(contentsOf: file, encoding: .utf8)
            let lines = source.components(separatedBy: .newlines)
            let path = relativePath(file, root: root)
            for index in lines.indices where lines[index].contains(".runModal(") {
                violations.append("\(path):\(index + 1)")
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            "Production AppKit code must use nonblocking sheets, panel begin(), presentError, beep, or cancellation instead of runModal:\n"
                + violations.joined(separator: "\n")
        )
    }

    func testProductionKitAndLeafSourcesAvoidExplicitLayerBacking() throws {
        let root = repositoryRoot()
        let scannedSourceRoots = [
            "Sources/LungfishKit",
            "Sources/LungfishAlignmentUI",
            "Sources/LungfishAssemblyUI",
            "Sources/LungfishEsVirituUI",
            "Sources/LungfishGenotypeUI",
            "Sources/LungfishNaoMgsUI",
            "Sources/LungfishNvdUI",
            "Sources/LungfishPhylogeneticsUI",
            "Sources/LungfishTaxTriageUI",
            "Sources/LungfishTwelveSUI",
        ]
        var violations: [String] = []

        for sourceRoot in scannedSourceRoots {
            let swiftFiles = try swiftSourceFiles(
                under: root.appendingPathComponent(sourceRoot, isDirectory: true)
            )
            for file in swiftFiles {
                let source = try String(contentsOf: file, encoding: .utf8)
                let lines = source.components(separatedBy: .newlines)
                let path = relativePath(file, root: root)
                for index in lines.indices {
                    let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
                    guard trimmed.contains("wantsLayer"), !isCommentLine(trimmed) else {
                        continue
                    }
                    violations.append("\(path):\(index + 1)")
                }
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            "Production Kit and leaf UI code must use draw-backed NSView rendering instead of explicit wantsLayer toggles:\n"
                + violations.joined(separator: "\n")
        )
    }

    func testTargetedAppKitCallbacksAvoidUnsafeMainActorTaskHops() throws {
        let root = repositoryRoot()
        let scannedPaths = [
            "Sources/LungfishApp/App/AppDelegate.swift",
            "Sources/LungfishApp/Services/ONTImportOperationCoordinator.swift",
            "Sources/LungfishApp/Services/ViralReconWorkflowExecutionService.swift",
            "Sources/LungfishApp/Views/Assembly/AssemblyConfigurationViewModel.swift",
            "Sources/LungfishApp/Views/Inspector/InspectorViewController.swift",
            "Sources/LungfishApp/Views/Settings/AIServicesSettingsTab.swift",
            "Sources/LungfishApp/Views/Settings/StorageSettingsTab.swift",
            "Sources/LungfishApp/Views/WorkflowBuilder/WorkflowBuilderViewController.swift",
            "Sources/LungfishApp/Views/DatabaseBrowser/DatabaseBrowserViewController.swift",
            "Sources/LungfishApp/Views/Viewer/ViewerViewController.swift",
            "Sources/LungfishKit/MetadataColumnController.swift",
            "Sources/LungfishNaoMgsUI/NaoMgsResultViewController.swift",
            "Sources/LungfishKit/MiniBAMViewController.swift",
            "Sources/LungfishKit/OperationCenter.swift",
        ]
        let mainActorRunForbiddenPaths: Set<String> = [
            "Sources/LungfishApp/Views/Settings/StorageSettingsTab.swift",
        ]
        let operationCenterMainQueueIsolationRequiredPaths: Set<String> = [
            "Sources/LungfishApp/Views/Viewer/ViewerViewController.swift",
        ]
        var violations: [String] = []

        for path in scannedPaths {
            let url = root.appendingPathComponent(path)
            // InspectorViewController.swift was split into focused files; scan the
            // combined source so unsafe hops in an extension are still caught.
            let source: String
            if path == "Sources/LungfishApp/Views/Inspector/InspectorViewController.swift" {
                source = combinedInspectorViewControllerSource()
            } else {
                source = try String(contentsOf: url, encoding: .utf8)
            }
            // Owned project-open/migration tasks are asynchronous transactions,
            // not completion callbacks. Exempt only their declaration token;
            // their entire bodies remain subject to the remaining checks.
            let callbackSource = callbackTaskScanSource(source, path: path)
            if callbackSource.contains("Task { @MainActor") {
                violations.append("\(path): contains Task { @MainActor")
            }
            if mainActorRunForbiddenPaths.contains(path), source.contains("await MainActor.run") {
                violations.append("\(path): contains await MainActor.run")
            }
            let lines = source.components(separatedBy: .newlines)
            for index in lines.indices where lines[index].contains("Task.detached") {
                let upperBound = min(lines.endIndex, index + 80)
                let context = lines[index..<upperBound].joined(separator: "\n")
                // An isolated terminal acknowledgment touches OperationCenter only;
                // it presents no AppKit UI and must follow worker cleanup.
                let uiContext = path == "Sources/LungfishApp/Views/Viewer/ViewerViewController.swift"
                    ? context.replacingOccurrences(
                        of: #"await\s+MainActor\.run\s*\{\s*OperationCenter\.shared\.acknowledgeCancellation\(id:\s*operationID\)\s*\}"#,
                        with: "", options: .regularExpression)
                    : context
                if uiContext.contains("await MainActor.run") {
                    violations.append("\(path):\(index + 1) detached callback contains an unreviewed UI actor hop")
                }
            }
            if operationCenterMainQueueIsolationRequiredPaths.contains(path) {
                for index in lines.indices where lines[index].contains("DispatchQueue.main.async") {
                    let upperBound = min(lines.endIndex, index + 20)
                    let context = lines[index..<upperBound].joined(separator: "\n")
                    if context.contains("OperationCenter.shared"), !context.contains("MainActor.assumeIsolated") {
                        violations.append("\(path):\(index + 1) OperationCenter main-queue block lacks MainActor.assumeIsolated")
                    }
                }
            }
        }

        let cliRunnerFiles = try swiftSourceFiles(
            under: root.appendingPathComponent("Sources/LungfishApp/Services", isDirectory: true)
        )
        .filter { $0.lastPathComponent.hasPrefix("CLI") && $0.lastPathComponent.hasSuffix("Runner.swift") }

        for file in cliRunnerFiles {
            let source = try String(contentsOf: file, encoding: .utf8)
            if source.contains("await MainActor.run") {
                violations.append("\(relativePath(file, root: root)): contains await MainActor.run")
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            "Unsafe AppKit callback actor hops must use DispatchQueue.main/MainActor.assumeIsolated or performOnMainRunLoop:\n"
                + violations.joined(separator: "\n")
        )
    }

    func testCallbackPolicyExemptsOnlyOwnedProjectTaskDeclaration() {
        let owned = "split.projectOpenTask = Task { @MainActor [weak self, weak controller, weak split] in"
        let nestedCallback = "Task { @MainActor in callback() }"
        let path = "Sources/LungfishApp/App/AppDelegate.swift"
        XCTAssertFalse(callbackTaskScanSource(owned, path: path).contains("Task { @MainActor"))
        XCTAssertTrue(callbackTaskScanSource(owned + "\n" + nestedCallback, path: path).contains("Task { @MainActor"))
        XCTAssertTrue(callbackTaskScanSource(owned, path: "Other.swift").contains("Task { @MainActor"))
    }

    private func callbackTaskScanSource(_ source: String, path: String) -> String {
        guard path == "Sources/LungfishApp/App/AppDelegate.swift" else { return source }
        return source.replacingOccurrences(
            of: "split.projectOpenTask = Task { @MainActor [weak self, weak controller, weak split] in",
            with: "split.projectOpenTask = Task { [weak self, weak controller, weak split] in")
    }

    func testMainActorNotificationObserversUseMainQueueDelivery() throws {
        let root = repositoryRoot()
        let expectations = [
            (
                path: "Sources/LungfishApp/Views/Welcome/WelcomeWindowController.swift",
                notification: ".managedResourcesDidChange",
                reason: "WelcomeViewModel is @MainActor; managed resource notifications may be posted off-main."
            ),
            (
                path: "Sources/LungfishApp/App/AppDelegate.swift",
                notification: ".workflowLibraryEnablementChanged",
                reason: "Workflow enablement changes rebuild AppKit menus and may be posted off-main."
            ),
        ]
        var violations: [String] = []

        for expectation in expectations {
            let source = try String(
                contentsOf: root.appendingPathComponent(expectation.path),
                encoding: .utf8
            )
            let context = observerContext(in: source, notificationName: expectation.notification)
            if !context.contains("addObserver(")
                || !context.contains("forName:")
                || !context.contains("queue: .main") {
                violations.append("\(expectation.path): \(expectation.notification) must use a block observer delivered on .main. \(expectation.reason)")
            }
            if context.contains("selector:") {
                violations.append("\(expectation.path): \(expectation.notification) must not use selector observer delivery. \(expectation.reason)")
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            "Main-actor/AppKit notification observers must marshal delivery onto OperationQueue.main:\n"
                + violations.joined(separator: "\n")
        )
    }

    func testProductionSheetsAvoidMainActorTaskAwaitPattern() throws {
        let root = repositoryRoot()
        let appRoot = root.appendingPathComponent("Sources/LungfishApp", isDirectory: true)
        let swiftFiles = try swiftSourceFiles(under: appRoot)
        var violations: [String] = []

        for file in swiftFiles {
            let source = try String(contentsOf: file, encoding: .utf8)
            if containsAwaitedSheetInMainActorTask(source) {
                violations.append(relativePath(file, root: root))
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            "Explicit MainActor Task blocks must use completion-handler sheet presentation rather than await beginSheetModal:\n"
                + violations.joined(separator: "\n")
        )
    }

    func testSheetPolicyDistinguishesAwaitedPresentationFromAdjacentAsyncWork() {
        XCTAssertTrue(containsAwaitedSheetInMainActorTask("Task { @MainActor in let result = await alert.beginSheetModal(for: window) }"))
        XCTAssertTrue(containsAwaitedSheetInMainActorTask("Task { @MainActor [weak self] in if ready { await alert.beginSheetModal(for: window) } }"))
        XCTAssertTrue(containsAwaitedSheetInMainActorTask("Task { @MainActor in let label = \"}\"; await alert.beginSheetModal(for: window) }"))
        XCTAssertFalse(containsAwaitedSheetInMainActorTask("Task { @MainActor in await load(); alert.beginSheetModal(for: window, completionHandler: nil) }"))
        XCTAssertFalse(containsAwaitedSheetInMainActorTask("Task { @MainActor in await load() }\nfunc choose() async { await panel.beginSheetModal(for: window) }"))
        XCTAssertFalse(containsAwaitedSheetInMainActorTask("func choose() async { await alert.beginSheetModal(for: window) }"))
        XCTAssertFalse(containsAwaitedSheetInMainActorTask("Task { await alert.beginSheetModal(for: window) }"))
        XCTAssertFalse(containsAwaitedSheetInMainActorTask("// Task { @MainActor in await alert.beginSheetModal(for: window) }"))
        XCTAssertFalse(containsAwaitedSheetInMainActorTask("Task { @MainActor in /* await alert.beginSheetModal(for: window) } */ await load() }"))
    }

    private func containsAwaitedSheetInMainActorTask(_ source: String) -> Bool {
        // This is a targeted source policy, not a general Swift parser. Mask
        // ordinary literals/comments so their braces cannot end a Task body.
        let ignoredTokens = #"\"(?:\\.|[^\"\\])*\"|//[^\n]*|/\*[\s\S]*?\*/"#
        let code = source.replacingOccurrences(of: ignoredTokens, with: " ", options: .regularExpression)
        let taskPattern = #"\bTask\s*\{\s*@MainActor\b"#
        let awaitedSheetPattern = #"\bawait\s+[A-Za-z_][A-Za-z0-9_.?]*\.beginSheetModal\s*\("#
        var searchStart = code.startIndex
        while searchStart < code.endIndex,
              let task = code.range(of: taskPattern, options: .regularExpression,
                  range: searchStart..<code.endIndex),
              let openingBrace = code[task].firstIndex(of: "{") {
            var depth = 1
            var cursor = code.index(after: openingBrace)
            let bodyStart = cursor
            while cursor < code.endIndex, depth > 0 {
                if code[cursor] == "{" { depth += 1 }
                if code[cursor] == "}" { depth -= 1 }
                if depth == 0 { break }
                cursor = code.index(after: cursor)
            }
            if code.range(of: awaitedSheetPattern, options: .regularExpression,
                range: bodyStart..<cursor) != nil { return true }
            searchStart = task.upperBound
        }
        return false
    }

    func testAppDelegateVolatileImportProgressDoesNotUseUpdateWithLog() throws {
        let root = repositoryRoot()
        let path = "Sources/LungfishApp/App/AppDelegate.swift (+ AppDelegate+*.swift)"
        _ = root.appendingPathComponent("Sources/LungfishApp/App/AppDelegate.swift")
        let source = combinedAppDelegateSource()
        let lines = source.components(separatedBy: .newlines)
        let volatileMarkers = [
            "Self.runVCFImportViaHelper(",
            "Self.runVCFResumeViaHelper(",
            "BAMImportHelperClient.importViaCLI(",
        ]
        var violations: [String] = []

        for marker in volatileMarkers {
            let markerLines = lines.indices.filter { lines[$0].contains(marker) }
            guard !markerLines.isEmpty else {
                XCTFail("Missing volatile import marker \(marker)")
                continue
            }
            for markerLine in markerLines {
                let upperBound = min(lines.endIndex, markerLine + 35)
                let context = lines[markerLine..<upperBound].joined(separator: "\n")
                if context.contains("updateWithLog") {
                    violations.append("\(path):\(markerLine + 1) \(marker)")
                }
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            "Volatile VCF/BAM progress handlers must update visible progress without appending every ETA/progress detail to OperationCenter history:\n"
                + violations.joined(separator: "\n")
        )
    }

    /// Non-volatile, non-ETA-suffixed progress streams (mapped-reads annotation,
    /// filtered-alignment derivation, GATK variant attach, reference import,
    /// metagenomics import) must pair progress updates with `.log()` so the
    /// Operations Panel's expanded history captures intermediate messages
    /// (F26, F27, F28, F29, F31). Unlike the VCF/BAM volatile-import family
    /// guarded by `testAppDelegateVolatileImportProgressDoesNotUseUpdateWithLog`,
    /// these streams do not append a changing ETA suffix on every tick, so
    /// logging every message does not flood the history.
    func testNonVolatileProgressHandlersPairUpdateWithLog() throws {
        let root = repositoryRoot()
        var violations: [String] = []

        func assertLogged(path: String, marker: String, source: String) {
            let lines = source.components(separatedBy: .newlines)
            let markerLines = lines.indices.filter { lines[$0].contains(marker) }
            guard !markerLines.isEmpty else {
                violations.append("\(path): missing marker \(marker)")
                return
            }
            for markerLine in markerLines {
                let lowerBound = max(0, markerLine - 10)
                let upperBound = min(lines.endIndex, markerLine + 20)
                let context = lines[lowerBound..<upperBound].joined(separator: "\n")
                if !context.contains("updateWithLog") {
                    violations.append("\(path):\(markerLine + 1) \(marker) does not pair with updateWithLog")
                }
            }
        }

        let trimDuplicateWorkflowsPath = "Sources/LungfishApp/Views/Inspector/InspectorViewController+TrimDuplicateWorkflows.swift"
        let trimDuplicateWorkflowsSource = try String(
            contentsOf: root.appendingPathComponent(trimDuplicateWorkflowsPath),
            encoding: .utf8
        )
        assertLogged(
            path: trimDuplicateWorkflowsPath,
            marker: "convertMappedReads(",
            source: trimDuplicateWorkflowsSource
        )
        assertLogged(
            path: trimDuplicateWorkflowsPath,
            marker: "deriveFilteredAlignment(",
            source: trimDuplicateWorkflowsSource
        )

        let variantWorkflowPath = "Sources/LungfishApp/Views/Inspector/InspectorViewController+VariantWorkflow.swift"
        let variantWorkflowSource = try String(
            contentsOf: root.appendingPathComponent(variantWorkflowPath),
            encoding: .utf8
        )
        assertLogged(
            path: variantWorkflowPath,
            marker: "Attaching GATK variants to bundle...",
            source: variantWorkflowSource
        )

        let fastqImportPath = "Sources/LungfishApp/Views/MainWindow/MainSplitViewController+FASTQImport.swift"
        let fastqImportSource = try String(
            contentsOf: root.appendingPathComponent(fastqImportPath),
            encoding: .utf8
        )
        assertLogged(
            path: fastqImportPath,
            marker: "importAsReferenceBundleViaAppHelper(",
            source: fastqImportSource
        )

        let importCenterPath = "Sources/LungfishApp/App/AppDelegate+ImportCenter.swift"
        let importCenterSource = try String(
            contentsOf: root.appendingPathComponent(importCenterPath),
            encoding: .utf8
        )
        assertLogged(
            path: importCenterPath,
            marker: "importAsReferenceBundleViaAppHelper(",
            source: importCenterSource
        )
        assertLogged(
            path: importCenterPath,
            marker: "MetagenomicsImportHelperClient.importViaCLI(",
            source: importCenterSource
        )

        XCTAssertTrue(
            violations.isEmpty,
            "Non-volatile progress handlers must pair OperationCenter.update() with .log() (or use updateWithLog):\n"
                + violations.joined(separator: "\n")
        )
    }

    func testMiniBAMAlignmentLoadingDoesNotInheritMainActor() throws {
        let root = repositoryRoot()
        let path = "Sources/LungfishKit/MiniBAMViewController.swift"
        let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)

        XCTAssertTrue(
            source.contains("loadTask = Task.detached"),
            "MiniBAM alignment fetching and SAM parsing must run in a detached task so TaxTriage row selection cannot block AppKit event handling."
        )
        XCTAssertFalse(
            source.contains("loadTask = Task {"),
            "MiniBAM alignment loading must not use actor-inheriting Task { ... } from the @MainActor view controller."
        )
    }

    func testTaxTriageSelectionDoesNotSynchronouslyParseBAMReferences() throws {
        let root = repositoryRoot()
        let path = "Sources/LungfishTaxTriageUI/TaxTriageResultViewController.swift"
        let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        let selectionBlocks = [
            sourceSlice(
                in: source,
                from: "batchFlatTableView.onRowSelected = { [weak self] row in",
                to: "batchFlatTableView.onMultipleRowsSelected = { [weak self] rows in"
            ),
            sourceSlice(
                in: source,
                from: "// Wire batch flat table callbacks (same pattern as configureFromDatabase).",
                to: "batchFlatTableView.onMultipleRowsSelected = { [weak self] rows in",
                occurrence: 2
            ),
            sourceSlice(
                in: source,
                from: "organismTableView.onRowSelected = { [weak self] row in",
                to: "organismTableView.onBlastRequested = { [weak self] row, readCount in"
            ),
        ]
        XCTAssertEqual(selectionBlocks.count, 3)

        for block in selectionBlocks {
            XCTAssertFalse(
                block.contains("parseBamReferenceLengths("),
                "TaxTriage row selection must not synchronously launch samtools reference parsing on the main actor."
            )
            XCTAssertTrue(
                block.contains("displayTaxTriageMiniBAM("),
                "TaxTriage row selection should route MiniBAM display through the async-safe helper."
            )
        }
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func sourceSlice(
        in source: String,
        from startMarker: String,
        to endMarker: String,
        occurrence: Int = 1
    ) -> String {
        var searchStart = source.startIndex
        var startRange: Range<String.Index>?
        for _ in 0..<occurrence {
            guard let range = source.range(of: startMarker, range: searchStart..<source.endIndex) else {
                return ""
            }
            startRange = range
            searchStart = range.upperBound
        }
        guard let startRange,
              let endRange = source.range(of: endMarker, range: startRange.upperBound..<source.endIndex) else {
            return ""
        }
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }

    private func observerContext(in source: String, notificationName: String) -> String {
        let nameMarkers = [
            "name: \(notificationName)",
            "forName: \(notificationName)",
        ]
        guard let nameRange = nameMarkers.lazy.compactMap({
            source.range(of: $0)
        }).first,
            let observerStart = source.range(
                of: "addObserver(",
                options: .backwards,
                range: source.startIndex..<nameRange.lowerBound
            ) else {
            return ""
        }
        let argumentStart = observerStart.upperBound
        var depth = 1
        var cursor = argumentStart
        while cursor < source.endIndex {
            let character = source[cursor]
            if character == "(" {
                depth += 1
            } else if character == ")" {
                depth -= 1
                if depth == 0 {
                    let upper = source.index(after: cursor)
                    return String(source[observerStart.lowerBound..<upper])
                }
            }
            cursor = source.index(after: cursor)
        }
        return String(source[observerStart.lowerBound..<source.endIndex])
    }

    private func swiftSourceFiles(under root: URL) throws -> [URL] {
        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [URL] = []
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            let values = try file.resourceValues(forKeys: resourceKeys)
            if values.isRegularFile == true {
                files.append(file)
            }
        }
        return files
    }

    private func relativePath(_ url: URL, root: URL) -> String {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return url.path.hasPrefix(rootPath) ? String(url.path.dropFirst(rootPath.count)) : url.path
    }

    private func isCommentLine(_ trimmedLine: String) -> Bool {
        trimmedLine.hasPrefix("//")
            || trimmedLine.hasPrefix("/*")
            || trimmedLine.hasPrefix("*")
    }
}
