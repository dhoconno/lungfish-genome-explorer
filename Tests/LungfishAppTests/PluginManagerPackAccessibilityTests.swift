import AppKit
import SwiftUI
import XCTest
import LungfishTestSupport
@testable import LungfishApp
@testable import LungfishWorkflow

/// Every pack card of the Plugin Manager is in the accessibility tree and its
/// install button is pressable, however many packs are listed.
@MainActor
final class PluginManagerPackAccessibilityTests: XCTestCase {
    private func makeStatus(index: Int) -> PluginPackStatus {
        let id = String(format: "pack-%02d", index)
        let requirement = PackToolRequirement(
            id: "\(id)-tool", displayName: "Tool", environment: "\(id)-env", executables: ["tool"]
        )
        let pack = PluginPack(
            id: id, name: "Pack \(index)", description: "A pack.", sfSymbol: "shippingbox",
            packages: ["tool"], category: "Pack \(index)", requirements: [requirement]
        )
        let toolStatus = PackToolStatus(
            requirement: requirement, environmentExists: false, missingExecutables: ["tool"],
            smokeTestFailure: nil, storageUnavailablePath: nil
        )
        return PluginPackStatus(pack: pack, state: .needsInstall, toolStatuses: [toolStatus], failureMessage: nil)
    }

    func testEveryPackCardIsInTheAccessibilityTree() throws {
        let viewModel = PluginManagerViewModel(automaticallyRefresh: false)
        viewModel.selectedTab = .installed
        viewModel.optionalPackStatuses = (1...16).map(makeStatus(index:))
        let window = AccessibilityTreeProbe.host(PacksTabViewHarness(viewModel: viewModel), size: CGSize(width: 700, height: 500))
        defer { window.orderOut(nil) }
        let lastID = PluginManagerAccessibilityID.packCard("pack-16")
        AccessibilityTreeProbe.waitUntil {
            AccessibilityTreeProbe.element(in: window, identifier: lastID) != nil
        }
        XCTAssertNotNil(
            AccessibilityTreeProbe.element(in: window, identifier: lastID),
            "the last card must be reachable; tree:\n" + AccessibilityTreeProbe.dump(window)
        )
        let opaque = AccessibilityTreeProbe.all(in: window).filter {
            (AccessibilityTreeProbe.role($0) ?? "").contains("OpaqueProvider")
                || (AccessibilityTreeProbe.subrole($0) ?? "").contains("OpaqueProvider")
        }
        XCTAssertTrue(opaque.isEmpty, AccessibilityTreeProbe.dump(window))
        let buttons = AccessibilityTreeProbe.all(in: window).filter {
            AccessibilityTreeProbe.role($0) == NSAccessibility.Role.button.rawValue
        }
        XCTAssertGreaterThanOrEqual(buttons.count, 16, "each card offers an action button")
    }
}
