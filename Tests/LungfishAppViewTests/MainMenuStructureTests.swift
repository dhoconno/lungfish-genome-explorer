import AppKit
@testable import LungfishCore
import LungfishKit
import XCTest
@testable import LungfishApp

@MainActor
final class MainMenuStructureTests: XCTestCase {
    func testFileMenuExplainsPersistenceInsteadOfOfferingUnimplementedDocumentSave() throws {
        _ = NSApplication.shared
        let menu = try XCTUnwrap(MainMenu.createMainMenu().items.first { $0.title == "File" }?.submenu)
        XCTAssertFalse(menu.items.contains { $0.action == #selector(NSDocument.save(_:)) || $0.action == #selector(NSDocument.saveAs(_:)) })
        let explanation = try XCTUnwrap(menu.items.first { $0.title == "About Saving…" })
        XCTAssertNotNil(explanation.action)
    }

    func testFileMenuReplacesClearTemporaryFilesWithStorageManager() throws {
        _ = NSApplication.shared
        let fileMenu = try XCTUnwrap(
            MainMenu.createMainMenu()
                .items
                .first(where: { $0.title == "File" })?
                .submenu
        )
        let item = try XCTUnwrap(
            fileMenu.items.first(where: {
                $0.title == "Manage Project Storage…"
            })
        )

        XCTAssertEqual(
            item.identifier?.rawValue,
            MainMenuAccessibilityID.manageProjectStorage
        )
        XCTAssertEqual(
            item.action,
            #selector(AppDelegate.manageProjectStorage(_:))
        )
        XCTAssertNil(
            fileMenu.items.first(where: {
                $0.title == "Clear Temporary Files…"
            })
        )
    }

    func testContentTextSizeSubmenuHasStableItemsActionsAndShortcuts() throws {
        _ = NSApplication.shared
        let mainMenu = MainMenu.createMainMenu()
        let viewMenu = try XCTUnwrap(
            mainMenu.items.first(where: { $0.title == "View" })?.submenu
        )
        let contentTextSizeItem = try XCTUnwrap(
            viewMenu.items.first(where: { $0.title == "Content Text Size" })
        )
        let contentTextSizeMenu = try XCTUnwrap(contentTextSizeItem.submenu)
        let larger = try XCTUnwrap(
            contentTextSizeMenu.items.first(where: { $0.title == "Larger" })
        )
        let smaller = try XCTUnwrap(
            contentTextSizeMenu.items.first(where: { $0.title == "Smaller" })
        )
        let defaultItem = try XCTUnwrap(
            contentTextSizeMenu.items.first(where: { $0.title == "Default" })
        )

        XCTAssertEqual(
            contentTextSizeItem.identifier?.rawValue,
            MainMenuAccessibilityID.contentTextSize
        )
        XCTAssertEqual(
            larger.identifier?.rawValue,
            MainMenuAccessibilityID.contentTextSizeLarger
        )
        XCTAssertEqual(
            smaller.identifier?.rawValue,
            MainMenuAccessibilityID.contentTextSizeSmaller
        )
        XCTAssertEqual(
            defaultItem.identifier?.rawValue,
            MainMenuAccessibilityID.contentTextSizeDefault
        )
        XCTAssertEqual(contentTextSizeItem.accessibilityLabel(), "Content text size")
        XCTAssertEqual(larger.accessibilityLabel(), "Increase content text size")
        XCTAssertEqual(smaller.accessibilityLabel(), "Decrease content text size")
        XCTAssertEqual(
            defaultItem.accessibilityLabel(),
            "Reset content text size to System"
        )
        XCTAssertEqual(larger.action, #selector(ViewMenuActions.increaseContentTextSize(_:)))
        XCTAssertEqual(smaller.action, #selector(ViewMenuActions.decreaseContentTextSize(_:)))
        XCTAssertEqual(defaultItem.action, #selector(ViewMenuActions.resetContentTextSize(_:)))
        XCTAssertEqual(larger.keyEquivalent, "+")
        XCTAssertEqual(smaller.keyEquivalent, "-")
        XCTAssertEqual(defaultItem.keyEquivalent, "0")
        XCTAssertEqual(
            larger.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask),
            [.command, .option]
        )
        XCTAssertEqual(
            smaller.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask),
            [.command, .option]
        )
        XCTAssertEqual(
            defaultItem.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask),
            [.command, .option]
        )
    }

    func testScientificZoomShortcutsRemainCommandOnly() throws {
        _ = NSApplication.shared
        let mainMenu = MainMenu.createMainMenu()
        let viewMenu = try XCTUnwrap(
            mainMenu.items.first(where: { $0.title == "View" })?.submenu
        )
        let cases = [
            ("Zoom In", "+"),
            ("Zoom Out", "-"),
            ("Zoom to Fit", "0"),
        ]

        for (title, keyEquivalent) in cases {
            let item = try XCTUnwrap(viewMenu.items.first(where: { $0.title == title }))
            XCTAssertEqual(item.keyEquivalent, keyEquivalent)
            XCTAssertEqual(
                item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask),
                [.command]
            )
        }
    }

    func testIncreaseContentTextSizeSavesOncePersistsAndAnnounces() {
        preservingAppSettings {
            let delegate = AppDelegate()
            let announcements = RecordingAccessibilityAnnouncementPoster()
            let saves = AppSettingsSaveCounter()
            delegate.contentTextSizeAnnouncementPoster = announcements
            AppSettings.shared.contentTextSizePreference = .system

            delegate.increaseContentTextSize(nil)

            XCTAssertEqual(AppSettings.shared.contentTextSizePreference, .custom(125))
            XCTAssertEqual(saves.count, 1)
            XCTAssertEqual(announcements.messages, ["Content text size 125 percent"])

            AppSettings.shared.contentTextSizePreference = .system
            AppSettings.load()
            XCTAssertEqual(AppSettings.shared.contentTextSizePreference, .custom(125))
        }
    }

    func testDecreaseContentTextSizeFromSystemUsesNinetyPercent() {
        preservingAppSettings {
            let delegate = AppDelegate()
            let announcements = RecordingAccessibilityAnnouncementPoster()
            let saves = AppSettingsSaveCounter()
            delegate.contentTextSizeAnnouncementPoster = announcements
            AppSettings.shared.contentTextSizePreference = .system

            delegate.decreaseContentTextSize(nil)

            XCTAssertEqual(AppSettings.shared.contentTextSizePreference, .custom(90))
            XCTAssertEqual(saves.count, 1)
            XCTAssertEqual(announcements.messages, ["Content text size 90 percent"])
        }
    }

    func testResetContentTextSizeRestoresSystemAndSavesOnce() {
        preservingAppSettings {
            let delegate = AppDelegate()
            let announcements = RecordingAccessibilityAnnouncementPoster()
            let saves = AppSettingsSaveCounter()
            delegate.contentTextSizeAnnouncementPoster = announcements
            AppSettings.shared.contentTextSizePreference = .custom(175)

            delegate.resetContentTextSize(nil)

            XCTAssertEqual(AppSettings.shared.contentTextSizePreference, .system)
            XCTAssertEqual(saves.count, 1)
            XCTAssertEqual(announcements.messages, ["Content text size System"])
        }
    }

    func testContentTextSizeActionsValidateBoundsAndNoOpAtBounds() {
        preservingAppSettings {
            let delegate = AppDelegate()
            let announcements = RecordingAccessibilityAnnouncementPoster()
            let saves = AppSettingsSaveCounter()
            delegate.contentTextSizeAnnouncementPoster = announcements
            let larger = NSMenuItem(
                title: "Larger",
                action: #selector(AppDelegate.increaseContentTextSize(_:)),
                keyEquivalent: "+"
            )
            let smaller = NSMenuItem(
                title: "Smaller",
                action: #selector(AppDelegate.decreaseContentTextSize(_:)),
                keyEquivalent: "-"
            )
            let defaultItem = NSMenuItem(
                title: "Default",
                action: #selector(AppDelegate.resetContentTextSize(_:)),
                keyEquivalent: "0"
            )

            AppSettings.shared.contentTextSizePreference = .custom(200)
            XCTAssertFalse(delegate.validateMenuItem(larger))
            XCTAssertTrue(delegate.validateMenuItem(smaller))
            XCTAssertTrue(delegate.validateMenuItem(defaultItem))
            delegate.increaseContentTextSize(nil)

            AppSettings.shared.contentTextSizePreference = .custom(90)
            XCTAssertTrue(delegate.validateMenuItem(larger))
            XCTAssertFalse(delegate.validateMenuItem(smaller))
            XCTAssertTrue(delegate.validateMenuItem(defaultItem))
            delegate.decreaseContentTextSize(nil)

            AppSettings.shared.contentTextSizePreference = .system
            XCTAssertTrue(delegate.validateMenuItem(larger))
            XCTAssertTrue(delegate.validateMenuItem(smaller))
            XCTAssertFalse(delegate.validateMenuItem(defaultItem))
            delegate.resetContentTextSize(nil)

            XCTAssertEqual(saves.count, 0)
            XCTAssertTrue(announcements.messages.isEmpty)
        }
    }

    func testAppearanceRestoreDefaultsPersistsSystemWithOneNarrowNotification() {
        preservingAppSettings {
            let settings = AppSettings.shared
            settings.resetSection(.appearance)
            settings.contentTextSizePreference = .custom(175)
            settings.sequenceAppearance.baseColors["A"] = "#123456"
            settings.annotationTypeColorHexes["gene"] = "#654321"
            settings.variantColorThemeName = "High Contrast"
            settings.defaultAnnotationHeight = 32
            settings.defaultAnnotationSpacing = 8
            settings.horizontalScrollDirection = .natural
            settings.verticalScrollDirection = .traditional
            settings.save()
            let saves = AppSettingsSaveCounter()
            let contentTextSizeChanges = ContentTextSizeNotificationCounter()
            let variantThemeChanges = VariantThemeNotificationCounter()
            var colorReloadCount = 0
            let persistence = AppearanceSettingsPersistence(
                settings: settings,
                notificationCenter: .default
            )

            persistence.restoreDefaults {
                colorReloadCount += 1
            }

            XCTAssertEqual(settings.contentTextSizePreference, .system)
            XCTAssertEqual(settings.sequenceAppearance, .default)
            XCTAssertEqual(
                settings.annotationTypeColorHexes,
                AppSettings.defaultAnnotationTypeColorHexes
            )
            XCTAssertEqual(settings.variantColorThemeName, "Modern")
            XCTAssertEqual(settings.defaultAnnotationHeight, 16)
            XCTAssertEqual(settings.defaultAnnotationSpacing, 2)
            XCTAssertEqual(settings.horizontalScrollDirection, .traditional)
            XCTAssertEqual(settings.verticalScrollDirection, .system)
            XCTAssertEqual(saves.count, 1)
            XCTAssertEqual(contentTextSizeChanges.count, 1)
            XCTAssertEqual(variantThemeChanges.count, 1)
            XCTAssertEqual(colorReloadCount, 1)

            settings.contentTextSizePreference = .custom(175)
            AppSettings.load()
            XCTAssertEqual(
                settings.contentTextSizePreference,
                .system,
                "Restore Defaults must persist System, not only update the in-memory picker"
            )
        }
    }

    func testDirectUserVariantThemeChangeSavesAndNotifiesExactlyOnce() {
        preservingAppSettings {
            let settings = AppSettings.shared
            settings.resetSection(.appearance)
            settings.save()
            let saves = AppSettingsSaveCounter()
            let contentTextSizeChanges = ContentTextSizeNotificationCounter()
            let variantThemeChanges = VariantThemeNotificationCounter()
            let persistence = AppearanceSettingsPersistence(
                settings: settings,
                notificationCenter: .default
            )

            persistence.updateVariantTheme("High Contrast")
            persistence.updateVariantTheme("High Contrast")

            XCTAssertEqual(settings.variantColorThemeName, "High Contrast")
            XCTAssertEqual(saves.count, 1)
            XCTAssertEqual(contentTextSizeChanges.count, 0)
            XCTAssertEqual(variantThemeChanges.count, 1)
        }
    }

    private func preservingAppSettings(_ body: () -> Void) {
        let typographySuiteName = "LungfishTypographyTests.\(UUID().uuidString)"
        let typographyDefaults = UserDefaults(suiteName: typographySuiteName)!
        let restoreSettings = AppSettings.isolateForTesting(defaults: typographyDefaults)
        defer {
            restoreSettings()
            typographyDefaults.removePersistentDomain(forName: typographySuiteName)
        }
        body()
    }
}

@MainActor
private final class RecordingAccessibilityAnnouncementPoster: AccessibilityAnnouncementPosting {
    private(set) var messages: [String] = []

    func post(
        _ message: String,
        priority: ContentAccessibilityAnnouncementPriority
    ) {
        messages.append(message)
    }
}

@MainActor
private final class AppSettingsSaveCounter {
    private(set) var count = 0
    private let notificationCenter: NotificationCenter
    private var token: NSObjectProtocol?

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
        token = notificationCenter.addObserver(
            forName: .appSettingsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.count += 1
            }
        }
    }

    isolated deinit {
        if let token {
            notificationCenter.removeObserver(token)
        }
    }
}

@MainActor
private final class ContentTextSizeNotificationCounter {
    private(set) var count = 0
    private let notificationCenter: NotificationCenter
    private var token: NSObjectProtocol?

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
        token = notificationCenter.addObserver(
            forName: .contentTextSizeDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.count += 1
            }
        }
    }

    isolated deinit {
        if let token {
            notificationCenter.removeObserver(token)
        }
    }
}

@MainActor
private final class VariantThemeNotificationCounter {
    private(set) var count = 0
    private let notificationCenter: NotificationCenter
    private var token: NSObjectProtocol?

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
        token = notificationCenter.addObserver(
            forName: .variantColorThemeDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.count += 1
            }
        }
    }

    isolated deinit {
        if let token {
            notificationCenter.removeObserver(token)
        }
    }
}
