import AppKit
import SwiftUI
import XCTest
@testable import LungfishCore
@testable import LungfishKit

@MainActor
final class ContentTypographyTests: XCTestCase {
    func testSystemPreferenceUsesPreferredFontsWithoutCustomScaling() {
        let provider = StubPreferredFontProvider()
        let typography = ContentTypography(
            preference: .system,
            preferredFontProvider: provider
        )

        XCTAssertEqual(typography.font(for: .body).pointSize, 13)
        XCTAssertEqual(typography.font(for: .detail).pointSize, 11)
        XCTAssertEqual(typography.font(for: .caption).pointSize, 10)
    }

    func testCustomScalePreservesWeightAndMonospacedDesign() {
        let typography = ContentTypography(
            preference: .custom(200),
            preferredFontProvider: StubPreferredFontProvider()
        )

        let emphasized = typography.font(for: .emphasizedBody)
        let monospaced = typography.font(for: .monospaced)

        XCTAssertEqual(emphasized.pointSize, 26)
        XCTAssertTrue(emphasized.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertEqual(monospaced.pointSize, 26)
        XCTAssertTrue(monospaced.isFixedPitch)
    }

    func testCustomScaleNeverResolvesContentBelowTenPoints() {
        let typography = ContentTypography(
            preference: .custom(90),
            preferredFontProvider: StubPreferredFontProvider()
        )

        XCTAssertEqual(typography.font(for: .caption).pointSize, 10)
    }

    func testTableGeometryGrowsAndRecoversWithoutCompounding() {
        let provider = StubPreferredFontProvider()
        let normal = ContentTypography(
            preference: .custom(100),
            preferredFontProvider: provider
        )
        let large = ContentTypography(
            preference: .custom(200),
            preferredFontProvider: provider
        )
        let recovered = ContentTypography(
            preference: .custom(100),
            preferredFontProvider: provider
        )

        XCTAssertGreaterThan(large.tableRowHeight(), normal.tableRowHeight())
        XCTAssertGreaterThan(large.tableHeaderHeight(), normal.tableHeaderHeight())
        XCTAssertEqual(recovered.tableRowHeight(), normal.tableRowHeight())
        XCTAssertEqual(recovered.tableHeaderHeight(), normal.tableHeaderHeight())
        XCTAssertEqual(recovered.font(for: .body).pointSize, normal.font(for: .body).pointSize)
    }

    func testAllCustomStopsResolveFromBaselineWithAdaptiveGeometry() {
        let provider = StubPreferredFontProvider()
        let cases: [(percentage: Int, expectedBodySize: CGFloat)] = [
            (90, 11.7),
            (100, 13),
            (125, 16.25),
            (150, 19.5),
            (175, 22.75),
            (200, 26),
        ]

        for testCase in cases {
            let typography = ContentTypography(
                preference: .custom(testCase.percentage),
                preferredFontProvider: provider
            )
            let bodyHeight = typography.font(for: .body).boundingRectForFont.height
            let headerHeight = typography.font(for: .tableHeader).boundingRectForFont.height

            XCTAssertEqual(
                typography.font(for: .body).pointSize,
                testCase.expectedBodySize,
                accuracy: 0.001,
                "\(testCase.percentage)% should resolve from the unscaled baseline"
            )
            XCTAssertEqual(
                typography.tableRowHeight(),
                max(22, ceil(bodyHeight + 6)),
                "\(testCase.percentage)% should derive row geometry from its resolved font"
            )
            XCTAssertEqual(
                typography.tableHeaderHeight(),
                max(24, ceil(headerHeight + 7)),
                "\(testCase.percentage)% should derive header geometry from its resolved font"
            )
        }
    }

    func testRealAppKitProviderPreservesSemanticTraits() {
        let typography = ContentTypography(
            preference: .system,
            preferredFontProvider: AppKitContentPreferredFontProvider()
        )

        XCTAssertGreaterThanOrEqual(typography.font(for: .body).pointSize, 10)
        XCTAssertTrue(typography.font(for: .emphasizedBody).fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertTrue(typography.font(for: .tableHeader).fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertTrue(typography.font(for: .monospaced).isFixedPitch)
    }

    func testSwiftUIModelRefreshesFromNarrowNotification() {
        let notificationCenter = NotificationCenter()
        let preference = MutableContentTextSizePreference(.custom(100))
        let model = ContentTypographyModel(
            notificationCenter: notificationCenter,
            preferenceProvider: { preference.value },
            preferredFontProvider: StubPreferredFontProvider()
        )

        XCTAssertEqual(model.resolvedNSFont(for: .body).pointSize, 13)

        preference.value = .custom(200)
        notificationCenter.post(name: .contentTextSizeDidChange, object: nil)

        XCTAssertEqual(model.resolvedNSFont(for: .body).pointSize, 26)
        _ = model.font(for: .body) as Font
    }

    func testSwiftUIModelDeallocationCancelsItsNotificationRegistration() {
        let notifications = TrackingContentTypographyNotifications()
        weak var releasedModel: ContentTypographyModel?

        autoreleasepool {
            let model = ContentTypographyModel(
                notifications: notifications,
                preferenceProvider: { .system },
                preferredFontProvider: StubPreferredFontProvider()
            )
            releasedModel = model
            XCTAssertEqual(notifications.activeRegistrationCount, 1)
        }

        XCTAssertNil(releasedModel)
        XCTAssertEqual(notifications.activeRegistrationCount, 0)
        XCTAssertEqual(notifications.cancellationCount, 1)
    }

    func testRepeatedSwiftUIModelConstructionDoesNotAccumulateRegistrations() {
        let notifications = TrackingContentTypographyNotifications()

        for _ in 0..<20 {
            autoreleasepool {
                _ = ContentTypographyModel(
                    notifications: notifications,
                    preferenceProvider: { .system },
                    preferredFontProvider: StubPreferredFontProvider()
                )
            }
        }

        XCTAssertEqual(notifications.registrationCount, 20)
        XCTAssertEqual(notifications.cancellationCount, 20)
        XCTAssertEqual(notifications.activeRegistrationCount, 0)
        notifications.post(.contentTextSizeDidChange)
        XCTAssertEqual(notifications.callbackInvocationCount, 0)
    }

    func testSystemMonitorPostsOnceOnlyWhenPreferredFontSignatureChanges() {
        let notificationCenter = NotificationCenter()
        let provider = MutablePreferredFontProvider(pointSize: 13)
        let notifications = TypographyNotificationCounter()
        let token = notificationCenter.addObserver(
            forName: .contentTextSizeDidChange,
            object: nil,
            queue: nil
        ) { _ in
            MainActor.assumeIsolated {
                notifications.count += 1
            }
        }
        defer { notificationCenter.removeObserver(token) }
        let monitor = ContentTypographySystemMonitor(
            notificationCenter: notificationCenter,
            preferenceProvider: { .system },
            preferredFontProvider: provider
        )

        monitor.refreshAfterApplicationActivation()
        XCTAssertEqual(notifications.count, 0)

        provider.pointSize = 15
        monitor.refreshAfterApplicationActivation()
        monitor.refreshAfterApplicationActivation()

        XCTAssertEqual(notifications.count, 1)
    }

    func testSystemMonitorIgnoresPreferredFontChangesForCustomScale() {
        let notificationCenter = NotificationCenter()
        let provider = MutablePreferredFontProvider(pointSize: 13)
        let notifications = TypographyNotificationCounter()
        let token = notificationCenter.addObserver(
            forName: .contentTextSizeDidChange,
            object: nil,
            queue: nil
        ) { _ in
            MainActor.assumeIsolated {
                notifications.count += 1
            }
        }
        defer { notificationCenter.removeObserver(token) }
        let monitor = ContentTypographySystemMonitor(
            notificationCenter: notificationCenter,
            preferenceProvider: { .custom(150) },
            preferredFontProvider: provider
        )

        provider.pointSize = 15
        monitor.refreshAfterApplicationActivation()

        XCTAssertEqual(notifications.count, 0)
    }

    func testSystemMonitorStopAndDeallocationCancelAllRegistrations() {
        let notifications = TrackingContentTypographyNotifications()
        var monitor: ContentTypographySystemMonitor? = ContentTypographySystemMonitor(
            notifications: notifications,
            preferenceProvider: { .system },
            preferredFontProvider: StubPreferredFontProvider()
        )

        monitor?.start()
        XCTAssertEqual(notifications.activeRegistrationCount, 2)

        monitor?.stop()
        XCTAssertEqual(notifications.activeRegistrationCount, 0)

        monitor?.start()
        XCTAssertEqual(notifications.activeRegistrationCount, 2)

        weak let releasedMonitor = monitor
        monitor = nil
        XCTAssertNil(releasedMonitor)
        XCTAssertEqual(notifications.activeRegistrationCount, 0)
        XCTAssertEqual(notifications.cancellationCount, 4)
    }

    func testRepeatedSystemMonitorConstructionDoesNotAccumulateRegistrations() {
        let notifications = TrackingContentTypographyNotifications()

        for _ in 0..<20 {
            autoreleasepool {
                let monitor = ContentTypographySystemMonitor(
                    notifications: notifications,
                    preferenceProvider: { .system },
                    preferredFontProvider: StubPreferredFontProvider()
                )
                monitor.start()
            }
        }

        XCTAssertEqual(notifications.registrationCount, 40)
        XCTAssertEqual(notifications.cancellationCount, 40)
        XCTAssertEqual(notifications.activeRegistrationCount, 0)
        notifications.post(NSApplication.didBecomeActiveNotification)
        XCTAssertEqual(notifications.callbackInvocationCount, 0)
    }

    func testSwitchingBackToSystemSynchronizesSignatureBeforeActivation() {
        let notificationCenter = NotificationCenter()
        let preference = MutableContentTextSizePreference(.custom(150))
        let provider = MutablePreferredFontProvider(pointSize: 13)
        let notifications = TypographyNotificationCounter()
        let token = notificationCenter.addObserver(
            forName: .contentTextSizeDidChange,
            object: nil,
            queue: nil
        ) { _ in
            MainActor.assumeIsolated {
                notifications.count += 1
            }
        }
        defer { notificationCenter.removeObserver(token) }
        let monitor = ContentTypographySystemMonitor(
            notificationCenter: notificationCenter,
            preferenceProvider: { preference.value },
            preferredFontProvider: provider
        )
        monitor.start()

        provider.pointSize = 15
        preference.value = .system
        notificationCenter.post(name: .contentTextSizeDidChange, object: nil)
        XCTAssertEqual(notifications.count, 1)

        monitor.refreshAfterApplicationActivation()

        XCTAssertEqual(
            notifications.count,
            1,
            "Returning to System already re-resolves typography and must not announce the same signature again"
        )
    }

    func testAccessibilityAnnouncementPosterUsesInjectedHandler() {
        var received: (String, ContentAccessibilityAnnouncementPriority)?
        let poster = AccessibilityAnnouncementPoster { message, priority in
            received = (message, priority)
        }

        poster.post("Content text size 150 percent", priority: .high)

        XCTAssertEqual(received?.0, "Content text size 150 percent")
        XCTAssertEqual(received?.1, .high)
    }

    func testGenomicSummaryCardsScaleAndRecoverWithAdaptiveHeight() {
        let settings = AppSettings.shared
        let typographySuiteName = "LungfishTypographyTests.\(UUID().uuidString)"
        let typographyDefaults = UserDefaults(suiteName: typographySuiteName)!
        let restoreSettings = AppSettings.isolateForTesting(defaults: typographyDefaults)
        defer {
            restoreSettings()
            typographyDefaults.removePersistentDomain(forName: typographySuiteName)
        }
        let bar = TestGenomicSummaryCardBar()
        bar.setContentPreferredFontProvider(StubPreferredFontProvider())

        settings.contentTextSizePreference = .custom(100)
        settings.save()
        let baseline = bar.testingTypographyMetrics

        settings.contentTextSizePreference = .custom(200)
        settings.save()
        let enlarged = bar.testingTypographyMetrics
        XCTAssertEqual(enlarged.labelPointSize, 18)
        XCTAssertEqual(enlarged.valuePointSize, 26)
        XCTAssertGreaterThan(enlarged.preferredHeight, baseline.preferredHeight)

        settings.contentTextSizePreference = .custom(100)
        settings.save()
        XCTAssertEqual(bar.testingTypographyMetrics, baseline)
    }

    func testGenomicSummaryCardsReflowAtTwoHundredPercentAndExposeFullAccessibility() {
        let settings = AppSettings.shared
        let typographySuiteName = "LungfishTypographyTests.\(UUID().uuidString)"
        let typographyDefaults = UserDefaults(suiteName: typographySuiteName)!
        let restoreSettings = AppSettings.isolateForTesting(defaults: typographyDefaults)
        defer {
            restoreSettings()
            typographyDefaults.removePersistentDomain(forName: typographySuiteName)
        }
        settings.contentTextSizePreference = .custom(200)
        settings.save()
        let bar = FourCardGenomicSummaryCardBar(
            frame: NSRect(x: 0, y: 0, width: 240, height: 200)
        )
        bar.setContentPreferredFontProvider(StubPreferredFontProvider())
        bar.layoutSubtreeIfNeeded()

        let metrics = bar.testingTypographyMetrics
        XCTAssertGreaterThanOrEqual(metrics.cardRowCount, 2)
        XCTAssertGreaterThan(metrics.preferredHeight, 48)
        for frame in bar.testingCardFrames {
            XCTAssertTrue(bar.bounds.contains(frame), "\(frame) escaped \(bar.bounds)")
        }
        let elements = try? XCTUnwrap(bar.accessibilityChildren() as? [NSAccessibilityElement])
        XCTAssertEqual(elements?.count, 4)
        XCTAssertEqual(elements?.first?.accessibilityLabel(), "Total Reads")
        XCTAssertEqual(elements?.first?.accessibilityValue() as? String, "123")
    }

    func testGenomicSummaryCardsWrapLongValuesAndInvalidateAfterCardMutation() {
        let settings = AppSettings.shared
        let typographySuiteName = "LungfishTypographyTests.\(UUID().uuidString)"
        let typographyDefaults = UserDefaults(suiteName: typographySuiteName)!
        let restoreSettings = AppSettings.isolateForTesting(defaults: typographyDefaults)
        defer {
            restoreSettings()
            typographyDefaults.removePersistentDomain(forName: typographySuiteName)
        }
        settings.contentTextSizePreference = .custom(200)
        let bar = MutableGenomicSummaryCardBar(
            frame: NSRect(x: 0, y: 0, width: 180, height: 48)
        )
        bar.setContentPreferredFontProvider(StubPreferredFontProvider())
        var reportedHeights: [CGFloat] = []
        bar.onPreferredContentHeightChanged = { reportedHeights.append($0) }

        bar.values = [
            .init(
                label: "Dominant Species",
                value: "Betacoronavirus extremely-long-scientific-identifier"
            ),
        ]
        bar.cardsDidChange()
        let oneCardHeight = bar.preferredContentHeight
        XCTAssertGreaterThan(oneCardHeight, 80)
        XCTAssertEqual(
            (bar.accessibilityChildren()?.first as? NSAccessibilityElement)?
                .accessibilityValue() as? String,
            "Betacoronavirus extremely-long-scientific-identifier"
        )

        bar.values.append(.init(label: "Database", value: "RefSeq release 999"))
        bar.cardsDidChange()
        XCTAssertGreaterThan(bar.preferredContentHeight, oneCardHeight)
        XCTAssertEqual(bar.accessibilityChildren()?.count, 2)
        XCTAssertEqual(reportedHeights.last, bar.preferredContentHeight)
        XCTAssertEqual(bar.intrinsicContentSize.height, bar.preferredContentHeight)
    }

    func testGenomicSummaryCardsPreserveProviderTraitsWhileAddingSemanticEmphasis() {
        let bar = TestGenomicSummaryCardBar(
            frame: NSRect(x: 0, y: 0, width: 300, height: 80)
        )
        bar.setContentPreferredFontProvider(TraitPreferredFontProvider())

        let metrics = bar.testingTypographyMetrics
        XCTAssertTrue(metrics.labelTraits.contains(.italic))
        XCTAssertTrue(metrics.valueTraits.contains(.italic))
        XCTAssertTrue(metrics.valueTraits.contains(.bold))
        XCTAssertTrue(metrics.valueIsFixedPitch)
    }

    func testGenomicSummaryBarIsHostedAccessibilityGroupWithStableChildrenAndMutationNotification() {
        let bar = MutableGenomicSummaryCardBar(
            frame: NSRect(x: 0, y: 0, width: 96, height: 180)
        )
        bar.values = [.init(label: "Database", value: "RefSeq")]
        bar.cardsDidChange()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 96, height: 180),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = bar
        defer {
            _ = window.makeFirstResponder(nil)
            window.orderOut(nil)
            window.contentView = nil
        }
        let unignored = NSAccessibility.unignoredChildren(
            from: window.accessibilityChildren() ?? []
        )
        XCTAssertTrue(unignored.contains { ($0 as AnyObject) === bar })
        XCTAssertEqual(bar.accessibilityRole(), .group)
        let hostedGroup = unignored.first { ($0 as AnyObject) === bar } as? NSView
        let firstChildren = hostedGroup?.accessibilityChildren()
            as? [NSAccessibilityElement]
        let first = firstChildren?.first
        XCTAssertTrue(
            (bar.accessibilityChildren() as? [NSAccessibilityElement])?.first === first
        )
        XCTAssertTrue(bar.testingCardFrames.allSatisfy(bar.bounds.contains))
        var notifications: [NSAccessibility.Notification] = []
        bar.setTestingAccessibilityNotificationPoster {
            notifications.append($0)
        }

        bar.values[0] = .init(label: "Database", value: "RefSeq release 999")
        bar.cardsDidChange()
        XCTAssertTrue(notifications.contains(.valueChanged))
        XCTAssertTrue(notifications.contains(.layoutChanged))
        XCTAssertFalse(
            (bar.accessibilityChildren() as? [NSAccessibilityElement])?.first === first
        )
        XCTAssertEqual(
            (bar.accessibilityChildren()?.first as? NSAccessibilityElement)?
                .accessibilityValue() as? String,
            "RefSeq release 999"
        )
    }

    func testGenomicSummaryTypographyObserverDoesNotRetainBar() {
        weak var weakBar: TestGenomicSummaryCardBar?
        autoreleasepool {
            let bar = TestGenomicSummaryCardBar()
            weakBar = bar
        }
        XCTAssertNil(weakBar)
        NotificationCenter.default.post(name: .contentTextSizeDidChange, object: nil)
        XCTAssertNil(weakBar)
    }

    func testEveryGenomicSummaryCardHostUsesAdaptiveHeightCallback() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let paths = [
            "Sources/LungfishEsVirituUI/EsVirituResultViewController.swift",
            "Sources/LungfishNaoMgsUI/NaoMgsResultViewController.swift",
            "Sources/LungfishNvdUI/NvdResultViewController.swift",
            "Sources/LungfishTaxTriageUI/TaxTriageResultViewController.swift",
            "Sources/LungfishApp/Views/Metagenomics/TaxonomyViewController.swift",
            "Sources/LungfishApp/Views/Viewer/FASTACollectionViewController.swift",
            "Sources/LungfishApp/Views/Viewer/FASTQDatasetViewController.swift",
        ]
        for path in paths {
            let source = try String(
                contentsOf: root.appendingPathComponent(path),
                encoding: .utf8
            )
            XCTAssertTrue(
                source.contains("onPreferredContentHeightChanged"),
                "\(path) must follow live summary-card height changes"
            )
        }
    }

    func testViewApplicatorScalesPersistentTextAndTableGeometryWithoutCompounding() {
        let settings = AppSettings.shared
        let typographySuiteName = "LungfishTypographyTests.\(UUID().uuidString)"
        let typographyDefaults = UserDefaults(suiteName: typographySuiteName)!
        let restoreSettings = AppSettings.isolateForTesting(defaults: typographyDefaults)
        defer {
            restoreSettings()
            typographyDefaults.removePersistentDomain(forName: typographySuiteName)
        }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        let label = NSTextField(labelWithString: "Primary detail")
        label.font = .systemFont(ofSize: 14, weight: .bold)
        let mono = NSTextField(labelWithString: "NC_000001")
        mono.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        let table = NSTableView()
        table.headerView = NSTableHeaderView()
        table.rowHeight = 22
        [label, mono, table].forEach(root.addSubview)
        let applicator = ContentTypographyViewApplicator(
            preferredFontProvider: StubPreferredFontProvider()
        )

        settings.contentTextSizePreference = .custom(100)
        applicator.apply(to: root)
        let baseline = (label.font, mono.font, table.rowHeight, table.headerView?.frame.height)
        settings.contentTextSizePreference = .custom(200)
        applicator.apply(to: root)
        XCTAssertEqual(label.font?.pointSize, 28)
        XCTAssertEqual(mono.font?.pointSize, 22)
        XCTAssertTrue(label.font?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        XCTAssertTrue(mono.font?.isFixedPitch == true)
        XCTAssertGreaterThan(table.rowHeight, baseline.2)

        applicator.apply(to: root)
        XCTAssertEqual(label.font?.pointSize, 28)
        settings.contentTextSizePreference = .custom(100)
        applicator.apply(to: root)
        XCTAssertEqual(label.font, baseline.0)
        XCTAssertEqual(mono.font, baseline.1)
        XCTAssertEqual(table.rowHeight, baseline.2)
        XCTAssertEqual(table.headerView?.frame.height, baseline.3)
    }

    func testViewApplicatorDoesNotTraverseEveryOutlineItemToPreserveExpansion() {
        let settings = AppSettings.shared
        let typographySuiteName = "LungfishTypographyTests.\(UUID().uuidString)"
        let typographyDefaults = UserDefaults(suiteName: typographySuiteName)!
        let restoreSettings = AppSettings.isolateForTesting(defaults: typographyDefaults)
        defer {
            restoreSettings()
            typographyDefaults.removePersistentDomain(forName: typographySuiteName)
        }
        settings.contentTextSizePreference = .custom(100)
        let dataSource = CountingOutlineDataSource(rowCount: 500)
        let outline = CountingItemLookupOutlineView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 180)
        )
        outline.addTableColumn(
            NSTableColumn(identifier: NSUserInterfaceItemIdentifier("value"))
        )
        outline.outlineTableColumn = outline.tableColumns[0]
        outline.dataSource = dataSource
        outline.reloadData()
        outline.resetItemLookupCount()
        let root = NSView()
        root.addSubview(outline)

        ContentTypographyViewApplicator(
            preferredFontProvider: StubPreferredFontProvider()
        ).apply(to: root)

        XCTAssertLessThanOrEqual(
            outline.itemLookupCount,
            2,
            "Typography updates may resolve only the visible scroll anchor, not scan every outline row."
        )
    }

    func testSemanticallyResolvedMetadataFontUsesInjectedPreferredBodyExactlyOnce() {
        let settings = AppSettings.shared
        let typographySuiteName = "LungfishTypographyTests.\(UUID().uuidString)"
        let typographyDefaults = UserDefaults(suiteName: typographySuiteName)!
        let restoreSettings = AppSettings.isolateForTesting(defaults: typographyDefaults)
        defer {
            restoreSettings()
            typographyDefaults.removePersistentDomain(forName: typographySuiteName)
        }
        let provider = EnlargedBodyPreferredFontProvider()
        let root = NSView()
        let field = ResolvedMetadataTestTextField(
            preferredFontProvider: provider
        )
        field.stringValue = "clinical"
        root.addSubview(field)
        let applicator = ContentTypographyViewApplicator(
            preferredFontProvider: provider
        )

        settings.contentTextSizePreference = .system
        applicator.apply(to: root)
        XCTAssertEqual(field.font?.pointSize ?? 0, 15, accuracy: 0.001)

        settings.contentTextSizePreference = .custom(200)
        applicator.apply(to: root)
        XCTAssertEqual(field.font?.pointSize ?? 0, 30, accuracy: 0.001)
        applicator.apply(to: root)
        XCTAssertEqual(field.font?.pointSize ?? 0, 30, accuracy: 0.001)

        settings.contentTextSizePreference = .custom(100)
        applicator.apply(to: root)
        XCTAssertEqual(field.font?.pointSize ?? 0, 15, accuracy: 0.001)
        settings.contentTextSizePreference = .system
        applicator.apply(to: root)
        XCTAssertEqual(field.font?.pointSize ?? 0, 15, accuracy: 0.001)
    }

    func testViewObservationAppliesInitiallyAndOnContentSizeNotifications() {
        let center = NotificationCenter()
        let root = NSView()
        let label = NSTextField(labelWithString: "Persistent content")
        label.font = .systemFont(ofSize: 13)
        root.addSubview(label)
        let settings = AppSettings.shared
        let typographySuiteName = "LungfishTypographyTests.\(UUID().uuidString)"
        let typographyDefaults = UserDefaults(suiteName: typographySuiteName)!
        let restoreSettings = AppSettings.isolateForTesting(defaults: typographyDefaults)
        defer {
            restoreSettings()
            typographyDefaults.removePersistentDomain(forName: typographySuiteName)
        }
        settings.contentTextSizePreference = .custom(100)
        var applicationCount = 0

        var observation: ContentTypographyViewObservation? =
            ContentTypographyViewObservation(
                notificationCenter: center,
                applicator: ContentTypographyViewApplicator(
                    preferredFontProvider: StubPreferredFontProvider()
                ),
                rootProvider: { root },
                afterApply: { applicationCount += 1 }
            )
        XCTAssertEqual(applicationCount, 1)
        XCTAssertEqual(label.font?.pointSize, 13)

        settings.contentTextSizePreference = .custom(200)
        center.post(name: .contentTextSizeDidChange, object: nil)
        XCTAssertEqual(applicationCount, 2)
        XCTAssertEqual(label.font?.pointSize, 26)

        observation = nil
        center.post(name: .contentTextSizeDidChange, object: nil)
        XCTAssertEqual(applicationCount, 2)
        XCTAssertNil(observation)
    }
}

@MainActor
private final class TestGenomicSummaryCardBar: GenomicSummaryCardBar {
    override var cards: [Card] {
        [Card(label: "Total Reads", value: "123")]
    }
}

@MainActor
private final class FourCardGenomicSummaryCardBar: GenomicSummaryCardBar {
    override var cards: [Card] {
        [
            Card(label: "Total Reads", value: "123"),
            Card(label: "Unique Taxa", value: "42"),
            Card(label: "Mean Coverage", value: "99.9%"),
            Card(label: "Longest Label", value: "1000"),
        ]
    }
}

@MainActor
private final class MutableGenomicSummaryCardBar: GenomicSummaryCardBar {
    var values: [Card] = []
    override var cards: [Card] { values }
}

@MainActor
private final class CountingItemLookupOutlineView: NSOutlineView {
    private(set) var itemLookupCount = 0

    override func item(atRow row: Int) -> Any? {
        itemLookupCount += 1
        return super.item(atRow: row)
    }

    func resetItemLookupCount() {
        itemLookupCount = 0
    }
}

@MainActor
private final class CountingOutlineDataSource: NSObject, NSOutlineViewDataSource {
    private let items: [NSString]

    init(rowCount: Int) {
        items = (0..<rowCount).map { NSString(string: "row-\($0)") }
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        numberOfChildrenOfItem item: Any?
    ) -> Int {
        item == nil ? items.count : 0
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        child index: Int,
        ofItem item: Any?
    ) -> Any {
        items[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        false
    }
}

@MainActor
private final class ResolvedMetadataTestTextField:
    NSTextField,
    ContentTypographySemanticFontProviding
{
    let contentTypographyRole = ContentTypography.Role.body

    init(preferredFontProvider: any ContentPreferredFontProviding) {
        let resolved = ContentTypography(
            preference: .system,
            preferredFontProvider: preferredFontProvider
        ).font(for: .body)
        super.init(frame: .zero)
        font = resolved
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
private struct EnlargedBodyPreferredFontProvider: ContentPreferredFontProviding {
    func preferredFont(for role: ContentTypography.Role) -> NSFont {
        switch role {
        case .emphasizedBody, .tableHeader:
            return .systemFont(ofSize: 15, weight: .semibold)
        case .monospaced:
            return .monospacedSystemFont(ofSize: 15, weight: .regular)
        default:
            return .systemFont(ofSize: 15)
        }
    }

    func canonicalUnscaledPointSize(for role: ContentTypography.Role) -> CGFloat {
        13
    }
}

@MainActor
private struct StubPreferredFontProvider: ContentPreferredFontProviding {
    func preferredFont(for role: ContentTypography.Role) -> NSFont {
        switch role {
        case .body:
            return .systemFont(ofSize: 13)
        case .emphasizedBody:
            return .systemFont(ofSize: 13, weight: .bold)
        case .detail:
            return .systemFont(ofSize: 11)
        case .caption:
            return .systemFont(ofSize: 9)
        case .monospaced:
            return .monospacedSystemFont(ofSize: 13, weight: .regular)
        case .tableHeader:
            return .systemFont(ofSize: 12, weight: .semibold)
        }
    }
}

@MainActor
private struct TraitPreferredFontProvider: ContentPreferredFontProviding {
    func preferredFont(for role: ContentTypography.Role) -> NSFont {
        let manager = NSFontManager.shared
        switch role {
        case .caption:
            return manager.convert(
                .systemFont(ofSize: 9),
                toHaveTrait: .italicFontMask
            )
        case .emphasizedBody:
            let italic = manager.convert(
                .systemFont(ofSize: 13, weight: .bold),
                toHaveTrait: .italicFontMask
            )
            return manager.convert(italic, toHaveTrait: .boldFontMask)
        default:
            return .systemFont(ofSize: 13)
        }
    }
}

@MainActor
private final class MutablePreferredFontProvider: ContentPreferredFontProviding {
    var pointSize: CGFloat

    init(pointSize: CGFloat) {
        self.pointSize = pointSize
    }

    func preferredFont(for role: ContentTypography.Role) -> NSFont {
        switch role {
        case .monospaced:
            return .monospacedSystemFont(ofSize: pointSize, weight: .regular)
        case .emphasizedBody:
            return .systemFont(ofSize: pointSize, weight: .bold)
        default:
            return .systemFont(ofSize: pointSize)
        }
    }
}

@MainActor
private final class MutableContentTextSizePreference {
    var value: ContentTextSizePreference

    init(_ value: ContentTextSizePreference) {
        self.value = value
    }
}

@MainActor
private final class TypographyNotificationCounter {
    var count = 0
}

@MainActor
private final class TrackingContentTypographyNotifications: ContentTypographyNotificationObserving {
    private(set) var registrationCount = 0
    private(set) var cancellationCount = 0
    private(set) var callbackInvocationCount = 0
    private var handlers: [UUID: (name: Notification.Name, handler: () -> Void)] = [:]

    var activeRegistrationCount: Int {
        handlers.count
    }

    func observe(
        _ name: Notification.Name,
        using handler: @escaping @MainActor () -> Void
    ) -> ContentTypographyNotificationObservation {
        let identifier = UUID()
        registrationCount += 1
        handlers[identifier] = (name, handler)
        return ContentTypographyNotificationObservation { [weak self] in
            guard let self, self.handlers.removeValue(forKey: identifier) != nil else {
                return
            }
            self.cancellationCount += 1
        }
    }

    func post(_ name: Notification.Name) {
        for entry in handlers.values where entry.name == name {
            callbackInvocationCount += 1
            entry.handler()
        }
    }
}
