// DeadWorkflowSurfaceTests.swift - source regressions for pruned workflow surfaces
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest

final class DeadWorkflowSurfaceTests: XCTestCase {
    func testDeprecatedWorkflowUIFilesStayPruned() {
        let root = repositoryRoot()
        let removedPrivateAppUIPaths = [
            "Sources/LungfishApp/Views/Workflow/WorkflowConfigurationPanel.swift",
            "Sources/LungfishApp/Views/Workflow/ParameterFormView.swift",
            "Sources/LungfishApp/Views/Workflow/ParameterControlFactory.swift",
            "Sources/LungfishApp/Views/Workflow/ContainerRuntimeSelector.swift",
            "Sources/LungfishApp/Views/Workflow/WorkflowExecutionView.swift",
            "Sources/LungfishApp/Views/Workflow/WorkflowLogView.swift",
        ]

        let restoredPaths = removedPrivateAppUIPaths.filter { path in
            FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)
        }

        XCTAssertTrue(
            restoredPaths.isEmpty,
            "Deprecated private workflow UI files must remain absent:\n"
                + restoredPaths.joined(separator: "\n")
        )
    }

    func testDeprecatedWorkflowUITestFilesStayPruned() {
        let root = repositoryRoot()
        let removedTestPaths = [
            "Tests/LungfishAppTests/WorkflowConfigurationPanelTests.swift",
        ]

        let restoredPaths = removedTestPaths.filter { path in
            FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)
        }

        XCTAssertTrue(
            restoredPaths.isEmpty,
            "Deprecated workflow UI tests must remain absent:\n"
                + restoredPaths.joined(separator: "\n")
        )
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
