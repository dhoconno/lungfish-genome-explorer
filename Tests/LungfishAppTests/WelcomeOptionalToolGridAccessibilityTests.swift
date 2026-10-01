import AppKit
import SwiftUI
import XCTest
import LungfishTestSupport
@testable import LungfishApp
@testable import LungfishWorkflow

private actor FixedPackStatusProvider: PluginPackStatusProviding {
    let statuses: [PluginPackStatus]
    init(statuses: [PluginPackStatus]) { self.statuses = statuses }
    func visibleStatuses() async -> [PluginPackStatus] { statuses }
    func status(for pack: PluginPack) async -> PluginPackStatus { statuses.first { $0.pack.id == pack.id }! }
    func invalidateVisibleStatusesCache() async {}
    func install(pack: PluginPack, reinstall: Bool, progress: (@Sendable (PluginPackInstallProgress) -> Void)?) async throws {}
}

/// The Welcome window's Optional Tools page is reachable by AX clients, and
/// every tool tile has a pressable Open button however many tools there are.
@MainActor
final class WelcomeOptionalToolGridAccessibilityTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        super.tearDown()
    }

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

    func testEveryOptionalToolTileHasAPressableOpenButton() async throws {
        let required = PluginPackStatus(pack: .requiredSetupPack, state: .ready, toolStatuses: [], failureMessage: nil)
        let viewModel = WelcomeViewModel(
            statusProvider: FixedPackStatusProvider(statuses: [required] + (1...14).map(makeStatus(index:))),
            debugLaunchConfiguration: AppDebugLaunchConfiguration(environment: [:])
        )
        await viewModel.refreshSetup()
        XCTAssertEqual(viewModel.optionalPackStatuses.count, 14)
        var opened: [String] = []
        viewModel.onOpenOptionalPack = { opened.append($0) }
        let window = AccessibilityTreeProbe.host(WelcomeView(viewModel: viewModel), size: CGSize(width: 1_100, height: 700))
        windows.append(window)

        AccessibilityTreeProbe.waitUntil {
            AccessibilityTreeProbe.element(in: window, identifier: "welcome-nav-optional-tools") != nil
        }
        let nav = try XCTUnwrap(
            AccessibilityTreeProbe.element(in: window, identifier: "welcome-nav-optional-tools"),
            "tree:\n" + AccessibilityTreeProbe.dump(window)
        )
        XCTAssertEqual(AccessibilityTreeProbe.role(nav), NSAccessibility.Role.button.rawValue)
        XCTAssertTrue(AccessibilityTreeProbe.press(nav))

        AccessibilityTreeProbe.waitUntil {
            AccessibilityTreeProbe.element(in: window, identifier: "welcome-optional-tool-open-pack-14") != nil
        }
        for index in [1, 7, 14] {
            let identifier = String(format: "welcome-optional-tool-open-pack-%02d", index)
            let button = try XCTUnwrap(
                AccessibilityTreeProbe.element(in: window, identifier: identifier),
                "\(identifier) missing; tree:\n" + AccessibilityTreeProbe.dump(window)
            )
            XCTAssertEqual(AccessibilityTreeProbe.role(button), NSAccessibility.Role.button.rawValue)
            XCTAssertEqual(AccessibilityTreeProbe.label(button), "Open Pack \(index)")
        }
        let last = try XCTUnwrap(AccessibilityTreeProbe.element(in: window, identifier: "welcome-optional-tool-open-pack-14"))
        XCTAssertTrue(AccessibilityTreeProbe.press(last))
        XCTAssertEqual(opened, ["pack-14"])
        let opaque = AccessibilityTreeProbe.all(in: window).filter {
            (AccessibilityTreeProbe.role($0) ?? "").contains("OpaqueProvider")
                || (AccessibilityTreeProbe.subrole($0) ?? "").contains("OpaqueProvider")
        }
        XCTAssertTrue(opaque.isEmpty)
    }
}
