import XCTest
@testable import CenterWord

final class TeleprompterModelTests: XCTestCase {
    func testTokenizerSplitsWhitespace() {
        XCTAssertEqual(
            TeleprompterText.words(in: "one   two\nthree\tfour"),
            ["one", "two", "three", "four"]
        )
    }

    func testTokenizerSplitsCommonDelimiters() {
        XCTAssertEqual(
            TeleprompterText.words(in: "hello-hello /Users/nickita/Applications/CenterWord.app a+b foo_bar one,two|three"),
            ["hello", "-", "hello", "/", "Users", "/", "nickita", "/", "Applications", "/", "CenterWord", ".", "app", "a", "+", "b", "foo", "_", "bar", "one", ",", "two", "|", "three"]
        )
    }

    func testTokenizerKeepsApostrophesInsideWords() {
        XCTAssertEqual(
            TeleprompterText.words(in: "don't we’re it's"),
            ["don't", "we’re", "it's"]
        )
    }

    func testTokenizerTreatsStandaloneQuotesAsSeparateTokens() {
        XCTAssertEqual(
            TeleprompterText.words(in: "'hello' end/'start' a''b"),
            ["'", "hello", "'", "end", "/", "'", "start", "'", "a", "'", "'", "b"]
        )
    }

    func testParseWordsPerMinuteFiltersAndClamps() {
        XCTAssertEqual(TeleprompterLogic.parseWordsPerMinute(from: "320"), 320)
        XCTAssertEqual(TeleprompterLogic.parseWordsPerMinute(from: "0"), 1)
        XCTAssertEqual(TeleprompterLogic.parseWordsPerMinute(from: "999999"), 2_000)
        XCTAssertEqual(TeleprompterLogic.parseWordsPerMinute(from: "2a5b0"), 250)
        XCTAssertNil(TeleprompterLogic.parseWordsPerMinute(from: ""))
    }

    func testStoredDefaultWordsPerMinuteFallsBackWhenUnset() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)

        XCTAssertEqual(
            TeleprompterLogic.storedDefaultWordsPerMinute(userDefaults: defaults),
            TeleprompterLogic.fallbackWordsPerMinute
        )
    }

    func testStoredDefaultWordsPerMinuteClampsSavedValue() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defaults.set(999999, forKey: TeleprompterLogic.defaultWordsPerMinuteKey)

        XCTAssertEqual(
            TeleprompterLogic.storedDefaultWordsPerMinute(userDefaults: defaults),
            2_000
        )
    }

    func testSeekIndexUsesSecondsAtCurrentSpeed() {
        let tokens = Array(repeating: "word", count: 500)
        XCTAssertEqual(
            TeleprompterLogic.seekIndex(currentIndex: 100, bySeconds: 5, wordsPerMinute: 240, tokens: tokens),
            120
        )
        XCTAssertEqual(
            TeleprompterLogic.seekIndex(currentIndex: 100, bySeconds: -5, wordsPerMinute: 240, tokens: tokens),
            80
        )
    }

    func testSeekIndexClampsWithinBounds() {
        let tokens = Array(repeating: "word", count: 40)
        XCTAssertEqual(
            TeleprompterLogic.seekIndex(currentIndex: 2, bySeconds: -5, wordsPerMinute: 300, tokens: tokens),
            0
        )
        XCTAssertEqual(
            TeleprompterLogic.seekIndex(currentIndex: 38, bySeconds: 5, wordsPerMinute: 300, tokens: tokens),
            39
        )
    }

    func testDurationHelpersUseCurrentSpeed() {
        XCTAssertEqual(TeleprompterLogic.wordsToSeek(forSeconds: 5, wordsPerMinute: 240), 20)
        XCTAssertEqual(
            TeleprompterLogic.elapsedSeconds(
                currentIndex: 30,
                tokens: Array(repeating: "word", count: 61),
                wordsPerMinute: 120
            ),
            15,
            accuracy: 0.001
        )
        XCTAssertEqual(
            TeleprompterLogic.remainingSeconds(
                currentIndex: 30,
                tokens: Array(repeating: "word", count: 61),
                wordsPerMinute: 120
            ),
            15,
            accuracy: 0.001
        )
    }

    func testSeparatorTokensUseHalfDuration() {
        let tokens = ["Users", "/", "nickita"]

        XCTAssertEqual(TeleprompterLogic.durationUnits(for: "/"), 0.5)
        XCTAssertEqual(TeleprompterLogic.displayDuration(for: "/", wordsPerMinute: 120), 0.25, accuracy: 0.001)
        XCTAssertEqual(
            TeleprompterLogic.elapsedSeconds(currentIndex: 2, tokens: tokens, wordsPerMinute: 120),
            0.75,
            accuracy: 0.001
        )
    }

    func testReaderFontSizeClampsWithinBounds() {
        XCTAssertEqual(TeleprompterLogic.clampReaderFontSize(12), 36)
        XCTAssertEqual(TeleprompterLogic.clampReaderFontSize(72), 72)
        XCTAssertEqual(TeleprompterLogic.clampReaderFontSize(300), 140)
    }

    func testSetupScreenOnlyAppearsUntilOnboardingIsComplete() {
        let missingPermissionSnapshot = CenterWordPermissionSnapshot(
            accessibility: false,
            listenEvent: false,
            postEvent: false
        )
        let grantedPermissionSnapshot = CenterWordPermissionSnapshot(
            accessibility: false,
            listenEvent: true,
            postEvent: false
        )

        XCTAssertTrue(
            TeleprompterLogic.shouldPresentSetupScreen(
                hasCompletedOnboarding: false,
                permissionSnapshot: missingPermissionSnapshot,
                hotKeyStatus: .registered
            )
        )
        XCTAssertFalse(
            TeleprompterLogic.shouldPresentSetupScreen(
                hasCompletedOnboarding: true,
                permissionSnapshot: grantedPermissionSnapshot,
                hotKeyStatus: .registered
            )
        )
    }

    func testPermissionWarningOnlyShowsAfterOnboardingIfPermissionIsMissing() {
        let missingPermissionSnapshot = CenterWordPermissionSnapshot(
            accessibility: true,
            listenEvent: false,
            postEvent: false
        )
        let grantedPermissionSnapshot = CenterWordPermissionSnapshot(
            accessibility: false,
            listenEvent: true,
            postEvent: false
        )

        XCTAssertFalse(
            TeleprompterLogic.shouldShowPermissionWarning(
                hasCompletedOnboarding: false,
                permissionSnapshot: missingPermissionSnapshot,
                hotKeyStatus: .registered
            )
        )
        XCTAssertTrue(
            TeleprompterLogic.shouldShowPermissionWarning(
                hasCompletedOnboarding: true,
                permissionSnapshot: missingPermissionSnapshot,
                hotKeyStatus: .registered
            )
        )
        XCTAssertFalse(
            TeleprompterLogic.shouldShowPermissionWarning(
                hasCompletedOnboarding: true,
                permissionSnapshot: grantedPermissionSnapshot,
                hotKeyStatus: .registered
            )
        )
    }

    func testClipboardWorkflowOnlyRequiresGlobalShortcutPermission() {
        let shortcutReadySnapshot = CenterWordPermissionSnapshot(
            accessibility: false,
            listenEvent: true,
            postEvent: false
        )

        XCTAssertFalse(
            TeleprompterLogic.shouldPresentSetupScreen(
                hasCompletedOnboarding: false,
                permissionSnapshot: shortcutReadySnapshot,
                hotKeyStatus: .registered
            )
        )
        XCTAssertFalse(
            TeleprompterLogic.shouldShowPermissionWarning(
                hasCompletedOnboarding: true,
                permissionSnapshot: shortcutReadySnapshot,
                hotKeyStatus: .registered
            )
        )
    }

    func testLaunchAgentConfigurationTargetsInstalledApp() {
        let configuration = LaunchAtLoginManager.launchAgentConfiguration(
            bundleIdentifier: "com.nickita.centerword",
            executableURL: URL(fileURLWithPath: "/Users/test/Applications/CenterWord.app/Contents/MacOS/CenterWord"),
            homeDirectoryURL: URL(fileURLWithPath: "/Users/test", isDirectory: true)
        )

        XCTAssertEqual(
            configuration.plistURL.path,
            "/Users/test/Library/LaunchAgents/com.nickita.centerword.plist"
        )
        XCTAssertEqual(configuration.contents["Label"] as? String, "com.nickita.centerword")
        XCTAssertEqual(
            configuration.contents["ProgramArguments"] as? [String],
            ["/Users/test/Applications/CenterWord.app/Contents/MacOS/CenterWord"]
        )
        XCTAssertEqual(
            configuration.contents["AssociatedBundleIdentifiers"] as? [String],
            ["com.nickita.centerword"]
        )
        XCTAssertEqual(configuration.contents["LimitLoadToSessionType"] as? [String], ["Aqua"])
        XCTAssertEqual(configuration.contents["ProcessType"] as? String, "Interactive")
        XCTAssertEqual(
            (configuration.contents["KeepAlive"] as? [String: Bool])?["SuccessfulExit"],
            false
        )
    }
}
