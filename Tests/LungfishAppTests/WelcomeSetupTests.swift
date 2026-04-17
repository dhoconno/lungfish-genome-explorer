import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

private actor StubWelcomePackStatusProvider: PluginPackStatusProviding {
    var statuses: [PluginPackStatus]

    init(statuses: [PluginPackStatus]) {
        self.statuses = statuses
    }

    func visibleStatuses() async -> [PluginPackStatus] {
        statuses
    }

    func status(for pack: PluginPack) async -> PluginPackStatus {
        statuses.first(where: { $0.pack.id == pack.id })!
    }

    func install(
        pack: PluginPack,
        reinstall: Bool,
        progress: (@Sendable (PluginPackInstallProgress) -> Void)?
    ) async throws {
        progress?(PluginPackInstallProgress(
            requirementID: nil,
            requirementDisplayName: nil,
            overallFraction: 1.0,
            itemFraction: 1.0,
            message: "Installed"
        ))
    }
}

@MainActor
final class WelcomeSetupTests: XCTestCase {

    func testWelcomeWindowUsesStandardTitlebarChrome() {
        let controller = WelcomeWindowController()
        guard let window = controller.window else {
            XCTFail("Expected welcome window")
            return
        }

        XCTAssertFalse(window.titlebarAppearsTransparent)
        XCTAssertFalse(window.isMovableByWindowBackground)
        XCTAssertGreaterThanOrEqual(window.contentMinSize.width, 980)
        XCTAssertGreaterThanOrEqual(window.contentMinSize.height, 640)
        XCTAssertLessThanOrEqual(window.contentMinSize.height, 700)
    }

    func testWelcomeViewSourceOmitsBrandingHeaderStack() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/Welcome/WelcomeWindowController.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("Image(nsImage: Self.loadLogo())"))
        XCTAssertFalse(source.contains("Text(\"Lungfish Genome Explorer\")"))
        XCTAssertFalse(source.contains("Text(\"Seeing the invisible. Informing action.\")"))
    }

    func testWelcomeViewSourceIncludesSidebarNavigationSections() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/Welcome/WelcomeWindowController.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("Get Started"))
        XCTAssertTrue(source.contains("Recent Projects"))
        XCTAssertTrue(source.contains("Required Setup"))
        XCTAssertTrue(source.contains("Optional Tools"))
    }

    func testWelcomeViewSourceUsesCoreToolsStatusCopy() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/Welcome/WelcomeWindowController.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("Lungfish Tools Ready"))
        XCTAssertTrue(source.contains("Core Tools Installed"))
    }

    func testWelcomeViewSourceUsesLungfishOrangeSidebarTintAndNoVerticalFixedSize() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/Welcome/WelcomeWindowController.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("Color.lungfishOrangeFallback"))
        XCTAssertFalse(source.contains(".fixedSize(horizontal: false, vertical: true)"))
    }

    func testAvailableActionsExcludeOpenFiles() {
        XCTAssertEqual(WelcomeAction.allCases, [.createProject, .openProject])
    }

    func testLaunchRemainsDisabledUntilRequiredSetupIsReady() async {
        let required = PluginPackStatus(
            pack: .requiredSetupPack,
            state: .needsInstall,
            toolStatuses: [],
            failureMessage: nil
        )
        let optional = PluginPackStatus(
            pack: PluginPack.activeOptionalPacks[0],
            state: .needsInstall,
            toolStatuses: [],
            failureMessage: nil
        )

        let viewModel = WelcomeViewModel(
            statusProvider: StubWelcomePackStatusProvider(statuses: [required, optional])
        )
        await viewModel.refreshSetup()

        XCTAssertFalse(viewModel.canLaunch)
        XCTAssertEqual(viewModel.optionalPackStatuses.map(\.pack.id), ["metagenomics"])
    }

    func testLaunchEnablesWhenRequiredSetupIsReady() async {
        let required = PluginPackStatus(
            pack: .requiredSetupPack,
            state: .ready,
            toolStatuses: [],
            failureMessage: nil
        )

        let viewModel = WelcomeViewModel(
            statusProvider: StubWelcomePackStatusProvider(statuses: [required])
        )
        await viewModel.refreshSetup()

        XCTAssertTrue(viewModel.canLaunch)
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
