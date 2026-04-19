import XCTest

final class DatabaseSearchDialogSourceTests: XCTestCase {
    func testDatabaseSearchDialogReusesSharedOperationsShell() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/DatabaseBrowser/DatabaseSearchDialog.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("DatasetOperationsDialog("))
        XCTAssertTrue(source.contains("DatabaseSearchDialogShell"))
        XCTAssertTrue(source.contains("@ObservedObject var viewModel: DatabaseBrowserViewModel"))
        XCTAssertTrue(source.contains("primaryActionTitle: primaryActionTitle"))
        XCTAssertTrue(source.contains("onRun: state.performPrimaryAction"))
        XCTAssertTrue(source.contains("switch state.selectedDestination"))
    }

    func testDatabaseSearchDialogDeclaresReusableXCUIIdentifiers() throws {
        let shellSource = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/Operations/DatasetOperationsDialog.swift"),
            encoding: .utf8
        )
        let dialogSource = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/DatabaseBrowser/DatabaseSearchDialog.swift"),
            encoding: .utf8
        )
        let paneSource = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/DatabaseBrowser/DatabaseBrowserPane.swift"),
            encoding: .utf8
        )
        let genbankSource = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/DatabaseBrowser/GenBankGenomesSearchPane.swift"),
            encoding: .utf8
        )
        let pathoplexusSource = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/DatabaseBrowser/PathoplexusSearchPane.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(shellSource.contains("accessibilityNamespace"))
        XCTAssertTrue(dialogSource.contains("accessibilityNamespace: \"database-search\""))
        XCTAssertTrue(shellSource.contains("accessibilitySlug"))
        XCTAssertTrue(paneSource.contains("database-search-query-field"))
        XCTAssertTrue(paneSource.contains("database-search-results-list"))
        XCTAssertTrue(paneSource.contains("database-search-result-"))
        XCTAssertTrue(genbankSource.contains("database-search-ncbi-mode-picker"))
        XCTAssertTrue(pathoplexusSource.contains("database-search-pathoplexus-consent-accept"))
        XCTAssertTrue(pathoplexusSource.contains("database-search-pathoplexus-consent-cancel"))
    }

    func testGenBankGenomesPaneExposesNCBIModePicker() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/DatabaseBrowser/GenBankGenomesSearchPane.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(#"Picker("Mode", selection: $viewModel.ncbiSearchType)"#))
        XCTAssertTrue(source.contains("Nucleotide"))
        XCTAssertTrue(source.contains("Genome"))
        XCTAssertTrue(source.contains("Virus"))
        XCTAssertTrue(source.contains("RefSeq Only"))
    }

    func testSRARunsPaneImportsAccessionListsExplicitly() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/DatabaseBrowser/SRARunsSearchPane.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(#"Button("Import Accessions")"#))
        XCTAssertTrue(source.contains("viewModel.importAccessionList()"))
    }

    func testSharedBrowserPaneUsesTextFirstSearchScaffold() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/DatabaseBrowser/DatabaseBrowserPane.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("AppKitTextField"))
        XCTAssertTrue(source.contains(#"Button("Search")"#))
        XCTAssertTrue(source.contains("ProgressView"))
        XCTAssertTrue(source.contains("List"))
        XCTAssertTrue(source.contains("DatabaseSearchResultRow"))
        XCTAssertTrue(source.contains(".tint(.lungfishCreamsicleFallback)"))
        XCTAssertTrue(source.contains("SearchScope.allCases"))
        XCTAssertTrue(source.contains("Advanced Search Filters"))
        XCTAssertTrue(source.contains("viewModel.clearFilters()"))
    }

    func testUnifiedSearchFilesDoNotUseLegacyAccentColor() throws {
        let files = [
            "Sources/LungfishApp/Views/DatabaseBrowser/DatabaseBrowserPane.swift",
            "Sources/LungfishApp/Views/DatabaseBrowser/GenBankGenomesSearchPane.swift",
            "Sources/LungfishApp/Views/DatabaseBrowser/SRARunsSearchPane.swift",
            "Sources/LungfishApp/Views/DatabaseBrowser/PathoplexusSearchPane.swift",
        ]

        for file in files {
            let source = try String(
                contentsOf: repositoryRoot().appendingPathComponent(file),
                encoding: .utf8
            )
            XCTAssertFalse(source.contains("Color.accentColor"), file)
        }
    }

    func testPathoplexusPaneKeepsConsentGateAndOrganismSelector() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/DatabaseBrowser/PathoplexusSearchPane.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("isShowingPathoplexusConsent"))
        XCTAssertTrue(source.contains("I Understand and Agree"))
        XCTAssertTrue(source.contains("Cancel"))
        XCTAssertTrue(source.contains("Organism"))
        XCTAssertTrue(source.contains("pathoplexusOrganisms"))
        XCTAssertTrue(source.contains("PathoplexusChipFlowLayout"))
        XCTAssertTrue(source.contains("consent-aware browsing"))
        XCTAssertTrue(source.contains("organism targeting"))
    }

    func testDatabaseBrowserControllerHostsUnifiedSearchDialog() throws {
        let source = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Sources/LungfishApp/Views/DatabaseBrowser/DatabaseBrowserViewController.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("DatabaseSearchDialog(state: dialogState)"))
        XCTAssertFalse(source.contains("public struct DatabaseBrowserView: View"))
        XCTAssertFalse(source.contains("DatabaseBrowserLegacyView"))
        XCTAssertFalse(source.contains("#if false"))
    }

    func testUnifiedSearchFilesDoNotUseLegacyDecorativeSystemImages() throws {
        let files = [
            "Sources/LungfishApp/Views/DatabaseBrowser/DatabaseBrowserPane.swift",
            "Sources/LungfishApp/Views/DatabaseBrowser/GenBankGenomesSearchPane.swift",
            "Sources/LungfishApp/Views/DatabaseBrowser/SRARunsSearchPane.swift",
            "Sources/LungfishApp/Views/DatabaseBrowser/PathoplexusSearchPane.swift",
        ]
        let bannedSymbols = [
            "doc.text.magnifyingglass",
            "building.columns",
            "globe.europe.africa",
            "microbe",
            "clock.arrow.circlepath",
            "line.3.horizontal.decrease.circle",
            "slider.horizontal.3",
        ]

        for file in files {
            let source = try String(
                contentsOf: repositoryRoot().appendingPathComponent(file),
                encoding: .utf8
            )
            for symbol in bannedSymbols {
                XCTAssertFalse(source.contains(#"Image(systemName: "\#(symbol)")"#), "\(file) contains \(symbol)")
            }
        }
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
