// AppKitConcurrencyModalSafetyTests.swift - source regressions for modal/concurrency safety
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest

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

    func testTargetedAppKitCallbacksAvoidUnsafeMainActorTaskHops() throws {
        let root = repositoryRoot()
        let scannedPaths = [
            "Sources/LungfishApp/App/AppDelegate.swift",
            "Sources/LungfishApp/Services/ViralReconWorkflowExecutionService.swift",
            "Sources/LungfishApp/Views/Assembly/AssemblyConfigurationViewModel.swift",
            "Sources/LungfishApp/Views/Inspector/InspectorViewController.swift",
            "Sources/LungfishApp/Views/Settings/AIServicesSettingsTab.swift",
            "Sources/LungfishApp/Views/Settings/StorageSettingsTab.swift",
            "Sources/LungfishApp/Views/WorkflowBuilder/WorkflowBuilderViewController.swift",
            "Sources/LungfishApp/Views/DatabaseBrowser/DatabaseBrowserViewController.swift",
            "Sources/LungfishApp/Views/Viewer/ViewerViewController.swift",
            "Sources/LungfishApp/Views/Metagenomics/NaoMgsResultViewController.swift",
            "Sources/LungfishApp/Views/Metagenomics/MiniBAMViewController.swift",
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
            let source = try String(contentsOf: url, encoding: .utf8)
            if source.contains("Task { @MainActor") {
                violations.append("\(path): contains Task { @MainActor")
            }
            if mainActorRunForbiddenPaths.contains(path), source.contains("await MainActor.run") {
                violations.append("\(path): contains await MainActor.run")
            }
            let lines = source.components(separatedBy: .newlines)
            for index in lines.indices where lines[index].contains("Task.detached") {
                let upperBound = min(lines.endIndex, index + 80)
                let context = lines[index..<upperBound].joined(separator: "\n")
                if context.contains("await MainActor.run") {
                    violations.append("\(path):\(index + 1) Task.detached block contains await MainActor.run")
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

    func testProductionSheetsAvoidMainActorTaskAwaitPattern() throws {
        let root = repositoryRoot()
        let appRoot = root.appendingPathComponent("Sources/LungfishApp", isDirectory: true)
        let swiftFiles = try swiftSourceFiles(under: appRoot)
        var violations: [String] = []

        for file in swiftFiles {
            let source = try String(contentsOf: file, encoding: .utf8)
            let lines = source.components(separatedBy: .newlines)
            for index in lines.indices {
                let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
                guard trimmed.contains("Task { @MainActor"), !trimmed.hasPrefix("//") else {
                    continue
                }

                let upperBound = min(lines.endIndex, index + 20)
                let context = lines[index..<upperBound].joined(separator: "\n")
                if context.contains("await"), context.contains("beginSheetModal") {
                    violations.append(relativePath(file, root: root) + ":\(index + 1)")
                }
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            "Sheet callbacks must use completion-handler sheets instead of Task { @MainActor ... await beginSheetModal }:\n"
                + violations.joined(separator: "\n")
        )
    }

    func testAppDelegateVolatileImportProgressDoesNotUseUpdateWithLog() throws {
        let root = repositoryRoot()
        let path = "Sources/LungfishApp/App/AppDelegate.swift"
        let url = root.appendingPathComponent(path)
        let source = try String(contentsOf: url, encoding: .utf8)
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

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
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
}
