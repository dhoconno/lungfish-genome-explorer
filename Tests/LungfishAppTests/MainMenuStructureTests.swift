import AppKit
import LungfishCore
import LungfishKit
import XCTest
@testable import LungfishApp

@MainActor
final class MainMenuStructureTests: XCTestCase {
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

    private func preservingAppSettings(_ body: () -> Void) {
        let key = "com.lungfish.appSettings"
        let persistedData = UserDefaults.standard.data(forKey: key)
        let originalPreference = AppSettings.shared.contentTextSizePreference
        defer {
            AppSettings.shared.contentTextSizePreference = originalPreference
            if let persistedData {
                UserDefaults.standard.set(persistedData, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
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
